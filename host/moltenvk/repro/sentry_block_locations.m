// Link separately translated stages, including block/standalone interface crossings.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: block-locations <vertex.metallib> <fragment.metallib>\n");
            return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "FAIL: no Metal device\n"); return 1; }
        NSError *error = nil;
        id<MTLLibrary> vertex = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
        if (!vertex) { fprintf(stderr, "FAIL: %s\n", error.description.UTF8String); return 1; }
        id<MTLLibrary> fragment = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[2])] error:&error];
        if (!fragment) { fprintf(stderr, "FAIL: %s\n", error.description.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [vertex newFunctionWithName:@"main0"];
        descriptor.fragmentFunction = [fragment newFunctionWithName:@"main0"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        if (!descriptor.vertexFunction || !descriptor.fragmentFunction) {
            fprintf(stderr, "FAIL: missing translated entry point\n"); return 1;
        }
        if (![device newRenderPipelineStateWithDescriptor:descriptor error:&error]) {
            fprintf(stderr, "FAIL: %s\n", error.description.UTF8String); return 1;
        }
        printf("PASS: linked %s + %s\n", argv[1], argv[2]);
    }
    return 0;
}
