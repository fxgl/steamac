/* STEAMAC-59/7K: the launcher presents with a legacy Metal queue while KK
 * records Metal4 workloads in the same process. Exercise both with Apple's
 * HUD visible; this is an opt-in windowed probe, not a headless suite test. */
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <stdatomic.h>
#define main kk_diagnostics_main
#include "metal_diagnostics.c"
#undef main

static atomic_bool stop_work;
static void *run_kk(void *unused)
{
	(void)unused;
	unsigned rounds = 0;
	while (!atomic_load(&stop_work)) {
		if (kk_diagnostics_main()) abort();
		rounds++;
	}
	fprintf(stderr, "OK metal_hud: KK completed %u rounds alongside visible HUD\n", rounds);
	return NULL;
}

int main(void)
{
	@autoreleasepool {
		if (!getenv("MTL_HUD_ENABLED") || strcmp(getenv("MTL_HUD_ENABLED"), "1")) {
			fprintf(stderr, "FAIL: run with MTL_HUD_ENABLED=1 before Metal loads\n"); return 2;
		}
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 960, 640)
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
			backing:NSBackingStoreBuffered defer:NO];
		window.title = @"STEAMAC-59/7K — KK + visible Apple Metal HUD";
		window.contentView.wantsLayer = YES;
		CAMetalLayer *layer = [CAMetalLayer layer];
		layer.device = MTLCreateSystemDefaultDevice();
		layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		layer.framebufferOnly = YES;
		layer.drawableSize = CGSizeMake(960, 640);
		layer.frame = window.contentView.bounds;
		window.contentView.layer = layer;
		[window makeKeyAndOrderFront:nil];
		[NSApp finishLaunching];
		[NSApp activateIgnoringOtherApps:YES];
		id<MTLCommandQueue> queue = [layer.device newCommandQueue];
		pthread_t worker;
		if (pthread_create(&worker, NULL, run_kk, NULL)) abort();
		for (unsigned f = 0; f < 600; ++f) {
			@autoreleasepool {
				NSEvent *event;
				while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil
					inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				if (!drawable) { fprintf(stderr, "FAIL: no visible drawable\n"); abort(); }
				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = drawable.texture;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, (f % 120) / 240.0, 0.3, 1);
				id<MTLCommandBuffer> cmd = [queue commandBuffer];
				[[cmd renderCommandEncoderWithDescriptor:pass] endEncoding];
				[cmd presentDrawable:drawable];
				[cmd commit];
				[cmd waitUntilCompleted];
				if (cmd.error) { fprintf(stderr, "FAIL: present %s\n", cmd.error.description.UTF8String); abort(); }
				if (f == 1) {
					layer.developerHUDProperties = @{ @"mode": @"default" };
					fprintf(stderr, "metal_hud: window=%ld visible=%d HUD mode=%s\n",
						(long)window.windowNumber, window.visible,
						[[layer.developerHUDProperties objectForKey:@"mode"] UTF8String]);
				}
				[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0/60.0]];
			}
		}
		atomic_store(&stop_work, true);
		pthread_join(worker, NULL);
		[queue release];
		[window close];
		fprintf(stderr, "OK metal_hud: 600 presented frames with HUD mode=default\n");
	}
	return 0;
}
