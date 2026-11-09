/* wmtr client: a drop-in winemetal unixlib (exports __wine_unix_call_funcs) that forwards every
 * DXMT winemetal unix call to a host executor over shared memory instead of calling Metal.
 * Built as winemetal.so for the Wine side (x86-64 Linux, or AArch64 Linux for native ARM64EC
 * Wine; x86-64 macOS for the two-process prototype). The transport is pluggable. */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "winemetal_thunks.h"
#include "airconv_thunks.h"
#include "wmtr_wire.h"
#include "wmtr_transport.h"
#include "wmtr_spin.h"

typedef int32_t NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_UNSUCCESSFUL ((NTSTATUS)0xC0000001)
#define STATUS_NOT_SUPPORTED ((NTSTATUS)0xC00000BB)

#define INLINE_IN_MAX (256u << 10) /* larger inputs go through an arena staging block */
#define INLINE_OUT_MAX (48u << 10) /* reply-slot budget for outputs */

static int wmtr_log_level = 1;
/* WMTR_CLIENT_HANDLES=0 turns off client-assigned handles (wmtr_proto.h): pool and encoder creations wait for
 * the host's result again */
static int client_handles = 1;

/* small decimal parser: libc's atoi binds to a glibc 2.38 symbol in new headers (see wmtr_glibc_compat.h) */
static int
env_int(const char *s) {
  int v = 0, neg = s && *s == '-';
  for (s += neg; s && *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0');
  return neg ? -v : v;
}
#define LOG(lvl, ...) do { if (wmtr_log_level >= (lvl)) { fprintf(stderr, "wmtr: " __VA_ARGS__); } } while (0)

/* ---------------------------------------------------------------------------------------------
 * shared state */
static struct wmtr_transport *T;
static struct wmtr_ring *R;
static uint8_t *ring_data;
static struct wmtr_slot *slots;
static pthread_mutex_t ring_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int init_ok;
static _Atomic uint64_t slot_bitmap;
static pthread_key_t slot_key;

/* arena */
struct arena_blob { uint8_t *base; uint64_t size; uint32_t id; };
struct range { uint64_t off, size; };
struct arena_free { struct range *r; int n, cap; };
static struct arena_blob blobs[WMTR_MAX_BLOBS];
static struct arena_free blob_free[WMTR_MAX_BLOBS];
static uint32_t nblobs = 1; /* blob 0 is the ring */
static pthread_mutex_t arena_lock = PTHREAD_MUTEX_INITIALIZER;
/* Trim after a peak: a blob with no live range is "idle". Idle blobs beyond a warm reserve
 * (WMTR_ARENA_KEEP_MB, default 128) that stay idle for WMTR_ARENA_TRIM_MS (default 1000) go back
 * to the host (transport release_blob), so the Mac stops paying for them. The steady-state cost
 * is one compare per sync call; the clock is read only while idle bytes exceed the reserve. */
static uint64_t blob_idle_since[WMTR_MAX_BLOBS]; /* CLOCK_MONOTONIC ns; 0 = in use */
static _Atomic uint64_t arena_idle_bytes;
static uint64_t arena_keep_bytes = UINT64_MAX; /* UINT64_MAX: never release (no transport support) */
static uint64_t arena_trim_ns = 1000000000ull;
uint64_t wmtr_arena_released_blobs, wmtr_arena_released_bytes; /* tests */

static void
slot_release(void *p) {
  int s = (int)(intptr_t)p - 1;
  if (s >= 0) atomic_fetch_and(&slot_bitmap, ~(1ull << s));
}

/* WMTR_TRACE=<path> (debugging): one line per call before and after, with the first parameter words */
#include <sys/syscall.h>
#include <unistd.h>
static FILE *trace_f;
static pthread_mutex_t trace_lock = PTHREAD_MUTEX_INITIALIZER;
static void
trace_call(char tag, uint16_t call, const void *params, uint32_t size, NTSTATUS st) {
  uint64_t q[4] = {0, 0, 0, 0};
  if (call <= 1) q[0] = (uint64_t)(uintptr_t)params;
  else memcpy(q, params, size < sizeof q ? size : sizeof q);
  pthread_mutex_lock(&trace_lock);
  fprintf(trace_f, "%c %ld %u %x %llx %llx %llx %llx\n", tag, (long)syscall(SYS_gettid), call, (unsigned)st,
          (unsigned long long)q[0], (unsigned long long)q[1], (unsigned long long)q[2], (unsigned long long)q[3]);
  pthread_mutex_unlock(&trace_lock);
}

static void
wmtr_init(void) {
  const char *l = getenv("WMTR_LOG");
  if (l) wmtr_log_level = env_int(l);
  const char *ch = getenv("WMTR_CLIENT_HANDLES");
  if (ch && *ch) client_handles = env_int(ch) != 0;
  const char *tp = getenv("WMTR_TRACE");
  if (tp && *tp) {
    char path[512];
    snprintf(path, sizeof path, "%s.%d", tp, (int)getpid());
    if ((trace_f = fopen(path, "w"))) setvbuf(trace_f, NULL, _IOLBF, 0);
  }
  pthread_key_create(&slot_key, slot_release);
  T = wmtr_transport_create();
  if (!T) { LOG(0, "no transport\n"); return; }
  uint8_t *base = T->open_ring(T, WMTR_RING_BLOB_BYTES);
  if (!base) { LOG(0, "open_ring failed\n"); return; }
  R = (struct wmtr_ring *)base;
  ring_data = base + WMTR_RING_DATA_OFFSET;
  slots = (struct wmtr_slot *)(base + WMTR_SLOTS_OFFSET);
  blobs[0].base = base; blobs[0].size = WMTR_RING_BLOB_BYTES; blobs[0].id = 0;
  if (T->release_blob) {
    const char *k = getenv("WMTR_ARENA_KEEP_MB"), *tm = getenv("WMTR_ARENA_TRIM_MS");
    int keep_mb = k && *k ? env_int(k) : 128, trim_ms = tm && *tm ? env_int(tm) : 1000;
    if (keep_mb >= 0) arena_keep_bytes = (uint64_t)keep_mb << 20;
    if (trim_ms >= 0) arena_trim_ns = (uint64_t)trim_ms * 1000000ull;
  }
  init_ok = 1;
  LOG(1, "connected: ring %llu bytes, %d slots\n", (unsigned long long)WMTR_RING_BLOB_BYTES, WMTR_SLOTS);
}

static int
my_slot(void) {
  intptr_t v = (intptr_t)pthread_getspecific(slot_key);
  if (v) return (int)v - 1;
  for (;;) {
    uint64_t m = atomic_load(&slot_bitmap);
    if (m == ~0ull) { sched_yield(); continue; }
    int s = __builtin_ctzll(~m);
    if (atomic_compare_exchange_weak(&slot_bitmap, &m, m | (1ull << s))) {
      pthread_setspecific(slot_key, (void *)(intptr_t)(s + 1));
      return s;
    }
  }
}

/* ---------------------------------------------------------------------------------------------
 * arena allocator: page-granular first fit per blob; freed ranges also come back from the host
 * (NoCopy MTLBuffer deallocator) through the ring's free queue. */
static void
range_add(struct arena_free *f, uint64_t off, uint64_t size) {
  int i = 0;
  while (i < f->n && f->r[i].off < off) i++;
  /* merge with neighbours */
  if (i > 0 && f->r[i - 1].off + f->r[i - 1].size == off) {
    f->r[i - 1].size += size;
    if (i < f->n && f->r[i - 1].off + f->r[i - 1].size == f->r[i].off) {
      f->r[i - 1].size += f->r[i].size;
      memmove(&f->r[i], &f->r[i + 1], (f->n - i - 1) * sizeof(*f->r));
      f->n--;
    }
    return;
  }
  if (i < f->n && off + size == f->r[i].off) { f->r[i].off = off; f->r[i].size += size; return; }
  if (f->n == f->cap) { f->cap = f->cap ? f->cap * 2 : 16; f->r = realloc(f->r, f->cap * sizeof(*f->r)); }
  memmove(&f->r[i + 1], &f->r[i], (f->n - i) * sizeof(*f->r));
  f->r[i].off = off; f->r[i].size = size; f->n++;
}

static uint64_t now_ns(void);

/* returns a range to blob `b`; a blob whose whole size is free becomes idle */
static void
arena_put_locked(uint32_t b, uint64_t off, uint64_t size) {
  struct arena_free *f = &blob_free[b];
  range_add(f, off, size);
  if (!blob_idle_since[b] && f->n == 1 && f->r[0].off == 0 && f->r[0].size == blobs[b].size) {
    blob_idle_since[b] = arena_keep_bytes == UINT64_MAX ? 1 : now_ns();
    atomic_fetch_add_explicit(&arena_idle_bytes, blobs[b].size, memory_order_relaxed);
  }
}

static void
drain_host_frees_locked(void) {
  uint64_t h = __atomic_load_n(&R->free_head, __ATOMIC_ACQUIRE), t = R->free_tail;
  for (; t < h; t++) {
    struct wmtr_free_entry e = R->free_ring[t % WMTR_FREE_RING];
    if (e.blob && e.blob < nblobs && blobs[e.blob].base) arena_put_locked(e.blob, e.offset, e.size);
  }
  __atomic_store_n(&R->free_tail, t, __ATOMIC_RELEASE);
}

static uint64_t
now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* releases blobs that have been idle for arena_trim_ns while idle bytes exceed the reserve,
 * highest blob number first (low blobs stay as the warm pool) */
static void
arena_trim_locked(void) {
  if (atomic_load_explicit(&arena_idle_bytes, memory_order_relaxed) <= arena_keep_bytes) return;
  uint64_t now = now_ns();
  for (uint32_t b = nblobs - 1; b >= 1; b--) {
    if (atomic_load_explicit(&arena_idle_bytes, memory_order_relaxed) <= arena_keep_bytes) break;
    if (!blob_idle_since[b] || now - blob_idle_since[b] < arena_trim_ns) continue;
    uint64_t size = blobs[b].size;
    T->release_blob(T, b, blobs[b].base, size);
    blobs[b].base = NULL; blobs[b].size = 0;
    blob_free[b].n = 0;
    blob_idle_since[b] = 0;
    atomic_fetch_sub_explicit(&arena_idle_bytes, size, memory_order_relaxed);
    wmtr_arena_released_blobs++; wmtr_arena_released_bytes += size;
    LOG(2, "arena blob %u released: %llu MiB\n", b, (unsigned long long)(size >> 20));
  }
}

static void *
arena_alloc(uint64_t size, uint32_t *blob_out, uint32_t *off_out) {
  size = (size + WMTR_PAGE - 1) & ~(uint64_t)(WMTR_PAGE - 1);
  pthread_mutex_lock(&arena_lock);
  drain_host_frees_locked();
  for (uint32_t b = 1; b < nblobs; b++) {
    struct arena_free *f = &blob_free[b];
    for (int i = 0; i < f->n; i++) {
      if (f->r[i].size >= size) {
        if (blob_idle_since[b]) {
          blob_idle_since[b] = 0;
          atomic_fetch_sub_explicit(&arena_idle_bytes, blobs[b].size, memory_order_relaxed);
        }
        uint64_t off = f->r[i].off;
        f->r[i].off += size; f->r[i].size -= size;
        if (!f->r[i].size) { memmove(&f->r[i], &f->r[i + 1], (f->n - i - 1) * sizeof(*f->r)); f->n--; }
        pthread_mutex_unlock(&arena_lock);
        *blob_out = b; *off_out = (uint32_t)off;
        return blobs[b].base + off;
      }
    }
  }
  uint32_t b = 1;
  while (b < nblobs && blobs[b].base) b++; /* reuse the number of a released blob */
  if (b == WMTR_MAX_BLOBS) { pthread_mutex_unlock(&arena_lock); return NULL; }
  uint64_t bsize = size > WMTR_ARENA_BLOB_BYTES ? size : WMTR_ARENA_BLOB_BYTES;
  uint8_t *p = T->add_blob(T, b, bsize);
  if (!p) { pthread_mutex_unlock(&arena_lock); LOG(0, "add_blob %u (%llu bytes) failed\n", b, (unsigned long long)bsize); return NULL; }
  blobs[b].base = p; blobs[b].size = bsize; blobs[b].id = b;
  if (b == nblobs) nblobs++;
  if (bsize > size) range_add(&blob_free[b], size, bsize - size);
  pthread_mutex_unlock(&arena_lock);
  LOG(2, "arena blob %u: %llu MiB\n", b, (unsigned long long)(bsize >> 20));
  *blob_out = b; *off_out = 0;
  return p;
}

static void
arena_free(uint32_t blob, uint32_t off, uint64_t size) {
  size = (size + WMTR_PAGE - 1) & ~(uint64_t)(WMTR_PAGE - 1);
  pthread_mutex_lock(&arena_lock);
  arena_put_locked(blob, off, size);
  arena_trim_locked();
  pthread_mutex_unlock(&arena_lock);
}

/* after a sync call: take the host's frees and trim, only when there is something to do */
static void
arena_maintain(void) {
  if (__atomic_load_n(&R->free_head, __ATOMIC_RELAXED) == R->free_tail &&
      atomic_load_explicit(&arena_idle_bytes, memory_order_relaxed) <= arena_keep_bytes)
    return;
  pthread_mutex_lock(&arena_lock);
  drain_host_frees_locked();
  arena_trim_locked();
  pthread_mutex_unlock(&arena_lock);
}

/* ---------------------------------------------------------------------------------------------
 * request builder (thread-local scratch) */
#define MAX_OUT 32
#define MAX_STAGE 8
struct out_dst { void *dst; uint32_t size; uint8_t *arena; /* non-NULL: output landed in arena */ };
struct stage { uint32_t blob, off; uint64_t size; };
struct builder {
  uint8_t *buf; uint32_t cap, len; /* payload */
  uint32_t params_size;
  uint32_t *relocs; int n_reloc, cap_reloc;
  struct wmtr_out outs[MAX_OUT]; struct out_dst dsts[MAX_OUT]; int n_out;
  struct stage stages[MAX_STAGE]; int n_stage;
  int force_sync;
  int error;
};
static __thread struct builder B;

static uint32_t
b_grow(uint32_t need) {
  if (B.len + need > B.cap) {
    uint32_t nc = B.cap ? B.cap : 65536;
    while (nc < B.len + need) nc *= 2;
    B.buf = realloc(B.buf, nc);
    B.cap = nc;
  }
  uint32_t o = B.len;
  B.len += WMTR_ALIGN8(need);
  return o;
}

static void
b_begin(const void *params, uint32_t size) {
  B.len = 0; B.n_reloc = 0; B.n_out = 0; B.n_stage = 0; B.force_sync = 0; B.error = 0;
  B.params_size = size;
  uint32_t o = b_grow(size ? size : 8);
  memset(B.buf + o, 0, WMTR_ALIGN8(size ? size : 8));
  if (size) memcpy(B.buf + o, params, size);
}

static void
b_reloc(uint32_t field_off, uint64_t value) {
  memcpy(B.buf + field_off, &value, 8);
  if (B.n_reloc == B.cap_reloc) {
    if (B.n_reloc == 65535) { B.error = 1; return; } /* the header counts relocations in 16 bits */
    B.cap_reloc = B.cap_reloc ? B.cap_reloc * 2 : 256;
    if (B.cap_reloc > 65535) B.cap_reloc = 65535;
    B.relocs = realloc(B.relocs, B.cap_reloc * sizeof *B.relocs);
  }
  B.relocs[B.n_reloc++] = field_off;
}

/* copy `size` input bytes the field at `field_off` points to; returns the payload offset of the copy
 * (inline) or UINT32_MAX when staged in the arena */
static uint32_t
b_in(uint32_t field_off, const void *src, uint64_t size) {
  if (!src) { uint64_t z = 0; memcpy(B.buf + field_off, &z, 8); return UINT32_MAX; }
  if (size > INLINE_IN_MAX && B.n_stage < MAX_STAGE) {
    uint32_t blob, off;
    uint8_t *p = arena_alloc(size, &blob, &off);
    if (p) {
      memcpy(p, src, size);
      B.stages[B.n_stage++] = (struct stage){blob, off, size};
      B.force_sync = 1;
      b_reloc(field_off, WMTR_REF_ARENA | ((uint64_t)blob << 32) | off);
      return UINT32_MAX;
    }
  }
  uint32_t o = b_grow((uint32_t)size ? (uint32_t)size : 1);
  memcpy(B.buf + o, src, size);
  b_reloc(field_off, WMTR_REF_EXTRA | o);
  return o;
}

static void
b_out(uint32_t field_off, void *dst, uint64_t size, int inout) {
  if (!dst) { uint64_t z = 0; memcpy(B.buf + field_off, &z, 8); return; }
  if (B.n_out == MAX_OUT) { B.error = 1; return; }
  B.force_sync = 1;
  uint32_t used = 0;
  for (int i = 0; i < B.n_out; i++) if (!B.dsts[i].arena) used += B.outs[i].size;
  if (size > INLINE_OUT_MAX || used + size + B.params_size > WMTR_SLOT_BYTES) {
    uint32_t blob, off;
    uint8_t *p = (B.n_stage < MAX_STAGE) ? arena_alloc(size, &blob, &off) : NULL;
    if (!p) { B.error = 1; return; }
    if (inout) memcpy(p, dst, size);
    B.stages[B.n_stage++] = (struct stage){blob, off, size};
    B.dsts[B.n_out] = (struct out_dst){dst, (uint32_t)size, p};
    B.outs[B.n_out++] = (struct wmtr_out){0, 0}; /* not copied through the slot */
    b_reloc(field_off, WMTR_REF_ARENA | ((uint64_t)blob << 32) | off);
    return;
  }
  uint32_t o = b_grow(size ? (uint32_t)size : 8); /* a zero-length output still needs an in-bounds address */
  if (inout) memcpy(B.buf + o, dst, size);
  else memset(B.buf + o, 0, WMTR_ALIGN8((uint32_t)size));
  B.dsts[B.n_out] = (struct out_dst){dst, (uint32_t)size, NULL};
  B.outs[B.n_out++] = (struct wmtr_out){o, (uint32_t)size};
  b_reloc(field_off, WMTR_REF_EXTRA | o);
}

static void
b_cstr(uint32_t field_off, const char *s) {
  if (!s) { uint64_t z = 0; memcpy(B.buf + field_off, &z, 8); return; }
  b_in(field_off, s, strlen(s) + 1);
}

/* ---------------------------------------------------------------------------------------------
 * ring */
static uint64_t
ring_space(void) {
  return WMTR_RING_BYTES - (R->head - __atomic_load_n(&R->tail, __ATOMIC_ACQUIRE));
}

static NTSTATUS send_built_flags(uint16_t call, uint16_t extra_flags, void *params, uint32_t params_size);

/* how a call runs on the host (wmtr_calls.inc): picks the reply wait's spin budget (wmtr_spin.h) */
#define WMTR_CLS_A 0
#define WMTR_CLS_S 1
#define WMTR_CLS_B 2
#define WMTR_CLS_C 3
#define WMTR_CLS_N 1
static const uint8_t call_cls[WMTR_NCALLS] = {
#define X(i, n, t, c) [i] = WMTR_CLS_##c,
#include "wmtr_calls.inc"
#undef X
};

static NTSTATUS
send_built(uint16_t call, int sync, void *params, uint32_t params_size) {
  if (sync) B.force_sync = 1;
  return send_built_flags(call, 0, params, params_size);
}

static NTSTATUS
send_built_flags(uint16_t call, uint16_t extra_flags, void *params, uint32_t params_size) {
  int sync = 0;
  if (B.error) { LOG(0, "call %u: request too complex\n", call); return STATUS_UNSUCCESSFUL; }
  sync |= B.force_sync;
  int slot = my_slot(); /* async requests carry it too: the host keeps per-thread autorelease state */
  struct wmtr_req_ext hdr = {0};
  hdr.h.call = call;
  hdr.h.flags = (sync ? WMTR_F_SYNC : 0) | extra_flags;
  hdr.h.slot = slot;
  hdr.h.params_size = params_size;
  hdr.n_reloc = (uint16_t)B.n_reloc;
  hdr.n_out = (uint16_t)B.n_out;
  hdr.payload_size = B.len;
  uint32_t poff = wmtr_req_payload_offset(&hdr);
  uint32_t total = WMTR_ALIGN8(poff + B.len);
  hdr.h.size = total;
  if (total > WMTR_RING_BYTES / 2) { LOG(0, "call %u: request %u bytes too large\n", call, total); return STATUS_UNSUCCESSFUL; }

  pthread_mutex_lock(&ring_lock);
  uint64_t seq = 0;
  if (sync) seq = slots[slot].done_seq + 1;
  hdr.h.seq = seq;
  uint64_t head = R->head;
  uint32_t pos = (uint32_t)(head % WMTR_RING_BYTES);
  uint32_t to_end = WMTR_RING_BYTES - pos;
  uint64_t need = total + (to_end < total ? to_end : 0);
  for (int spins = 0; ring_space() < need; spins++) {
    if (wmtr_claim_kick(&R->host_idle)) T->kick(T);
    if (spins > 64) sched_yield();
  }
  if (to_end < total) {
    if (to_end >= sizeof(struct wmtr_req)) {
      struct wmtr_req w = {0};
      w.size = to_end; w.flags = WMTR_F_WRAP;
      memcpy(ring_data + pos, &w, sizeof w);
    }
    head += to_end; pos = 0;
  }
  uint8_t *dst = ring_data + pos;
  memcpy(dst, &hdr, sizeof hdr);
  memcpy(dst + sizeof hdr, B.relocs, 4u * B.n_reloc);
  memcpy(dst + sizeof hdr + 4u * B.n_reloc, B.outs, sizeof(struct wmtr_out) * B.n_out);
  memcpy(dst + poff, B.buf, B.len);
  __atomic_store_n(&R->head, head + total, __ATOMIC_RELEASE);
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  if (wmtr_claim_kick(&R->host_idle)) T->kick(T);
  pthread_mutex_unlock(&ring_lock);

  if (!sync) return STATUS_SUCCESS;
  struct wmtr_slot *s = &slots[slot];
  if (__atomic_load_n(&s->done_seq, __ATOMIC_ACQUIRE) < seq) {
    __atomic_store_n(&s->waiting, 1, __ATOMIC_SEQ_CST);
    int cls = (extra_flags & WMTR_F_CONTROL) || call >= WMTR_NCALLS ? WMTR_CLS_S : call_cls[call];
    T->wait(T, &s->done_seq, seq, slot, wmtr_spin_budget_ns(cls));
    __atomic_store_n(&s->waiting, 0, __ATOMIC_RELAXED);
  }
  NTSTATUS st = (NTSTATUS)s->status;
  /* copy back: params, restoring the caller's pointer fields, then outputs in order */
  if (params && params_size) {
    uint8_t saved[1024];
    uint32_t n = params_size < sizeof saved ? params_size : sizeof saved;
    memcpy(saved, params, n);
    memcpy(params, (const void *)s->data, params_size);
    for (int i = 0; i < B.n_reloc; i++)
      if (B.relocs[i] + 8 <= n) memcpy((uint8_t *)params + B.relocs[i], saved + B.relocs[i], 8);
  }
  uint32_t o = WMTR_ALIGN8(params_size);
  for (int i = 0; i < B.n_out; i++) {
    if (B.dsts[i].arena) { memcpy(B.dsts[i].dst, B.dsts[i].arena, B.dsts[i].size); continue; }
    memcpy(B.dsts[i].dst, (const void *)(s->data + o), B.outs[i].size);
    o += WMTR_ALIGN8(B.outs[i].size);
  }
  for (int i = 0; i < B.n_stage; i++) arena_free(B.stages[i].blob, B.stages[i].off, B.stages[i].size);
  arena_maintain();
  return st;
}

/* ---------------------------------------------------------------------------------------------
 * per-object client knowledge */
#define MAPN 65536
struct kv { uint64_t k, v; };
static struct kv tex_fmt[MAPN];        /* texture handle -> WMTPixelFormat */
static struct kv shader_counts[MAPN];  /* sm50 shader -> NumConstantBuffers | NumArguments << 32 */
static struct kv host_blobs[4096];     /* compiled bitcode host pointers (key) -> size */
static pthread_mutex_t map_lock = PTHREAD_MUTEX_INITIALIZER;

static void
map_put(struct kv *m, uint32_t n, uint64_t k, uint64_t v) {
  if (!k) return;
  pthread_mutex_lock(&map_lock);
  uint32_t i = (uint32_t)((k >> 4) * 0x9E3779B1u) & (n - 1);
  for (uint32_t c = 0; c < n; c++, i = (i + 1) & (n - 1)) {
    if (m[i].k == k || m[i].k == 0 || m[i].k == ~0ull) { m[i].k = k; m[i].v = v; break; }
  }
  pthread_mutex_unlock(&map_lock);
}
static int
map_get(struct kv *m, uint32_t n, uint64_t k, uint64_t *v) {
  if (!k) return 0;
  int found = 0;
  pthread_mutex_lock(&map_lock);
  uint32_t i = (uint32_t)((k >> 4) * 0x9E3779B1u) & (n - 1);
  for (uint32_t c = 0; c < n; c++, i = (i + 1) & (n - 1)) {
    if (m[i].k == k) { *v = m[i].v; found = 1; break; }
    if (m[i].k == 0) break;
  }
  pthread_mutex_unlock(&map_lock);
  return found;
}
static void
map_del(struct kv *m, uint32_t n, uint64_t k) {
  pthread_mutex_lock(&map_lock);
  uint32_t i = (uint32_t)((k >> 4) * 0x9E3779B1u) & (n - 1);
  for (uint32_t c = 0; c < n; c++, i = (i + 1) & (n - 1)) {
    if (m[i].k == k) { m[i].k = ~0ull; break; }
    if (m[i].k == 0) break;
  }
  pthread_mutex_unlock(&map_lock);
}

static int
is_block_compressed(uint32_t fmt) {
  uint32_t base = fmt & 0xfff;
  return (base >= 130 && base <= 143) || (base >= 150 && base <= 153); /* MTLPixelFormatBC1..BC5, BC6H, BC7 */
}

static uint32_t texture_format(obj_handle_t tex);

static uint64_t
region_bytes(obj_handle_t texture, struct WMTSize size, uint64_t bytes_per_row, uint64_t bytes_per_image) {
  uint64_t rows = size.height;
  if (is_block_compressed(texture_format(texture))) rows = (size.height + 3) / 4;
  uint64_t depth = size.depth ? size.depth : 1;
  uint64_t last = rows * bytes_per_row;
  if (depth > 1 && bytes_per_image) return (depth - 1) * bytes_per_image + last;
  return last;
}

/* ---------------------------------------------------------------------------------------------
 * shared-event listener: the host queues (listener, Win32 event handle) when an MTLSharedEvent
 * reaches a value; the thread DXMT parks in SharedEventListener_start sets the events here, in the
 * Wine process, with ntdll's NtSetEvent. */
#include <dlfcn.h>
typedef NTSTATUS (*pNtSetEvent)(void *handle, void *prev);
static pthread_mutex_t event_lock = PTHREAD_MUTEX_INITIALIZER;

#ifdef __linux__
#include <link.h>
/* Wine on Linux loads ntdll.so RTLD_LOCAL, so its symbols are not in the global scope: find the
 * loaded ntdll.so and look the symbol up in it (RTLD_NOLOAD: never loads a second copy). */
static int
find_ntdll(struct dl_phdr_info *info, size_t size, void *out) {
  (void)size;
  const char *n = info->dlpi_name;
  size_t l = n ? strlen(n) : 0;
  if (l < 9 || strcmp(n + l - 9, "/ntdll.so")) return 0;
  *(void **)out = dlopen(n, RTLD_NOW | RTLD_NOLOAD);
  return *(void **)out != NULL;
}
#endif

/* ntdll's NtSetEvent in this process (exported for tests) */
__attribute__((visibility("default"))) void *
wmtr_find_nt_set_event(void) {
  void *f = dlsym(RTLD_DEFAULT, "NtSetEvent");
#ifdef __linux__
  void *h = NULL;
  if (!f && dl_iterate_phdr(find_ntdll, &h) && h) f = dlsym(h, "NtSetEvent");
#endif
  return f;
}

static NTSTATUS
listener_run(uint64_t listener) {
  static pNtSetEvent set_event;
  if (!set_event) set_event = (pNtSetEvent)wmtr_find_nt_set_event();
  if (!set_event) { LOG(0, "NtSetEvent not found\n"); return STATUS_UNSUCCESSFUL; }
  LOG(2, "listener %llx running\n", (unsigned long long)listener);
  for (;;) {
    pthread_mutex_lock(&event_lock);
    uint64_t t = R->event_tail;
    uint64_t h = __atomic_load_n(&R->event_head, __ATOMIC_ACQUIRE);
    int stop = 0;
    for (; t < h; t++) {
      struct wmtr_event e = R->event_ring[t % WMTR_EVENT_RING];
      if (e.listener != listener) continue; /* one listener per device in DXMT; others are dropped */
      if (!e.event_handle) { stop = 1; continue; }
      set_event((void *)(uintptr_t)e.event_handle, NULL);
    }
    __atomic_store_n(&R->event_tail, t, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&event_lock);
    if (stop) return STATUS_SUCCESS;
    T->wait(T, &R->event_head, t + 1, WMTR_EVENT_SLOT, 0); /* events come once or twice a frame */
  }
}

/* ---------------------------------------------------------------------------------------------
 * call marshalling */
#define OFF(type, field) ((uint32_t)offsetof(type, field))

static uint32_t
cmd_size(int kind, uint16_t type) {
#define CMD(k, e, s) if (kind == WMTR_KIND_##k && type == e) return sizeof(struct s);
  enum { WMTR_KIND_BLIT, WMTR_KIND_COMPUTE, WMTR_KIND_RENDER };
#include "wmtr_cmds.inc"
#undef CMD
  if (type == 0) return sizeof(struct wmtcmd_base);
  return 0;
}

/* copy a command list into extra; `next` and the embedded data pointers become relocations */
static void
marshal_cmds(int kind, uint32_t head_field_off, const struct wmtcmd_base *c) {
  uint32_t link = head_field_off;
  for (; c; c = (const struct wmtcmd_base *)c->next.ptr) {
    uint32_t sz = cmd_size(kind, c->type);
    if (!sz) { LOG(0, "unknown command kind %d type %u\n", kind, c->type); B.error = 1; return; }
    uint32_t o = b_grow(sz);
    memcpy(B.buf + o, c, sz);
    b_reloc(link, WMTR_REF_EXTRA | o);
    link = o + OFF(struct wmtcmd_base, next);
    uint64_t z = 0; memcpy(B.buf + link, &z, 8);
    if (kind == 1 && c->type == WMTComputeCommandSetBytes) {
      const struct wmtcmd_compute_setbytes *b = (const void *)c;
      b_in(o + OFF(struct wmtcmd_compute_setbytes, bytes), b->bytes.ptr, b->length);
    } else if (kind == 2 && c->type == WMTRenderCommandSetFragmentBytes) {
      const struct wmtcmd_render_setbytes *b = (const void *)c;
      b_in(o + OFF(struct wmtcmd_render_setbytes, bytes), b->bytes.ptr, b->length);
    } else if (kind == 2 && c->type == WMTRenderCommandSetViewports) {
      const struct wmtcmd_render_setviewports *b = (const void *)c;
      b_in(o + OFF(struct wmtcmd_render_setviewports, viewports), b->viewports.ptr,
           (uint64_t)b->viewport_count * sizeof(struct WMTViewport));
    } else if (kind == 2 && c->type == WMTRenderCommandSetScissorRects) {
      const struct wmtcmd_render_setscissorrects *b = (const void *)c;
      b_in(o + OFF(struct wmtcmd_render_setscissorrects, scissor_rects), b->scissor_rects.ptr,
           (uint64_t)b->rect_count * sizeof(struct WMTScissorRect));
    }
  }
}

/* SM50 compile-argument linked list (airconv_public.h) */
static void
marshal_sm50_args(uint32_t field_off, const struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *a) {
  uint32_t link = field_off;
  if (!a) { uint64_t z = 0; memcpy(B.buf + field_off, &z, 8); return; }
  for (; a; a = a->next) {
    uint32_t sz;
    switch (a->type) {
    case SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT: sz = sizeof(struct SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT_DATA); break;
    case SM50_SHADER_COMMON: sz = sizeof(struct SM50_SHADER_COMMON_DATA); break;
    case SM50_SHADER_PSO_PIXEL_SHADER: sz = sizeof(struct SM50_SHADER_PSO_PIXEL_SHADER_DATA); break;
    case SM50_SHADER_IA_INPUT_LAYOUT: sz = sizeof(struct SM50_SHADER_IA_INPUT_LAYOUT_DATA); break;
    case SM50_SHADER_GS_PASS_THROUGH: sz = sizeof(struct SM50_SHADER_GS_PASS_THROUGH_DATA); break;
    case SM50_SHADER_PSO_GEOMETRY_SHADER: sz = sizeof(struct SM50_SHADER_PSO_GEOMETRY_SHADER_DATA); break;
    case SM50_SHADER_PSO_TESSELLATOR: sz = sizeof(struct SM50_SHADER_PSO_TESSELLATOR_DATA); break;
    /* D3D12: the serialized root signature (ROOT_SIGNATURE2: the vertex stage's, for tessellation) */
    case SM50_SHADER_ROOT_SIGNATURE: case SM50_SHADER_ROOT_SIGNATURE2: sz = sizeof(struct SM50_SHADER_ROOT_SIGNATURE_DATA); break;
    default: LOG(0, "sm50 arg type %u not remotable\n", a->type); B.error = 1; return;
    }
    uint32_t o = b_grow(sz);
    memcpy(B.buf + o, a, sz);
    b_reloc(link, WMTR_REF_EXTRA | o);
    link = o; /* next is the first member */
    uint64_t z = 0; memcpy(B.buf + link, &z, 8);
    if (a->type == SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT) {
      const struct SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT_DATA *d = (const void *)a;
      b_in(o + OFF(struct SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT_DATA, elements), d->elements,
           (uint64_t)d->num_elements * sizeof(struct SM50_STREAM_OUTPUT_ELEMENT));
    } else if (a->type == SM50_SHADER_ROOT_SIGNATURE || a->type == SM50_SHADER_ROOT_SIGNATURE2) {
      const struct SM50_SHADER_ROOT_SIGNATURE_DATA *d = (const void *)a;
      b_in(o + OFF(struct SM50_SHADER_ROOT_SIGNATURE_DATA, bytecode), d->bytecode, (uint64_t)d->bytecode_length);
    } else if (a->type == SM50_SHADER_IA_INPUT_LAYOUT) {
      const struct SM50_SHADER_IA_INPUT_LAYOUT_DATA *d = (const void *)a;
      b_in(o + OFF(struct SM50_SHADER_IA_INPUT_LAYOUT_DATA, elements), d->elements,
           (uint64_t)d->num_elements * sizeof(struct SM50_IA_INPUT_ELEMENT));
    }
  }
}

static uint32_t
data_type_size(uint32_t t) {
  /* MTLDataType values used for function constants (bool/int/uint/float families) */
  switch (t) {
  case 53: case 45: case 49: return 1;           /* bool, char, uchar */
  case 54: case 46: case 50: return 2;           /* bool2, char2, uchar2 */
  case 55: case 47: case 51: return 3;
  case 56: case 48: case 52: return 4;
  case 41: case 37: case 16: return 2;           /* short, ushort, half */
  case 42: case 38: case 17: return 4;
  case 43: case 39: case 18: return 6;
  case 44: case 40: case 19: return 8;
  case 29: case 33: case 3: return 4;            /* int, uint, float */
  case 30: case 34: case 4: return 8;
  case 31: case 35: case 5: return 12;
  case 32: case 36: case 6: return 16;
  case 81: case 85: return 8;                    /* long, ulong */
  default: return 16;
  }
}

static uint32_t
texture_format(obj_handle_t tex) {
  uint64_t v;
  if (map_get(tex_fmt, MAPN, tex, &v)) return (uint32_t)v;
  struct unixcall_generic_obj_uint64_ret p = {tex, 0};
  b_begin(&p, sizeof p);
  send_built(39, 1, &p, sizeof p);
  map_put(tex_fmt, MAPN, tex, p.ret);
  return (uint32_t)p.ret;
}

/* NSAutoreleasePool_alloc_init and the command encoder creations: the client assigns the handle and does not
 * wait (WMTR_F_CLIENT_HANDLE). DXMT only passes these results back to later calls, which the ring orders after
 * the creation; a failed creation is reported by the host and the calls using its handle fail there. */
static _Atomic uint64_t next_handle;
static __thread uint32_t next_pool;

static NTSTATUS
send_client_handle(uint16_t call, void *params, uint32_t size) {
  uint64_t handle;
  uint32_t ret_off;
  b_begin(params, size);
  if (call == 10) {
    handle = WMTR_HANDLE_TAG | WMTR_HANDLE_POOL | (uint64_t)my_slot() << 32 | ++next_pool;
    ret_off = OFF(struct unixcall_generic_obj_ret, ret);
  } else {
    handle = WMTR_HANDLE_TAG | ((atomic_fetch_add_explicit(&next_handle, 1, memory_order_relaxed) + 1) & (WMTR_HANDLE_POOL - 1));
    ret_off = call == 30 ? OFF(struct unixcall_generic_obj_obj_ret, ret) : OFF(struct unixcall_generic_obj_uint64_obj_ret, ret);
    if (call == 32)
      b_in(OFF(struct unixcall_generic_obj_uint64_obj_ret, arg),
           (const void *)(uintptr_t)((struct unixcall_generic_obj_uint64_obj_ret *)params)->arg, sizeof(struct WMTRenderPassInfo));
  }
  memcpy(B.buf + ret_off, &handle, 8);
  memcpy((uint8_t *)params + ret_off, &handle, 8);
  return send_built_flags(call, WMTR_F_CLIENT_HANDLE, params, size); /* sync only if the request needs a reply */
}

static NTSTATUS
dispatch(uint16_t call, void *params, uint32_t size, int sync) {
  if (client_handles && (call == 10 || (call >= 30 && call <= 32))) return send_client_handle(call, params, size);
  switch (call) {
  case 8: { /* NSString_getCString */
    struct unixcall_nsstring_getcstring *p = params;
    b_begin(p, size);
    b_out(OFF(struct unixcall_nsstring_getcstring, buffer_ptr), (void *)(uintptr_t)p->buffer_ptr, p->max_length, 0);
    break;
  }
  case 18: { /* MTLDevice_newBuffer */
    struct unixcall_mtldevice_newbuffer *p = params;
    struct WMTBufferInfo *info = p->info.ptr;
    uint32_t blob = 0, off = 0;
    void *mem = NULL;
    int private_storage = (info->options & 0xf0) == WMTResourceStorageModePrivate;
    if (!private_storage || info->memory.ptr) {
      /* caller-placed memory (DXMT's CpuPlaced buffers) is not host-visible: back the buffer with arena
       * memory holding the same initial bytes; DXMT reads the pointer back from info->memory */
      mem = arena_alloc(info->length, &blob, &off);
      if (!mem) return STATUS_UNSUCCESSFUL;
      if (info->memory.ptr) memcpy(mem, info->memory.ptr, info->length);
    }
    b_begin(p, size);
    void *caller_mem = info->memory.ptr;
    info->memory.ptr = NULL;
    b_out(OFF(struct unixcall_mtldevice_newbuffer, info), info, sizeof *info, 1);
    (void)caller_mem;
    if (mem) b_reloc(B.outs[0].off + OFF(struct WMTBufferInfo, memory), WMTR_REF_ARENA | ((uint64_t)blob << 32) | off);
    NTSTATUS st = send_built(call, 1, p, size);
    info->memory.ptr = mem;
    if (!p->ret && mem) arena_free(blob, off, info->length);
    return st;
  }
  case 19: b_begin(params, size); b_out(OFF(struct unixcall_mtldevice_newsamplerstate, info), ((struct unixcall_mtldevice_newsamplerstate *)params)->info.ptr, sizeof(struct WMTSamplerInfo), 1); break;
  case 20: b_begin(params, size); b_in(OFF(struct unixcall_mtldevice_newdepthstencilstate, info), ((struct unixcall_mtldevice_newdepthstencilstate *)params)->info.ptr, sizeof(struct WMTDepthStencilInfo)); break;
  case 21: case 120: { /* newTexture, newSharedTexture */
    struct unixcall_mtldevice_newtexture *p = params;
    struct WMTTextureInfo *info = p->info.ptr;
    b_begin(p, size);
    b_out(OFF(struct unixcall_mtldevice_newtexture, info), info, sizeof *info, 1);
    NTSTATUS st = send_built(call, 1, p, size);
    map_put(tex_fmt, MAPN, p->ret, info->pixel_format);
    return st;
  }
  case 22: {
    struct unixcall_mtlbuffer_newtexture *p = params;
    struct WMTTextureInfo *info = p->info.ptr;
    b_begin(p, size);
    b_out(OFF(struct unixcall_mtlbuffer_newtexture, info), info, sizeof *info, 1);
    NTSTATUS st = send_built(call, 1, p, size);
    map_put(tex_fmt, MAPN, p->ret, info->pixel_format);
    return st;
  }
  case 23: {
    struct unixcall_mtltexture_newtextureview *p = params;
    b_begin(p, size);
    NTSTATUS st = send_built(call, 1, p, size);
    map_put(tex_fmt, MAPN, p->ret, p->format);
    return st;
  }
  case 26: { struct unixcall_generic_obj_uint64_obj_ret *p = params; b_begin(p, size); b_cstr(OFF(struct unixcall_generic_obj_uint64_obj_ret, arg), (const char *)(uintptr_t)p->arg); break; }
  case 29: { struct unixcall_mtldevice_newcomputepso *p = params; const struct WMTComputePipelineInfo *i = p->info.ptr; b_begin(p, size);
    uint32_t o = b_in(OFF(struct unixcall_mtldevice_newcomputepso, info), i, sizeof *i);
    if (o != UINT32_MAX) b_in(o + OFF(struct WMTComputePipelineInfo, binary_archives_for_lookup), i->num_binary_archives_for_lookup ? i->binary_archives_for_lookup.ptr : NULL, 8ull * i->num_binary_archives_for_lookup);
    break; }
  case 34: case 131: { struct unixcall_mtldevice_newrenderpso *p = params; b_begin(p, size);
    if (call == 34) { const struct WMTRenderPipelineInfo *i = p->info.ptr;
      uint32_t o = b_in(OFF(struct unixcall_mtldevice_newrenderpso, info), i, sizeof *i);
      if (o != UINT32_MAX) b_in(o + OFF(struct WMTRenderPipelineInfo, binary_archives_for_lookup), i->num_binary_archives_for_lookup ? i->binary_archives_for_lookup.ptr : NULL, 8ull * i->num_binary_archives_for_lookup);
    } else { const struct WMTTileRenderPipelineInfo *i = p->info.ptr;
      uint32_t o = b_in(OFF(struct unixcall_mtldevice_newrenderpso, info), i, sizeof *i);
      if (o != UINT32_MAX) b_in(o + OFF(struct WMTTileRenderPipelineInfo, binary_archives_for_lookup), i->num_binary_archives_for_lookup ? i->binary_archives_for_lookup.ptr : NULL, 8ull * i->num_binary_archives_for_lookup);
    }
    break; }
  case 35: { struct unixcall_mtldevice_newmeshrenderpso *p = params; const struct WMTMeshRenderPipelineInfo *i = p->info.ptr; b_begin(p, size);
    uint32_t o = b_in(OFF(struct unixcall_mtldevice_newmeshrenderpso, info), i, sizeof *i);
    if (o != UINT32_MAX) b_in(o + OFF(struct WMTMeshRenderPipelineInfo, binary_archives_for_lookup), i->num_binary_archives_for_lookup ? i->binary_archives_for_lookup.ptr : NULL, 8ull * i->num_binary_archives_for_lookup);
    break; }
  case 32: { struct unixcall_generic_obj_uint64_obj_ret *p = params; b_begin(p, size); b_in(OFF(struct unixcall_generic_obj_uint64_obj_ret, arg), (const void *)(uintptr_t)p->arg, sizeof(struct WMTRenderPassInfo)); break; }
  case 36: case 37: case 38: { struct unixcall_generic_obj_cmd_noret *p = params; b_begin(p, size);
    marshal_cmds(call - 36, OFF(struct unixcall_generic_obj_cmd_noret, cmd_head), p->cmd_head.ptr); break; }
  case 45: case 145: { /* replaceRegion (in) / getBytes (out) */
    struct unixcall_mtltexture_replaceregion *p = params;
    uint64_t n = region_bytes(p->texture, p->size, p->bytes_per_row, p->bytes_per_image);
    b_begin(p, size);
    if (call == 45) b_in(OFF(struct unixcall_mtltexture_replaceregion, data), p->data.ptr, n);
    else b_out(OFF(struct unixcall_mtltexture_replaceregion, data), p->data.ptr, n, 0);
    break;
  }
  case 54: { struct unixcall_mtlcapturemanager_startcapture *p = params; const struct WMTCaptureInfo *i = p->info.ptr; b_begin(p, size);
    uint32_t o = b_in(OFF(struct unixcall_mtlcapturemanager_startcapture, info), i, sizeof *i);
    if (o != UINT32_MAX) b_cstr(o + OFF(struct WMTCaptureInfo, output_url), i->output_url.ptr); break; }
  case 56: b_begin(params, size); b_in(OFF(struct unixcall_mtldevice_newfxtemporalscaler, info), ((struct unixcall_mtldevice_newfxtemporalscaler *)params)->info.ptr, sizeof(struct WMTFXTemporalScalerInfo)); break;
  case 57: b_begin(params, size); b_in(OFF(struct unixcall_mtldevice_newfxspatialscaler, info), ((struct unixcall_mtldevice_newfxspatialscaler *)params)->info.ptr, sizeof(struct WMTFXSpatialScalerInfo)); break;
  case 58: b_begin(params, size); b_in(OFF(struct unixcall_mtlcommandbuffer_temporal_scale, props), ((struct unixcall_mtlcommandbuffer_temporal_scale *)params)->props.ptr, sizeof(struct WMTFXTemporalScalerProps)); break;
  case 60: case 61: b_begin(params, size); b_cstr(OFF(struct unixcall_nsstring_string, buffer_ptr), ((struct unixcall_nsstring_string *)params)->buffer_ptr.ptr); break;
  case 70: b_begin(params, size); b_in(OFF(struct unixcall_generic_obj_constptr_noret, arg), ((struct unixcall_generic_obj_constptr_noret *)params)->arg.ptr, sizeof(struct WMTLayerProps)); break;
  case 71: b_begin(params, size); b_out(OFF(struct unixcall_generic_obj_ptr_noret, arg), ((struct unixcall_generic_obj_ptr_noret *)params)->arg.ptr, sizeof(struct WMTLayerProps), 0); break;
  case 74: { struct sm50_initialize_params *p = params; b_begin(p, size);
    b_in(OFF(struct sm50_initialize_params, bytecode), p->bytecode, p->bytecode_size);
    b_out(OFF(struct sm50_initialize_params, shader), p->shader, sizeof(sm50_shader_t), 0);
    b_out(OFF(struct sm50_initialize_params, reflection), p->reflection, sizeof(struct MTL_SHADER_REFLECTION), 0);
    b_out(OFF(struct sm50_initialize_params, error), p->error, sizeof(sm50_error_t), 0);
    NTSTATUS st = send_built(call, 1, p, size);
    if (p->shader && p->reflection) {
      const struct MTL_SHADER_REFLECTION *r = p->reflection;
      map_put(shader_counts, MAPN, (uint64_t)(uintptr_t)*p->shader, r->NumConstantBuffers | ((uint64_t)r->NumArguments << 32));
    }
    return st;
  }
  case 75: { struct sm50_destroy_params *p = params; map_del(shader_counts, MAPN, (uint64_t)(uintptr_t)p->shader); b_begin(p, size); break; }
  case 76: { struct sm50_compile_params *p = params; b_begin(p, size);
    marshal_sm50_args(OFF(struct sm50_compile_params, args), p->args);
    b_cstr(OFF(struct sm50_compile_params, func_name), p->func_name);
    b_out(OFF(struct sm50_compile_params, bitcode), p->bitcode, sizeof(sm50_bitcode_t), 0);
    b_out(OFF(struct sm50_compile_params, error), p->error, sizeof(sm50_error_t), 0); break; }
  case 81: case 82: case 84: case 85: { /* pipeline compile variants share one layout */
    struct sm50_compile_geometry_pipeline_vertex_params *p = params; b_begin(p, size);
    marshal_sm50_args(OFF(struct sm50_compile_geometry_pipeline_vertex_params, vertex_args), p->vertex_args);
    b_cstr(OFF(struct sm50_compile_geometry_pipeline_vertex_params, func_name), p->func_name);
    b_out(OFF(struct sm50_compile_geometry_pipeline_vertex_params, bitcode), p->bitcode, sizeof(sm50_bitcode_t), 0);
    b_out(OFF(struct sm50_compile_geometry_pipeline_vertex_params, error), p->error, sizeof(sm50_error_t), 0); break; }
  case 77: { struct sm50_get_compiled_bitcode_params *p = params; b_begin(p, size);
    b_out(OFF(struct sm50_get_compiled_bitcode_params, data_out), p->data_out, sizeof(struct SM50_COMPILED_BITCODE), 0);
    NTSTATUS st = send_built(call, 1, p, size);
    if (p->data_out) map_put(host_blobs, 4096, (uint64_t)(uintptr_t)p->data_out->Data, p->data_out->Size);
    return st; }
  case 78: { struct sm50_destroy_bitcode_params *p = params; b_begin(p, size); break; }
  case 79: { struct sm50_get_error_message_params *p = params; b_begin(p, size);
    b_out(OFF(struct sm50_get_error_message_params, buffer), p->buffer, p->buffer_size, 0); break; }
  case 88: { struct sm50_get_arguments_info_params *p = params; uint64_t c = 0;
    map_get(shader_counts, MAPN, (uint64_t)(uintptr_t)p->shader, &c);
    b_begin(p, size);
    b_out(OFF(struct sm50_get_arguments_info_params, constant_buffers), p->constant_buffers, (c & 0xffffffff) * sizeof(struct MTL_SM50_SHADER_ARGUMENT), 0);
    b_out(OFF(struct sm50_get_arguments_info_params, arguments), p->arguments, (c >> 32) * sizeof(struct MTL_SM50_SHADER_ARGUMENT), 0);
    break; }
  case 91: { struct unixcall_enumerate *p = params; b_begin(p, size); b_out(OFF(struct unixcall_enumerate, buffer), p->buffer.ptr, p->buffer_size * 8, 0); break; }
  case 96: b_begin(params, size); b_out(OFF(struct unixcall_generic_obj_ptr_noret, arg), ((struct unixcall_generic_obj_ptr_noret *)params)->arg.ptr, sizeof(struct WMTDisplayDescription), 0); break;
  case 97: b_begin(params, size); b_out(OFF(struct unixcall_generic_obj_constptr_noret, arg), (void *)((struct unixcall_generic_obj_constptr_noret *)params)->arg.ptr, sizeof(struct WMTEDRValue), 0); break;
  case 98: { struct unixcall_mtllibrary_newfunction_with_constants *p = params; b_begin(p, size);
    b_cstr(OFF(struct unixcall_mtllibrary_newfunction_with_constants, name), p->name.ptr);
    const struct WMTFunctionConstant *cs = p->constants.ptr;
    uint32_t o = b_in(OFF(struct unixcall_mtllibrary_newfunction_with_constants, constants), cs, p->num_constants * sizeof *cs);
    if (o != UINT32_MAX)
      for (uint64_t i = 0; i < p->num_constants; i++)
        b_in(o + (uint32_t)(i * sizeof *cs) + OFF(struct WMTFunctionConstant, data), cs[i].data.ptr, data_type_size(cs[i].type));
    break; }
  case 99: b_begin(params, size); b_out(OFF(struct unixcall_query_display_setting, hdr_metadata), ((struct unixcall_query_display_setting *)params)->hdr_metadata.ptr, sizeof(struct WMTHDRMetadata), 0); break;
  case 100: b_begin(params, size); b_in(OFF(struct unixcall_update_display_setting, hdr_metadata), ((struct unixcall_update_display_setting *)params)->hdr_metadata.ptr, sizeof(struct WMTHDRMetadata)); break;
  case 101: b_begin(params, size); b_out(OFF(struct unixcall_query_display_setting_for_layer, hdr_metadata), ((struct unixcall_query_display_setting_for_layer *)params)->hdr_metadata.ptr, sizeof(struct WMTHDRMetadata), 0); break;
  case 107: { struct unixcall_mtlbuffer_updatecontents *p = params; b_begin(p, size); b_in(OFF(struct unixcall_mtlbuffer_updatecontents, data), p->data.ptr, p->length); break; }
  case 112: { struct unixcall_mtldevice_newbinaryarchive *p = params; b_begin(p, size); b_cstr(OFF(struct unixcall_mtldevice_newbinaryarchive, url), p->url.ptr); break; }
  case 113: { struct unixcall_mtlbinaryarchive_serialize *p = params; b_begin(p, size); b_cstr(OFF(struct unixcall_mtlbinaryarchive_serialize, url), p->url.ptr); break; }
  case 114: { /* DispatchData_alloc_init(native_ptr, length): copy guest bytes unless it is host bitcode */
    struct unixcall_generic_obj_uint64_obj_ret *p = params; uint64_t hs;
    b_begin(p, size);
    if (!map_get(host_blobs, 4096, p->handle, &hs))
      b_in(OFF(struct unixcall_generic_obj_uint64_obj_ret, handle), (const void *)(uintptr_t)p->handle, p->arg);
    break; }
  case 115: case 117: { struct unixcall_cache_alloc_init *p = params; b_begin(p, size); b_cstr(OFF(struct unixcall_cache_alloc_init, path), p->path.ptr); break; }
  case 116: { struct unixcall_cache_get *p = params; b_begin(p, size); b_in(OFF(struct unixcall_cache_get, key), p->key.ptr, p->key_length); break; }
  case 118: { struct unixcall_cache_set *p = params; b_begin(p, size); b_in(OFF(struct unixcall_cache_set, key), p->key.ptr, p->key_length); break; }
  case 119: { struct unixcall_setmetalcachepath *p = params; b_begin(p, size); b_cstr(OFF(struct unixcall_setmetalcachepath, path), p->path.ptr); break; }
  case 128: { struct unixcall_mtlcountersamplebuffer_resolvecounterrange *p = params; b_begin(p, size); b_out(OFF(struct unixcall_mtlcountersamplebuffer_resolvecounterrange, data_out), p->data_out.ptr, p->data_length, 0); break; }
  case 129: { struct unixcall_mtlcommandbuffer_blitcommandencoderwithsamplebuffers *p = params; b_begin(p, size); b_in(OFF(struct unixcall_mtlcommandbuffer_blitcommandencoderwithsamplebuffers, attachments), p->attachments.ptr, p->num_attachments * sizeof(struct WMTSampleBufferAttachmentInfo)); break; }
  case 133: case 134: { struct unixcall_mtlresidencyset_addallocations *p = params; b_begin(p, size); b_in(OFF(struct unixcall_mtlresidencyset_addallocations, allocations), p->allocations.ptr, p->count * 8); break; }
  case 138: b_begin(params, size); b_in(OFF(struct unixcall_mtldevice_newheap, info), ((struct unixcall_mtldevice_newheap *)params)->info.ptr, sizeof(struct WMTHeapInfo)); break;
  case 140: b_begin(params, size); b_out(OFF(struct unixcall_mtldevice_heaptexturesizeandalign, info), ((struct unixcall_mtldevice_heaptexturesizeandalign *)params)->info.ptr, sizeof(struct WMTTextureInfo), 1); break;
  case 141: { struct unixcall_mtlheap_newbuffer *p = params; struct WMTBufferInfo *i = p->info.ptr; b_begin(p, size);
    b_out(OFF(struct unixcall_mtlheap_newbuffer, info), i, sizeof *i, 1);
    NTSTATUS st = send_built(call, 1, p, size);
    if (i->memory.ptr) { LOG(1, "heap buffer contents are host memory; CPU access unavailable\n"); i->memory.ptr = NULL; }
    return st; }
  case 142: { struct unixcall_mtlheap_newtexture *p = params; struct WMTTextureInfo *i = p->info.ptr; b_begin(p, size);
    b_out(OFF(struct unixcall_mtlheap_newtexture, info), i, sizeof *i, 1);
    NTSTATUS st = send_built(call, 1, p, size);
    map_put(tex_fmt, MAPN, p->ret, i->pixel_format);
    return st; }
  case 143: b_begin(params, size); b_out(OFF(struct unixcall_mtldevice_newicb, info), ((struct unixcall_mtldevice_newicb *)params)->info.ptr, sizeof(struct WMTIndirectCommandBufferInfo), 1); break;
  case 144: { struct unixcall_mtldevice_newlibrarywithsource *p = params; b_begin(p, size); b_in(OFF(struct unixcall_mtldevice_newlibrarywithsource, source), p->source.ptr, p->length); break; }
  case 109: return listener_run(((struct unixcall_generic_obj_noret *)params)->handle);
  case 121: case 122: case 123: case 124: return STATUS_NOT_SUPPORTED; /* mach ports do not cross the VM */
  default: b_begin(params, size); break;
  }
  return send_built(call, sync, params, size);
}

/* ---------------------------------------------------------------------------------------------
 * entry points */
#define WMTR_SYNC_A 0
#define WMTR_SYNC_S 1
#define WMTR_SYNC_B 1
#define WMTR_SYNC_C 1
#define WMTR_SYNC_N 1
static const uint8_t call_sync[WMTR_NCALLS] = {
#define X(i, n, t, c) [i] = WMTR_SYNC_##c,
#include "wmtr_calls.inc"
#undef X
};
static const uint32_t call_size[WMTR_NCALLS] = {
#define X(i, n, t, c) [i] = WMTR_SIZEOF_##c(t),
#define WMTR_SIZEOF_A(t) sizeof(t)
#define WMTR_SIZEOF_S(t) sizeof(t)
#define WMTR_SIZEOF_B(t) sizeof(t)
#define WMTR_SIZEOF_C(t) sizeof(t)
#define WMTR_SIZEOF_N(t) 0
#include "wmtr_calls.inc"
#undef X
};

static NTSTATUS
entry_untraced(uint16_t call, void *params) {
  if (call == 0 || call == 1) { /* retain / release take the handle itself */
    b_begin(params, 8);
    return send_built(call, 0, params, 8);
  }
  return dispatch(call, params, call_size[call], call_sync[call]);
}

static NTSTATUS
entry(uint16_t call, void *params) {
  pthread_once(&init_once, wmtr_init);
  if (!init_ok) return STATUS_UNSUCCESSFUL;
  if (__builtin_expect(trace_f != NULL, 0)) {
    trace_call('>', call, params, call_size[call], 0);
    NTSTATUS st = entry_untraced(call, params);
    trace_call('<', call, params, call_size[call], st);
    return st;
  }
  return entry_untraced(call, params);
}

#define E(n) static NTSTATUS e##n(void *p) { return entry(n, p); }
#define E10(n) E(n##0) E(n##1) E(n##2) E(n##3) E(n##4) E(n##5) E(n##6) E(n##7) E(n##8) E(n##9)
E(0) E(1) E(2) E(3) E(4) E(5) E(6) E(7) E(8) E(9) E10(1) E10(2) E10(3) E10(4) E10(5) E10(6) E10(7) E10(8) E10(9)
E10(10) E10(11) E10(12) E10(13) E(140) E(141) E(142) E(143) E(144) E(145) E(146)
#define P(n) e##n,
#define P10(n) P(n##0) P(n##1) P(n##2) P(n##3) P(n##4) P(n##5) P(n##6) P(n##7) P(n##8) P(n##9)
__attribute__((visibility("default"))) const void *__wine_unix_call_funcs[WMTR_NCALLS] = {
    P(0) P(1) P(2) P(3) P(4) P(5) P(6) P(7) P(8) P(9) P10(1) P10(2) P10(3) P10(4) P10(5) P10(6) P10(7) P10(8) P10(9)
        P10(10) P10(11) P10(12) P10(13) P(140) P(141) P(142) P(143) P(144) P(145) P(146)};
_Static_assert(WMTR_NCALLS == 147, "add entries for new calls above");

/* test hook: wait through the transport for *done >= seq on reply slot `slot` */
__attribute__((visibility("default"))) int
wmtr_debug_wait(volatile uint64_t *done, uint64_t seq, uint32_t slot) {
  pthread_once(&init_once, wmtr_init);
  if (!init_ok) return -1;
  T->wait(T, done, seq, slot, wmtr_spin_budget_ns(WMTR_CLS_S));
  return 0;
}

/* measurement hook: one synchronous no-op round trip through the transport and host executor */
__attribute__((visibility("default"))) int
wmtr_debug_ping(void) {
  pthread_once(&init_once, wmtr_init);
  if (!init_ok) return -1;
  uint64_t dummy = 0;
  b_begin(&dummy, 8);
  B.force_sync = 1;
  return send_built_flags(WMTR_CTL_PING, WMTR_F_CONTROL, &dummy, 8);
}

/* guest VR runtime link (guest/vr/runtime/transport.cpp): one message of the guest VR protocol
 * (guest/vr/include/steamac_vr_guest.h) answered by the executor's VR exporter on this process's own
 * context, so the same ring orders it with the DXMT work. Returns 0 or a negative errno. */
__attribute__((visibility("default"))) int
wmtr_vr_call(const void *req, uint32_t req_size, void *rep, uint32_t rep_cap) {
  pthread_once(&init_once, wmtr_init);
  if (!init_ok) return -ENODEV;
  uint8_t buf[4096] __attribute__((aligned(8)));
  uint32_t size = WMTR_ALIGN8(req_size > rep_cap ? req_size : rep_cap);
  if (!req || !rep || req_size < 8 || size > sizeof buf) return -EINVAL;
  memset(buf, 0, size);
  memcpy(buf, req, req_size);
  b_begin(buf, size);
  B.force_sync = 1;
  NTSTATUS st = send_built_flags(WMTR_CTL_VR_QUERY, WMTR_F_CONTROL, buf, size);
  if (st) return -EIO;
  uint32_t got = ((const uint32_t *)buf)[1]; /* reply header: op, size */
  if (got < 8 || got > rep_cap) return -EPROTO;
  memcpy(rep, buf, got);
  return 0;
}
