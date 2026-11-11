/* STEAMAC-AG / STEAMAC-G (RDR2): unsupported statistics must not become a
 * missing Venus object; 8192 timestamps exceed Metal's 4096-sample buffer;
 * Vulkan 1D images are Metal 2D by default, including CPU texture copies.
 * No validation layer: the statistics case intentionally violates VUID-00791
 * as RDR2 does, without claiming support for pipelineStatisticsQuery. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL %s (line %d)\n", #x, __LINE__); exit(1); } } while (0)
static VkInstance inst;
static VkPhysicalDevice pd;
static VkDevice dev;
static VkQueue queue;
static VkCommandPool cp;
static VkCommandBuffer cmd;
static VkPhysicalDeviceMemoryProperties mp;

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags flags)
{
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags) return i;
	REQUIRE(0 && "memory type");
	return 0;
}
static void setup(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	REQUIRE(n);
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
	const char *extensions[] = { VK_EXT_HOST_IMAGE_COPY_EXTENSION_NAME, VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME };
	VkPhysicalDeviceHostImageCopyFeaturesEXT host = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT, .hostImageCopy = VK_TRUE };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &host, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci, .enabledExtensionCount = 2, .ppEnabledExtensionNames = extensions };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	CK(vkCreateCommandPool(dev, &pci, NULL, &cp));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .commandBufferCount = 1 };
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
}
static void begin(void)
{
	CK(vkResetCommandBuffer(cmd, 0));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &bi));
}
static void submit(void)
{
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
}
static void host_barrier(void)
{
	VkMemoryBarrier b = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &b, 0, NULL, 0, NULL);
}
static VkBuffer buffer(VkDeviceSize size, VkDeviceMemory *mem, void **map)
{
	VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT };
	VkBuffer b;
	CK(vkCreateBuffer(dev, &ci, NULL, &b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, b, &mr);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memory_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	CK(vkAllocateMemory(dev, &ai, NULL, mem));
	CK(vkBindBufferMemory(dev, b, *mem, 0));
	CK(vkMapMemory(dev, *mem, 0, VK_WHOLE_SIZE, 0, map));
	memset(*map, 0xab, size);
	return b;
}
static void query_case(int statistics)
{
	VkPhysicalDeviceFeatures features;
	vkGetPhysicalDeviceFeatures(pd, &features);
	if (statistics) REQUIRE(!features.pipelineStatisticsQuery);
	VkQueryPoolCreateInfo ci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
		.queryType = statistics ? VK_QUERY_TYPE_PIPELINE_STATISTICS : VK_QUERY_TYPE_TIMESTAMP,
		.queryCount = statistics ? 8 : 8192, .pipelineStatistics = statistics ? 0x7ff : 0 };
	VkQueryPool pool;
	CK(vkCreateQueryPool(dev, &ci, NULL, &pool));
	VkDeviceMemory mem;
	uint64_t *out;
	VkBuffer b = buffer(4096, &mem, (void **)&out);
	const uint32_t ids[] = { 0, 4095, 4096, 8191 };
	uint32_t count = statistics ? 3 : 4;
	uint32_t lanes = statistics ? 11 : 1;
	for (unsigned round = 0; round < 2; round++) {
		begin();
		vkCmdResetQueryPool(cmd, pool, 0, ci.queryCount);
		for (uint32_t i = 0; i < count; i++) {
			uint32_t id = statistics ? i + 2 : ids[i];
			if (statistics) { vkCmdBeginQuery(cmd, pool, id, 0); vkCmdEndQuery(cmd, pool, id); }
			else vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, pool, id);
		}
		submit();
		/* Venus copies from a different command buffer, 64-bit + availability;
		 * also exercise 32-bit, packed direct copies and non-zero firstQuery. */
		begin();
		for (uint32_t i = 0; i < count; i++) {
			uint32_t id = statistics ? i + 2 : ids[i];
			vkCmdCopyQueryPoolResults(cmd, pool, id, 1, b, i * 128, 128,
				VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT);
			vkCmdCopyQueryPoolResults(cmd, pool, id, 1, b, 1024 + i * 64, 64,
				VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT);
		}
		if (statistics) {
			vkCmdCopyQueryPoolResults(cmd, pool, 2, 3, b, 2048, 88, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
		} else {
			/* Direct and compute resolves must split a range across sample buffers. */
			vkCmdCopyQueryPoolResults(cmd, pool, 4095, 2, b, 2048, 8, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
			vkCmdCopyQueryPoolResults(cmd, pool, 4095, 2, b, 2304, 16,
				VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT);
		}
		host_barrier();
		submit();
		for (uint32_t i = 0; i < count; i++) {
			uint64_t result[12];
			memset(result, 0xcd, sizeof(result));
			uint32_t id = statistics ? i + 2 : ids[i];
			CK(vkGetQueryPoolResults(dev, pool, id, 1, sizeof(result), result, sizeof(result),
				VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT));
			REQUIRE(result[lanes] == 1 && out[i * 16 + lanes] == 1);
			uint32_t *out32 = (uint32_t *)((uint8_t *)out + 1024 + i * 64);
			REQUIRE(out32[lanes] == 1);
			for (uint32_t lane = 0; lane < lanes; lane++) {
				REQUIRE(out[i * 16 + lane] == result[lane]);
				REQUIRE(out32[lane] == (uint32_t)result[lane]);
				if (statistics) REQUIRE(result[lane] == 0);
				else REQUIRE(result[lane] != 0);
			}
		}
		if (statistics) for (uint32_t i = 0; i < 33; i++) REQUIRE(out[256 + i] == 0);
		else {
			REQUIRE(out[256] == out[16] && out[257] == out[32]);
			REQUIRE(out[288] == out[16] && out[290] == out[32] && out[289] == 1 && out[291] == 1);
			uint64_t crossing[4];
			CK(vkGetQueryPoolResults(dev, pool, 4095, 2, sizeof(crossing), crossing, 16,
				VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT));
			REQUIRE(crossing[0] == out[16] && crossing[2] == out[32] && crossing[1] == 1 && crossing[3] == 1);
		}
		uint64_t unavailable[12];
		memset(unavailable, 0xef, sizeof(unavailable));
		REQUIRE(vkGetQueryPoolResults(dev, pool, 1, 1, sizeof(unavailable), unavailable, sizeof(unavailable),
			VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT) == VK_NOT_READY);
		REQUIRE(unavailable[0] == UINT64_C(0xefefefefefefefef) && unavailable[lanes] == 0);
	}
	vkDestroyQueryPool(dev, pool, NULL);
	vkDestroyBuffer(dev, b, NULL);
	vkFreeMemory(dev, mem, NULL);
}
static void image_case(const char *name)
{
	int linear = strstr(name, "linear") != NULL;
	int host = strstr(name, "host") != NULL;
	int imported = strstr(name, "import") != NULL;
	int array = strstr(name, "array") != NULL;
	int two = strstr(name, "2d") != NULL;
	int compressed = strstr(name, "bc1") != NULL;
	const uint32_t width = compressed ? 4 : 300, layers = array ? 3 : 1, height = compressed ? 64 : (two ? 3 : 1);
	const uint32_t rows = compressed ? (height + 3) / 4 : height;
	const uint32_t row_bytes = compressed ? 8 : width * 4;
	const uint32_t bytes = row_bytes * rows * layers;
	VkImageType type = (two || compressed) ? VK_IMAGE_TYPE_2D : VK_IMAGE_TYPE_1D;
	VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = type,
		.format = compressed ? VK_FORMAT_BC1_RGBA_UNORM_BLOCK : VK_FORMAT_R8G8B8A8_UNORM,
		.extent = { width, height, 1 }, .mipLevels = 1, .arrayLayers = layers, .samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = linear ? VK_IMAGE_TILING_LINEAR : VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
			((host || (!linear && !imported)) ? VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT : 0),
		.initialLayout = (host || (!linear && !imported)) ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_PREINITIALIZED };
	VkImageFormatProperties fp;
	CK(vkGetPhysicalDeviceImageFormatProperties(pd, ci.format, ci.imageType, ci.tiling, ci.usage, ci.flags, &fp));
	if (strstr(name, "volume")) {
		ci.imageType = VK_IMAGE_TYPE_3D;
		ci.extent = (VkExtent3D){ 4, 4, 4 };
		VkImageFormatProperties unsupported;
		REQUIRE(vkGetPhysicalDeviceImageFormatProperties(pd, ci.format, ci.imageType, ci.tiling, ci.usage, ci.flags, &unsupported)
			== VK_ERROR_FORMAT_NOT_SUPPORTED);
		VkImage rejected = VK_NULL_HANDLE;
		REQUIRE(vkCreateImage(dev, &ci, NULL, &rejected) == VK_ERROR_FEATURE_NOT_PRESENT);
		REQUIRE(rejected == VK_NULL_HANDLE);
		return;
	}
	VkExternalMemoryImageCreateInfo ext = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	if (imported) ci.pNext = &ext;
	VkImage image;
	CK(vkCreateImage(dev, &ci, NULL, &image));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, image, &mr);
	VkImportMemoryHostPointerInfoEXT imp = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, .handleType = ext.handleTypes };
	void *pointer = NULL;
	if (imported) {
		pointer = mmap(NULL, mr.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
		REQUIRE(pointer != MAP_FAILED);
		PFN_vkGetMemoryHostPointerPropertiesEXT gethp = (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(dev, "vkGetMemoryHostPointerPropertiesEXT");
		VkMemoryHostPointerPropertiesEXT hp = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
		CK(gethp(dev, imp.handleType, pointer, &hp));
		mr.memoryTypeBits &= hp.memoryTypeBits;
		imp.pHostPointer = pointer;
	}
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = imported ? &imp : NULL,
		.allocationSize = mr.size, .memoryTypeIndex = memory_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &ai, NULL, &mem));
	CK(vkBindImageMemory(dev, image, mem, 0));
	uint8_t pixels[300 * 3 * 3 * 4], output[300 * 3 * 3 * 4];
	REQUIRE(bytes <= sizeof(pixels));
	for (uint32_t i = 0; i < bytes; i++) pixels[i] = (uint8_t)(i * 123 + 17);
	if (host || (!linear && !imported)) {
		PFN_vkTransitionImageLayoutEXT transition = (PFN_vkTransitionImageLayoutEXT)vkGetDeviceProcAddr(dev, "vkTransitionImageLayoutEXT");
		VkHostImageLayoutTransitionInfoEXT t = { VK_STRUCTURE_TYPE_HOST_IMAGE_LAYOUT_TRANSITION_INFO_EXT,
			.image = image, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, layers } };
		CK(transition(dev, 1, &t));
		VkMemoryToImageCopyEXT r = { VK_STRUCTURE_TYPE_MEMORY_TO_IMAGE_COPY_EXT, .pHostPointer = pixels,
			.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, layers }, .imageExtent = { width, height, 1 } };
		VkCopyMemoryToImageInfoEXT copy = { VK_STRUCTURE_TYPE_COPY_MEMORY_TO_IMAGE_INFO_EXT,
			.dstImage = image, .dstImageLayout = VK_IMAGE_LAYOUT_GENERAL, .regionCount = 1, .pRegions = &r };
		PFN_vkCopyMemoryToImageEXT upload = (PFN_vkCopyMemoryToImageEXT)vkGetDeviceProcAddr(dev, "vkCopyMemoryToImageEXT");
		CK(upload(dev, &copy));
		if (!host) {
			// OPTIMAL's mapped layout is opaque. Do not invent a CPU row layout:
			// mapping/flushing without CPU writes must preserve the uploaded image.
			void *opaque;
			CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, &opaque));
			VkMappedMemoryRange range = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = mem, .size = VK_WHOLE_SIZE };
			CK(vkFlushMappedMemoryRanges(dev, 1, &range));
			CK(vkInvalidateMappedMemoryRanges(dev, 1, &range));
			vkUnmapMemory(dev, mem);
		}
		VkImageToMemoryCopyEXT rr = { VK_STRUCTURE_TYPE_IMAGE_TO_MEMORY_COPY_EXT, .pHostPointer = output,
			.imageSubresource = r.imageSubresource, .imageExtent = r.imageExtent };
		VkCopyImageToMemoryInfoEXT read = { VK_STRUCTURE_TYPE_COPY_IMAGE_TO_MEMORY_INFO_EXT,
			.srcImage = image, .srcImageLayout = VK_IMAGE_LAYOUT_GENERAL, .regionCount = 1, .pRegions = &rr };
		PFN_vkCopyImageToMemoryEXT download = (PFN_vkCopyImageToMemoryEXT)vkGetDeviceProcAddr(dev, "vkCopyImageToMemoryEXT");
		CK(download(dev, &read));
		REQUIRE(memcmp(pixels, output, bytes) == 0);
	} else {
		void *map;
		CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, &map));
		for (uint32_t layer = 0; layer < layers; layer++) {
			VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, layer };
			VkSubresourceLayout layout;
			vkGetImageSubresourceLayout(dev, image, &sub, &layout);
			for (uint32_t y = 0; y < rows; y++) memcpy((uint8_t *)map + layout.offset + y * layout.rowPitch,
				pixels + (layer * rows + y) * row_bytes, row_bytes);
		}
		VkMappedMemoryRange range = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = mem, .size = VK_WHOLE_SIZE };
		CK(vkFlushMappedMemoryRanges(dev, 1, &range));
		VkDeviceMemory rbmem;
		void *rbmap;
		VkBuffer rb = buffer(bytes, &rbmem, &rbmap);
		begin();
		VkImageMemoryBarrier barrier = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .oldLayout = VK_IMAGE_LAYOUT_PREINITIALIZED,
			.newLayout = VK_IMAGE_LAYOUT_GENERAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
			.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, layers } };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
		VkBufferImageCopy r = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, layers }, .imageExtent = { width, height, 1 } };
		vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_GENERAL, rb, 1, &r);
		host_barrier();
		submit();
		REQUIRE(memcmp(pixels, rbmap, bytes) == 0);
		/* Exercise getBytes as well as replaceRegion on mapped images. */
		CK(vkInvalidateMappedMemoryRanges(dev, 1, &range));
		for (uint32_t layer = 0; layer < layers; layer++) {
			VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, layer };
			VkSubresourceLayout layout;
			vkGetImageSubresourceLayout(dev, image, &sub, &layout);
			for (uint32_t y = 0; y < rows; y++) REQUIRE(memcmp((uint8_t *)map + layout.offset + y * layout.rowPitch,
				pixels + (layer * rows + y) * row_bytes, row_bytes) == 0);
		}
		vkDestroyBuffer(dev, rb, NULL);
		vkFreeMemory(dev, rbmem, NULL);
		vkUnmapMemory(dev, mem);
	}
	vkDestroyImage(dev, image, NULL);
	vkFreeMemory(dev, mem, NULL);
	if (pointer) munmap(pointer, mr.size);
}
int main(int argc, char **argv)
{
	if (argc == 2) {
		setup();
		if (!strcmp(argv[1], "statistics")) query_case(1);
		else if (!strcmp(argv[1], "timestamps")) query_case(0);
		else image_case(argv[1]);
		vkDestroyCommandPool(dev, cp, NULL);
		vkDestroyDevice(dev, NULL);
		vkDestroyInstance(inst, NULL);
		printf("OK sentry_ag %s\n", argv[1]);
		return 0;
	}
	const char *cases[] = { "statistics", "timestamps", "linear-1d", "linear-1d-import", "mapped-1d",
		"mapped-1d-import", "mapped-1d-array", "host-1d", "host-1d-array", "mapped-2d", "host-2d",
		"mapped-2d-import", "mapped-bc1", "mapped-bc1-import", "host-bc1", "linear-volume" };
	int failed = 0;
	for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		pid_t pid = fork();
		REQUIRE(pid >= 0);
		if (!pid) { execl(argv[0], argv[0], cases[i], (char *)NULL); _exit(127); }
		int status;
		REQUIRE(waitpid(pid, &status, 0) == pid);
		if (!WIFEXITED(status) || WEXITSTATUS(status)) { fprintf(stderr, "FAIL sentry_ag %s status 0x%x\n", cases[i], status); failed = 1; }
	}
	return failed;
}
