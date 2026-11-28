// STEAMAC-CB/CF: run sentry-cb-robust-hoist.comp. cb holds 16 uint4 but its bound buffer size
// says 4 (64 bytes); m[k] = (100 + k, 5, 0, 0). i = 0, 1 read m[2], m[3] (y = 5) and write
// o[i + 1] = m[i + 2].x + 2 * (i + 2); i = 2 reads index 4, out of bounds: v = 0 ends the loop and
// o[0] = v = 0. A v not zeroed reads the clamped m[3].y = 5 and runs on to i = 5, o[0] = 5.
// Usage: sentry_cb_robust_hoist <file.metal> robust|plain
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        const bool robust = !strcmp(argv[2], "robust");
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
        uint32_t m[16][4] = {};
        for (uint32_t k = 0; k < 16; k++) { m[k][0] = 100 + k; m[k][1] = 5; }
        id<MTLBuffer> cbuf = [device newBufferWithBytes:m length:sizeof(m) options:MTLResourceStorageModeShared];
        uint32_t o[8];
        for (int i = 0; i < 8; i++) o[i] = 0xdeadbeef;
        id<MTLBuffer> obuf = [device newBufferWithBytes:o length:sizeof(o) options:MTLResourceStorageModeShared];
        uint32_t sizes[2] = { 64, sizeof(o) };
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:cbuf offset:0 atIndex:0];
        [encoder setBuffer:obuf offset:0 atIndex:1];
        if (robust) [encoder setBytes:sizes length:sizeof(sizes) atIndex:25];
        [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [encoder endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "FAIL command buffer status %ld\n", (long)cb.status); return 1; }
        memcpy(o, obuf.contents, sizeof(o));
        // Without robustness all 16 entries are in bounds: m[k].y = 5 runs to i = 5, o[0] = 5.
        static const uint32_t in_bounds[8] = { 0, 106, 109, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef };
        static const uint32_t unbounded[8] = { 5, 106, 109, 112, 115, 118, 0xdeadbeef, 0xdeadbeef };
        const uint32_t *expected = robust ? in_bounds : unbounded;
        for (int i = 0; i < 8; i++) {
            if (o[i] != expected[i]) { fprintf(stderr, "FAIL %s o[%d] = %u, expected %u\n", argv[2], i, o[i], expected[i]); return 1; }
        }
        printf("OK %s: the value loaded in the loop is %s after it\n", argv[2], robust ? "zero out of bounds" : "the last loaded");
    }
    return 0;
}
