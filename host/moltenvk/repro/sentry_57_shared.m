// STEAMAC-57: print the compiler's actual threadgroup footprint, not a guessed layout.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: %s <shader.metal>\n", argv[0]); return 2; }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "FAIL no Metal device\n"); return 1; }
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        if (!source) { fprintf(stderr, "FAIL source: %s\n", error.description.UTF8String); return 1; }
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion3_0;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (!library) { fprintf(stderr, "FAIL library %s: %s\n", argv[1], error.description.UTF8String); return 1; }
        unsigned kernels = 0;
        for (NSString *name in library.functionNames) {
            id<MTLFunction> function = [library newFunctionWithName:name];
            if (function.functionType != MTLFunctionTypeKernel) continue;
            MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
            descriptor.computeFunction = function;
            descriptor.maxTotalThreadsPerThreadgroup = 968;
            id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithDescriptor:descriptor
                options:MTLPipelineOptionNone reflection:nil error:&error];
            if (!pipeline) { fprintf(stderr, "FAIL pipeline %s %s: %s\n", argv[1], name.UTF8String, error.description.UTF8String); return 1; }
            printf("PASS %s entry=%s staticThreadgroupMemoryLength=%lu maxThreadgroupMemoryLength=%lu\n",
                argv[1], name.UTF8String, (unsigned long)pipeline.staticThreadgroupMemoryLength,
                (unsigned long)device.maxThreadgroupMemoryLength);
            if (pipeline.staticThreadgroupMemoryLength > device.maxThreadgroupMemoryLength) return 1;
            kernels++;
        }
        if (!kernels) { fprintf(stderr, "FAIL no compute entry point\n"); return 1; }
        return 0;
    }
}
