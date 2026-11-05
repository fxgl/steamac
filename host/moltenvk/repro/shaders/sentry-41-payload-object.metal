// STEAMAC-41 fe8dd2b0 / STEAMAC-R b140588e: complete captured MSL.
#include <metal_stdlib>
#include <simd/simd.h>
#include <metal_mesh>

using namespace metal;

struct _985
{
    float _m0;
};

struct spvDescriptorSetBuffer0
{
    constant void* _m0_pad [[id(0)]];
    constant void* _m1_pad [[id(1)]];
    constant _985* m_5618 [[id(2)]];
};

struct MainVs_out
{
    float4 m_4046 [[user(locn0)]];
    float4 m_5137 [[user(locn1)]];
    float m_5651 [[user(locn2)]];
    float gl_PointSize [[point_size]];
};

struct MainVs_in
{
    float3 m_4314;
    float4 m_5842;
};

MainVs_out MainVs(MainVs_in in, constant spvDescriptorSetBuffer0& spvDescriptorSet0)
{
    MainVs_out out = {};
    float3 _22236 = in.m_5842.xyz * float3(0.077399380505084991455078125);
    float3 _24533 = powr(fma(in.m_5842.xyz, float3(0.947867333889007568359375), float3(0.052132703363895416259765625)), float3(2.400000095367431640625));
    float _21354;
    if (in.m_5842.x <= 0.040449999272823333740234375)
    {
        _21354 = _22236.x;
    }
    else
    {
        _21354 = _24533.x;
    }
    float _21355;
    if (in.m_5842.y <= 0.040449999272823333740234375)
    {
        _21355 = _22236.y;
    }
    else
    {
        _21355 = _24533.y;
    }
    float _19302;
    if (in.m_5842.z <= 0.040449999272823333740234375)
    {
        _19302 = _22236.z;
    }
    else
    {
        _19302 = _24533.z;
    }
    out.m_4046 = float4(in.m_4314, 1.0);
    out.m_5137 = float4(_21354, _21355, _19302, in.m_5842.w);
    out.m_5651 = (*spvDescriptorSet0.m_5618)._m0;
    out.gl_PointSize = 1.0;
    return out;
}

struct spvGSVertex
{
    float4 position;
    float pointSize;
    float clipDistance[8];
    float cullDistance[8];
    uint4 locations[32];
};

struct Payload
{
    uint primitiveId;
    uint spvPayloadPad[3];
    spvGSVertex vertices[1];
};
struct DrawInfo
{
    int32_t indexed;
    int32_t indexSize;
    int64_t indexBuffer;
    int32_t baseVertex;
    uint32_t baseInstance;
    uint32_t vertexStrides[31];
    uint32_t vertexDivisors[31];
    uint8_t topoStrip;
};

static inline uint spvFetchIndex(constant DrawInfo *drawInfo, int b, uint vertexIndex, uint instance)
{
    uint d = drawInfo->vertexDivisors[b];
    return d == 0xffffffffu ? vertexIndex : drawInfo->baseInstance + (d ? instance / d : 0u);
}

[[object]]  void MainVs(object_data Payload &payload [[payload]], mesh_grid_properties meshGridProperties, constant DrawInfo *drawInfo [[buffer(24)]],
device uchar *vb30 [[buffer(30)]],
constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]],
uint3 positionInGrid [[thread_position_in_grid]], uint3 gridSize [[threadgroups_per_grid]])
{
    int vertexCount = 1;
    int startingIndex = drawInfo->topoStrip ? int(positionInGrid.x) : int(positionInGrid.x) * vertexCount;
    int instanceIndex = int(positionInGrid.y + drawInfo->baseInstance);
    payload.primitiveId = positionInGrid.x;
    payload.spvPayloadPad[0] = positionInGrid.y * gridSize.x + positionInGrid.x;
    for (int i = 0; i < vertexCount; ++i)
    {
        uint vertexIndex;
        int element = (drawInfo->topoStrip == 1 && vertexCount == 3 && (positionInGrid.x & 1) && i > 0) ? 3 - i : i;
        if (drawInfo->indexed)
        {
            
		if (drawInfo->indexSize == 1) {
			vertexIndex = ((constant uchar *)drawInfo->indexBuffer)[startingIndex + element];
			if (vertexIndex == 0xff) {
				return;
			}
		} else if (drawInfo->indexSize == 2) {
			vertexIndex = ((constant ushort *)drawInfo->indexBuffer)[startingIndex + element];
			if (vertexIndex == 0xffff) {
				return;
			}
		} else {
			vertexIndex = ((constant uint *)drawInfo->indexBuffer)[startingIndex + element];
			if (vertexIndex == 0xffffffff) {
				return;
			}
		}
        }
        else vertexIndex = startingIndex + element;
        vertexIndex += uint(drawInfo->baseVertex);
        MainVs_in in;
        in.m_4314 = *(device packed_float3 *)(vb30 + 0 + spvFetchIndex(drawInfo, 30, vertexIndex, positionInGrid.y) * drawInfo->vertexStrides[30]);
        in.m_5842 = float4(*(device packed_uchar4 *)(vb30 + 52 + spvFetchIndex(drawInfo, 30, vertexIndex, positionInGrid.y) * drawInfo->vertexStrides[30])) * (1.f/255.f);
        auto spvVSOut = MainVs(
        in
        , spvDescriptorSet0
        );
        payload.vertices[i].locations[0][0] = as_type<uint>(spvVSOut.m_4046.x);
        payload.vertices[i].locations[0][1] = as_type<uint>(spvVSOut.m_4046.y);
        payload.vertices[i].locations[0][2] = as_type<uint>(spvVSOut.m_4046.z);
        payload.vertices[i].locations[0][3] = as_type<uint>(spvVSOut.m_4046.w);
        payload.vertices[i].locations[1][0] = as_type<uint>(spvVSOut.m_5137.x);
        payload.vertices[i].locations[1][1] = as_type<uint>(spvVSOut.m_5137.y);
        payload.vertices[i].locations[1][2] = as_type<uint>(spvVSOut.m_5137.z);
        payload.vertices[i].locations[1][3] = as_type<uint>(spvVSOut.m_5137.w);
        payload.vertices[i].locations[2][0] = as_type<uint>(spvVSOut.m_5651);
        payload.vertices[i].pointSize = spvVSOut.gl_PointSize;
    }
    meshGridProperties.set_threadgroups_per_grid(uint3(1, 1, 1));
}
