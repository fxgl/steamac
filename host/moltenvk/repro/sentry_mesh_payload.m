// STEAMAC-41/R: exact captured pipeline, using the tested translator's payload ABI.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 4) return 2;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        for (unsigned version = 0; version < 2; version++) {
            MTLCompileOptions *options = [MTLCompileOptions new];
            options.languageVersion = version ? MTLLanguageVersion4_0 : MTLLanguageVersion3_0;
            id<MTLFunction> functions[3];
            NSString *names[] = {@"MainVs", @"MainGs", @"MainPs"};
            for (unsigned stage = 0; stage < 3; stage++) {
                NSError *error = nil;
                NSString *source = [NSString stringWithContentsOfFile:@(argv[stage + 1])
                    encoding:NSUTF8StringEncoding error:&error];
                id<MTLLibrary> library = source ? [device newLibraryWithSource:source options:options error:&error] : nil;
                if (!library || !(functions[stage] = [library newFunctionWithName:names[stage]])) {
                    fprintf(stderr, "FAIL library %u: %s\n", stage, error.description.UTF8String);
                    return 1;
                }
            }
            for (unsigned samples = 1; samples <= 4; samples *= 4) {
                MTLMeshRenderPipelineDescriptor *descriptor = [MTLMeshRenderPipelineDescriptor new];
                descriptor.objectFunction = functions[0];
                descriptor.meshFunction = functions[1];
                descriptor.fragmentFunction = functions[2];
                descriptor.rasterSampleCount = samples;
                descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
                descriptor.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
                descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
                NSError *error = nil;
                id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithMeshDescriptor:descriptor
                    options:MTLPipelineOptionNone reflection:nil error:&error];
                if (!pipeline) {
                    fprintf(stderr, "FAIL captured pipeline: %s\n", error.description.UTF8String);
                    return 1;
                }
                printf("PASS: captured STEAMAC-41/R pipeline MSL %u, %ux MSAA (%s)\n",
                    version ? 4 : 3, samples, device.name.UTF8String);
            }
        }
    }
    return 0;
}
