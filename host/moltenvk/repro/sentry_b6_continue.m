// STEAMAC-B6/B7/B8/B9: run the loop whose continue block writes texel (i, 0) = i for i < 8 into a
// 16x1 R32Float texture (preset to -1). Texels 0-7 must hold 0-7, texels 8-15 stay -1.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (!library) { fprintf(stderr, "FAIL library: %s\n", error.description.UTF8String); return 1; }
        id<MTLFunction> function = [library newFunctionWithName:library.functionNames[0]];
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) { fprintf(stderr, "FAIL pipeline: %s\n", error.description.UTF8String); return 1; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                      width:16 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        float texels[16];
        for (int i = 0; i < 16; i++) texels[i] = -1.0f;
        [texture replaceRegion:MTLRegionMake2D(0, 0, 16, 1) mipmapLevel:0 withBytes:texels bytesPerRow:sizeof(texels)];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:texture atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [encoder endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "FAIL command buffer status %ld\n", (long)cb.status); return 1; }
        [texture getBytes:texels bytesPerRow:sizeof(texels) fromRegion:MTLRegionMake2D(0, 0, 16, 1) mipmapLevel:0];
        for (int i = 0; i < 16; i++) {
            float expected = i < 8 ? (float)i : -1.0f;
            if (texels[i] != expected) { fprintf(stderr, "FAIL texel %d = %g, expected %g\n", i, texels[i], expected); return 1; }
        }
        printf("OK continue-block writes: texels 0-7 = 0-7, 8-15 untouched\n");
    }
    return 0;
}
