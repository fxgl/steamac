// STEAMAC-41 fe8dd2b0 / STEAMAC-R b140588e: complete captured MSL.
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _985
{
    float _m0;
};

struct spvDescriptorSetBuffer0
{
    constant void* _m0_pad [[id(0)]];
    constant _985* m_5618 [[id(1)]];
    constant void* _m2_pad [[id(2)]];
    constant void* _m3_pad [[id(3)]];
    sampler m_3234 [[id(4)]];
    texture2d<float> m_3469 [[id(5)]];
};

struct MainPs_out
{
    float4 m_3711 [[color(0)]];
};

struct MainPs_in
{
    float4 m_5842 [[user(locn0)]];
    float2 m_5800 [[user(locn1)]];
};

fragment MainPs_out MainPs(MainPs_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    MainPs_out out = {};
    float4 _3401 = spvDescriptorSet0.m_3469.sample(spvDescriptorSet0.m_3234, in.m_5800.xy);
    float4 _20794 = in.m_5842.xyzw * _3401.xyzw;
    if (_20794.w < (*spvDescriptorSet0.m_5618)._m0)
    {
        discard_fragment();
    }
    _20794.w = 1.0;
    out.m_3711 = _20794;
    return out;
}

