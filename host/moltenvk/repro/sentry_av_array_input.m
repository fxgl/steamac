// Execute the translated object fetch, read its payload from a tiny mesh stage.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    int32_t indexed, indexSize;
    int64_t indexBuffer;
    int32_t baseVertex;
    uint32_t baseInstance, vertexStrides[31], vertexDivisors[31];
    uint8_t topoStrip;
} DrawInfo;

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        unsigned format = (unsigned)strtoul(argv[2], NULL, 10);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        if (!source) return 2;
        source = [source stringByAppendingString:@"\nstruct CheckVertex { float4 position [[position]]; };\n"
            "struct CheckPrimitive {};\n"
            "[[mesh]] void check(object_data const Payload &p [[payload]], "
            "metal::mesh<CheckVertex, CheckPrimitive, 1, 1, metal::topology::point> m, "
            "device float4 *values [[buffer(30)]]) {\n"
            "for (uint i=0;i<3;i++) values[i]=float4(as_type<float>(p.vertices[i].locations[0][0]), "
            "as_type<float>(p.vertices[i].locations[0][1]), as_type<float>(p.vertices[i].locations[0][2]), "
            "as_type<float>(p.vertices[i].locations[0][3])); m.set_primitive_count(0); }\n"
            "fragment float4 checkFragment() { return float4(1); }\n"];
        for (unsigned version = 0; version < 2; version++) {
            MTLCompileOptions *options = [MTLCompileOptions new];
            options.languageVersion = version ? MTLLanguageVersion4_0 : MTLLanguageVersion3_0;
            id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
            if (!library) { fprintf(stderr, "FAIL AV library: %s\n", error.description.UTF8String); return 1; }
            MTLMeshRenderPipelineDescriptor *desc = [MTLMeshRenderPipelineDescriptor new];
            desc.objectFunction = [library newFunctionWithName:@"main0"];
            desc.meshFunction = [library newFunctionWithName:@"check"];
            desc.fragmentFunction = [library newFunctionWithName:@"checkFragment"];
            desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithMeshDescriptor:desc options:MTLPipelineOptionNone reflection:nil error:&error];
            if (!pipeline) { fprintf(stderr, "FAIL AV pipeline: %s\n", error.description.UTF8String); return 1; }
            DrawInfo info = {0};
            for (unsigned i=0; i<31; i++) info.vertexDivisors[i] = UINT32_MAX;
            info.vertexStrides[28] = 4;
            info.vertexStrides[29] = 16;
            _Float16 first[6] = {0.25, -0.5, 0.5, -0.5, 0.75, -0.5};
            uint8_t second[52] = {0};
            float expected[2] = {0.5, 0.75};
            for (unsigned i=0; i<3; i++) {
                void *p = second + 4 + i*16;
                if (format == 8) { _Float16 values[2] = {0.5, 0.75}; memcpy(p, values, sizeof(values)); }
                else if (format == 4) { float values[2] = {0.5, 0.75}; memcpy(p, values, sizeof(values)); }
                else if (format == 1) { uint8_t values[2] = {128, 255}; memcpy(p, values, sizeof(values)); expected[0] = 128.f/255.f; expected[1] = 1; }
                else if (format == 12) { uint32_t value = 512 | (1023 << 10); memcpy(p, &value, sizeof(value)); expected[0] = 512.f/1023.f; expected[1] = 1; }
                else return 2;
            }
            id<MTLBuffer> output = [device newBufferWithLength:48 options:MTLResourceStorageModeShared];
            id<MTLCommandQueue> queue = [device newCommandQueue];
            id<MTLCommandBuffer> command = [queue commandBuffer];
            MTLTextureDescriptor *targetDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
            targetDesc.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> target = [device newTextureWithDescriptor:targetDesc];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.renderTargetWidth = pass.renderTargetHeight = 1;
            pass.colorAttachments[0].texture = target;
            id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
            [encoder setRenderPipelineState:pipeline];
            [encoder setObjectBytes:&info length:sizeof(info) atIndex:20];
            [encoder setObjectBytes:first length:sizeof(first) atIndex:28];
            [encoder setObjectBytes:second length:sizeof(second) atIndex:29];
            [encoder setMeshBuffer:output offset:0 atIndex:30];
            [encoder drawMeshThreadgroups:MTLSizeMake(1, 1, 1) threadsPerObjectThreadgroup:MTLSizeMake(1, 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(1, 1, 1)];
            [encoder endEncoding];
            [command commit];
            [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "FAIL AV GPU: %s\n", command.error.description.UTF8String); return 1; }
            float *values = output.contents;
            for (unsigned i=0; i<3; i++) {
                if (values[i*4] != (i+1)*0.25f || values[i*4+1] != -0.5f || fabsf(values[i*4+2]-expected[0]) > 0.00001f || fabsf(values[i*4+3]-expected[1]) > 0.00001f) {
                    fprintf(stderr, "FAIL AV vertex %u: %g %g %g %g\n", i, values[i*4], values[i*4+1], values[i*4+2], values[i*4+3]); return 1;
                }
            }
            printf("PASS AV: MSL %u half2[2], separate binding/offset/stride, second format %u, 3 payloads\n", version ? 4 : 3, format);
        }
        return 0;
    }
}
