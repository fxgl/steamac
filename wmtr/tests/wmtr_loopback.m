/* wmtr_loopback: client and host executor in one process over an in-memory transport.
 * Oracle: each test calls a winemetal entry once directly (the native path: the implementation
 * reads the caller's memory) and once through __wine_unix_call_funcs of the wmtr client (params
 * relocated into the ring, executed by the host, outputs copied back). Results must be identical.
 * The implementations are small fakes with the real param layouts, plus real Metal for newBuffer. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/mman.h>
#include <time.h>

#define WINEMETAL_API
#include "winemetal_thunks.h"
#include "airconv_thunks.h"
#include "wmtr_wire.h"
#include "wmtr_transport.h"
#include "wmtr_host.h"
#include "wmtr_vr.h"
#include "vrlink.h"
#include "steamac_vr_guest.h"
#include <IOSurface/IOSurface.h>
#include <servers/bootstrap.h>
#include <sys/socket.h>
#include <poll.h>

typedef int NTSTATUS;
typedef NTSTATUS (*fn_t)(void *);
extern const void *__wine_unix_call_funcs[];
extern int wmtr_vr_call(const void *req, uint32_t req_size, void *rep, uint32_t rep_cap);

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)
/* the free-ring burst below deadlocks before the fix, and a deadlocked test would otherwise hang forever */
static _Atomic int burst_done;
static void *
burst_watchdog(void *arg) {
  (void)arg;
  for (int i = 0; i < 200; i++) {
    usleep(100000);
    if (atomic_load_explicit(&burst_done, memory_order_relaxed)) return NULL;
  }
  fprintf(stderr, "FAIL %s:%d: the executor waited for a client drain with a full free ring (deadlock)\n", __FILE__, __LINE__);
  _exit(1);
  return NULL;
}

/* ---------------- fake implementations (the "host Metal") ---------------- */
static NTSTATUS f_getcstring(void *a) {
  struct unixcall_nsstring_getcstring *p = a;
  const char *s = (const char *)p->str; /* the fake NSString handle is a C string */
  strncpy((char *)(uintptr_t)p->buffer_ptr, s, p->max_length);
  p->ret = 1;
  return 0;
}
static uint64_t encode_sum; static uint32_t encode_cmds, encode_vp;
static NTSTATUS f_render_encode(void *a) {
  struct unixcall_generic_obj_cmd_noret *p = a;
  for (const struct wmtcmd_base *c = p->cmd_head.ptr; c; c = c->next.ptr) {
    encode_cmds++;
    if (c->type == WMTRenderCommandSetFragmentBytes) {
      const struct wmtcmd_render_setbytes *b = (const void *)c;
      for (uint64_t i = 0; i < b->length; i++) encode_sum += ((const uint8_t *)b->bytes.ptr)[i];
    } else if (c->type == WMTRenderCommandSetViewports) {
      const struct wmtcmd_render_setviewports *v = (const void *)c;
      for (int i = 0; i < v->viewport_count; i++) encode_vp += (uint32_t)((const struct WMTViewport *)v->viewports.ptr)[i].width;
    }
  }
  return 0;
}
static NTSTATUS f_getbytes(void *a) {
  struct unixcall_mtltexture_replaceregion *p = a;
  uint8_t *d = p->data.ptr;
  for (uint64_t i = 0; i < p->bytes_per_row * p->size.height; i++) d[i] = (uint8_t)(i * 7 + p->level);
  return 0;
}
static uint64_t replace_sum;
static NTSTATUS f_replace(void *a) {
  struct unixcall_mtltexture_replaceregion *p = a;
  const uint8_t *d = p->data.ptr;
  for (uint64_t i = 0; i < p->bytes_per_row * p->size.height; i++) replace_sum += d[i] * (i + 1);
  return 0;
}
static NTSTATUS f_argsinfo(void *a) { (void)a; return 0; }
static NTSTATUS f_noop(void *a) { (void)a; return 0; }
static NTSTATUS f_fault(void *a) { (void)a; return *(volatile int *)(uintptr_t)0x10; }
/* an autoreleased result whose lifetime the test watches */
static int probe_alive;
@interface Probe : NSObject
@end
@implementation Probe
- (instancetype)init { if ((self = [super init])) probe_alive = 1; return self; }
- (void)dealloc { probe_alive = 0; [super dealloc]; }
@end
/* A shared event keeps the actual notification block registered by host_call(104). Delivering it
 * explicitly makes the after-destroy race deterministic, without depending on Metal queue timing. */
@interface DelayedSharedEvent : NSObject {
  MTLSharedEventNotificationBlock notification;
}
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block;
- (void)fire;
@end
@implementation DelayedSharedEvent
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block {
  [notification release];
  notification = [block copy];
}
- (void)fire { if (notification) notification((id<MTLSharedEvent>)self, 1); }
- (void)dealloc { [notification release]; [super dealloc]; }
@end
static NTSTATUS f_autoreleased(void *a) { ((struct unixcall_generic_obj_ret *)a)->ret = (obj_handle_t)[[[Probe alloc] init] autorelease]; return 0; }
/* DXMT's out-errors: autoreleased NSError retained before the handle is returned (+1, owned by the caller) */
static int err_alive;
@interface ErrProbe : NSObject
@end
@implementation ErrProbe
- (instancetype)init { if ((self = [super init])) err_alive = 1; return self; }
- (void)dealloc { err_alive = 0; [super dealloc]; }
@end
static NTSTATUS f_newlibrary(void *a) {
  struct unixcall_mtldevice_newlibrary *p = a;
  p->ret_library = 0;
  p->ret_error = (obj_handle_t)[[[[ErrProbe alloc] init] autorelease] retain];
  return 0;
}
/* SM50Compile: walks the argument list the way airconv does; sums each root signature's bytecode */
static uint64_t sm50_rs_sum[2]; static uint32_t sm50_rs_len[2];
static NTSTATUS f_sm50compile(void *a) {
  struct sm50_compile_params *p = a;
  memset(sm50_rs_sum, 0, sizeof sm50_rs_sum); memset(sm50_rs_len, 0, sizeof sm50_rs_len);
  for (struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *g = p->args; g; g = g->next) {
    if (g->type != SM50_SHADER_ROOT_SIGNATURE && g->type != SM50_SHADER_ROOT_SIGNATURE2) continue;
    struct SM50_SHADER_ROOT_SIGNATURE_DATA *d = (void *)g;
    int k = g->type == SM50_SHADER_ROOT_SIGNATURE2;
    sm50_rs_len[k] = (uint32_t)d->bytecode_length;
    for (size_t i = 0; i < d->bytecode_length; i++) sm50_rs_sum[k] = sm50_rs_sum[k] * 31 + ((const uint8_t *)d->bytecode)[i];
  }
  *p->bitcode = (sm50_bitcode_t)(uintptr_t)0x5150; p->ret = 0;
  return 0;
}
static NTSTATUS f_pixelformat(void *a) { ((struct unixcall_generic_obj_uint64_ret *)a)->ret = 70; return 0; } /* RGBA8 */
static NTSTATUS f_release(void *a) { [(id)*(obj_handle_t *)a release]; return 0; }
static NTSTATUS f_newfunction(void *a) {
  struct unixcall_generic_obj_uint64_obj_ret *p = a;
  p->ret = strlen((const char *)(uintptr_t)p->arg) * 1000 + p->handle;
  return 0;
}
static NTSTATUS f_signal(void *p) { /* encodeSignalEvent, as DXMT's unix side */
  struct unixcall_generic_obj_obj_uint64_noret *a = p;
  [(id<MTLCommandBuffer>)a->handle encodeSignalEvent:(id<MTLSharedEvent>)a->arg0 value:a->arg1];
  return 0;
}
static NTSTATUS f_commit(void *a) { [(id<MTLCommandBuffer>)((struct unixcall_generic_obj_noret *)a)->handle commit]; return 0; }
/* encoders: autoreleased objects; the log records (call, receiver or result) in execution order */
static uint64_t enc_log[64][2]; static int n_enc_log;
static void enc_note(uint64_t call, uint64_t v) { if (n_enc_log < 64) { enc_log[n_enc_log][0] = call; enc_log[n_enc_log][1] = v; } n_enc_log++; }
static NTSTATUS f_new_encoder(uint64_t *ret, uint64_t call, int fail) {
  *ret = fail ? 0 : (obj_handle_t)[[[NSObject alloc] init] autorelease];
  enc_note(call, *ret);
  return 0;
}
static NTSTATUS f_blit_enc(void *a) { return f_new_encoder(&((struct unixcall_generic_obj_obj_ret *)a)->ret, 30, 0); }
static NTSTATUS f_compute_enc(void *a) { struct unixcall_generic_obj_uint64_obj_ret *p = a; return f_new_encoder(&p->ret, 31, p->arg == 99); }
static NTSTATUS f_render_enc(void *a) {
  struct unixcall_generic_obj_uint64_obj_ret *p = a;
  const struct WMTRenderPassInfo *i = (const void *)(uintptr_t)p->arg;
  return f_new_encoder(&p->ret, 32, !i || i->render_target_width != 640);
}
static NTSTATUS f_end_encoding(void *a) { enc_note(33, ((struct unixcall_generic_obj_noret *)a)->handle); return 0; }
static NTSTATUS f_compute_encode(void *a) { enc_note(37, ((struct unixcall_generic_obj_cmd_noret *)a)->encoder); return 0; }
const void *wmtr_impl_funcs[WMTR_NCALLS] = {[12] = f_commit, [1] = f_release, [17] = f_signal, [25] = f_newlibrary, [76] = f_sm50compile, [30] = f_blit_enc, [31] = f_compute_enc, [32] = f_render_enc,
                                    [33] = f_end_encoding, [37] = f_compute_encode, [8] = f_getcstring, [26] = f_newfunction, [38] = f_render_encode,
                                    [39] = f_pixelformat, [47] = f_noop, [53] = f_autoreleased, [5] = f_fault, [88] = f_argsinfo, [45] = f_replace, [145] = f_getbytes};

/* ---------------- loopback transport ---------------- */
static struct wmtr_host *H;
static void *blob_base[WMTR_MAX_BLOBS]; static uint64_t blob_size[WMTR_MAX_BLOBS];
static void *t_blob_ptr(void *c, uint32_t b, uint64_t *s) { if (b >= WMTR_MAX_BLOBS) return NULL; *s = blob_size[b]; return blob_base[b]; }
static uint64_t wake_count;
static void t_wake(void *c, uint32_t s) { __atomic_fetch_add(&wake_count, 1, __ATOMIC_RELAXED); }
static uint64_t next_view = 0x1000, released[8]; static int n_released;
uint64_t wmtr_test_present_create_view(void *c, uint64_t hwnd, void *dev, uint64_t *layer) { *layer = 0x77; return next_view++; }
void wmtr_test_present_release_view(void *c, uint64_t v) { if (n_released < 8) released[n_released] = v; n_released++; }
static const struct wmtr_host_ops host_ops = {t_blob_ptr, t_wake};
static void *pages(uint64_t n) { void *p; posix_memalign(&p, WMTR_PAGE, n); memset(p, 0, n); return p; }
static void *t_open_ring(struct wmtr_transport *t, uint64_t size) {
  struct wmtr_ring *R = pages(size);
  R->magic = WMTR_RING_MAGIC; R->version = WMTR_VERSION;
  blob_base[0] = R; blob_size[0] = size;
  H = wmtr_host_create(R, &host_ops, NULL);
  return R;
}
/* arena blobs are their own mappings, like the shm blobs of the real transports */
static void *t_add_blob(struct wmtr_transport *t, uint32_t b, uint64_t size) {
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) return NULL;
  blob_base[b] = p; blob_size[b] = size; return p;
}
static int n_blob_released;
static void t_release_blob(struct wmtr_transport *t, uint32_t b, void *base, uint64_t size) {
  if (base == blob_base[b] && size == blob_size[b]) { munmap(blob_base[b], size); blob_base[b] = NULL; blob_size[b] = 0; n_blob_released++; }
}
static uint64_t arena_bytes(void) { uint64_t n = 0; for (int b = 1; b < WMTR_MAX_BLOBS; b++) n += blob_base[b] ? blob_size[b] : 0; return n; }
static uint64_t footprint(void) { struct rusage_info_v2 ri; return proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&ri) ? 0 : ri.ri_phys_footprint; }
static void t_kick(struct wmtr_transport *t) { wmtr_host_kick(H); }
static void t_wait(struct wmtr_transport *t, volatile uint64_t *d, uint64_t seq, uint32_t slot, uint64_t spin_ns) { (void)spin_ns; while (__atomic_load_n(d, __ATOMIC_ACQUIRE) < seq) sched_yield(); }
struct wmtr_transport *wmtr_transport_create(void) {
  struct wmtr_transport *t = calloc(1, sizeof *t);
  t->open_ring = t_open_ring; t->add_blob = t_add_blob; t->kick = t_kick; t->wait = t_wait;
  t->release_blob = t_release_blob;
  return t;
}
static NTSTATUS remote(int call, void *p) { return ((fn_t)__wine_unix_call_funcs[call])(p); }
static NTSTATUS native(int call, void *p) { return ((fn_t)wmtr_impl_funcs[call])(p); }


/* ---------------- VR export (call 146) ---------------- */
extern kern_return_t bootstrap_register2(mach_port_t, name_t, mach_port_t, uint64_t);
static mach_port_t vr_port;
static IOSurfaceRef vr_surf[16][VRL_MAX_IMAGES];
static uint32_t vr_fmt[16];
/* the steamac-vrhost end, minimal: next packet; swapchain ports are taken from the Mach port */
static int vr_recv(int fd, void *buf, size_t n, int timeout_ms) {
  struct pollfd pf = {fd, POLLIN, 0};
  if (poll(&pf, 1, timeout_ms) != 1) return -1;
  int r = (int)recv(fd, buf, n, 0);
  struct vrl_header *h = buf;
  if (r >= (int)sizeof(struct vrl_swapchain) && h->type == VRL_SWAPCHAIN) {
    struct vrl_swapchain *sc = buf;
    struct vrl_mach_swapchain_rcv m;
    memset(&m, 0, sizeof m);
    if (mach_msg(&m.msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, vr_port, 2000, MACH_PORT_NULL) == KERN_SUCCESS &&
        m.msg.swapchain_id == sc->id && sc->id < 16) {
      for (uint32_t i = 0; i < m.msg.image_count; i++) {
        vr_surf[sc->id][i] = IOSurfaceLookupFromMachPort(m.msg.ports[i].name);
        mach_port_deallocate(mach_task_self(), m.msg.ports[i].name);
      }
      vr_fmt[sc->id] = sc->pixel_format;
    }
  }
  return r;
}
static int vr_next(int fd, uint32_t type, void *buf, size_t n) {
  for (int i = 0; i < 16; i++) {
    if (vr_recv(fd, buf, n, 3000) <= 0) return 0;
    if (((struct vrl_header *)buf)->type == type) return 1;
  }
  return 0;
}
static uint32_t pattern(int eye, uint32_t x, uint32_t y) { return 0xff000000u | ((eye ? 0x00ff00u : 0x0000ffu) ^ (((x * 3 + y * 5) & 0xff) << 16)); }
static int surface_matches(IOSurfaceRef s, int eye, uint32_t ox, uint32_t oy, uint32_t w, uint32_t h) {
  IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
  const uint8_t *b = IOSurfaceGetBaseAddress(s); size_t bpr = IOSurfaceGetBytesPerRow(s);
  int ok = IOSurfaceGetWidth(s) == w && IOSurfaceGetHeight(s) == h;
  for (uint32_t y = 0; ok && y < h; y++)
    for (uint32_t x = 0; ok && x < w; x++) ok = ((const uint32_t *)(b + y * bpr))[x] == pattern(eye, ox + x, oy + y);
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return ok;
}
/* guest OpenVR runtime polls (WMTR_CTL_VR_QUERY through the ring, answered from the newest host packets) */
static void test_vr_query(struct wmtr_vr *vr, int host_fd) {
  struct svr_hello_req hq = {{SVR_HELLO, sizeof hq}, SVR_VERSION, 1, "test"};
  struct svr_hello_rep hr;
  CHECK(wmtr_vr_call(&hq, sizeof hq, &hr, sizeof hr) == 0 && hr.h.op == SVR_HELLO && hr.version == SVR_VERSION &&
        !hr.connected, "hello before any host state");
  struct svr_frame_req fq = {{SVR_FRAME, sizeof fq}, 0};
  struct svr_frame_rep fr;
  CHECK(wmtr_vr_call(&fq, sizeof fq, &fr, sizeof fr) == 0 && fr.frame_id == 1 && fr.refresh_hz == 90.0f &&
        fr.wake_up <= fr.predicted_display, "frame without a headset keeps a local cadence");

  struct vrl_state st = {{VRL_STATE, sizeof st}, 1, 1832, 1920, 72.0f, 0.065f, {{-0.9f, 0.8f, 0.85f, -0.85f}, {-0.8f, 0.9f, 0.85f, -0.85f}},
                         VRL_PROFILE_INDEX, 0, "Quest 3"};
  /* host clock = this process's (CLOCK_UPTIME_RAW, as steamac-vrhost): a current pacer frame */
  const int64_t t0 = (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 5000000;
  struct vrl_timing tm = {{VRL_TIMING, sizeof tm}, 500, t0, t0 + 27777778, 72.0f, 0};
  struct vrl_poses po = {{VRL_POSES, sizeof po}, t0 + 27777778};
  for (int d = 0; d < VRL_DEV_COUNT; d++) {
    po.pose[d].orientation[3] = 1;
    po.pose[d].position[0] = (float)d;
    po.pose[d].flags = VRL_POSE_VALID | VRL_POSE_TRACKED;
  }
  struct vrl_input in = {{VRL_INPUT, sizeof in}, 999, VRL_PROFILE_INDEX, 0};
  in.value[1][SVR_IN_TRIGGER_VALUE] = 0.5f;
  in.value[0][SVR_IN_THUMBSTICK_X] = -1.0f;
  send(host_fd, &st, sizeof st, 0); send(host_fd, &tm, sizeof tm, 0);
  send(host_fd, &po, sizeof po, 0); send(host_fd, &in, sizeof in, 0);

  CHECK(wmtr_vr_call(&hq, sizeof hq, &hr, sizeof hr) == 0 && hr.connected && hr.eye_width == 1832 && hr.refresh_hz == 72.0f &&
        hr.profile == SVR_PROFILE_INDEX && !strcmp(hr.name, "Quest 3") && hr.fov[1][1] == 0.9f, "hello from VRL_STATE");
  fq.last_frame_id = 0;
  CHECK(wmtr_vr_call(&fq, sizeof fq, &fr, sizeof fr) == 0 && fr.frame_id == 500 && fr.wake_up == t0 &&
        fr.predicted_display == t0 + 27777778 && fr.pose_time == po.time && fr.pose[SVR_DEV_RIGHT_AIM].position[0] == 4.0f &&
        fr.input[1][SVR_IN_TRIGGER_VALUE] == 0.5f && fr.input[0][SVR_IN_THUMBSTICK_X] == -1.0f && fr.connected,
        "frame from VRL_TIMING/POSES/INPUT");
  fq.last_frame_id = 500; /* the guest already rendered it: continue the cadence */
  /* no newer host frame: the next one a period later (wmtr_vr_frame_cadence) */
  CHECK(wmtr_vr_call(&fq, sizeof fq, &fr, sizeof fr) == 0 && fr.frame_id == 501 &&
        fr.wake_up == t0 + (int64_t)(1e9f / 72.0f), "frame after the pacer's");

  struct svr_haptic_req hp = {{SVR_HAPTIC, sizeof hp}, 1, 0.05f, 160.0f, 0.75f};
  struct svr_ack ack;
  CHECK(wmtr_vr_call(&hp, sizeof hp, &ack, sizeof ack) == 0 && ack.status == 0, "haptic ack");
  union { struct vrl_header h; struct vrl_haptics hx; uint8_t raw[1024]; } u;
  CHECK(vr_next(host_fd, VRL_HAPTICS, &u, sizeof u) && u.hx.hand == 1 && u.hx.duration_s == 0.05f && u.hx.amplitude == 0.75f,
        "VRL_HAPTICS not sent");
  struct svr_hdr bogus = {77, sizeof bogus};
  CHECK(wmtr_vr_call(&bogus, sizeof bogus, &ack, sizeof ack) != 0, "unknown op accepted");
  struct wmtr_vr_stats s; wmtr_vr_get_stats(vr, &s);
  CHECK(s.queries >= 6 && s.haptics == 1, "query stats %llu/%llu", s.queries, s.haptics);
}

static void test_vr(id<MTLDevice> dev) {
  struct unixcall_wmtvr_submit sub;
  memset(&sub, 0, sizeof sub);
  CHECK(wmtr_vr_submit(NULL, &sub.info) == (int)0xC00000BB, "no exporter: not STATUS_NOT_SUPPORTED");
  char name[64]; snprintf(name, sizeof name, "com.steamac.vrhost.test.%d", (int)getpid());
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &vr_port);
  mach_port_insert_right(mach_task_self(), vr_port, vr_port, MACH_MSG_TYPE_MAKE_SEND);
  kern_return_t kr = bootstrap_register2(bootstrap_port, name, vr_port, 0);
  CHECK(kr == KERN_SUCCESS, "bootstrap_register2: %d", kr);
  int sv[2]; socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
  struct wmtr_vr *vr = wmtr_vr_create(sv[0], name);
  wmtr_host_set_vr(H, vr);
  union { struct vrl_header h; struct vrl_hello hello; struct vrl_submit s; uint8_t raw[1024]; } u;
  CHECK(vr_next(sv[1], VRL_HELLO, &u, sizeof u) && u.hello.version == VRL_VERSION, "no VRL_HELLO");
  /* two eye textures: an atlas-style left eye (sub-rect) and a whole right eye */
  id<MTLTexture> tex[2];
  uint32_t TW = 320, TH = 200;
  for (int e = 0; e < 2; e++) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:TW height:TH mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    tex[e] = [dev newTextureWithDescriptor:d];
    uint32_t *px = malloc(TW * TH * 4);
    for (uint32_t y = 0; y < TH; y++) for (uint32_t x = 0; x < TW; x++) px[y * TW + x] = pattern(e, x, y);
    [tex[e] replaceRegion:MTLRegionMake2D(0, 0, TW, TH) mipmapLevel:0 withBytes:px bytesPerRow:TW * 4];
    free(px);
  }
  /* the guest's rendering is ordered through a shared event: the export must wait for it */
  id<MTLSharedEvent> ev = [dev newSharedEvent];
  sub.info.frame_id = 7; sub.info.display_time = 123456789;
  sub.info.eye[0] = (struct WMTVREye){(obj_handle_t)tex[0], 16, 8, 256, 128, WMTVR_EYE_FLIP_Y, 0};
  sub.info.eye[1] = (struct WMTVREye){(obj_handle_t)tex[1], 0, 0, 0, 0, 0, 0};
  for (int e = 0; e < 2; e++) {
    float pose[7] = {0, 0, 0, 1, e ? 0.032f : -0.032f, 1.6f, 0};
    float fov[4] = {-0.9f, 0.8f, 0.85f, -0.95f};
    memcpy(sub.info.pose[e], pose, sizeof pose); memcpy(sub.info.fov[e], fov, sizeof fov);
  }
  sub.info.wait_event = (obj_handle_t)ev; sub.info.wait_value = 1;
  remote(146, &sub);
  struct unixcall_generic_obj_uint64_ret sync = {0}; remote(39, &sync);
  /* not signalled yet: nothing may arrive */
  struct pollfd pf = {sv[1], POLLIN, 0};
  int got_early = 0;
  while (poll(&pf, 1, 200) == 1) { vr_recv(sv[1], &u, sizeof u, 0); if (u.h.type == VRL_SUBMIT) got_early = 1; }
  CHECK(!got_early, "VRL_SUBMIT before the guest's work completed");
  ev.signaledValue = 1;
  int ok = vr_next(sv[1], VRL_SUBMIT, &u, sizeof u);
  CHECK(ok && u.s.frame_id == 7 && u.s.display_time == 123456789 && u.s.ready_time >= u.s.app_submit_time, "VRL_SUBMIT");
  if (ok) {
    CHECK(u.s.eye[0].w == 256 && u.s.eye[0].h == 128 && (u.s.eye[0].flags & VRL_EYE_FLIP_Y) && u.s.eye[1].w == TW && u.s.eye[1].h == TH,
          "eye rects %ux%u %ux%u", u.s.eye[0].w, u.s.eye[0].h, u.s.eye[1].w, u.s.eye[1].h);
    CHECK(u.s.pose[1][4] == 0.032f && u.s.fov[0][3] == -0.95f, "pose/fov not passed through");
    for (int e = 0; e < 2; e++) {
      IOSurfaceRef sf = u.s.eye[e].swapchain < 16 ? vr_surf[u.s.eye[e].swapchain][u.s.eye[e].image] : NULL;
      CHECK(sf && vr_fmt[u.s.eye[e].swapchain] == MTLPixelFormatRGBA8Unorm_sRGB, "eye %d: no surface", e);
      if (sf) CHECK(surface_matches(sf, e, e ? 0 : 16, e ? 0 : 8, e ? TW : 256, e ? TH : 128), "eye %d pixels differ", e);
    }
  }
  /* stage split of submit->copied: that frame waited >= 200 ms for the guest's event and no signal was encoded
   * through the executor, so the wait counts as rendering; the stages add up to ready - submit */
  struct wmtr_vr_stats sg; wmtr_vr_get_stats(vr, &sg);
  uint64_t sum = 0; for (int i = 0; i < WMTR_VR_STAGES; i++) sum += sg.stage_ns[i];
  CHECK(sg.stage_frames == 1 && sg.stage_ns[WMTR_VR_STAGE_ENCODE] == 0 && sg.stage_ns[WMTR_VR_STAGE_RENDER] >= 150000000ull &&
        ok && sum == (uint64_t)(u.s.ready_time - u.s.app_submit_time),
        "stages of frame 7: %llu frames, encode %llu render %llu sum %llu", sg.stage_frames, sg.stage_ns[0], sg.stage_ns[1], sum);
  /* a frame whose rendering is still being encoded when the submit arrives (the normal live order): the signal
   * goes through the executor (call 17) 60 ms after the submit, the GPU reaches it 60 ms later */
  if (ok) {
    struct vrl_release r7 = {{VRL_RELEASE, sizeof r7}, u.s.eye[0].swapchain, u.s.eye[0].image, u.s.frame_id, 0};
    send(sv[1], &r7, sizeof r7, 0);
    r7.swapchain = u.s.eye[1].swapchain; r7.image = u.s.eye[1].image; send(sv[1], &r7, sizeof r7, 0);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    id<MTLCommandQueue> gq = [dev newCommandQueue];
    id<MTLCommandBuffer> gcb = [gq commandBuffer];
    [gcb encodeWaitForEvent:gate value:1];
    sub.info.frame_id = 30; sub.info.wait_value = 2;
    remote(146, &sub); remote(39, &sync);
    usleep(60000);
    struct unixcall_generic_obj_obj_uint64_noret se = {(obj_handle_t)gcb, (obj_handle_t)ev, 2};
    remote(17, &se); remote(39, &sync);
    [gcb commit];
    usleep(60000);
    gate.signaledValue = 1;
    int ok30 = vr_next(sv[1], VRL_SUBMIT, &u, sizeof u);
    struct wmtr_vr_stats s2; wmtr_vr_get_stats(vr, &s2);
    uint64_t enc = s2.stage_ns[WMTR_VR_STAGE_ENCODE] - sg.stage_ns[WMTR_VR_STAGE_ENCODE], ren = s2.stage_ns[WMTR_VR_STAGE_RENDER] - sg.stage_ns[WMTR_VR_STAGE_RENDER];
    uint64_t sum2 = 0; for (int i = 0; i < WMTR_VR_STAGES; i++) sum2 += s2.stage_ns[i];
    CHECK(ok30 && u.s.frame_id == 30 && s2.stage_frames == 2 && enc >= 55000000ull && enc < 120000000ull && ren >= 55000000ull &&
          sum2 - sum == (uint64_t)(u.s.ready_time - u.s.app_submit_time),
          "stages of frame 30: sent %d, encode %llu render %llu", ok30, enc, ren);
    [gq release]; [gate release];
  }
  /* back-pressure: 3 images per eye, one still held by the host -> of 3 more frames, 2 go out and 1 drops */
  struct vrl_submit held = u.s;
  sub.info.wait_event = 0; sub.info.wait_value = 0;
  for (int i = 0; i < 3; i++) { sub.info.frame_id = 8 + i; remote(146, &sub); }
  remote(39, &sync);
  int n = 0;
  while (n < 2 && vr_next(sv[1], VRL_SUBMIT, &u, sizeof u)) n++;
  struct wmtr_vr_stats st; wmtr_vr_get_stats(vr, &st);
  CHECK(n == 2 && st.dropped == 1 && st.swapchains == 2, "back-pressure: %d sent, %llu dropped, %llu swapchains", n, st.dropped, st.swapchains);
  /* releasing the held image lets the next frame through */
  struct vrl_release rel = {{VRL_RELEASE, sizeof rel}, held.eye[0].swapchain, held.eye[0].image, held.frame_id, 0};
  send(sv[1], &rel, sizeof rel, 0);
  rel.swapchain = held.eye[1].swapchain; rel.image = held.eye[1].image; send(sv[1], &rel, sizeof rel, 0);
  sub.info.frame_id = 20; remote(146, &sub); remote(39, &sync);
  CHECK(vr_next(sv[1], VRL_SUBMIT, &u, sizeof u) && u.s.frame_id == 20, "frame after release not sent");
  /* a stalled host (link buffer full): the copy's completion handler must not block on the send (it would stall
   * Metal's completion thread for the whole process); the frame is dropped and its images freed */
  {
    rel.swapchain = u.s.eye[0].swapchain; rel.image = u.s.eye[0].image; send(sv[1], &rel, sizeof rel, 0);
    rel.swapchain = u.s.eye[1].swapchain; rel.image = u.s.eye[1].image; send(sv[1], &rel, sizeof rel, 0);
    remote(39, &sync);
    struct vrl_submit junk; memset(&junk, 0, sizeof junk); /* the size of the frame's packet: no room for it after */
    int filled = 0;
    while (send(sv[0], &junk, sizeof junk, MSG_DONTWAIT) > 0) filled++;
    struct wmtr_vr_stats s0; wmtr_vr_get_stats(vr, &s0);
    sub.info.frame_id = 25; remote(146, &sub); remote(39, &sync);
    int64_t t_wait = (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    struct wmtr_vr_stats s1;
    do { usleep(2000); wmtr_vr_get_stats(vr, &s1); }
    while (s1.dropped == s0.dropped && s1.sent == s0.sent && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t_wait < 2000000000ull);
    CHECK(filled > 0 && s1.dropped == s0.dropped + 1 && s1.sent == s0.sent,
          "stalled host: filled %d, dropped %llu -> %llu, sent %llu -> %llu", filled, s0.dropped, s1.dropped, s0.sent, s1.sent);
    char drain[4096];
    while (recv(sv[1], drain, sizeof drain, MSG_DONTWAIT) > 0) {}
  }
  /* a size change recreates the swapchain (new ports, new id) */
  sub.info.eye[0].w = 128; sub.info.eye[0].h = 64; sub.info.frame_id = 21;
  remote(146, &sub); remote(39, &sync);
  /* all images of eye 1 may be busy now; free everything first */
  ok = vr_next(sv[1], VRL_SUBMIT, &u, sizeof u);
  wmtr_vr_get_stats(vr, &st);
  CHECK(st.swapchains == 3, "resize: %llu swapchains", st.swapchains);
  /* a bad handle (MSAA / missing) is rejected without touching the link */
  sub.info.eye[1].texture = 0; uint64_t errs = st.errors;
  CHECK(wmtr_vr_submit(vr, &sub.info) == (int)0xC000000D, "null eye texture accepted");
  wmtr_vr_get_stats(vr, &st);
  CHECK(st.errors == errs + 1, "error not counted");
  test_vr_query(vr, sv[1]);
  wmtr_host_set_vr(H, NULL);
  wmtr_vr_destroy(vr);
  close(sv[1]);
  [tex[0] release]; [tex[1] release]; [ev release];
  printf("vr: submits=%llu sent=%llu dropped=%llu released=%llu swapchains=%llu\n", st.submits, st.sent, st.dropped, st.released, st.swapchains);
}

/* WMTR_VR_FD (steamac-vm's attach path): one link per process (a dup of the launcher's socketpair end, one
 * VRL_HELLO) shared by every context: a second context (the game after Proton's steam.exe did VR_Init) uses the
 * same link instead of being refused; the last context closes its dup, leaving the launcher's end open. */
static void *pages(uint64_t n);
/* an idle context: its own ring blob (ctx), nothing else */
static void *idle_blob_ptr(void *c, uint32_t b, uint64_t *s) { if (b) return NULL; *s = WMTR_RING_BLOB_BYTES; return c; }
static void t_wake(void *c, uint32_t s);
static const struct wmtr_host_ops idle_ops = {idle_blob_ptr, t_wake};
static struct wmtr_host *idle_host(void) {
  struct wmtr_ring *R = pages(WMTR_RING_BLOB_BYTES);
  R->magic = WMTR_RING_MAGIC; R->version = WMTR_VERSION;
  return wmtr_host_create(R, &idle_ops, R);
}
static void test_vr_fd(void) {
  char name[64]; snprintf(name, sizeof name, "com.steamac.vrhost.fdtest.%d", (int)getpid());
  mach_port_t port;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
  mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
  CHECK(bootstrap_register2(bootstrap_port, name, port, 0) == KERN_SUCCESS, "bootstrap_register2");
  int sv[2]; socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
  char fd[16]; snprintf(fd, sizeof fd, "%d", sv[0]);
  setenv("WMTR_VR_FD", fd, 1); setenv("WMTR_VR_MACH_NAME", name, 1);
  union { struct vrl_header h; struct vrl_hello hello; uint8_t raw[1024]; } u;
  struct wmtr_host *a = idle_host();
  CHECK(vr_recv(sv[1], &u, sizeof u, 2000) > 0 && u.h.type == VRL_HELLO, "WMTR_VR_FD: first context sent no VRL_HELLO");
  struct wmtr_host *b = idle_host();
  CHECK(vr_recv(sv[1], &u, sizeof u, 300) <= 0, "WMTR_VR_FD: second context opened a second link");
  /* the second context answers VR queries from the shared link (the refused one had no link: hello failed) */
  union { struct svr_hello_req q; struct svr_hello_rep r; } hb = {.q = {{SVR_HELLO, sizeof hb.q}, SVR_VERSION, 1, "test"}};
  CHECK(wmtr_host_vr(b) && wmtr_host_vr(b) == wmtr_host_vr(a), "WMTR_VR_FD: second context has no VR link");
  CHECK(wmtr_vr_query(wmtr_host_vr(b), &hb, sizeof hb) == 0 && hb.r.h.op == SVR_HELLO, "WMTR_VR_FD: second context's hello");
  wmtr_host_destroy(a);
  memset(&hb, 0, sizeof hb);
  hb.q = (struct svr_hello_req){{SVR_HELLO, sizeof hb.q}, SVR_VERSION, 1, "test"};
  CHECK(wmtr_vr_query(wmtr_host_vr(b), &hb, sizeof hb) == 0 && hb.r.h.op == SVR_HELLO,
        "WMTR_VR_FD: link closed while second context was still alive");
  wmtr_host_destroy(b);
  CHECK(fcntl(sv[0], F_GETFD) != -1, "WMTR_VR_FD: launcher's end closed");
  struct wmtr_host *c = idle_host();
  CHECK(vr_recv(sv[1], &u, sizeof u, 2000) > 0 && u.h.type == VRL_HELLO,
        "WMTR_VR_FD: new context did not reattach after the last old context ended");
  CHECK(wmtr_host_vr(c) != NULL, "WMTR_VR_FD: link gone after its first contexts ended");
  /* the host's answer to VRL_HELLO (its state) is on its way when a relaunched game's runtime says hello: the
   * hello must carry the headset, not "no headset, 0x0" */
  int host_fd = sv[1];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
    struct vrl_state st = {{VRL_STATE, sizeof st}, 1, 1832, 1920, 72.0f, 0.065f, {{-0.9f, 0.8f, 0.85f, -0.85f}, {-0.8f, 0.9f, 0.85f, -0.85f}},
                           VRL_PROFILE_INDEX, 0, "Quest 3"};
    send(host_fd, &st, sizeof st, 0);
  });
  memset(&hb, 0, sizeof hb);
  hb.q = (struct svr_hello_req){{SVR_HELLO, sizeof hb.q}, SVR_VERSION, 1, "test"};
  CHECK(wmtr_vr_query(wmtr_host_vr(c), &hb, sizeof hb) == 0 && hb.r.connected && hb.r.eye_width == 1832 && hb.r.eye_height == 1920,
        "WMTR_VR_FD: hello right after reattach: connected %u, %ux%u", hb.r.connected, hb.r.eye_width, hb.r.eye_height);
  wmtr_host_destroy(c);
  /* no context for a while: the host's per-frame packets fill the socket. The next link must still get the host's
   * answer to its hello (sent without waiting, as steamac-vrhost does) */
  struct vrl_timing tm = {{VRL_TIMING, sizeof tm}, 7, 1, 2, 72.0f, 0};
  int filled = 0;
  while (send(sv[1], &tm, sizeof tm, MSG_DONTWAIT) == (ssize_t)sizeof tm && filled < 1000000) filled++;
  CHECK(filled > 0 && filled < 1000000, "WMTR_VR_FD: could not fill the link socket (%d)", filled);
  struct wmtr_host *d = idle_host();
  CHECK(vr_next(sv[1], VRL_HELLO, &u, sizeof u), "WMTR_VR_FD: no VRL_HELLO over a full socket");
  /* the host's answer to that hello was lost (not sent here): the runtime's hello asks again and gets the state */
  dispatch_async(dispatch_get_global_queue(0, 0), ^{
    union { struct vrl_header h; uint8_t raw[1024]; } again;
    if (!vr_next(host_fd, VRL_HELLO, &again, sizeof again)) return;
    struct vrl_state st2 = {{VRL_STATE, sizeof st2}, 1, 2000, 2100, 90.0f, 0.065f, {{-0.9f, 0.8f, 0.85f, -0.85f}, {-0.8f, 0.9f, 0.85f, -0.85f}},
                            VRL_PROFILE_INDEX, 0, "Quest 3"};
    send(host_fd, &st2, sizeof st2, MSG_DONTWAIT);
  });
  memset(&hb, 0, sizeof hb);
  hb.q = (struct svr_hello_req){{SVR_HELLO, sizeof hb.q}, SVR_VERSION, 1, "test"};
  CHECK(wmtr_vr_query(wmtr_host_vr(d), &hb, sizeof hb) == 0 && hb.r.connected && hb.r.eye_width == 2000,
        "WMTR_VR_FD: host state lost after the hello (connected %u, %ux%u)", hb.r.connected, hb.r.eye_width, hb.r.eye_height);
  wmtr_host_destroy(d);
  unsetenv("WMTR_VR_FD"); unsetenv("WMTR_VR_MACH_NAME");
  close(sv[0]); close(sv[1]);
  printf("vr fd attach: ok\n");
}

static char frames_path[64];
/* SVR_FRAME cadence across headset connect / disconnect / reconnect (live 2026-10-17: VRChat started without a
 * headset ran ~9050 locally paced frames; after the reconnect the host pacer restarted at id 1 and the guest was
 * told to wake ~9000 frames later, i.e. froze). Each step: ids grow, wake-up within two frames of now. */
static void test_vr_cadence(void) {
  const int64_t P = 11111111; /* 90 Hz */
  struct wmtr_vr_cadence c = {0};
  int64_t now = 1000000000000ll, wake, disp;
  uint64_t last = 0, id;
  int bad = 0;
#define STEP(hid, hwake) do { \
    wmtr_vr_frame_cadence(&c, (hid), (hwake), (hwake) + 2 * P, last, now, P, &id, &wake, &disp); \
    if (id <= last || wake > now + 2 * P || wake < now - 2 * P || disp < wake) bad++; \
    last = id; now += P; } while (0)
  for (int i = 0; i < 9050; i++) STEP(0, 0);                 /* game started, no headset ever connected */
  CHECK(bad == 0 && last == 9050, "no-headset cadence: %d bad, last %llu", bad, (unsigned long long)last);
  for (uint64_t h = 1; h <= 300; h++) STEP(h, now + P / 2);  /* headset connects: pacer ids from 1 */
  CHECK(bad == 0 && last == 9350, "connect: %d bad, last %llu", bad, (unsigned long long)last);
  CHECK(wake == now - P + P / 2, "connect: host wake not used");
  for (int i = 0; i < 500; i++) STEP(300, now - 3 * P - i * P); /* disconnect: the host's last timing goes stale */
  CHECK(bad == 0 && last == 9850, "disconnect: %d bad, last %llu", bad, (unsigned long long)last);
  for (uint64_t h = 1; h <= 300; h++) STEP(h, now + P / 3);  /* reconnect: pacer restarts at 1 again */
  CHECK(bad == 0 && last == 10150, "reconnect: %d bad, last %llu", bad, (unsigned long long)last);
  CHECK(wake == now - P + P / 3, "reconnect: host wake not used");
  STEP(9999, now + 500 * P); /* a timing far ahead is clamped */
  CHECK(bad == 0, "far-ahead timing: wake %lld ms ahead", (long long)((wake - now + P) / 1000000));
#undef STEP
  printf("vr cadence: no headset / connect / disconnect / reconnect / far-ahead ok\n");
}

/* ---------------- hostile requests (a guest that writes the ring itself) ---------------- */
/* One raw record built here, not by the client: header fields, relocs, outs and payload exactly as given. Sent
 * on reply slot 60 (no client thread uses it); returns the reply status, *out_size the reply's size. */
#define RAW_SLOT 60
static uint32_t
raw_request(uint16_t call, uint32_t params_size, uint32_t payload_size, const uint32_t *relocs, uint16_t n_reloc,
            const struct wmtr_out *outs, uint16_t n_out, const void *payload, uint32_t payload_bytes, uint32_t *out_size) {
  struct wmtr_ring *R = blob_base[0];
  uint8_t *data = (uint8_t *)R + WMTR_RING_DATA_OFFSET;
  struct wmtr_slot *slot = (struct wmtr_slot *)((uint8_t *)R + WMTR_SLOTS_OFFSET) + RAW_SLOT;
  struct wmtr_req_ext hdr = {0};
  hdr.h.call = call; hdr.h.flags = WMTR_F_SYNC; hdr.h.slot = RAW_SLOT; hdr.h.params_size = params_size;
  hdr.h.seq = slot->done_seq + 1;
  hdr.n_reloc = n_reloc; hdr.n_out = n_out; hdr.payload_size = payload_size;
  uint32_t poff = wmtr_req_payload_offset(&hdr);
  uint32_t total = WMTR_ALIGN8(poff + payload_bytes);
  hdr.h.size = total;
  while (R->tail != R->head) sched_yield(); /* the client's own requests are consumed */
  uint64_t head = R->head;
  uint32_t pos = (uint32_t)(head % WMTR_RING_BYTES), to_end = WMTR_RING_BYTES - pos;
  if (to_end < total) {
    struct wmtr_req w = {0}; w.size = to_end; w.flags = WMTR_F_WRAP;
    if (to_end >= sizeof w) memcpy(data + pos, &w, sizeof w);
    head += to_end; pos = 0;
  }
  uint8_t *dst = data + pos;
  memset(dst, 0, total);
  memcpy(dst, &hdr, sizeof hdr);
  memcpy(dst + sizeof hdr, relocs, 4u * n_reloc);
  memcpy(dst + sizeof hdr + 4u * n_reloc, outs, sizeof *outs * n_out);
  memcpy(dst + poff, payload, payload_bytes);
  __atomic_store_n(&R->head, head + total, __ATOMIC_RELEASE);
  wmtr_host_kick(H);
  while (__atomic_load_n(&slot->done_seq, __ATOMIC_ACQUIRE) < hdr.h.seq) sched_yield();
  if (out_size) *out_size = slot->out_size;
  return slot->status;
}

/* Every size, offset and reference in a request is the guest's. Before the checks each of these wrote or read
 * host memory outside the request (32-bit wrap-around, or sizes larger than the reply slot / the arena blob). */
static void
test_hostile_requests(id<MTLDevice> dev) {
  { /* a ring blob smaller than the ring layout: the executor would read and write past it */
    uint64_t sz = WMTR_RING_BLOB_BYTES;
    void *small = pages(sz);
    ((struct wmtr_ring *)small)->magic = WMTR_RING_MAGIC; ((struct wmtr_ring *)small)->version = WMTR_VERSION;
    void *save_b = blob_base[0]; uint64_t save_s = blob_size[0];
    blob_base[0] = small; blob_size[0] = WMTR_PAGE;
    struct wmtr_host *hs = wmtr_host_create(small, &host_ops, NULL);
    CHECK(hs == NULL, "executor started on a %u-byte ring blob", WMTR_PAGE);
    if (hs) wmtr_host_destroy(hs);
    blob_base[0] = save_b; blob_size[0] = save_s;
    free(small);
  }
  const uint32_t inval = 0xC000000D;
  struct wmtr_slot *slots = (struct wmtr_slot *)((uint8_t *)blob_base[0] + WMTR_SLOTS_OFFSET);
  uint64_t payload[64] = {0};
  uint32_t out = 0;
  /* reloc offset near 4 GiB: offset + 8 wrapped below payload_size, the host rewrote 8 bytes 4 GiB away */
  uint32_t far = 0xfffffffcu;
  CHECK(raw_request(39, 16, 64, &far, 1, NULL, 0, payload, 64, NULL) == inval, "reloc offset wrap accepted");
  /* payload_size near 4 GiB: poff + payload_size wrapped below the record size */
  uint32_t r0 = 0;
  CHECK(raw_request(39, 16, 0xfffffff8u, &r0, 1, NULL, 0, payload, 64, NULL) == inval, "payload size wrap accepted");
  /* output range near 4 GiB: off + size wrapped, the reply copied from 4 GiB past the payload */
  struct wmtr_out wrap = {0xffffff00u, 0x200};
  uint32_t st = raw_request(39, 16, 64, NULL, 0, &wrap, 1, payload, 64, &out);
  CHECK(out <= 16, "wrapped output range copied (%u bytes, status %x)", out, st);
  /* params larger than a reply slot: the reply overwrote the next slot (and past the ring blob for the last) */
  static uint8_t big[WMTR_SLOT_BYTES + 4096];
  memset(slots[RAW_SLOT + 1].data, 0x5a, 64);
  st = raw_request(39, sizeof big, sizeof big, NULL, 0, NULL, 0, big, sizeof big, &out);
  CHECK(st == inval && out == 0, "params past the reply slot: status %x, %u bytes", st, out);
  CHECK(slots[RAW_SLOT + 1].data[0] == 0x5a && slots[RAW_SLOT + 1].data[63] == 0x5a, "next reply slot overwritten");
  /* params shorter than the call's struct: the implementation read and wrote past the request */
  CHECK(raw_request(8, 0, 0, NULL, 0, NULL, 0, NULL, 0, NULL) == inval, "short params accepted");
  /* newBuffer over arena memory longer than the blob: the NoCopy MTLBuffer reached host memory past it */
  uint32_t blob = 0;
  for (uint32_t b = 1; b < WMTR_MAX_BLOBS && !blob; b++) if (blob_base[b]) blob = b;
  CHECK(blob != 0, "no arena blob to test with");
  if (blob) {
    struct { struct unixcall_mtldevice_newbuffer p; struct WMTBufferInfo info; } nb;
    memset(&nb, 0, sizeof nb);
    nb.p.device = (obj_handle_t)dev;
    nb.p.info.ptr = (void *)(uintptr_t)(WMTR_REF_EXTRA | sizeof nb.p);
    nb.info.length = blob_size[blob] + WMTR_PAGE;
    nb.info.options = WMTResourceStorageModeShared;
    nb.info.memory.ptr = (void *)(uintptr_t)(WMTR_REF_ARENA | (uint64_t)blob << 32);
    uint32_t rel[2] = {offsetof(struct unixcall_mtldevice_newbuffer, info), sizeof nb.p + offsetof(struct WMTBufferInfo, memory)};
    st = raw_request(18, sizeof nb.p, sizeof nb, rel, 2, NULL, 0, &nb, sizeof nb, NULL);
    CHECK(st == inval, "newBuffer past its arena blob: status %x", st);
    nb.info.length = WMTR_PAGE; /* the same request inside the blob still works */
    st = raw_request(18, sizeof nb.p, sizeof nb, rel, 2, NULL, 0, &nb, sizeof nb, &out);
    CHECK(st == 0, "newBuffer inside its arena blob: status %x", st);
    /* kept alive: its deallocator would hand the client a free range the client never allocated */
  }
}

int main(void) {
  @autoreleasepool {
    test_vr_cadence();
    snprintf(frames_path, sizeof frames_path, "/tmp/wmtr_frames_%d.csv", (int)getpid());
    unlink(frames_path);
    setenv("WMTR_FRAMES", frames_path, 1);
    setenv("WMTR_ARENA_TRIM_MS", "300", 1); /* section 7 */
    char stats_path[] = "/tmp/wmtr_callstats_XXXXXX";
    close(mkstemp(stats_path));
    /* WMTR_TEST_TRIGGER=1: statistics turned on at runtime through the trigger file instead of the environment */
    int trigger_mode = getenv("WMTR_TEST_TRIGGER") != NULL;
    char trigger_path[64];
    snprintf(trigger_path, sizeof trigger_path, "/tmp/wmtr_trigger_%d", (int)getpid());
    if (trigger_mode) {
      unsetenv("WMTR_CALLSTATS");
      setenv("WMTR_CALLSTATS_TRIGGER", trigger_path, 1);
      setenv("WMTR_CALLSTATS_POLL_MS", "20", 1);
      FILE *tf = fopen(trigger_path, "w");
      fprintf(tf, "%s\n", stats_path);
      fclose(tf);
    } else {
      setenv("WMTR_CALLSTATS", stats_path, 1);
    }
    /* 1. output buffer through a uint64 pointer field */
    char a[32] = {0}, b[32] = {0};
    struct unixcall_nsstring_getcstring pa = {(obj_handle_t)"metal string", (uint64_t)(uintptr_t)a, sizeof a, 4, 0}, pb = pa;
    pb.buffer_ptr = (uint64_t)(uintptr_t)b;
    native(8, &pa); remote(8, &pb);
    CHECK(!strcmp(a, b) && pb.ret == 1 && pb.buffer_ptr == (uint64_t)(uintptr_t)b, "getCString: '%s' vs '%s'", a, b);
    if (trigger_mode) usleep(200000); /* the first call started the statistics thread; it sees the trigger */

    /* 2. C-string input in a uint64 arg, value result */
    struct unixcall_generic_obj_uint64_obj_ret fa = {5, (uint64_t)(uintptr_t)"vertex_main", 0}, fb = fa;
    native(26, &fa); remote(26, &fb);
    CHECK(fa.ret == fb.ret, "newFunction ret %llu vs %llu", fa.ret, fb.ret);

    /* 3. command list with embedded pointers (async call, then a sync call orders it) */
    struct WMTViewport vps[3] = {{0, 0, 640, 480, 0, 1}, {0, 0, 320, 240, 0, 1}, {0, 0, 7, 7, 0, 1}};
    uint8_t bytes[300]; for (int i = 0; i < 300; i++) bytes[i] = (uint8_t)(i * 13);
    struct wmtcmd_render_setviewports cv = {0}; cv.type = WMTRenderCommandSetViewports; cv.viewports.ptr = vps; cv.viewport_count = 3;
    struct wmtcmd_render_setbytes cbytes = {0}; cbytes.type = WMTRenderCommandSetFragmentBytes; cbytes.bytes.ptr = bytes; cbytes.length = 300; cbytes.index = 2;
    struct wmtcmd_base nop = {0}; nop.type = WMTRenderCommandNop;
    cv.next.ptr = &cbytes; cbytes.next.ptr = &nop; nop.next.ptr = NULL;
    struct unixcall_generic_obj_cmd_noret ce = {0x1234, {&cv}};
    native(38, &ce);
    uint64_t n_sum = encode_sum; uint32_t n_cmds = encode_cmds, n_vp = encode_vp;
    encode_sum = 0; encode_cmds = 0; encode_vp = 0;
    remote(38, &ce);
    remote(26, &fb); /* sync: the async encode before it has executed */
    CHECK(n_sum == encode_sum && n_cmds == encode_cmds && n_vp == encode_vp, "encode sum %llu/%llu cmds %u/%u vp %u/%u",
          n_sum, encode_sum, n_cmds, encode_cmds, n_vp, encode_vp);

    /* 3b. a command list longer than any fixed relocation budget (DXMT batches ~100+ draws per call) */
    {
      enum { N = 2000 };
      static struct wmtcmd_render_setbytes cmds[N]; static uint8_t payload[N][16];
      for (int i = 0; i < N; i++) {
        memset(&cmds[i], 0, sizeof cmds[i]); cmds[i].type = WMTRenderCommandSetFragmentBytes;
        for (int k = 0; k < 16; k++) payload[i][k] = (uint8_t)(i + k);
        cmds[i].bytes.ptr = payload[i]; cmds[i].length = 16; cmds[i].next.ptr = i + 1 < N ? &cmds[i + 1] : NULL;
      }
      struct unixcall_generic_obj_cmd_noret cl = {0x1234, {&cmds[0]}};
      encode_sum = 0; encode_cmds = 0; native(38, &cl);
      uint64_t s1 = encode_sum; uint32_t c1 = encode_cmds;
      encode_sum = 0; encode_cmds = 0; NTSTATUS st = remote(38, &cl); remote(26, &fb);
      CHECK(st == 0 && s1 == encode_sum && c1 == encode_cmds, "long list st=%x sum %llu/%llu cmds %u/%u", st, s1, encode_sum, c1, encode_cmds);
    }
    /* 3c. zero-length output array (SM50GetArgumentsInfo of a shader without constant buffers) */
    {
      struct MTL_SM50_SHADER_ARGUMENT none[1];
      struct sm50_get_arguments_info_params ga = {(sm50_shader_t)0x77, none, none};
      NTSTATUS st = remote(88, &ga);
      CHECK(st == 0 && ga.constant_buffers == none, "zero-length output st=%x", st);
    }

    /* 4. large input (arena staging) and large output (arena) */
    uint32_t W = 1024, Hh = 512; uint8_t *src = malloc(W * 4 * Hh), *o1 = malloc(W * 4 * Hh), *o2 = malloc(W * 4 * Hh);
    for (uint32_t i = 0; i < W * 4 * Hh; i++) src[i] = (uint8_t)(i ^ (i >> 9));
    struct unixcall_mtltexture_replaceregion rr = {0}; rr.texture = 0x9000; rr.size = (struct WMTSize){W, Hh, 1};
    rr.data.ptr = src; rr.bytes_per_row = W * 4; rr.level = 3;
    native(45, &rr); uint64_t n_rs = replace_sum; replace_sum = 0;
    remote(45, &rr); remote(26, &fb);
    CHECK(n_rs == replace_sum, "replaceRegion checksum %llu vs %llu", n_rs, replace_sum);
    rr.data.ptr = o1; native(145, &rr); rr.data.ptr = o2; remote(145, &rr);
    CHECK(!memcmp(o1, o2, W * 4 * Hh) && rr.data.ptr == o2, "getBytes output differs");

    /* 5. newBuffer: client arena memory backs a real MTLBuffer; CPU writes are GPU-visible
          (blit to a private buffer and back); release returns the range through the free queue */
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    struct WMTBufferInfo bi = {100000, WMTResourceStorageModeShared, {NULL}, 0};
    struct unixcall_mtldevice_newbuffer nb = {(obj_handle_t)dev, {&bi}, 0};
    remote(18, &nb);
    CHECK(nb.ret && bi.memory.ptr && bi.gpu_address, "newBuffer ret %llx mem %p gpu %llx", nb.ret, bi.memory.ptr, bi.gpu_address);
    if (nb.ret && bi.memory.ptr) {
      id<MTLBuffer> buf = (id<MTLBuffer>)nb.ret;
      memset(bi.memory.ptr, 0x5a, 100000);
      id<MTLBuffer> tmp = [dev newBufferWithLength:100000 options:MTLResourceStorageModeShared];
      id<MTLCommandQueue> q = [dev newCommandQueue];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
      [be copyFromBuffer:buf sourceOffset:0 toBuffer:tmp destinationOffset:0 size:100000];
      [be fillBuffer:buf range:NSMakeRange(0, 64) value:0x11];
      [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
      CHECK(((uint8_t *)tmp.contents)[99999] == 0x5a, "GPU did not see client writes");
      CHECK(((uint8_t *)bi.memory.ptr)[10] == 0x11, "client did not see GPU writes");
      [tmp release]; [q release];
      struct wmtr_ring *R = blob_base[0];
      uint64_t fh = R->free_head;
      obj_handle_t h = nb.ret;
      remote(1, &h); remote(26, &fb);
      for (int i = 0; i < 1000 && R->free_head == fh; i++) usleep(1000);
      CHECK(R->free_head == fh + 1, "buffer range not returned (free_head %llu)", R->free_head);
    }
    /* 6. caller-placed memory (DXMT CpuPlaced): initial bytes kept, pointer replaced by arena memory */
    {
      uint8_t *own; posix_memalign((void **)&own, 16384, 65536); memset(own, 0x3c, 65536);
      struct WMTBufferInfo ci = {65536, WMTResourceStorageModeShared, {own}, 0};
      struct unixcall_mtldevice_newbuffer cb2 = {(obj_handle_t)dev, {&ci}, 0};
      remote(18, &cb2);
      CHECK(cb2.ret && ci.memory.ptr && ci.memory.ptr != own && ((uint8_t *)ci.memory.ptr)[65535] == 0x3c,
            "caller-placed buffer ret %llx mem %p", cb2.ret, ci.memory.ptr);
      free(own);
    }
    /* 7. after a peak, idle arena blobs beyond the 128 MiB reserve go back to the host once they have
          been idle for WMTR_ARENA_TRIM_MS; blobs reused within that time are kept */
    {
      enum { NB = 8 };
      struct wmtr_ring *R = blob_base[0];
      uint64_t a0 = arena_bytes();
      obj_handle_t bh[NB];
      for (int i = 0; i < NB; i++) {
        struct WMTBufferInfo pi = {60u << 20, WMTResourceStorageModeShared, {NULL}, 0};
        struct unixcall_mtldevice_newbuffer pb = {(obj_handle_t)dev, {&pi}, 0};
        remote(18, &pb);
        bh[i] = pb.ret;
        if (pi.memory.ptr) memset(pi.memory.ptr, i + 1, 60u << 20);
      }
      uint64_t a_peak = arena_bytes(), fp_peak = footprint();
      CHECK(bh[NB - 1] && a_peak >= a0 + (NB - 1) * (60ull << 20), "peak: %llu arena MiB", a_peak >> 20);
      uint64_t fh = R->free_head;
      for (int i = 0; i < NB; i++) remote(1, &bh[i]);
      remote(26, &fb);
      for (int i = 0; i < 2000 && R->free_head < fh + NB; i++) usleep(1000);
      remote(26, &fb); /* takes the frees: the blobs are idle, but not for long enough yet */
      CHECK(n_blob_released == 0 && arena_bytes() == a_peak, "released %d blobs before the idle time", n_blob_released);
      usleep(400000);
      remote(26, &fb);
      uint64_t a_after = arena_bytes(), fp_after = footprint();
      printf("arena trim: arena %llu -> %llu MiB, footprint %llu -> %llu MiB, %d blobs released\n",
             a_peak >> 20, a_after >> 20, fp_peak >> 20, fp_after >> 20, n_blob_released);
      CHECK(a_after <= a0 + (128ull << 20), "arena kept %llu MiB after the peak (before %llu MiB)", a_after >> 20, a0 >> 20);
      CHECK(fp_after + (256ull << 20) <= fp_peak, "footprint %llu -> %llu MiB", fp_peak >> 20, fp_after >> 20);
      /* the arena still works: a released blob number is reused */
      struct WMTBufferInfo ri = {100u << 20, WMTResourceStorageModeShared, {NULL}, 0};
      struct unixcall_mtldevice_newbuffer rb = {(obj_handle_t)dev, {&ri}, 0};
      remote(18, &rb);
      CHECK(rb.ret && ri.memory.ptr, "newBuffer after trim");
      if (rb.ret) { memset(ri.memory.ptr, 7, 100u << 20); obj_handle_t h = rb.ret; remote(1, &h); }
    }
    /* 7b. more NoCopy frees than the free ring holds, with no client allocation to drain it (quit/logout:
          Metal runs the deallocator inside the release call the client waits on). The executor must queue
          them instead of waiting, and hand every range back as the client drains at its next sync call. */
    {
      enum { N = WMTR_FREE_RING + 512 };
      obj_handle_t bh[N];
      int nbuf = 0;
      struct wmtr_ring *R = blob_base[0];
      for (int i = 0; i < N; i++) {
        struct WMTBufferInfo bi = {WMTR_PAGE, WMTResourceStorageModeShared, {NULL}, 0};
        struct unixcall_mtldevice_newbuffer nb = {(obj_handle_t)dev, {&bi}, 0};
        remote(18, &nb);
        if (!nb.ret || !bi.memory.ptr) { CHECK(nb.ret, "burst: newBuffer %d", i); break; }
        bh[nbuf++] = nb.ret;
      }
      CHECK(nbuf == N, "burst: %d of %d buffers", nbuf, (int)N);
      uint64_t h0 = R->free_head;
      atomic_store_explicit(&burst_done, 0, memory_order_relaxed);
      pthread_t wd;
      if (pthread_create(&wd, NULL, burst_watchdog, NULL) == 0) pthread_detach(wd);
      for (int i = 0; i < nbuf; i++) remote(1, &bh[i]); /* async: no allocation or sync call drains the ring */
      /* a sync call drains the ring and the host moves queued frees into it before handling its request */
      for (int i = 0; i < 8 && R->free_head - h0 < (uint64_t)nbuf; i++) {
        struct unixcall_generic_obj_uint64_ret q = {0};
        remote(39, &q);
        usleep(1000);
      }
      CHECK(R->free_head - h0 == (uint64_t)nbuf, "burst: %llu of %d frees delivered",
            (unsigned long long)(R->free_head - h0), nbuf);
      CHECK(R->free_head - R->free_tail <= WMTR_FREE_RING, "free ring overrun: %llu entries",
            (unsigned long long)(R->free_head - R->free_tail));
      atomic_store_explicit(&burst_done, 1, memory_order_relaxed);
    }
    test_vr(dev);
    test_vr_fd();
    /* 8. client-assigned handles: a frame's pool + encoder creations do not wait for the host (one sync call
          apart from the calls that return values); each use reaches the host after its creation and gets the object;
          a failed creation makes the calls using its handle no-ops. WMTR_CLIENT_HANDLES=0: every creation waits. */
    {
      int on = !getenv("WMTR_CLIENT_HANDLES") || atoi(getenv("WMTR_CLIENT_HANDLES"));
      struct wmtr_host_stats s0, s1;
      wmtr_host_get_stats(H, &s0);
      n_enc_log = 0;
      struct unixcall_generic_obj_ret pool = {0};
      remote(10, &pool);
      struct unixcall_generic_obj_ret ar = {0};
      remote(53, &ar); /* autoreleased into the pool */
      struct WMTRenderPassInfo rpi; memset(&rpi, 0, sizeof rpi); rpi.render_target_width = 640;
      struct unixcall_generic_obj_uint64_obj_ret re = {0x77, (uint64_t)(uintptr_t)&rpi, 0}, ce = {0x77, 1, 0}, bad = {0x77, 99, 0};
      struct unixcall_generic_obj_obj_ret be = {0x77, 0};
      remote(32, &re);
      struct unixcall_generic_obj_noret end = {re.ret}; remote(33, &end);
      remote(31, &ce);
      struct unixcall_generic_obj_cmd_noret enc = {ce.ret, {NULL}}; remote(37, &enc);
      end.handle = ce.ret; remote(33, &end);
      remote(30, &be);
      end.handle = be.ret; remote(33, &end);
      remote(31, &bad); /* fails on the host */
      enc.encoder = bad.ret; remote(37, &enc);
      end.handle = bad.ret; remote(33, &end);
      obj_handle_t ph = pool.ret;
      int alive_in_pool = 0;
      struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q); /* sync: all of the above has executed */
      alive_in_pool = probe_alive;
      remote(1, &ph);
      remote(39, &q);
      wmtr_host_get_stats(H, &s1);
      uint64_t waits = s1.sync_requests - s0.sync_requests;
      CHECK(waits == (on ? 3u : 8u), "pool+encoders: %llu sync requests (want %d)", waits, on ? 3 : 8); /* 53 and 39 twice */
      CHECK(pool.ret && re.ret && ce.ret && be.ret && (on ? bad.ret != 0 : bad.ret == 0), "handles %llx %llx %llx %llx %llx",
            pool.ret, re.ret, ce.ret, be.ret, bad.ret);
      CHECK(alive_in_pool && !probe_alive, "pool handle: object alive in pool %d, after release %d", alive_in_pool, probe_alive);
      /* host order: 32 r, 33 r, 31 c, 37 c, 33 c, 30 b, 33 b, 31 0 (failed; its uses are skipped) */
      static const uint64_t want[8] = {32, 33, 31, 37, 33, 30, 33, 31};
      int ok = n_enc_log == (on ? 8 : 10);
      for (int i = 0; ok && i < 8; i++) ok = enc_log[i][0] == want[i];
      ok = ok && enc_log[0][1] && enc_log[1][1] == enc_log[0][1] && enc_log[3][1] == enc_log[2][1] &&
           enc_log[4][1] == enc_log[2][1] && enc_log[6][1] == enc_log[5][1] && enc_log[7][1] == 0;
      CHECK(ok, "encoder order/objects: %d log entries", n_enc_log);
      CHECK(end.handle == bad.ret, "the caller's receiver handle was changed to %llx", end.handle);
    }
    struct wmtr_host_stats st; wmtr_host_get_stats(H, &st);
    printf("requests=%llu sync=%llu bytes=%llu\n", st.requests, st.sync_requests, st.bytes);
    { /* an autoreleased result outside any client pool must outlive the request (DXMT reads it next) */
      struct unixcall_generic_obj_ret ar = {0};
      remote(53, &ar);
      struct unixcall_generic_obj_uint64_ret pf3 = {0}; remote(39, &pf3);
      CHECK(ar.ret && probe_alive, "autoreleased result without a pool was freed with the request");
    }
    { /* D3D12 pipelines pass serialized root signatures through SM50Compile's argument list */
      uint8_t rs1[300], rs2[77]; for (int i = 0; i < 300; i++) rs1[i] = (uint8_t)(i * 7 + 1); for (int i = 0; i < 77; i++) rs2[i] = (uint8_t)(i ^ 0x5a);
      struct SM50_SHADER_ROOT_SIGNATURE_DATA r2 = {.next = NULL, .type = SM50_SHADER_ROOT_SIGNATURE2, .bytecode = rs2, .bytecode_length = 77};
      struct SM50_SHADER_ROOT_SIGNATURE_DATA r1 = {.next = &r2, .type = SM50_SHADER_ROOT_SIGNATURE, .bytecode = rs1, .bytecode_length = 300};
      struct SM50_SHADER_COMMON_DATA cm = {0}; cm.next = &r1; cm.type = SM50_SHADER_COMMON;
      sm50_bitcode_t bc = 0; sm50_error_t er = 0;
      struct sm50_compile_params cp = {.shader = 0, .args = &cm, .func_name = "main", .bitcode = &bc, .error = &er};
      native(76, &cp); uint64_t n0 = sm50_rs_sum[0], n1 = sm50_rs_sum[1];
      bc = 0; NTSTATUS st = remote(76, &cp);
      CHECK(st == 0 && bc == (sm50_bitcode_t)(uintptr_t)0x5150 && sm50_rs_len[0] == 300 && sm50_rs_len[1] == 77 &&
            sm50_rs_sum[0] == n0 && sm50_rs_sum[1] == n1, "root signature args: st=%x len %u/%u", st, sm50_rs_len[0], sm50_rs_len[1]);
    }
    { /* a +1 out-error lives exactly as long as the caller holds it: wmtr neither keeps nor drops it */
      struct unixcall_mtldevice_newlibrary nl = {0};
      remote(25, &nl);
      struct unixcall_generic_obj_uint64_ret pf4 = {0}; remote(39, &pf4);
      CHECK(nl.ret_error && err_alive, "out-error freed before its owner released it");
      obj_handle_t eh = nl.ret_error;
      remote(1, &eh);
      remote(39, &pf4);
      CHECK(!err_alive, "out-error still alive after its owner released it (kept by wmtr)");
    }
    { /* WMTR_FRAMES: count a presenting command buffer, not a skipped nil-drawable frame. */
      id<MTLCommandQueue> q = [MTLCreateSystemDefaultDevice() newCommandQueue];
      id<MTLCommandBuffer> skipped = [q commandBuffer], cb = [q commandBuffer];
      struct unixcall_generic_obj_obj_noret pd = {.handle = (obj_handle_t)skipped, .arg = 0};
      remote(47, &pd);
      [skipped commit]; [skipped waitUntilCompleted];
      NSObject *drawable = [[NSObject alloc] init]; /* the loopback present implementation is a no-op */
      pd.handle = (obj_handle_t)cb; pd.arg = (obj_handle_t)drawable;
      remote(47, &pd);
      struct unixcall_generic_obj_uint64_ret pf2 = {0}; remote(39, &pf2); /* the async present is done */
      [cb commit]; [cb waitUntilCompleted];
      usleep(100000); /* completion handlers run after waitUntilCompleted returns */
      FILE *f = fopen(frames_path, "r"); char line[128] = ""; int n = 0; unsigned long long t = 0;
      while (f && fgets(line, sizeof line, f)) { n++; sscanf(line, "%llu,", &t); }
      if (f) fclose(f);
      CHECK(n == 1 && t > 0 && strstr(line, ",0,0,0,0,0"), "WMTR_FRAMES: %d lines, last '%s'", n, line);
      [drawable release];
      unlink(frames_path);
    }
    { /* views: ReleaseMetalView releases once; views the client never released go on destroy */
      struct unixcall_create_metal_view_from_hwnd v1 = {.hwnd = 1, .device = 2}, v2 = {.hwnd = 3, .device = 2};
      CHECK(remote(72, &v1) == 0 && remote(72, &v2) == 0 && v1.ret_view && v2.ret_view && v1.ret_layer == 0x77,
            "CreateMetalViewFromHWND %llx %llx", v1.ret_view, v2.ret_view);
      struct unixcall_generic_obj_noret r1 = {.handle = v1.ret_view};
      remote(73, &r1);
      remote(73, &r1); /* a second release of the same view is ignored */
      struct unixcall_generic_obj_uint64_ret pf = {0}; remote(39, &pf); /* sync call: the releases above are done */
      CHECK(n_released == 1 && released[0] == v1.ret_view, "ReleaseMetalView: %d releases", n_released);
      /* render-pass profile (rows 220-239, with the statistics): a 4x MSAA pass that stores its samples and
       * resolves, and the GPU time of its committed command buffer */
      id<MTLDevice> pdev = MTLCreateSystemDefaultDevice();
      MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
      md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4; md.usage = MTLTextureUsageRenderTarget; md.storageMode = MTLStorageModePrivate;
      id<MTLTexture> msaa = [pdev newTextureWithDescriptor:md];
      MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
      rd.usage = MTLTextureUsageRenderTarget; rd.storageMode = MTLStorageModePrivate;
      id<MTLTexture> res = [pdev newTextureWithDescriptor:rd];
      id<MTLCommandQueue> pq = [pdev newCommandQueue];
      id<MTLCommandBuffer> pcb = [pq commandBuffer];
      struct WMTRenderPassInfo pinfo; memset(&pinfo, 0, sizeof pinfo);
      pinfo.colors[0].texture = (obj_handle_t)msaa; pinfo.colors[0].load_action = WMTLoadActionClear;
      pinfo.colors[0].store_action = WMTStoreActionStoreAndMultisampleResolve; pinfo.colors[0].resolve_texture = (obj_handle_t)res;
      struct unixcall_generic_obj_uint64_obj_ret rce = {.handle = (obj_handle_t)pcb, .arg = (uint64_t)(uintptr_t)&pinfo};
      remote(32, &rce);
      struct unixcall_generic_obj_noret cm = {.handle = (obj_handle_t)pcb};
      remote(12, &cm);
      { struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q); }
      [pcb waitUntilCompleted];
      usleep(20000); /* the completion handler runs after waitUntilCompleted returns */
      /* Keep a registered event notification alive across destroy. A live delivery must wake and advance
       * progress; a late delivery must do neither, even though Metal still owns the copied block. */
      CHECK(wmtr_host_abi_version() == 1 && sizeof(struct wmtr_host_ops) == 2 * sizeof(void *), "host ABI 1");
      DelayedSharedEvent *late_event = [[DelayedSharedEvent alloc] init];
      struct { MTLSharedEventListener *listener; } late_listener = {nil};
      struct unixcall_mtlsharedevent_setevent late = {
        .shared_event = (obj_handle_t)late_event, .shared_event_listener = (obj_handle_t)&late_listener,
        .value = 1, .event_handle = 0x1234
      };
      CHECK(raw_request(104, sizeof late, sizeof late, NULL, 0, NULL, 0, &late, sizeof late, NULL) == 0,
            "register delayed event notification");
      uint64_t before_wake = __atomic_load_n(&wake_count, __ATOMIC_RELAXED);
      uint64_t before_event = wmtr_host_progress(H, WMTR_EVENT_SLOT);
      [late_event fire];
      CHECK(__atomic_load_n(&wake_count, __ATOMIC_RELAXED) == before_wake + 1 &&
            wmtr_host_progress(H, WMTR_EVENT_SLOT) == before_event + 1, "live event did not wake");
      test_hostile_requests(dev);
      /* a call that faults (bad handle) fails, the process lives, and the client is refused from then on */
      struct unixcall_generic_obj_uint64_ret fz = {0};
      NTSTATUS fs = remote(5, &fz);
      struct unixcall_generic_obj_uint64_ret pf4 = {0};
      NTSTATUS fs2 = remote(39, &pf4);
      CHECK(fs == (NTSTATUS)0xC0000005 && fs2 == (NTSTATUS)0xC0000005, "fault containment: %x then %x", fs, fs2);
      { /* executor spin budget: with a budget longer than the gaps between requests it never sleeps */
        struct wmtr_host_stats st0, st1, st2;
        wmtr_host_set_spin(H, 0);
        wmtr_host_get_stats(H, &st0);
        for (int i = 0; i < 20; i++) { struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q); usleep(300); }
        wmtr_host_get_stats(H, &st1);
        wmtr_host_set_spin(H, 20000000);
        { struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q); }
        wmtr_host_get_stats(H, &st1);
        /* a gap that really lasted longer than the budget (this thread descheduled on a loaded or
           virtualized machine, e.g. a CI runner) is allowed to end in a sleep */
        unsigned long long long_gaps = 0;
        for (int i = 0; i < 20; i++) {
          struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q);
          uint64_t g0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
          usleep(300);
          if (clock_gettime_nsec_np(CLOCK_MONOTONIC) - g0 >= 20000000) long_gaps++;
        }
        wmtr_host_get_stats(H, &st2);
        CHECK(st1.idle_sleeps - st0.idle_sleeps >= 15, "no spin: %llu sleeps in 20 gaps", st1.idle_sleeps - st0.idle_sleeps);
        CHECK(long_gaps <= 5 && st2.idle_sleeps - st1.idle_sleeps <= 1 + long_gaps,
              "20 ms spin: %llu sleeps in 20 gaps of 0.3 ms (%llu gaps lasted >= 20 ms)",
              st2.idle_sleeps - st1.idle_sleeps, long_gaps);
        wmtr_host_set_spin(H, WMTR_HOST_SPIN_US_DEFAULT * 1000);
      }
      wmtr_host_destroy(H);
      CHECK(n_released == 2 && released[1] == v2.ret_view, "destroy did not release the leftover view (%d releases)", n_released);
      uint64_t destroyed_wakes = __atomic_load_n(&wake_count, __ATOMIC_RELAXED);
      struct wmtr_ring *destroyed_ring = blob_base[0];
      uint64_t destroyed_events = __atomic_load_n(&destroyed_ring->event_head, __ATOMIC_ACQUIRE);
      [late_event fire];
      CHECK(__atomic_load_n(&wake_count, __ATOMIC_RELAXED) == destroyed_wakes &&
            __atomic_load_n(&destroyed_ring->event_head, __ATOMIC_ACQUIRE) == destroyed_events,
            "event callback touched ring or woke embedder after destroy");
      [late_event release];
      printf("wake after destroy: blocked\n");
      /* WMTR_CALLSTATS: destroy wrote a snapshot; call 39 (sync, above) is in it with its sync count */
      FILE *sf = fopen(stats_path, "r");
      char sl[256]; int found = 0;
      while (sf && fgets(sl, sizeof sl, sf)) {
        unsigned long long t, n, sy, ns; int call; char name[96]; unsigned cls;
        if (sscanf(sl, "%llu,%d,%95[^,],%u,%llu,%llu,%llu", &t, &call, name, &cls, &n, &sy, &ns) == 7 && call == 39 && n >= 1 && sy >= 1)
          found = 1;
      }
      if (sf) fclose(sf);
      CHECK(found, "WMTR_CALLSTATS: no snapshot line for call 39");
      sf = fopen(stats_path, "r"); found = 0;
      while (sf && fgets(sl, sizeof sl, sf)) if (strstr(sl, ",200,_executor_sleeps,9,")) found = 1;
      if (sf) fclose(sf);
      CHECK(found, "WMTR_CALLSTATS: no executor sleep row");
      int msaa_row = 0, gpu_row = 0, sig_row = 0;
      sf = fopen(stats_path, "r");
      while (sf && fgets(sl, sizeof sl, sf)) {
        unsigned long long t, n, sy, ns; int call; char name[96]; unsigned cls;
        if (sscanf(sl, "%llu,%d,%95[^,],%u,%llu,%llu,%llu", &t, &call, name, &cls, &n, &sy, &ns) != 7) continue;
        if (call == 224 && n >= 1 && ns >= 64ull * 64 * 4 * 4) msaa_row = 1;
        if (call == 220 && n >= 1 && ns > 0) gpu_row = 1;
        if (call >= 230 && strstr(name, "c64x64/f70/s4/L2/S3")) sig_row = 1;
      }
      if (sf) fclose(sf);
      CHECK(msaa_row && gpu_row && sig_row, "pass profile rows: msaa store %d, command buffer GPU time %d, signature %d",
            msaa_row, gpu_row, sig_row);
      unlink(stats_path);
      unlink(trigger_path);
    }
  }
  printf(failures ? "wmtr_loopback: %d FAILED\n" : "wmtr_loopback: all passed\n", failures);
  return failures != 0;
}
