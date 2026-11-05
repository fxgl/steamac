// STEAMAC-41 fe8dd2b0 / STEAMAC-R b140588e: complete captured MSL.
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>
#include <metal_mesh>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

struct spvXfbContext
{
    device uchar *buffers[4];
    uint mode;
    uint slot;
    uint count;
};

template<typename V>
static inline void spvXfbCapture(thread spvXfbContext &, thread const V &)
{
}

template<typename V, typename P, int MaxV, int MaxP, metal::topology T>
struct spvMeshStream
{
    using mesh_t = metal::mesh<V, P, MaxV, MaxP, T>;
    thread mesh_t &meshOut;
    int currentVertex = 0;
    int currentIndex = 0;
    int currentVertexInPrimitive = 0;
    int currentPrimitive = 0;
    thread P &primitiveData;
    thread V &vertexData;
    thread spvXfbContext *xfb;
    V xfbPrev[2];
    spvMeshStream(thread mesh_t &_meshOut, thread V &_v, thread P &_p, thread spvXfbContext *_xfb = nullptr) : meshOut(_meshOut), primitiveData(_p), vertexData(_v), xfb(_xfb)
    {
    }
    ~spvMeshStream()
    {
        meshOut.set_primitive_count(xfb && xfb->mode == 1 ? 0 : currentPrimitive);
    }
    int VperP()
    {
        if (T == metal::topology::triangle)          return 3;
        else if (T == metal::topology::line)         return 2;
        else /* if (T == metal::topology::point) */  return 1;
    }
    void EndPrimitive()
    {
        currentVertexInPrimitive = 0;
    }
    void EmitVertex()
    {
        V v = vertexData;
        v.gl_Position.y = -v.gl_Position.y; // Invert Y-axis for Metal
        meshOut.set_vertex(currentVertex++, v);
        currentVertexInPrimitive++;
        if (currentVertexInPrimitive >= VperP())
        {
            bool odd = T == metal::topology::triangle && ((currentVertexInPrimitive - 3) & 1);
            if (T == metal::topology::triangle) meshOut.set_index(currentIndex++, currentVertex-3);
            if (T == metal::topology::triangle) meshOut.set_index(currentIndex++, odd ? currentVertex-1 : currentVertex-2);
            if (T == metal::topology::triangle) meshOut.set_index(currentIndex++, odd ? currentVertex-2 : currentVertex-1);
            if (T == metal::topology::line) meshOut.set_index(currentIndex++, currentVertex-2);
            if (T != metal::topology::triangle) meshOut.set_index(currentIndex++, currentVertex-1);
            meshOut.set_primitive(currentPrimitive++, primitiveData);
            if (xfb)
            {
                if (T == metal::topology::point) spvXfbCapture(*xfb, vertexData);
                else if (T == metal::topology::line) { spvXfbCapture(*xfb, xfbPrev[1]); spvXfbCapture(*xfb, vertexData); }
                else if (!odd) { spvXfbCapture(*xfb, xfbPrev[0]); spvXfbCapture(*xfb, xfbPrev[1]); spvXfbCapture(*xfb, vertexData); }
                else { spvXfbCapture(*xfb, xfbPrev[0]); spvXfbCapture(*xfb, vertexData); spvXfbCapture(*xfb, xfbPrev[1]); }
            }
        }
        if (xfb && T != metal::topology::point) { xfbPrev[0] = xfbPrev[1]; xfbPrev[1] = vertexData; }
    }
};
struct _856
{
    float4 _m0[4];
};

struct _2964
{
    _856 _m0;
    char _m1_pad[256];
    float3 _m1;
    float3 _m2;
    char _m3_pad[24];
    float2 _m3;
    char _m4_pad[144];
    float4 _m4;
};

struct MainGs_out_2
{
};
struct spvDescriptorSetBuffer0
{
    constant void* _m0_pad [[id(0)]];
    constant void* _m1_pad [[id(1)]];
    constant void* _m2_pad [[id(2)]];
    constant _2964* m_4459 [[id(3)]];
};

struct MainGs_out_1
{
    float4 m_3813 [[user(locn0)]];
    float2 m_4667 [[user(locn1)]];
    float4 m_4023 [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct MainGs_out_2_1
{
};
struct MainGs_in
{
    spvUnsafeArray<float4, 1> m_4314;
    spvUnsafeArray<float4, 1> m_5842;
    spvUnsafeArray<float, 1> m_5919;
};

enum { VERTEX_COUNT = 4, PRIMITIVE_COUNT = 2 };
using mesh_stream_t = spvMeshStream<MainGs_out_1, MainGs_out_2_1, VERTEX_COUNT, PRIMITIVE_COUNT, metal::topology::triangle>;
void MainGs(mesh_stream_t::mesh_t spvMeshOut, MainGs_in in, constant spvDescriptorSetBuffer0& spvDescriptorSet0)
{
    MainGs_out_1 out = {};
    MainGs_out_2_1 out_1 = {};
    mesh_stream_t meshStream(spvMeshOut, out, out_1);
    float3 _16573 = cross((*spvDescriptorSet0.m_4459)._m1, (*spvDescriptorSet0.m_4459)._m2);
    float _17327 = in.m_5919[0] * (-0.5);
    float3 _19242 = in.m_4314[0].xyz + (_16573 * _17327);
    float3 _16954 = (*spvDescriptorSet0.m_4459)._m2 * _17327;
    float4 _21447 = (*spvDescriptorSet0.m_4459)._m4 * 1.0;
    float4x4 _15571 = float4x4(float4((*spvDescriptorSet0.m_4459)._m0._m0[0].x, (*spvDescriptorSet0.m_4459)._m0._m0[1].x, (*spvDescriptorSet0.m_4459)._m0._m0[2].x, (*spvDescriptorSet0.m_4459)._m0._m0[3].x), float4((*spvDescriptorSet0.m_4459)._m0._m0[0].y, (*spvDescriptorSet0.m_4459)._m0._m0[1].y, (*spvDescriptorSet0.m_4459)._m0._m0[2].y, (*spvDescriptorSet0.m_4459)._m0._m0[3].y), float4((*spvDescriptorSet0.m_4459)._m0._m0[0].z, (*spvDescriptorSet0.m_4459)._m0._m0[1].z, (*spvDescriptorSet0.m_4459)._m0._m0[2].z, (*spvDescriptorSet0.m_4459)._m0._m0[3].z), float4((*spvDescriptorSet0.m_4459)._m0._m0[0].w, (*spvDescriptorSet0.m_4459)._m0._m0[1].w, (*spvDescriptorSet0.m_4459)._m0._m0[2].w, (*spvDescriptorSet0.m_4459)._m0._m0[3].w));
    float4 _24259 = (float4((_19242 + _16954).xyz, 1.0) + _21447).xyzw * _15571;
    float2 _9003 = ((_24259.xy / float2(_24259.w)) * 0.5) + float2(0.5);
    float2 _18769 = float2(_9003.x, 1.0 - _9003.y) / (*spvDescriptorSet0.m_4459)._m3.xy;
    float _8683 = 0.5 * in.m_5919[0];
    float3 _19243 = in.m_4314[0].xyz + (_16573 * _8683);
    float3 _16955 = (*spvDescriptorSet0.m_4459)._m2 * _8683;
    float4 _9193 = (float4((_19243 + _16955).xyz, 1.0) + _21447).xyzw * _15571;
    float2 _9004 = ((_9193.xy / float2(_9193.w)) * 0.5) + float2(0.5);
    float2 _18542 = float2(_9004.x, 1.0 - _9004.y) / (*spvDescriptorSet0.m_4459)._m3.xy;
    float4 _5752 = float4(_18769.x, _18542.yx, _18769.y);
    float4 _11773 = (float4((_19242 + _16955).xyz, 1.0) + _21447).xyzw * _15571;
    out.m_3813 = in.m_5842[0];
    out.m_4667 = float2(0.0);
    out.m_4023 = _5752;
    _11773.y = -_11773.y;
    out.gl_Position = _11773;
    meshStream.EmitVertex();
    out.m_3813 = in.m_5842[0];
    out.m_4667 = float2(0.0, 1.0);
    out.m_4023 = _5752;
    _24259.y = -_24259.y;
    out.gl_Position = _24259;
    meshStream.EmitVertex();
    out.m_3813 = in.m_5842[0];
    out.m_4667 = float2(1.0, 0.0);
    out.m_4023 = _5752;
    _9193.y = -_9193.y;
    out.gl_Position = _9193;
    meshStream.EmitVertex();
    float4 _11774 = (float4((_19243 + _16954).xyz, 1.0) + _21447).xyzw * _15571;
    out.m_3813 = in.m_5842[0];
    out.m_4667 = float2(1.0);
    out.m_4023 = _5752;
    _11774.y = -_11774.y;
    out.gl_Position = _11774;
    meshStream.EmitVertex();
    meshStream.EndPrimitive();
    out.gl_Position.y = -(out.gl_Position.y);    // Invert Y-axis for Metal
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
[[mesh]] void MainGs(mesh_stream_t::mesh_t outputMesh, const object_data Payload &payload [[payload]],
constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]],
uint lid [[thread_index_in_threadgroup]], uint tid [[threadgroup_position_in_grid]])
{
    MainGs_in in;
    const unsigned long vertexCount = 1;
    for (unsigned long i = 0; i < vertexCount; ++i)
    {
        const object_data spvGSVertex &vtx = payload.vertices[i];
        in.m_4314[i] = float4(as_type<float>(vtx.locations[0][0]), as_type<float>(vtx.locations[0][1]), as_type<float>(vtx.locations[0][2]), as_type<float>(vtx.locations[0][3]));
        in.m_5842[i] = float4(as_type<float>(vtx.locations[1][0]), as_type<float>(vtx.locations[1][1]), as_type<float>(vtx.locations[1][2]), as_type<float>(vtx.locations[1][3]));
        in.m_5919[i] = as_type<float>(vtx.locations[2][0]);
    }
    MainGs(outputMesh, in
    , spvDescriptorSet0
    );
}
