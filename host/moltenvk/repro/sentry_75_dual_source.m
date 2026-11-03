// STEAMAC-75: run SPIRV-Cross's dual-source MSL through Metal and check the blend.
// Build: xcrun clang -fobjc-arc -framework Foundation -framework Metal sentry_75_dual_source.m -o dual-source
// Usage: dual-source <translated fragment .metal> [...]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

static void fail(NSString *message)
{
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static void check(id<MTLDevice> device, NSString *path)
{
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!source) fail(error.description);
    source = [source stringByAppendingString:
        @"\nvertex float4 sentry_vertex(uint v [[vertex_id]]) { "
         "return float4(float2((v << 1) & 2u, v & 2u) * 2.0 - 1.0, 0.0, 1.0); }\n"];
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_0;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (!library) fail(error.description);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"sentry_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"main0"];
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.pixelFormat = MTLPixelFormatRGBA8Unorm;
    color.blendingEnabled = YES;
    color.rgbBlendOperation = MTLBlendOperationAdd;
    color.alphaBlendOperation = MTLBlendOperationAdd;
    color.sourceRGBBlendFactor = MTLBlendFactorSource1Color;
    color.sourceAlphaBlendFactor = MTLBlendFactorSource1Alpha;
    color.destinationRGBBlendFactor = MTLBlendFactorZero;
    color.destinationAlphaBlendFactor = MTLBlendFactorZero;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fail(error.description);
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:color.pixelFormat
        width:1 height:1 mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    textureDescriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
    if (!texture) fail(@"render texture allocation failed");
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) fail(command.error.description);
    unsigned char actual[4];
    const unsigned char expected[4] = {32, 32, 191, 32};
    [texture getBytes:actual bytesPerRow:sizeof(actual) fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    for (unsigned component = 0; component < 4; component++) {
        if (abs((int)actual[component] - expected[component]) > 1) {
            fprintf(stderr, "FAIL: %s component %u = %u, expected %u\n", path.UTF8String,
                component, actual[component], expected[component]);
            exit(1);
        }
    }
    printf("PASS: %s dual-source blend RGBA = %u %u %u %u\n", path.UTF8String,
        actual[0], actual[1], actual[2], actual[3]);
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 2) fail(@"usage: dual-source <translated fragment .metal> [...]");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) fail(@"no Metal device");
        for (int i = 1; i < argc; i++) {
            @autoreleasepool { check(device, [NSString stringWithUTF8String:argv[i]]); }
        }
    }
    return 0;
}
