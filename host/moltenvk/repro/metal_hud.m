/* STEAMAC-59/7K/7Q/9X/9Y: legacy Metal presentation alongside repeated KK
 * Metal 4 render/compute encoder switches. Test injected HUD visible or hidden,
 * and MTL_HUD_ENABLED=0 as a control. Opt-in window, not a headless suite test. */
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include "metal_hud_work.c"

static atomic_bool stop_work;
static atomic_bool hud_ever_loaded;

static void image_added(const struct mach_header *header, intptr_t slide)
{
	(void)slide;
	Dl_info info;
	if (dladdr(header, &info) && info.dli_fname && strstr(info.dli_fname, "/libMTLHud.dylib"))
		atomic_store(&hud_ever_loaded, true);
}

static void *run_kk(void *shader_path)
{
	encoder_work(shader_path, &stop_work);
	return NULL;
}

static bool hud_library_loaded(void)
{
	for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
		const char *path = _dyld_get_image_name(i);
		if (path && strstr(path, "/libMTLHud.dylib")) return true;
	}
	return false;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc != 2) { fprintf(stderr, "FAIL: shader path required\n"); return 2; }
		const bool hud = getenv("MTL_HUD_ENABLED") && !strcmp(getenv("MTL_HUD_ENABLED"), "1");
		const char *mode = getenv("METAL_HUD_MODE") ?: "default";
		if (strcmp(mode, "default") && strcmp(mode, "off")) return 2;
		_dyld_register_func_for_add_image(image_added);
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 960, 640)
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
			backing:NSBackingStoreBuffered defer:NO];
		window.title = @"STEAMAC-59/7K/7Q/9X/9Y — KK render/compute + Apple Metal HUD";
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
		if (pthread_create(&worker, NULL, run_kk, argv[1])) abort();
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
					if (hud) layer.developerHUDProperties = @{ @"mode": @(mode) };
					const bool loaded = hud_library_loaded();
					fprintf(stderr, "metal_hud: window=%ld visible=%d injected=%d library-loaded=%d HUD mode=%s\n",
						(long)window.windowNumber, window.visible, hud, loaded, hud ? mode : "not configured");
					if (loaded != hud) { fprintf(stderr, "FAIL: HUD injection disagrees with loaded library\n"); abort(); }
				}
				[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0/60.0]];
			}
		}
		atomic_store(&stop_work, true);
		pthread_join(worker, NULL);
		[queue release];
		[window close];
		const bool loaded = hud_library_loaded();
		const bool ever_loaded = atomic_load(&hud_ever_loaded);
		if (loaded != hud || ever_loaded != hud) {
			fprintf(stderr, "FAIL: HUD library state disagrees with injection during KK encoding\n"); abort();
		}
		fprintf(stderr, "OK metal_hud: 600 presented frames, injected=%d library-loaded=%d library-ever-loaded=%d mode=%s\n",
			hud, loaded, ever_loaded, mode);
	}
	return 0;
}
