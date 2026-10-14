/*
 * What vkd3d-proton can report to a D3D12 game on this driver, and why an RE Engine title refuses
 * the GPU. Dragon's Dogma 2 (appid 2054970, Proton 11, KosmicKrisp) fails at start with
 *
 *	Unsupported graphics card.
 *	Please read the system requirements for details.
 *	Virtio-GPU Venus (Apple M5 Max) is not supported AtomicInt64OnDescriptorHeapResourceSupported.
 *
 * The same dialog names the missing capability for other RE Engine titles; vkd3d-proton's own log
 * reports the feature level refusal first ("Feature level 0xc100 is not supported"; 0xc100 is
 * D3D_FEATURE_LEVEL_12_1), and with 12_1 forced the game fails on the capability above instead.
 *
 * The game's CheckFeatureSupport results are derived, in vkd3d-proton, from this device's Vulkan
 * features (libs/vkd3d/device.c):
 *
 *	max_feature_level = 12_0	if TiledResourcesTier >= 2 (the sparse checks below),
 *					ResourceBindingTier >= 2 (vkd3d-proton reports tier 3) and
 *					TypedUAVLoadAdditionalFormats
 *	max_feature_level = 12_1	if 12_0 and ROVsSupported (VK_EXT_fragment_shader_interlock:
 *					fragmentShaderPixelInterlock && fragmentShaderSampleInterlock)
 *					and ConservativeRasterizationTier >= 1
 *					(VK_EXT_conservative_rasterization)
 *	options9.AtomicInt64OnGroupSharedSupported	= shaderSharedInt64Atomics
 *	options9.AtomicInt64OnTypedResourceSupported	= shaderImageInt64Atomics
 *							  (VK_EXT_shader_image_atomic_int64)
 *							  && minStorageBufferOffsetAlignment <= 16
 *	options11.AtomicInt64OnDescriptorHeapResourceSupported
 *							= shaderBufferInt64Atomics
 *							  && minStorageBufferOffsetAlignment <= 16
 *	max_shader_model = 6_2		if the float-control denorm properties are usable
 *			   = 6_6		if 6_5, computeDerivativeGroupLinear
 *					  (VK_KHR_compute_shader_derivatives),
 *					  shaderBufferInt64Atomics and shaderInt8
 *
 * Two of those inputs cannot be provided on Apple GPUs. Metal has no 64-bit atomic that returns a
 * value: atomic_ulong exists, and the MSL compiler accepts the *void*
 * atomic_max_explicit/atomic_min_explicit on device atomic_ulong (measured on an M5 Max,
 * 2026-10-13), but it rejects 64-bit fetch forms, loads, stores, exchanges, compare-exchanges and
 * every 64-bit atomic in threadgroup memory — DD2's pipeline dies on "no matching function for call
 * to 'atomic_fetch_max_explicit'". SPIR-V's OpAtomic*Min/Max must return the original value, so the
 * void forms are not enough for an honest shaderBufferInt64Atomics, and MoltenVK hardcodes it false
 * as well. Emulation is not the way out either: lanes of an Apple SIMD group do not make independent
 * progress, so a 32-bit spinlock in a shader hangs the GPU (tried, 2026-10-13), and a lock-free one
 * would need the 64-bit compare-exchange Metal does not have. Metal also has no conservative
 * rasterization (no Metal API; the coverage behaviour D3D12's Tier 1 is defined by cannot be
 * emulated). So the AtomicInt64 fields and feature level 12_1 stay false, SM 6.6 is unreachable, and
 * a title that requires AtomicInt64OnDescriptorHeapResourceSupported (Dragon's Dogma 2) cannot run.
 * 12_1 additionally needs ROVs, which Metal could express with raster order groups but neither host
 * driver maps to VK_EXT_fragment_shader_interlock yet. Apple's own D3DMetal sidesteps all of this by
 * compiling to AIR instead of MSL (air.atomic.global.{min,max}.u.i64, and no stage restriction on
 * the SIMD-group intrinsics); that route is closed to a Vulkan driver that emits MSL.
 *
 * The 12_0 prerequisites are what the sparse binding/residency work buys, so they are checked here as
 * a regression guard: a driver that loses them drops below D3D12 feature level 12_0 and every DX12
 * game's device creation gets weaker. The rest is printed, because a missing capability that a game
 * requires is a limitation to report, not a failure of this driver.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkPhysicalDevice pd;
static VkPhysicalDeviceProperties props;
static VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
static VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
static int failures;

static void check(int ok, const char *what)
{
	printf("%s %s\n", ok ? "OK  " : "FAIL", what);
	if (!ok)
		failures++;
}

static int has_ext(const char *name)
{
	uint32_t n = 0, i;
	CK(vkEnumerateDeviceExtensionProperties(pd, NULL, &n, NULL));
	VkExtensionProperties *e = malloc(n * sizeof(*e));
	CK(vkEnumerateDeviceExtensionProperties(pd, NULL, &n, e));
	int found = 0;
	for (i = 0; i < n; i++)
		if (!strcmp(e[i].extensionName, name))
			found = 1;
	free(e);
	return found;
}

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	uint32_t n = 1;
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
	VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p12 };
	VkDeviceSize align;
	VkBool32 group_shared, typed, heap_atomics, rovs = VK_FALSE, tiled2;
	const VkPhysicalDeviceSparseProperties *sp;
	const char *denorm;
	int has_interlock, has_conservative, has_image_i64, has_derivatives;
#ifdef VK_EXT_shader_image_atomic_int64
	VkPhysicalDeviceShaderImageAtomicInt64FeaturesEXT image_i64 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_IMAGE_ATOMIC_INT64_FEATURES_EXT };
#endif
#ifdef VK_EXT_fragment_shader_interlock
	VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT interlock = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT };
#endif
#ifdef VK_KHR_compute_shader_derivatives
	VkPhysicalDeviceComputeShaderDerivativesFeaturesKHR derivatives = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_COMPUTE_SHADER_DERIVATIVES_FEATURES_KHR };
#endif

	CK(vkCreateInstance(&ici, NULL, &inst));
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	vkGetPhysicalDeviceProperties(pd, &props);

	has_interlock = has_ext("VK_EXT_fragment_shader_interlock");
	has_conservative = has_ext("VK_EXT_conservative_rasterization");
	has_image_i64 = has_ext("VK_EXT_shader_image_atomic_int64");
	has_derivatives = has_ext("VK_KHR_compute_shader_derivatives");

	f2.pNext = &v12;
#ifdef VK_EXT_shader_image_atomic_int64
	if (has_image_i64) { image_i64.pNext = f2.pNext; f2.pNext = &image_i64; }
#endif
#ifdef VK_EXT_fragment_shader_interlock
	if (has_interlock) { interlock.pNext = f2.pNext; f2.pNext = &interlock; }
#endif
#ifdef VK_KHR_compute_shader_derivatives
	if (has_derivatives) { derivatives.pNext = f2.pNext; f2.pNext = &derivatives; }
#endif
	vkGetPhysicalDeviceFeatures2(pd, &f2);
	vkGetPhysicalDeviceProperties2(pd, &p2);

	align = props.limits.minStorageBufferOffsetAlignment;
	sp = &props.sparseProperties;
	group_shared = v12.shaderSharedInt64Atomics;
	typed = VK_FALSE;
	heap_atomics = v12.shaderBufferInt64Atomics && align <= 16;
#ifdef VK_EXT_shader_image_atomic_int64
	typed = has_image_i64 && image_i64.shaderImageInt64Atomics && align <= 16;
#endif
#ifdef VK_EXT_fragment_shader_interlock
	rovs = has_interlock && interlock.fragmentShaderPixelInterlock && interlock.fragmentShaderSampleInterlock;
#endif
	/* vkd3d-proton's d3d12_device_determine_tiled_resources_tier(), tier >= 2 (a sparse queue
	 * family is required too, which this file cannot see). */
	tiled2 = f2.features.sparseBinding && f2.features.sparseResidencyAliased && f2.features.sparseResidencyBuffer &&
		f2.features.sparseResidencyImage2D && sp->residencyStandard2DBlockShape && f2.features.shaderResourceResidency &&
		f2.features.shaderResourceMinLod && !sp->residencyAlignedMipSize && sp->residencyNonResidentStrict &&
		p12.filterMinmaxSingleComponentFormats;
	/* vkd3d-proton's shader model ladder, from 6.0 up: 6.2 needs the denorm controls, 6.6 the
	 * compute derivatives, 64-bit buffer atomics and 8-bit integers. */
	if (p12.denormBehaviorIndependence == VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_NONE ||
	    !(p12.shaderDenormFlushToZeroFloat32 && p12.shaderDenormPreserveFloat32))
		denorm = "float controls (stops at SM 6.0)";
	else
		denorm = "SM 6.2";

	printf("     device %s, Vulkan %u.%u.%u, driver %s\n", props.deviceName, VK_VERSION_MAJOR(props.apiVersion),
	       VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion), p12.driverName);
	printf("     shaderInt64=%u shaderInt8=%u minStorageBufferOffsetAlignment=%u\n", f2.features.shaderInt64,
	       v12.shaderInt8, (unsigned)align);
	printf("     shaderBufferInt64Atomics=%u shaderSharedInt64Atomics=%u shaderImageInt64Atomics=%u%s\n",
	       v12.shaderBufferInt64Atomics, v12.shaderSharedInt64Atomics,
#ifdef VK_EXT_shader_image_atomic_int64
	       has_image_i64 ? image_i64.shaderImageInt64Atomics : VK_FALSE,
#else
	       VK_FALSE,
#endif
	       has_image_i64 ? "" : " (extension absent)");
	printf("     VK_EXT_fragment_shader_interlock=%s VK_EXT_conservative_rasterization=%s VK_KHR_compute_shader_derivatives=%s\n",
	       has_interlock ? "present" : "absent", has_conservative ? "present" : "absent", has_derivatives ? "present" : "absent");
	printf("     vkd3d-proton D3D12: AtomicInt64OnGroupShared=%u AtomicInt64OnTypedResource=%u AtomicInt64OnDescriptorHeapResource=%u\n",
	       group_shared, typed, heap_atomics);
	printf("     vkd3d-proton D3D12: TiledResourcesTier>=2=%u ROVs=%u ConservativeRasterizationTier>=1=%u -> feature level %s\n",
	       tiled2, rovs, has_conservative, (tiled2 && rovs && has_conservative) ? "12_1" : (tiled2 ? "12_0" : "below 12_0"));
	printf("     vkd3d-proton D3D12: shader model reaches %s, 6.6 needs compute derivatives + 64-bit buffer atomics\n", denorm);

	/* 64-bit integer types are the prerequisite of any 64-bit atomic emulation; every driver here has it. */
	check(f2.features.shaderInt64 != VK_FALSE, "shaderInt64 (64-bit types; without it 64-bit atomics cannot be emulated either)");
	/* KosmicKrisp carries the sparse work that buys Tiled Resources Tier 2 and with it feature level 12_0.
	 * MoltenVK has no sparse support, so it stays below 12_0 and is not checked here. (Match on the
	 * driver name: KosmicKrisp's VK_DRIVER_ID_MESA_KOSMICKRISP is not what the loader reports here.) */
	if (!strcmp(p12.driverName, "KosmicKrisp"))
		check(tiled2 != VK_FALSE, "KosmicKrisp: the sparse prerequisites of Tiled Resources Tier 2 (D3D12 feature level 12_0)");

	if (!heap_atomics)
		printf("INFO D3D12 feature level 12_1 and SM 6.6 are out of reach here and RE Engine titles that require\n"
		       "INFO AtomicInt64OnDescriptorHeapResourceSupported (Dragon's Dogma 2) refuse the GPU; see the file header.\n");

	vkDestroyInstance(inst, NULL);
	return failures ? 1 : 0;
}
