/* wmtr_dxmt_test: DXMT's own guest API (winemetal_thunks.c, the code DXMT's winemetal.dll runs) through
 * the wmtr client and an in-memory transport into the production executor: libwmtr_host.dylib with
 * DXMT's winemetal_unix.c and object validation always on, on this Mac's Metal device. Blit, compute
 * and render command lists are built like dxmt_context.cpp builds them: a Nop head, then commands.
 * Oracle: every call succeeds and the GPU's results (filled and copied buffers, a compute kernel's
 * output, a cleared render target) are read back from the host objects.
 * 1.9.5's validator had no blit/compute Nop and refused every such list: Death's Door drew a black
 * frame with magenta menu arrows. The loopback test did not see it (fake implementations, checks off). */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define WINEMETAL_API
#include "winemetal.h"
#include "wineunixlib.h"
#include "wmtr_wire.h"
#include "wmtr_transport.h"
#include "wmtr_host.h"

typedef NTSTATUS (*fn_t)(void *);
extern const void *__wine_unix_call_funcs[]; /* the wmtr client's remoting thunks */

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
  fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

/* every unix call DXMT's thunks make: a refused call is a failure even where DXMT ignores the status,
 * unless the test expects the next one to be refused */
static int expect_refusal;
NTSTATUS
wmtr_test_unix_call(unsigned int code, void *args) {
  NTSTATUS st = ((fn_t)__wine_unix_call_funcs[code])(args);
  if (expect_refusal) { expect_refusal = 0; CHECK(st != 0, "unix call %u was expected to be refused", code); }
  else CHECK(st == 0, "unix call %u returned status %#x", code, (unsigned)st);
  return st;
}

/* ---------------- in-memory transport to the production executor ---------------- */
static struct wmtr_host *H;
static void *blob_base[WMTR_MAX_BLOBS];
static uint64_t blob_size[WMTR_MAX_BLOBS];
static void *t_blob_ptr(void *c, uint32_t b, uint64_t *s) { if (b >= WMTR_MAX_BLOBS) return NULL; *s = blob_size[b]; return blob_base[b]; }
static void t_wake(void *c, uint32_t s) {}
static const struct wmtr_host_ops host_ops = {t_blob_ptr, t_wake};
static void *t_open_ring(struct wmtr_transport *t, uint64_t size) {
  struct wmtr_ring *R;
  if (posix_memalign((void **)&R, WMTR_PAGE, size)) return NULL;
  memset(R, 0, size);
  R->magic = WMTR_RING_MAGIC; R->version = WMTR_VERSION;
  blob_base[0] = R; blob_size[0] = size;
  H = wmtr_host_create(R, &host_ops, NULL);
  return H ? R : NULL;
}
static void *t_add_blob(struct wmtr_transport *t, uint32_t b, uint64_t size) {
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) return NULL;
  blob_base[b] = p; blob_size[b] = size; return p;
}
static void t_release_blob(struct wmtr_transport *t, uint32_t b, void *base, uint64_t size) {
  if (base == blob_base[b] && size == blob_size[b]) { munmap(base, size); blob_base[b] = NULL; blob_size[b] = 0; }
}
static void t_kick(struct wmtr_transport *t) { wmtr_host_kick(H); }
static void t_wait(struct wmtr_transport *t, volatile uint64_t *d, uint64_t seq, uint32_t slot, uint64_t spin_ns) {
  while (__atomic_load_n(d, __ATOMIC_ACQUIRE) < seq) sched_yield();
}
struct wmtr_transport *
wmtr_transport_create(void) {
  struct wmtr_transport *t = calloc(1, sizeof *t);
  t->open_ring = t_open_ring; t->add_blob = t_add_blob; t->kick = t_kick; t->wait = t_wait;
  t->release_blob = t_release_blob;
  return t;
}

/* a host object behind a DXMT handle (same process: handles are the executor's object pointers) */
#define HOST(h) ((__bridge id)(void *)(uintptr_t)(h))

static const char kernel_msl[] =
  "#include <metal_stdlib>\nusing namespace metal;\n"
  "kernel void fill(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = i * 3u + 7u; }\n";

int
main(int argc, char **argv) { @autoreleasepool {
  obj_handle_t devices = WMTCopyAllDevices();
  CHECK(devices, "no Metal device through wmtr");
  if (!devices) return 1;
  obj_handle_t device = NSArray_object(devices, 0);
  obj_handle_t queue = MTLDevice_newCommandQueue(device, 16);

  struct WMTBufferInfo info = {.length = 256, .options = WMTResourceStorageModeShared};
  obj_handle_t src = MTLDevice_newBuffer(device, &info);
  info = (struct WMTBufferInfo){.length = 256, .options = WMTResourceStorageModeShared};
  obj_handle_t dst = MTLDevice_newBuffer(device, &info);
  info = (struct WMTBufferInfo){.length = 64 * sizeof(uint32_t), .options = WMTResourceStorageModeShared};
  obj_handle_t out = MTLDevice_newBuffer(device, &info);
  struct WMTTextureInfo tinfo = {
    .pixel_format = WMTPixelFormatRGBA8Unorm, .width = 4, .height = 4, .depth = 1, .array_length = 1,
    .type = WMTTextureType2D, .mipmap_level_count = 1, .sample_count = 1,
    .usage = WMTTextureUsageShaderRead | WMTTextureUsageRenderTarget, .options = WMTResourceStorageModeShared,
  };
  obj_handle_t target = MTLDevice_newTexture(device, &tinfo);
  obj_handle_t err = 0;
  obj_handle_t library = MTLDevice_newLibraryWithSource(device, kernel_msl, sizeof kernel_msl - 1, &err);
  obj_handle_t function = library ? MTLLibrary_newFunction(library, "fill") : 0;
  struct WMTComputePipelineInfo pinfo = {.compute_function = function};
  obj_handle_t pso = function ? MTLDevice_newComputePipelineState(device, &pinfo, &err) : 0;
  CHECK(src && dst && out && target && pso, "objects: src %llx dst %llx out %llx target %llx pso %llx",
        (unsigned long long)src, (unsigned long long)dst, (unsigned long long)out, (unsigned long long)target,
        (unsigned long long)pso);
  if (!(src && dst && out && target && pso)) return 1;
  memset([HOST(dst) contents], 0, 256);
  memset([HOST(out) contents], 0, 64 * sizeof(uint32_t));

  obj_handle_t cmdbuf = MTLCommandQueue_commandBuffer(queue);

  /* blit pass 1: Nop, FillBuffer */
  struct wmtcmd_base fill_head = {.type = WMTBlitCommandNop};
  struct wmtcmd_blit_fillbuffer fill = {.type = WMTBlitCommandFillBuffer, .buffer = src, .length = 256, .value = 0xab};
  fill_head.next.ptr = &fill;
  obj_handle_t blit = MTLCommandBuffer_blitCommandEncoder(cmdbuf);
  MTLBlitCommandEncoder_encodeCommands(blit, &fill_head);
  MTLCommandEncoder_endEncoding(blit);

  /* blit pass 2: Nop, CopyFromBufferToBuffer (src 16..143 to dst 0..127) */
  struct wmtcmd_base copy_head = {.type = WMTBlitCommandNop};
  struct wmtcmd_blit_copy_from_buffer_to_buffer copy = {
    .type = WMTBlitCommandCopyFromBufferToBuffer, .src = src, .src_offset = 16, .dst = dst, .copy_length = 128,
  };
  copy_head.next.ptr = &copy;
  blit = MTLCommandBuffer_blitCommandEncoder(cmdbuf);
  MTLBlitCommandEncoder_encodeCommands(blit, &copy_head);
  MTLCommandEncoder_endEncoding(blit);

  /* compute pass: Nop, SetPSO, SetBuffer, Dispatch (one threadgroup of 64) */
  struct wmtcmd_base compute_head = {.type = WMTComputeCommandNop};
  struct wmtcmd_compute_setpso setpso = {.type = WMTComputeCommandSetPSO, .pso = pso, .threadgroup_size = {64, 1, 1}};
  struct wmtcmd_compute_setbuffer setbuffer = {.type = WMTComputeCommandSetBuffer, .buffer = out, .index = 0};
  struct wmtcmd_compute_dispatch dispatch = {.type = WMTComputeCommandDispatch, .size = {1, 1, 1}};
  compute_head.next.ptr = &setpso; setpso.next.ptr = &setbuffer; setbuffer.next.ptr = &dispatch;
  obj_handle_t compute = MTLCommandBuffer_computeCommandEncoder(cmdbuf, false);
  MTLComputeCommandEncoder_encodeCommands(compute, &compute_head);
  MTLCommandEncoder_endEncoding(compute);

  /* render pass: clear the target to green; the list is only DXMT's Nop head */
  struct WMTRenderPassInfo pass = {.render_target_width = 4, .render_target_height = 4, .default_raster_sample_count = 1};
  pass.colors[0].texture = target;
  pass.colors[0].load_action = WMTLoadActionClear;
  pass.colors[0].store_action = WMTStoreActionStore;
  pass.colors[0].clear_color = (struct WMTClearColor){0.0, 1.0, 0.0, 1.0};
  struct wmtcmd_base render_head = {.type = WMTRenderCommandNop};
  obj_handle_t render = MTLCommandBuffer_renderCommandEncoder(cmdbuf, &pass);
  MTLRenderCommandEncoder_encodeCommands(render, &render_head);
  MTLCommandEncoder_endEncoding(render);

  MTLCommandBuffer_commit(cmdbuf);
  MTLCommandBuffer_waitUntilCompleted(cmdbuf);
  enum WMTCommandBufferStatus status = MTLCommandBuffer_status(cmdbuf);
  CHECK(status == WMTCommandBufferStatusCompleted, "command buffer status %llu, error %s", (unsigned long long)status,
        [[(id<MTLCommandBuffer>)HOST(cmdbuf) error] description].UTF8String ?: "none");

  const uint8_t *s = [HOST(src) contents], *d = [HOST(dst) contents];
  int bad = 0;
  for (int i = 0; i < 256; i++) bad += s[i] != 0xab;
  CHECK(!bad, "blit FillBuffer: %d of 256 bytes not 0xab (first %#x)", bad, s[0]);
  bad = 0;
  for (int i = 0; i < 256; i++) bad += d[i] != (i < 128 ? 0xab : 0);
  CHECK(!bad, "blit CopyFromBufferToBuffer: %d of 256 bytes wrong (first %#x)", bad, d[0]);
  const uint32_t *o = [HOST(out) contents];
  bad = 0;
  for (uint32_t i = 0; i < 64; i++) bad += o[i] != i * 3u + 7u;
  CHECK(!bad, "compute dispatch: %d of 64 values wrong (out[1] = %u, want 10)", bad, o[1]);
  uint8_t px[4 * 4 * 4];
  [(id<MTLTexture>)HOST(target) getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
  bad = 0;
  for (int i = 0; i < 16; i++) bad += px[4 * i] != 0 || px[4 * i + 1] != 0xff || px[4 * i + 2] != 0 || px[4 * i + 3] != 0xff;
  CHECK(!bad, "render clear: %d of 16 pixels not green (first %02x%02x%02x%02x)", bad, px[0], px[1], px[2], px[3]);

  /* Libraries from metallib bytes go through DispatchData_alloc_init and MTLDevice_newLibrary, the way
   * DXMT loads airconv's output. 1.9.6 refused the dispatch data (no object metadata for call 114),
   * the vertex function came back nil and Metal aborted the VM in newRenderPipelineState
   * (STEAMAC-6S/6W/3/6T). */
  NSData *metallib = argc > 1 ? [NSData dataWithContentsOfFile:@(argv[1])] : nil;
  CHECK(metallib.length, "no metallib (argument 1)");
  if (!metallib.length) return 1;
  obj_handle_t data = DispatchData_alloc_init((uint64_t)(uintptr_t)metallib.bytes, metallib.length);
  obj_handle_t shaders = data ? MTLDevice_newLibrary(device, data, &err) : 0;
  obj_handle_t vs = shaders ? MTLLibrary_newFunction(shaders, "vs") : 0;
  obj_handle_t fs = shaders ? MTLLibrary_newFunction(shaders, "fs") : 0;
  CHECK(data && shaders && vs && fs, "library from dispatch data: data %llx library %llx vs %llx fs %llx",
        (unsigned long long)data, (unsigned long long)shaders, (unsigned long long)vs, (unsigned long long)fs);
  struct WMTRenderPipelineInfo rinfo = {.rasterization_enabled = true, .raster_sample_count = 1, .max_tessellation_factor = 16,
                                        .vertex_function = vs, .fragment_function = fs};
  rinfo.colors[0].pixel_format = WMTPixelFormatRGBA8Unorm;
  rinfo.colors[0].write_mask = 0xf;
  obj_handle_t rpso = vs && fs ? MTLDevice_newRenderPipelineState(device, &rinfo, &err) : 0;
  CHECK(rpso, "render pipeline from a dispatch-data library");
  /* without a vertex function the call is refused: a nil pipeline drops draws, Metal would abort */
  struct WMTRenderPipelineInfo no_vertex = rinfo;
  no_vertex.vertex_function = 0;
  expect_refusal = 1;
  CHECK(!MTLDevice_newRenderPipelineState(device, &no_vertex, &err), "pipeline without a vertex function created");

  /* draw a full-target triangle with it: Nop, SetPSO, Draw */
  obj_handle_t target2 = MTLDevice_newTexture(device, &tinfo);
  struct WMTRenderPassInfo pass2 = pass;
  pass2.colors[0].texture = target2;
  pass2.colors[0].clear_color = (struct WMTClearColor){0.0, 0.0, 0.0, 1.0};
  struct wmtcmd_base draw_head = {.type = WMTRenderCommandNop};
  struct wmtcmd_render_setpso set_rpso = {.type = WMTRenderCommandSetPSO, .pso = rpso};
  struct wmtcmd_render_draw draw = {.type = WMTRenderCommandDraw, .primitive_type = WMTPrimitiveTypeTriangle,
                                    .vertex_count = 3, .instance_count = 1};
  draw_head.next.ptr = &set_rpso; set_rpso.next.ptr = &draw;
  cmdbuf = MTLCommandQueue_commandBuffer(queue);
  render = MTLCommandBuffer_renderCommandEncoder(cmdbuf, &pass2);
  MTLRenderCommandEncoder_encodeCommands(render, &draw_head);
  MTLCommandEncoder_endEncoding(render);

  /* a buffer the registry does not know (made outside the remoted calls) is still updated: one 1.9.6
   * report refused 357 MTLBuffer_updateContents calls */
  id<MTLBuffer> uncovered = [(id<MTLDevice>)HOST(device) newBufferWithLength:16 options:MTLResourceStorageModeShared];
  memset(uncovered.contents, 0, 16);
  static const uint8_t pattern[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
  MTLBuffer_updateContents((obj_handle_t)(uintptr_t)uncovered, 0, (struct WMTConstMemoryPointer){pattern}, sizeof pattern);

  MTLCommandBuffer_commit(cmdbuf);
  MTLCommandBuffer_waitUntilCompleted(cmdbuf);
  status = MTLCommandBuffer_status(cmdbuf);
  CHECK(status == WMTCommandBufferStatusCompleted, "draw command buffer status %llu", (unsigned long long)status);
  [(id<MTLTexture>)HOST(target2) getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
  bad = 0;
  for (int i = 0; i < 16; i++) bad += px[4 * i] != 0xff || px[4 * i + 1] != 0 || px[4 * i + 2] != 0 || px[4 * i + 3] != 0xff;
  CHECK(!bad, "triangle draw: %d of 16 pixels not red (first %02x%02x%02x%02x)", bad, px[0], px[1], px[2], px[3]);
  CHECK(!memcmp(uncovered.contents, pattern, sizeof pattern), "MTLBuffer_updateContents on an uncovered buffer");
  [uncovered release];

  /* The client goes away with an encoder still open (a game killed mid-frame, VRChat quitting): the
   * context's teardown ends it before releasing it. 1.9.6 aborted the VM: Command encoder released
   * without endEncoding (STEAMAC-6Z/70). */
  obj_handle_t open_cmdbuf = MTLCommandQueue_commandBuffer(queue);
  CHECK(MTLCommandBuffer_renderCommandEncoder(open_cmdbuf, &pass2), "render encoder left open");

  /* +1 objects go back through call 1 and its validation */
  obj_handle_t owned[] = {rpso, fs, vs, shaders, data, target2, pso, function, library, target, out, dst, src, queue, devices};
  for (size_t i = 0; i < sizeof owned / sizeof *owned; i++) NSObject_release(owned[i]);
  wmtr_host_destroy(H);

  printf("wmtr_dxmt_test: %s\n", failures ? "FAILED" : "all passed");
  return failures != 0;
} }
