/* STEAMAC-3F/6Y: Metal aborts on buffer-backed textures with seven mip levels.
 * Queries already limit LINEAR to one level/layer/sample, but vkCreateImage
 * accepted descriptors violating those limits. Invalid cases intentionally run
 * without Vulkan validation, in separate processes, and bind if creation was
 * wrongly accepted so the old driver reaches the original Metal assertion.
 * Optimal seven-mip host imports must still use the tiled private-heap path. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "FAIL %s = %d\n", #x, r_); exit(1); } } while (0)

static int run_case(const char *name)
{
	const int invalid = strncmp(name, "invalid-", 8) == 0;
	const int imported = strstr(name, "import") != NULL;
	const int optimal = strstr(name, "optimal") != NULL;
	const int input = strstr(name, "input") != NULL;
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CK(vkCreateInstance(&ici, NULL, &instance));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(instance, &n, &pd));
	if (!n) { fprintf(stderr, "FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceExternalMemoryHostPropertiesEXT host = {
		VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT };
	VkPhysicalDeviceProperties2 properties = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &host };
	vkGetPhysicalDeviceProperties2(pd, &properties);
	const char *extensions[] = { VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME };
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = extensions };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkExternalMemoryImageCreateInfo external = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.pNext = imported ? &external : NULL,
		.imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
		.extent = { 64, 64, 1 }, .mipLevels = strstr(name, "mips") ? 7 : 1,
		.arrayLayers = strstr(name, "array") ? 2 : 1,
		.samples = strstr(name, "msaa") ? VK_SAMPLE_COUNT_4_BIT : VK_SAMPLE_COUNT_1_BIT,
		.tiling = optimal ? VK_IMAGE_TILING_OPTIMAL : VK_IMAGE_TILING_LINEAR,
		.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT };
	if (input) ci.usage |= VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
	if (strstr(name, "volume")) { ci.imageType = VK_IMAGE_TYPE_3D; ci.extent.depth = 4; }

	/* Check both entry points, including the external-memory query Venus uses.
	 * Query a supported 2D shape even for the deliberately invalid 3D case. */
	VkImageFormatProperties legacy;
	CK(vkGetPhysicalDeviceImageFormatProperties(pd, ci.format, VK_IMAGE_TYPE_2D,
		ci.tiling, ci.usage, ci.flags, &legacy));
	VkPhysicalDeviceExternalImageFormatInfo ext_query = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
		.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	VkPhysicalDeviceImageFormatInfo2 query = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
		.pNext = imported ? &ext_query : NULL, .format = ci.format, .type = VK_IMAGE_TYPE_2D,
		.tiling = ci.tiling, .usage = ci.usage, .flags = ci.flags };
	VkExternalImageFormatProperties ext_props = { VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES };
	VkImageFormatProperties2 props = { VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, .pNext = &ext_props };
	CK(vkGetPhysicalDeviceImageFormatProperties2(pd, &query, &props));
	if ((!optimal && (legacy.maxMipLevels != 1 || props.imageFormatProperties.maxMipLevels != 1 ||
		legacy.maxArrayLayers != 1 || props.imageFormatProperties.maxArrayLayers != 1 ||
		legacy.sampleCounts != VK_SAMPLE_COUNT_1_BIT || props.imageFormatProperties.sampleCounts != VK_SAMPLE_COUNT_1_BIT)) ||
	    (optimal && (legacy.maxMipLevels < 7 || props.imageFormatProperties.maxMipLevels < 7)) ||
	    (imported && !(ext_props.externalMemoryProperties.externalMemoryFeatures & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT))) {
		fprintf(stderr, "FAIL %s: inconsistent image format limits/import support\n", name);
		return 1;
	}
	fprintf(stderr, "linear_images: %s (query mips=%u layers=%u samples=0x%x)\n", name,
		props.imageFormatProperties.maxMipLevels, props.imageFormatProperties.maxArrayLayers,
		props.imageFormatProperties.sampleCounts);
	VkImage image = VK_NULL_HANDLE;
	VkResult result = vkCreateImage(dev, &ci, NULL, &image);
	if (invalid && result == VK_ERROR_FORMAT_NOT_SUPPORTED) {
		vkDestroyDevice(dev, NULL);
		vkDestroyInstance(instance, NULL);
		printf("OK linear_images %s: rejected before Metal\n", name);
		return 0;
	}
	if (result != VK_SUCCESS) {
		fprintf(stderr, "FAIL %s: vkCreateImage = %d\n", name, result);
		return 1;
	}
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(dev, image, &req);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size };
	VkImportMemoryHostPointerInfoEXT import = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
		.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	void *pointer = NULL;
	if (imported) {
		VkDeviceSize alignment = host.minImportedHostPointerAlignment;
		if (alignment < 16384) alignment = 16384;
		ai.allocationSize = (req.size + alignment - 1) / alignment * alignment;
		pointer = mmap(NULL, ai.allocationSize, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
		if (pointer == MAP_FAILED) { perror("mmap"); return 1; }
		PFN_vkGetMemoryHostPointerPropertiesEXT get_host =
			(PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(dev, "vkGetMemoryHostPointerPropertiesEXT");
		if (!get_host) { fprintf(stderr, "FAIL no host pointer query\n"); return 1; }
		VkMemoryHostPointerPropertiesEXT hp = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
		CK(get_host(dev, import.handleType, pointer, &hp));
		req.memoryTypeBits &= hp.memoryTypeBits;
		import.pHostPointer = pointer;
		ai.pNext = &import;
	}
	if (!req.memoryTypeBits) { fprintf(stderr, "FAIL no compatible memory\n"); return 1; }
	while (!(req.memoryTypeBits & (1u << ai.memoryTypeIndex))) ai.memoryTypeIndex++;
	VkDeviceMemory memory;
	CK(vkAllocateMemory(dev, &ai, NULL, &memory));
	/* Before 0075 invalid-mips-linear[-import] aborts here with
	 * 'Linear texture: cannot be mipmapped, mipmapLevelCount (7) disallowed'. */
	CK(vkBindImageMemory(dev, image, memory, 0));
	VkImageView view = VK_NULL_HANDLE;
	if (!invalid) {
		VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
			.viewType = input ? VK_IMAGE_VIEW_TYPE_2D_ARRAY : VK_IMAGE_VIEW_TYPE_2D, .format = ci.format,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, ci.mipLevels - 1, 1, 0, 1 } };
		CK(vkCreateImageView(dev, &vi, NULL, &view));
		vkDestroyImageView(dev, view, NULL);
	}
	vkDestroyImage(dev, image, NULL);
	vkFreeMemory(dev, memory, NULL);
	if (pointer) munmap(pointer, ai.allocationSize);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(instance, NULL);
	if (invalid) { fprintf(stderr, "FAIL %s: unsupported descriptor accepted\n", name); return 1; }
	printf("OK linear_images %s: bound and viewed mip %u\n", name, ci.mipLevels - 1);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 2) return run_case(argv[1]);
	const char *cases[] = { "invalid-mips-linear", "invalid-mips-linear-import", "invalid-array-linear",
		"invalid-volume-linear", "invalid-msaa-linear", "valid-linear", "valid-linear-input-import",
		"valid-optimal-mips", "valid-optimal-mips-import" };
	int failed = 0;
	for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		pid_t child = fork();
		if (child == -1) { perror("fork"); return 1; }
		if (!child) { execl(argv[0], argv[0], cases[i], (char *)NULL); perror("execl"); _exit(1); }
		int status;
		if (waitpid(child, &status, 0) == -1) { perror("waitpid"); return 1; }
		if (!WIFEXITED(status) || WEXITSTATUS(status)) {
			fprintf(stderr, "FAIL linear_images %s: child status 0x%x\n", cases[i], status);
			failed = 1;
		}
	}
	return failed;
}
