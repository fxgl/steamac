// GPU checks for STEAMAC-6D raw BDA atomics, 5C subgroup fences, and 5K MS queries.
// Invoked by sentry-msl.sh after compiling SPIR-V through the private SPIRV-Cross.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void fail(NSString *message)
{
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static void check_multisample_levels(id<MTLDevice> device, NSString *source)
{
    source = [source stringByAppendingString:
        @"\nvertex float4 sentry_vertex(uint v [[vertex_id]]) { "
         "return float4(float2((v << 1) & 2u, v & 2u) * 2.0 - 1.0, 0.0, 1.0); }\n"];
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_0;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (!library) fail(error.description);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"sentry_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"main0"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fail(error.description);
    MTLTextureDescriptor *texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1 height:1 mipmapped:NO];
    texture.textureType = MTLTextureType2DMultisample;
    texture.sampleCount = 4;
    texture.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    texture.storageMode = MTLStorageModePrivate;
    id<MTLTexture> multisample = [device newTextureWithDescriptor:texture];
    texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:1 height:1 mipmapped:NO];
    texture.usage = MTLTextureUsageRenderTarget;
    texture.storageMode = MTLStorageModeShared;
    id<MTLTexture> output = [device newTextureWithDescriptor:texture];
    if (!multisample || !output) fail(@"multisample query texture allocation failed");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    for (unsigned null_texture = 0; null_texture < 2; null_texture++) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = output;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:null_texture ? nil : multisample atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) fail(command.error.description);
        uint32_t actual[4];
        [output getBytes:actual bytesPerRow:sizeof(actual) fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        const uint32_t levels = null_texture ? 0 : 1;
        const uint32_t samples = null_texture ? 0 : 4;
        if (actual[0] != levels || actual[1] != samples || actual[2] != levels || actual[3] != samples)
            fail(@"multisample levels/samples readback mismatch");
    }
    puts("PASS: multisample mip/sample queries and null descriptor GPU readback");
}

static void check_captured_components(id<MTLDevice> device, NSString *source)
{
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_0;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (!library) fail(error.description);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"main0"];
    descriptor.rasterizationEnabled = NO;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fail(error.description);
    const float expected[] = {1, 2, 3, 1, 4, 4, 6, 6, 1, 2, 3, 1};
    id<MTLBuffer> output = [device newBufferWithLength:3 * sizeof(expected) options:MTLResourceStorageModeShared];
    if (!output) fail(@"vertex capture buffer allocation failed");
    memset(output.contents, 0xff, output.length);
    uint32_t vertex_count = 3;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.renderTargetWidth = 1;
    pass.renderTargetHeight = 1;
    pass.defaultRasterSampleCount = 1;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:output offset:0 atIndex:28];
    [encoder setVertexBytes:&vertex_count length:sizeof(vertex_count) atIndex:29];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) fail(command.error.description);
    for (unsigned vertex = 0; vertex < 3; vertex++)
        if (memcmp((char *)output.contents + vertex * sizeof(expected), expected, sizeof(expected)))
            fail(@"captured flattened vertex component values mismatch");
    puts("PASS: flattened vertex output components and helper writes GPU readback");
}

static void check_interpolant_components(id<MTLDevice> device, NSString *source)
{
    source = [source stringByAppendingString:
        @"\nstruct sentry_vertex_out { float4 position [[position]]; float4 color [[user(locn3)]]; };\n"
         "vertex sentry_vertex_out sentry_vertex(uint v [[vertex_id]]) { "
         "sentry_vertex_out out; "
         "out.position = float4(float2((v << 1) & 2u, v & 2u) * 2.0 - 1.0, 0.0, 1.0); "
         "out.color = float4(0.125, 0.25, 0.5, 1.0); return out; }\n"];
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_2;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (!library) fail(error.description);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"sentry_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"main0"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fail(error.description);
    MTLTextureDescriptor *texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    texture.usage = MTLTextureUsageRenderTarget;
    texture.storageMode = MTLStorageModeShared;
    id<MTLTexture> output = [device newTextureWithDescriptor:texture];
    if (!output) fail(@"interpolant render target allocation failed");
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = output;
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
    float actual[4];
    const float expected[4] = {0.125f, 0.5f, 1.0f, 0.125f};
    [output getBytes:actual bytesPerRow:sizeof(actual) fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    if (memcmp(actual, expected, sizeof(expected)))
        fail(@"centroid/sample/offset interpolant component readback mismatch");
    puts("PASS: centroid/sample/offset interpolant components GPU readback");
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 3) fail(@"usage: sentry_msl_runtime <bda|fence|ms-levels|components|interpolant> <generated.metal>");
        BOOL bda = strcmp(argv[1], "bda") == 0;
        BOOL levels = strcmp(argv[1], "ms-levels") == 0;
        BOOL components = strcmp(argv[1], "components") == 0;
        BOOL interpolant = strcmp(argv[1], "interpolant") == 0;
        if (!bda && !levels && !components && !interpolant && strcmp(argv[1], "fence") != 0) fail(@"unknown test");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) fail(@"no Metal device");
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&error];
        if (!source) fail(error.description);
        if (levels) {
            check_multisample_levels(device, source);
            return 0;
        }
        if (components) {
            check_captured_components(device, source);
            return 0;
        }
        if (interpolant) {
            check_interpolant_components(device, source);
            return 0;
        }
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_2;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (!library) fail(error.description);
        id<MTLFunction> function = [library newFunctionWithName:@"main0"];
        if (!function) fail(@"main0 not found");
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) fail(error.description);
        id<MTLBuffer> output = [device newBufferWithLength:32 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> counter = bda ? [device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared] : nil;
        if (!output || (bda && !counter)) fail(@"buffer allocation failed");
        memset(output.contents, 0xff, output.length);
        if (bda) *(uint32_t *)counter.contents = 42;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        if (bda) {
            uint64_t address = counter.gpuAddress;
            [encoder setBytes:&address length:sizeof(address) atIndex:0];
            [encoder setBuffer:output offset:0 atIndex:1];
            [encoder useResource:counter usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        } else {
            [encoder setBuffer:output offset:0 atIndex:0];
        }
        [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(bda ? 1 : 32, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) fail(command.error.description);
        uint32_t *values = output.contents;
        if (bda) {
            if (values[0] != 42 || *(uint32_t *)counter.contents != 43) fail(@"BDA atomic old/new value mismatch");
        } else {
            for (uint32_t i = 0; i < 32; i++)
                if (values[i] != ((i + 1u) & 31u)) fail(@"subgroup shared-memory readback mismatch");
        }
        printf("PASS: %s GPU readback\n", argv[1]);
    }
    return 0;
}
