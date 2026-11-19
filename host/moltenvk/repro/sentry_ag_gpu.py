#!/usr/bin/env python3
"""Exercise the actual queue-error formatter with synthetic Metal error records.
No GPU fault/hang is induced. The normal launcher's MVK_CONFIG_LOG_LEVEL=1 must
not discard encoder status, debug signposts or shader validation messages.
"""
import pathlib
import subprocess
import sys

source = pathlib.Path(sys.argv[1]) / "MoltenVK/MoltenVK/GPUObjects/MVKQueue.mm"
work = pathlib.Path(sys.argv[2])
work.mkdir(parents=True, exist_ok=True)
text = source.read_text()


def function(signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


state = function("static const char* mvkStringFromMTLCommandEncoderErrorState")
if "static void mvkLogMetalCommandBufferDiagnostics" in text:
    formatter = function("static void mvkLogMetalCommandBufferDiagnostics")
else:
    # Baseline formatter was embedded in the queue callback; retain exactly its
    # diagnostic block and errors-only logging behavior for the before test.
    handler = function("void MVKQueue::handleMTLCommandBufferError")
    block = handler[handler.index("\tif (NSArray<id<MTLCommandBufferEncoderInfo>>*"):]
    formatter = "static void mvkLogMetalCommandBufferDiagnostics(id<MTLCommandBuffer> mtlCmdBuff) {\n" + block

fixture = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
// Equivalent to the old informational logger at the release errors-only level.
static void MVKLogInfo(const char* format, ...) {}
@interface TestEncoder : NSObject
@property(nonatomic, copy) NSString* label;
@property(nonatomic, copy) NSArray<NSString*>* debugSignposts;
@property(nonatomic) MTLCommandEncoderErrorState errorState;
@end
@implementation TestEncoder
@end
@interface TestBuffer : NSObject
@property(nonatomic, copy) NSString* label;
@property(nonatomic, retain) NSError* error;
@property(nonatomic, retain) NSArray* logs;
@property(nonatomic) double GPUStartTime;
@property(nonatomic) double GPUEndTime;
@end
@implementation TestBuffer
@end
'''
fixture += state + "\n" + formatter
fixture += r'''
int main() {
    @autoreleasepool {
        TestEncoder* faulted = [TestEncoder new];
        faulted.label = @"RDR2 synthetic render";
        faulted.errorState = MTLCommandEncoderErrorStateFaulted;
        faulted.debugSignposts = @[@"draw pipeline shader-hash-1234"];
        TestEncoder* completed = [TestEncoder new];
        completed.label = @"synthetic blit";
        completed.errorState = MTLCommandEncoderErrorStateCompleted;
        completed.debugSignposts = @[];
        TestBuffer* cb = [TestBuffer new];
        cb.label = @"vkQueueSubmit synthetic";
        cb.GPUStartTime = 1.25;
        cb.GPUEndTime = 2.5;
        cb.logs = @[@"shader validation message"];
        for (NSNumber* code in @[@(MTLCommandBufferErrorTimeout), @(MTLCommandBufferErrorPageFault), @(MTLCommandBufferErrorOutOfMemory)]) {
            cb.error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:code.integerValue
                userInfo:@{MTLCommandBufferEncoderInfoErrorKey: @[completed, faulted]}];
            mvkLogMetalCommandBufferDiagnostics((id<MTLCommandBuffer>)cb);
        }
        cb.error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:@{}];
        cb.logs = @[];
        mvkLogMetalCommandBufferDiagnostics((id<MTLCommandBuffer>)cb);
    }
}
'''
unit = work / "gpu_diagnostics.mm"
unit.write_text(fixture)
binary = work / "gpu_diagnostics"
subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-framework", "Foundation", "-framework", "Metal",
                str(unit), "-o", str(binary)], check=True)
result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
(work / "gpu_diagnostics.log").write_text(result.stderr)
for expected in ['Encoder "RDR2 synthetic render": faulted', 'Encoder "synthetic blit": completed',
                 'Signpost: draw pipeline shader-hash-1234', 'Shader log: shader validation message',
                 'GPU start=1.250000000 end=2.500000000', 'MVK_CONFIG_DEBUG=1', 'MVK_CONFIG_SHADER_DUMP_DIR']:
    if expected not in result.stderr:
        raise SystemExit("FAIL GPU diagnostics missing: " + expected)
for code in (2, 3, 8):
    if f"code={code} " not in result.stderr:
        raise SystemExit(f"FAIL GPU diagnostics missing Metal error code {code}")
print("OK sentry_ag GPU diagnostics: synthetic timeout/page-fault/OOM, status/signposts/shader logs at errors-only level")
