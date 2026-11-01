/* Real-object regression for cross-context pools and pre-dispatch handle validation.
 * Unlike the marshalling loopback's fake integer handles, provenance checks are enabled here. */
#define WMTR_TESTING 1
#include "../src/wmtr_host.m"
static int alive, dispatched, failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)
@interface LifetimeProbe : NSObject
@end
@implementation LifetimeProbe
- (instancetype)init { if ((self = [super init])) alive++; return self; }
- (void)dealloc { alive--; [super dealloc]; }
@end
static NTSTATUS make_probe(void *p) { ((struct unixcall_generic_obj_ret *)p)->ret = (uint64_t)[[[LifetimeProbe alloc] init] autorelease]; return 0; }
static NTSTATUS make_owned(void *p) { ((struct unixcall_generic_obj_ret *)p)->ret = (uint64_t)[[LifetimeProbe alloc] init]; return 0; }
static NTSTATUS query(void *p) { dispatched++; ((struct unixcall_generic_obj_uint64_ret *)p)->ret = 42; return 0; }
static NTSTATUS retain_object(void *p) { [(id)*(uint64_t *)p retain]; return 0; }
static NTSTATUS release_object(void *p) { [(id)*(uint64_t *)p release]; return 0; }
static NTSTATUS noop(void *p) { dispatched++; return 0; }
static NTSTATUS command_buffer(void *p) {
  ((struct unixcall_generic_obj_obj_ret *)p)->ret = (uint64_t)[(id<MTLCommandQueue>)((struct unixcall_generic_obj_obj_ret *)p)->handle commandBuffer]; return 0;
}
static NTSTATUS queue(void *p) { ((struct unixcall_generic_obj_ret *)p)->ret = (uint64_t)[[MTLCreateSystemDefaultDevice() newCommandQueue] autorelease]; return 0; }
static NTSTATUS bad_string(void *p) { char buffer[8]; [(id)((struct unixcall_nsstring_getcstring *)p)->str getCString:buffer maxLength:sizeof buffer encoding:NSUTF8StringEncoding]; return 0; }
const void *wmtr_impl_funcs[WMTR_NCALLS] = {[0]=retain_object, [1]=release_object, [4]=make_owned, [5]=query, [53]=make_probe, [62]=queue, [11]=command_buffer, [30]=noop, [38]=noop, [8]=bad_string, [92]=query};
uint64_t wmtr_test_present_create_view(void *c, uint64_t hwnd, void *dev, uint64_t *layer) { return 0; }
void wmtr_test_present_release_view(void *c, uint64_t v) {}
static void *blob(void *ctx, uint32_t n, uint64_t *size) { *size = WMTR_RING_BLOB_BYTES; return n ? NULL : ctx; }
static void wake(void *ctx, uint32_t n) {}
static const struct wmtr_host_ops ops = {blob, wake};
static struct wmtr_host *new_host(void) {
  struct wmtr_ring *ring = calloc(1, WMTR_RING_BLOB_BYTES);
  ring->magic = WMTR_RING_MAGIC; ring->version = WMTR_VERSION;
  return wmtr_host_create(ring, &ops, ring);
}
static void destroy_host(struct wmtr_host *h) { void *ring = h->ring; wmtr_host_destroy(h); free(ring); }
static NTSTATUS call(struct wmtr_host *h, uint16_t n, void *params, uint32_t size) {
  uint8_t record[8192] = {0};
  struct wmtr_req_ext *r = (void *)record;
  r->h.call=n; r->h.flags=WMTR_F_SYNC; r->h.slot=0; r->h.params_size=size;
  r->payload_size=size; uint32_t off=wmtr_req_payload_offset(r); r->h.size=off+size;
  memcpy(record+off, params, size); execute(h, record, off+size);
  memcpy(params, h->slots[0].data, size); return h->slots[0].status;
}
int main(void) { @autoreleasepool {
  setenv("WMTR_TEST_STRICT_OBJECTS", "1", 1);
  struct wmtr_host *a=new_host(), *b=new_host(); CHECK(a && b);
  struct unixcall_generic_obj_uint64_ret color={WMTColorSpaceHDR10,0};
  CHECK(call(a,92,&color,sizeof color)==0 && color.ret==42); /* enum, not an object handle */
  struct unixcall_generic_obj_ret pa={0}, pb={0}, oa={0}, ob={0};
  CHECK(call(a,10,&pa,sizeof pa)==0); CHECK(call(a,53,&oa,sizeof oa)==0);
  CHECK(call(b,10,&pb,sizeof pb)==0); CHECK(call(b,53,&ob,sizeof ob)==0); CHECK(alive==2);
  uint64_t pool=pa.ret; CHECK(call(a,1,&pool,8)==0);
  CHECK(alive==1); /* old globals drain b's slot-0 pool as well */
  struct unixcall_generic_obj_uint64_ret q={ob.ret,0}; CHECK(call(b,5,&q,sizeof q)==0 && q.ret==42);
  q.handle=oa.ret; CHECK(call(a,5,&q,sizeof q)==STATUS_INVALID_HANDLE); /* freed with a's pool */
  q.handle=0x365a41f3321aa8ull; int before=dispatched;
  CHECK(call(a,5,&q,sizeof q)==STATUS_INVALID_HANDLE && dispatched==before); /* garbage (STEAMAC-5W) */
  /* A live object the registry does not know (another context's, or made by a call the metadata does
   * not cover, like DispatchData_alloc_init) goes through: refusing it gave DXMT nil libraries. */
  q.handle=ob.ret; before=dispatched; CHECK(call(a,5,&q,sizeof q)==0 && q.ret==42 && dispatched==before+1);
  LifetimeProbe *uncovered=[[LifetimeProbe alloc] init];
  q.handle=(uint64_t)uncovered; CHECK(call(a,5,&q,sizeof q)==0 && q.ret==42);
  [uncovered release];
  pool=pb.ret; CHECK(call(b,1,&pool,8)==0); CHECK(alive==0);
  /* Deterministic worker-versus-pool-drain interleaving: the call's lease survives its owner. */
  CHECK(call(b,10,&pb,sizeof pb)==0); CHECK(call(b,53,&ob,sizeof ob)==0);
  uint64_t borrowed=ob.ret; CHECK(call(b,1,&borrowed,8)==STATUS_INVALID_HANDLE && alive==1);
  struct unixcall_generic_obj_uint64_ret leased_query={ob.ret,0};
  struct object_walk lease={b,(uint8_t *)&leased_query,sizeof leased_query,OBJECT_LEASE,5};
  pthread_mutex_lock(&b->object_lock);
  CHECK(objects_walk(&lease,(void *)&leased_query,0));
  pthread_mutex_unlock(&b->object_lock);
  pool=pb.ret; CHECK(call(b,1,&pool,8)==0); CHECK(alive==1);
  lease.mode=OBJECT_UNLEASE; CHECK(objects_walk(&lease,(void *)&leased_query,0)); CHECK(alive==0);
  struct unixcall_generic_obj_ret owned={0}; CHECK(call(a,4,&owned,sizeof owned)==0);
  uint64_t handle=owned.ret; CHECK(call(a,0,&handle,8)==0); CHECK(call(a,1,&handle,8)==0); CHECK(alive==1);
  CHECK(call(a,1,&handle,8)==0); CHECK(alive==0); before=dispatched;
  CHECK(call(a,1,&handle,8)==STATUS_INVALID_HANDLE && dispatched==before);
  /* Embedded command resources are validated, not merely the receiver. */
  CHECK(call(a,4,&owned,sizeof owned)==0);
  struct { struct unixcall_generic_obj_cmd_noret p; struct wmtcmd_render_settexture c; } cmd={0};
  cmd.p.encoder=owned.ret; cmd.p.cmd_head.ptr=&cmd.c; cmd.c.type=WMTRenderCommandSetFragmentTexture; cmd.c.texture=0xdeadbeef;
  struct object_walk walk={a,(uint8_t *)&cmd,sizeof cmd,OBJECT_VALIDATE,38};
  CHECK(!objects_walk(&walk,(void *)&cmd,0));
  /* DXMT heads every blit, compute and render list with a Nop (dxmt_context.cpp). 1.9.5 refused
   * every blit and compute list: Death's Door drew a black frame with magenta menu arrows. */
  for (uint16_t kind = 36; kind <= 38; kind++) {
    struct { struct unixcall_generic_obj_cmd_noret p; struct wmtcmd_base head; } list={0};
    list.p.encoder=owned.ret; list.p.cmd_head.ptr=&list.head;
    struct object_walk nop={a,(uint8_t *)&list,sizeof list,OBJECT_VALIDATE,kind};
    CHECK(objects_walk(&nop,(void *)&list,0));
  }
  handle=owned.ret; CHECK(call(a,1,&handle,8)==0);
  /* A known but wrong object type is caught at the Objective-C boundary, not a VM abort. */
  CHECK(call(a,4,&owned,sizeof owned)==0);
  struct unixcall_nsstring_getcstring s={.str=owned.ret};
  CHECK(call(a,8,&s,sizeof s)==STATUS_INVALID_PARAMETER && a->faulted);
  destroy_host(a); destroy_host(b);
  CHECK(alive==0); /* context loss also releases caller-owned objects */
  /* A committed real Metal buffer must not reach encoder creation (Metal would abort). */
  a=new_host(); struct unixcall_generic_obj_ret qr={0}; CHECK(call(a,62,&qr,sizeof qr)==0);
  struct unixcall_generic_obj_obj_ret cb={qr.ret,0}; CHECK(call(a,11,&cb,sizeof cb)==0);
  [(id<MTLCommandBuffer>)cb.ret commit]; [(id<MTLCommandBuffer>)cb.ret waitUntilCompleted];
  struct unixcall_generic_obj_obj_ret enc={cb.ret,0}; before=dispatched;
  CHECK(call(a,30,&enc,sizeof enc)==STATUS_INVALID_PARAMETER && enc.ret==0 && dispatched==before && a->faulted);
  destroy_host(a);
  printf("wmtr_lifetime_test: %s\n", failures ? "FAILED" : "all passed");
  return failures != 0;
} }
