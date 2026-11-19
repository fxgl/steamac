/* STEAMAC-BN/BP: exercise the shipped driver's real Metal bridge, not a copy.
 * The reports retain no MSL. Missing/wrong-stage entrypoints are controlled
 * failure inputs, not a claim to have reproduced CS2's unknown producer.
 * nm supplies the private symbol's image-relative address; no test exports.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REQUIRE(x, text) do { if (!(x)) { fprintf(stderr, "FAIL %s\n", text); exit(1); } } while (0)

int main(int argc, char **argv)
{
    REQUIRE(argc == 4, "usage: sentry-bn-entrypoint <dylib> <symbol-offset> <valid|missing|wrong-stage|nil>");
    @autoreleasepool {
        void *driver = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        REQUIRE(driver, dlerror());
        Dl_info info;
        REQUIRE(dladdr(dlsym(driver, "vk_icdGetInstanceProcAddr"), &info), "driver image base");
        id (*compile)(id, id) = (void *)((uintptr_t)info.dli_fbase + strtoull(argv[2], NULL, 16));
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
        REQUIRE(compiler, "Metal compiler");
        MTL4LibraryDescriptor *source = [MTL4LibraryDescriptor new];
        source.source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 vs(uint id [[vertex_id]]) { return float4(id == 1 ? 3 : -1, id == 2 ? 3 : -1, 0, 1); }\n"
            "fragment float4 fs() { return float4(0, 1, 0, 1); }\n";
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:source error:&error];
        REQUIRE(library, "Metal library");
        MTL4LibraryFunctionDescriptor *vertex = [MTL4LibraryFunctionDescriptor new];
        vertex.library = library;
        vertex.name = !strcmp(argv[3], "missing") ? @"absent_vertex" :
                      !strcmp(argv[3], "wrong-stage") ? @"fs" : @"vs";
        MTL4LibraryFunctionDescriptor *fragment = [MTL4LibraryFunctionDescriptor new];
        fragment.library = library;
        fragment.name = @"fs";
        MTL4RenderPipelineDescriptor *desc = [MTL4RenderPipelineDescriptor new];
        desc.vertexFunctionDescriptor = !strcmp(argv[3], "nil") ? nil : vertex;
        desc.fragmentFunctionDescriptor = fragment;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipeline = compile(compiler, desc);
        if (strcmp(argv[3], "valid")) {
            REQUIRE(!pipeline, "invalid vertex function must fail without entering Metal pipeline validation");
            printf("OK %s: invalid vertex function rejected\n", argv[3]);
            return 0;
        }
        REQUIRE(pipeline, "valid render pipeline");
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:4 height:4 mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:rp];
        [encoder setRenderPipelineState:pipeline];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        REQUIRE(cb.status == MTLCommandBufferStatusCompleted, "valid rendering completes");
        uint32_t pixels[16];
        [target getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
        for (unsigned i = 0; i < 16; i++) REQUIRE(pixels[i] == 0xff00ff00, "valid vertex/fragment pixels");
        puts("OK valid: 16 green pixels through the driver's bridge");
        [pipeline release];
    }
    return 0;
}
