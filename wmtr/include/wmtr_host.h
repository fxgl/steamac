/* wmtr host executor: runs remoted winemetal calls against Metal (DXMT's own winemetal_unix.c).
 * Embedded in the VMM (libkrun virtio-gpu context). The embedder owns shared memory and wake-ups;
 * see struct wmtr_host_ops. */
#ifndef WMTR_HOST_H
#define WMTR_HOST_H
#include <stdint.h>

struct wmtr_host;

struct wmtr_host_ops {
  /* host address and size of arena blob `blob` (registered by the embedder), NULL if unknown */
  void *(*blob_ptr)(void *ctx, uint32_t blob, uint64_t *size);
  /* wake a client thread waiting on reply slot `slot` (or WMTR_EVENT_SLOT) */
  void (*wake)(void *ctx, uint32_t slot);
};

/* ABI 1 has exactly the two callbacks above. Destroy drains executor jobs and disables delayed Metal
 * callbacks before returning: the embedder may then release ops, ctx and the ring mapping. */
uint32_t wmtr_host_abi_version(void);
/* `ring` is the host mapping of blob 0 (struct wmtr_ring + data + slots), already initialised by
 * the client. Starts the executor thread. */
struct wmtr_host *wmtr_host_create(void *ring, const struct wmtr_host_ops *ops, void *ctx);
/* the client kicked: the executor may be idle */
void wmtr_host_kick(struct wmtr_host *h);
void wmtr_host_destroy(struct wmtr_host *h);
/* done_seq of reply slot `slot`, or event_head for WMTR_EVENT_SLOT */
uint64_t wmtr_host_progress(struct wmtr_host *h, uint32_t slot);
/* Presenter: overlay in the launcher's VMView with WMTR_PRESENT=overlay, otherwise a window per HWND. */
uint64_t wmtr_present_create_view(void *ctx, uint64_t hwnd, void *mtl_device, uint64_t *layer);
void wmtr_present_release_view(void *ctx, uint64_t view);
/* Synchronous pre-present hook: encode into command_buffer before it is committed. Objects are
 * borrowed; retain capture resources in a Metal completion handler. Clearing waits for an in-flight
 * callback, so userdata can then be released. The callback must not call this setter. */
typedef void (*wmtr_stream_capture_callback)(void *userdata, void *command_buffer, void *drawable);
void wmtr_stream_capture_set(wmtr_stream_capture_callback callback, void *userdata);
void wmtr_layout(uint64_t *ring_bytes, uint64_t *data_offset, uint64_t *slots_offset, uint64_t *slot_size);
/* counters for measurements */
struct wmtr_host_stats { uint64_t requests, sync_requests, bytes, worker_calls, idle_sleeps; };
void wmtr_host_get_stats(struct wmtr_host *h, struct wmtr_host_stats *out);
/* How long the executor polls an empty ring before it sleeps (default WMTR_HOST_SPIN_US_DEFAULT us, env
 * WMTR_HOST_SPIN_US at create). Longer: fewer kicks (guest VM exits) for host CPU. VRChat (DXMT): 2 us -> 100 us
 * cut kicks from 290 to 64 a frame and executor sleeps from 97 to 15, idle fps 82 -> 99, host CPU of the VM process
 * unchanged (347% vs 336%), n=1 each. */
#define WMTR_HOST_SPIN_US_DEFAULT 100
void wmtr_host_set_spin(struct wmtr_host *h, uint64_t ns);

#endif
