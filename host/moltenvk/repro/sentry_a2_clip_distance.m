// STEAMAC-A2: link translated vertex/object, geometry/mesh, and fragment stages.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 4) return 2;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        for (unsigned version = 0; version < 2; ++version) {
            MTLCompileOptions *options = [MTLCompileOptions new];
            options.languageVersion = version ? MTLLanguageVersion4_0 : MTLLanguageVersion3_0;
            id<MTLFunction> functions[3];
            for (unsigned stage = 0; stage < 3; ++stage) {
                NSError *error = nil;
                NSString *source = [NSString stringWithContentsOfFile:@(argv[stage + 1])
                    encoding:NSUTF8StringEncoding error:&error];
                id<MTLLibrary> library = source ? [device newLibraryWithSource:source options:options error:&error] : nil;
                functions[stage] = library ? [library newFunctionWithName:@"main0"] : nil;
                if (!functions[stage]) {
                    fprintf(stderr, "FAIL MSL %u stage %u (%s): %s\n", version ? 4 : 3,
                        stage, argv[stage + 1], error.description.UTF8String);
                    return 1;
                }
            }
            MTLMeshRenderPipelineDescriptor *descriptor = [MTLMeshRenderPipelineDescriptor new];
            descriptor.objectFunction = functions[0];
            descriptor.meshFunction = functions[1];
            descriptor.fragmentFunction = functions[2];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            NSError *error = nil;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithMeshDescriptor:descriptor
                options:MTLPipelineOptionNone reflection:nil error:&error];
            if (!pipeline) {
                fprintf(stderr, "FAIL A2 mesh/fragment link (%s): %s\n", argv[2], error.description.UTF8String);
                return 1;
            }
            printf("PASS: A2 mesh/fragment link MSL %u (%s)\n", version ? 4 : 3, device.name.UTF8String);
        }
    }
    return 0;
}
