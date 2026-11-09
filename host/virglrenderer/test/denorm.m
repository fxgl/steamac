/* STEAMAC-AC/AB/A0: measure the FP32 denormal behavior behind the SM 6.2 gate.
 * Uses KosmicKrisp's exact MTL4Compiler path and MSL 4.0 compile options
 * (kk_shader.c: MTLMathModeFast + MTLMathFloatingPointFunctionsFast), plus
 * safe/relaxed and precise controls. A measurement is NOT an API guarantee:
 * Metal Shading Language 4.1 section 8.1 permits input/output denormals to flush.
 * Build: xcrun clang -fobjc-arc -Wall -Wextra -Werror denorm.m -framework Metal -framework Foundation -o denorm
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const char source[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void denorm(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
    "  float sub = as_type<float>(in[0]);\n"
    "  float normal = as_type<float>(in[1]);\n"
    "  float two = as_type<float>(in[2]);\n"
    "  float next = as_type<float>(in[3]);\n"
    "  out[0] = as_type<uint>(sub);\n"
    "  out[1] = as_type<uint>(sub * two);\n"
    "  out[2] = as_type<uint>(normal / two);\n"
    "  out[3] = as_type<uint>(next - normal);\n"
    "}\n";

int main(int argc, char **argv)
{
    const int require_preserve = argc == 2 && !strcmp(argv[1], "--require-preserve");
    if (argc > 2 || (argc == 2 && !require_preserve)) {
        fprintf(stderr, "usage: %s [--require-preserve]\n", argv[0]);
        return 2;
    }
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "no Metal device\n");
            return 1;
        }
        NSError *error = nil;
        id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!compiler || !queue) {
            fprintf(stderr, "Metal initialization failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        const uint32_t input[] = {0x00400000, 0x00800000, 0x40000000, 0x00800001};
        const uint32_t preserved[] = {0x00400000, 0x00800000, 0x00400000, 0x00000001};
        id<MTLBuffer> in = [device newBufferWithBytes:input length:sizeof(input) options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [device newBufferWithLength:sizeof(preserved) options:MTLResourceStorageModeShared];
        if (!in || !out)
            return 1;
        const char *names[] = {"safe", "relaxed", "fast"};
        int all_preserved = 1;
        printf("device=%s; MTL4Compiler, MSL4.0; bits: copy, denorm-input multiply, denorm-output divide, normal subtract\n",
               device.name.UTF8String);
        for (unsigned mode = 0; mode < 3; mode++) {
            for (unsigned precise = 0; precise < 2; precise++) {
                MTLCompileOptions *options = [MTLCompileOptions new];
                options.languageVersion = MTLLanguageVersion4_0;
                options.mathMode = (MTLMathMode)mode;
                options.mathFloatingPointFunctions = (MTLMathFloatingPointFunctions)precise;
                MTL4LibraryDescriptor *library_desc = [MTL4LibraryDescriptor new];
                library_desc.source = [NSString stringWithUTF8String:source];
                library_desc.options = options;
                id<MTLLibrary> library = [compiler newLibraryWithDescriptor:library_desc error:&error];
                if (!library) {
                    fprintf(stderr, "library failed: %s\n", error.localizedDescription.UTF8String);
                    return 1;
                }
                MTL4LibraryFunctionDescriptor *function = [MTL4LibraryFunctionDescriptor new];
                function.name = @"denorm";
                function.library = library;
                MTL4ComputePipelineDescriptor *pipeline_desc = [MTL4ComputePipelineDescriptor new];
                pipeline_desc.computeFunctionDescriptor = function;
                pipeline_desc.maxTotalThreadsPerThreadgroup = 1;
                id<MTLComputePipelineState> pipeline = [compiler newComputePipelineStateWithDescriptor:pipeline_desc
                                                                                 compilerTaskOptions:nil error:&error];
                if (!pipeline) {
                    fprintf(stderr, "pipeline failed: %s\n", error.localizedDescription.UTF8String);
                    return 1;
                }
                memset(out.contents, 0xcd, out.length);
                id<MTLCommandBuffer> commands = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
                [encoder setComputePipelineState:pipeline];
                [encoder setBuffer:in offset:0 atIndex:0];
                [encoder setBuffer:out offset:0 atIndex:1];
                [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                [encoder endEncoding];
                [commands commit];
                [commands waitUntilCompleted];
                if (commands.status != MTLCommandBufferStatusCompleted) {
                    fprintf(stderr, "dispatch failed: %s\n", commands.error.localizedDescription.UTF8String);
                    return 1;
                }
                const uint32_t *bits = out.contents;
                const int preserve = !memcmp(bits, preserved, sizeof(preserved));
                all_preserved &= preserve;
                printf("math=%s functions=%s: %08x %08x %08x %08x preserve=%s%s\n", names[mode],
                       precise ? "precise" : "fast", bits[0], bits[1], bits[2], bits[3], preserve ? "yes" : "NO",
                       mode == MTLMathModeFast && !precise ? " (KosmicKrisp default)" : "");
                if (bits[0] != input[0]) {
                    fprintf(stderr, "denormal bit transport failed\n");
                    return 1;
                }
            }
        }
        printf("preserve reference: %08x %08x %08x %08x\n", preserved[0], preserved[1], preserved[2], preserved[3]);
        return require_preserve && !all_preserved ? 1 : 0;
    }
}
