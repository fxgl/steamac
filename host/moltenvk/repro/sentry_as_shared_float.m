// Reconstructed STEAMAC-AS: contended FAdd returns, float bit preservation and plain accesses.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int compare(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        options.mathMode = MTLMathModeSafe;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (!library) { fprintf(stderr, "FAIL library: %s\n", error.description.UTF8String); return 1; }
        id<MTLFunction> function = [library newFunctionWithName:library.functionNames[0]];
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) { fprintf(stderr, "FAIL pipeline: %s\n", error.description.UTF8String); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLBuffer> buffer = [device newBufferWithLength:1032 * sizeof(float) options:MTLResourceStorageModeShared];
        for (unsigned iteration = 0; iteration < 8; iteration++) {
            memset(buffer.contents, 0xff, buffer.length);
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:buffer offset:0 atIndex:0];
            [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(512, 1, 1)];
            [encoder endEncoding];
            [command commit];
            [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "FAIL GPU: %s\n", command.error.description.UTF8String); return 1; }
            float *values = buffer.contents;
            uint32_t sign;
            memcpy(&sign, &values[513], sizeof(sign));
            if (values[512] != 256.0f || sign != 0x80000000u || values[514] != 1.5f ||
                !isnan(values[515]) || !isnan(values[516])) {
                fprintf(stderr, "FAIL atomic values: %g 0x%x %g %g %g\n", values[512], sign, values[514], values[515], values[516]); return 1;
            }
            qsort(values, 512, sizeof(float), compare);
            for (unsigned i = 0; i < 512; i++) {
                if (values[i] != i * 0.5f || values[520+i] != i) {
                    fprintf(stderr, "FAIL lane %u: atomic %g plain %g\n", i, values[i], values[520+i]); return 1;
                }
            }
        }
        printf("PASS AS: 8 x 512 contended adds, original values, NaN, signed zero, exchange, plain accesses; shared=%lu\n", (unsigned long)pipeline.staticThreadgroupMemoryLength);
        return 0;
    }
}
