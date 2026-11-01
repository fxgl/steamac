// Shaders for wmtr_dxmt_test, loaded as a metallib through DispatchData_alloc_init + MTLDevice_newLibrary
#include <metal_stdlib>
using namespace metal;

// one triangle covering the whole target
vertex float4 vs(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2);
  return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 fs() { return float4(1.0, 0.0, 0.0, 1.0); }
