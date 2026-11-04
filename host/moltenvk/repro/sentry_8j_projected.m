// STEAMAC-8J: link projected sample-rate MSL and compare interpolation/readback.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

enum { Width = 2, Height = 2, Components = Width * Height * 4 };
static void fail(NSString *message) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }

static id<MTLLibrary> library(id<MTLDevice> device, NSString *path, MTLMathMode mode) {
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!source) fail(error.description);
    source = [source stringByAppendingString:
        @"\nstruct SentryVertex { float4 position [[position]]; float4 c0 [[user(locn0)]]; float4 c1 [[user(locn1)]]; uint tag [[user(locn2)]]; };\n"
         "vertex SentryVertex sentry_vertex(uint id [[vertex_id]]) { SentryVertex o; "
         "float2 xy=float2((id<<1)&2u,id&2u)*2.0f-1.0f; float w=id==0?1.0f:(id==1?8.0f:64.0f); "
         "o.position=float4(xy*w,0.0f,w); o.c0=float4(0.1f+float(id)*0.4f,0.8f-float(id)*0.3f,0.4f,0.5f+float(id)*0.2f); "
         "o.c1=o.c0.wzyx; o.tag=7u; return o; }\n"];
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_0;
    options.mathMode = mode;
    id<MTLLibrary> result = [device newLibraryWithSource:source options:options error:&error];
    if (!result) fail(error.description);
    return result;
}

static void render(id<MTLDevice> device, id<MTLLibrary> lib, NSUInteger samples, _Float16 output[Components]) {
    NSError *error = nil;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [lib newFunctionWithName:@"sentry_vertex"];
    descriptor.fragmentFunction = [lib newFunctionWithName:@"main0"];
    descriptor.rasterSampleCount = samples;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fail(error.description);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
        width:Width height:Height mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> resolved = [device newTextureWithDescriptor:td];
    id<MTLTexture> target = resolved;
    if (samples > 1) {
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = samples;
        td.storageMode = MTLStorageModePrivate;
        target = [device newTextureWithDescriptor:td];
    }
    if (!target || !resolved) fail(@"render texture allocation");
    MTLTextureDescriptor *inputDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:1 height:1 mipmapped:NO];
    inputDescriptor.storageMode = MTLStorageModeShared;
    inputDescriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> input = [device newTextureWithDescriptor:inputDescriptor];
    const unsigned char texel[] = {64, 128, 192, 255};
    [input replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:texel bytesPerRow:4];
    MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:samplerDescriptor];
    if (!input || !sampler) fail(@"sampled texture allocation");
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].resolveTexture = samples > 1 ? resolved : nil;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = samples > 1 ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:input atIndex:0];
    [encoder setFragmentSamplerState:sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) fail(command.error.description);
    [resolved getBytes:output bytesPerRow:Width * 4 * sizeof(_Float16)
        fromRegion:MTLRegionMake2D(0, 0, Width, Height) mipmapLevel:0];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) fail(@"usage: projected <fragment.metal> [reference-interpolation.metal]");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) fail(@"no Metal device");
        const MTLMathMode modes[] = {MTLMathModeFast, MTLMathModeSafe, MTLMathModeRelaxed};
        const NSUInteger counts[] = {1, 4, 8};
        unsigned checks = 0;
        for (unsigned mode = 0; mode < 3; mode++) {
            id<MTLLibrary> actualLibrary = library(device, @(argv[1]), modes[mode]);
            id<MTLLibrary> referenceLibrary = argc == 3 ? library(device, @(argv[2]), modes[mode]) : nil;
            for (unsigned s = 0; s < 3; s++) {
                if (![device supportsTextureSampleCount:counts[s]]) continue;
                _Float16 actual[Components], expected[Components];
                render(device, actualLibrary, counts[s], actual);
                if (referenceLibrary) render(device, referenceLibrary, counts[s], expected);
                for (unsigned c = 0; c < Components; c++) {
                    const float sampled[] = {64.0f/255.0f, 128.0f/255.0f, 192.0f/255.0f, 1.0f};
                    float wanted = referenceLibrary ? (float)expected[c] : sampled[c % 4];
                    if (!isfinite((float)actual[c]) || fabsf((float)actual[c] - wanted) > 0.002f) {
                        fail([NSString stringWithFormat:@"sample/interpolation mismatch mode=%u samples=%lu component=%u actual=%g expected=%g",
                            mode, (unsigned long)counts[s], c, (double)actual[c], (double)wanted]);
                    }
                }
                checks++;
            }
        }
        printf("PASS: %s %u math/sample-count combinations, %s GPU readback\n", argv[1], checks,
            argc == 3 ? "native vs sample-position interpolation" : "projected texture");
    }
}
