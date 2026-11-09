/* STEAMAC-9S/9T: deliberately invalid null buffer handles must not crash the
 * host. Each case runs in a fresh process without Vulkan validation. Valid
 * dense copies (nonzero bindings/offsets, multiple regions) and fully unbound
 * sparse-residency buffers are controls, not inputs to reject. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
	fprintf(stderr, "FAIL %s = %d\n", #x, r_); exit(1); } } while (0)
#define SIZE 1024u
static VkDevice dev;
static VkPhysicalDeviceMemoryProperties memory_props;

struct buffer {
	VkBuffer handle;
	VkDeviceMemory memory;
	void *map;
	VkDeviceSize offset;
	int coherent;
};

static struct buffer make_buffer(int sparse)
{
	struct buffer b = {0};
	VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
		.flags = sparse ? VK_BUFFER_CREATE_SPARSE_BINDING_BIT | VK_BUFFER_CREATE_SPARSE_RESIDENCY_BIT : 0,
		.size = sparse ? 65536 : SIZE,
		.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	CK(vkCreateBuffer(dev, &ci, NULL, &b.handle));
	if (sparse) return b;
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, b.handle, &req);
	uint32_t type;
	for (type = 0; type < memory_props.memoryTypeCount; type++)
		if ((req.memoryTypeBits & (1u << type)) &&
		    (memory_props.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) break;
	if (type == memory_props.memoryTypeCount) { fprintf(stderr, "FAIL no host memory\n"); exit(1); }
	b.coherent = !!(memory_props.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	b.offset = req.alignment;
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = b.offset + req.size, .memoryTypeIndex = type };
	CK(vkAllocateMemory(dev, &ai, NULL, &b.memory));
	CK(vkBindBufferMemory(dev, b.handle, b.memory, b.offset));
	CK(vkMapMemory(dev, b.memory, 0, VK_WHOLE_SIZE, 0, &b.map));
	return b;
}

static uint8_t *bytes(struct buffer *b) { return (uint8_t *)b->map + b->offset; }

static void sync_host(struct buffer *b, int invalidate)
{
	if (b->coherent) return;
	VkMappedMemoryRange range = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
		.memory = b->memory, .size = VK_WHOLE_SIZE };
	if (invalidate) CK(vkInvalidateMappedMemoryRanges(dev, 1, &range));
	else CK(vkFlushMappedMemoryRanges(dev, 1, &range));
}

static void destroy_buffer(struct buffer *b)
{
	if (b->map) vkUnmapMemory(dev, b->memory);
	vkDestroyBuffer(dev, b->handle, NULL);
	vkFreeMemory(dev, b->memory, NULL);
}

static void copy(VkCommandBuffer cmd, int legacy, VkBuffer src, VkBuffer dst,
                 uint32_t count, const VkBufferCopy2 *regions)
{
	if (legacy) {
		VkBufferCopy old[2];
		for (uint32_t i = 0; i < count; i++) old[i] = (VkBufferCopy) {
			regions[i].srcOffset, regions[i].dstOffset, regions[i].size };
		vkCmdCopyBuffer(cmd, src, dst, count, old);
	} else {
		VkCopyBufferInfo2 info = { VK_STRUCTURE_TYPE_COPY_BUFFER_INFO_2,
			.srcBuffer = src, .dstBuffer = dst, .regionCount = count, .pRegions = regions };
		vkCmdCopyBuffer2(cmd, &info);
	}
}

static void barrier(VkCommandBuffer cmd, VkPipelineStageFlags src_stage, VkAccessFlags src,
                    VkPipelineStageFlags dst_stage, VkAccessFlags dst)
{
	VkMemoryBarrier b = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = src, .dstAccessMask = dst };
	vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 1, &b, 0, NULL, 0, NULL);
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <legacy|copy2>-<null-src|null-dst|null-both|dense|sparse>\n", argv[0]); return 1; }
	const char *name = argv[1];
	const int legacy = strncmp(name, "legacy-", 7) == 0;
	const int invalid = strstr(name, "null-") != NULL;
	const int sparse = strstr(name, "sparse") != NULL;
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "copy_buffer_null",
		.apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CK(vkCreateInstance(&ici, NULL, &instance));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(instance, &n, &pd));
	if (!n) { fprintf(stderr, "FAIL no physical device\n"); return 1; }
	vkGetPhysicalDeviceMemoryProperties(pd, &memory_props);
	VkPhysicalDeviceFeatures features;
	vkGetPhysicalDeviceFeatures(pd, &features);
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);
	if (sparse && (!features.sparseBinding || !features.sparseResidencyBuffer || !props.sparseProperties.residencyNonResidentStrict)) {
		fprintf(stderr, "FAIL sparse strict residency not supported\n"); return 1;
	}
	uint32_t family_count = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &family_count, NULL);
	VkQueueFamilyProperties *families = calloc(family_count, sizeof(*families));
	if (!families) return 1;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &family_count, families);
	uint32_t family;
	for (family = 0; family < family_count; family++)
		if (families[family].queueFlags & VK_QUEUE_COMPUTE_BIT) break;
	free(families);
	if (family == family_count) { fprintf(stderr, "FAIL no compute queue\n"); return 1; }
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
	VkPhysicalDeviceFeatures enabled = { .sparseBinding = sparse, .sparseResidencyBuffer = sparse };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci, .pEnabledFeatures = &enabled };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, family, 0, &queue);
	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	struct buffer src = make_buffer(0), dst = make_buffer(0), reserved = {0};
	if (sparse) reserved = make_buffer(1);
	for (unsigned i = 0; i < SIZE; i++) bytes(&src)[i] = (uint8_t)(i * 37 + 11);
	memset(bytes(&dst), 0xa5, SIZE);
	sync_host(&src, 0);
	sync_host(&dst, 0);
	uint8_t expected[SIZE];
	memset(expected, 0xa5, sizeof(expected));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &bi));
	barrier(cmd, VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_WRITE_BIT,
		VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT);
	if (invalid) {
		VkBuffer s = src.handle, d = dst.handle;
		if (strstr(name, "null-src") || strstr(name, "null-both")) s = VK_NULL_HANDLE;
		if (strstr(name, "null-dst") || strstr(name, "null-both")) d = VK_NULL_HANDLE;
		VkBufferCopy2 region = { VK_STRUCTURE_TYPE_BUFFER_COPY_2, .srcOffset = 32, .dstOffset = 0, .size = 4 };
		for (unsigned i = 0; i < 1024; i++) copy(cmd, legacy, s, d, 1, &region);
	}
	/* A good copy after invalid input proves the recording path is still usable. */
	VkBufferCopy2 regions[2] = {
		{ VK_STRUCTURE_TYPE_BUFFER_COPY_2, .srcOffset = 32, .dstOffset = 64, .size = 96 },
		{ VK_STRUCTURE_TYPE_BUFFER_COPY_2, .srcOffset = 256, .dstOffset = 512, .size = 128 } };
	copy(cmd, legacy, src.handle, dst.handle, 2, regions);
	memcpy(expected + 64, bytes(&src) + 32, 96);
	memcpy(expected + 512, bytes(&src) + 256, 128);
	if (sparse) {
		VkBufferCopy2 region = { VK_STRUCTURE_TYPE_BUFFER_COPY_2, .srcOffset = 0, .dstOffset = 256, .size = 64 };
		copy(cmd, legacy, src.handle, reserved.handle, 1, &region);
		barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
			VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT);
		region.srcOffset = 256;
		region.dstOffset = 768;
		copy(cmd, legacy, reserved.handle, dst.handle, 1, &region);
		memset(expected + 768, 0, 64);
	}
	barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
		VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_READ_BIT);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	sync_host(&dst, 1);
	for (unsigned i = 0; i < SIZE; i++) if (bytes(&dst)[i] != expected[i]) {
		fprintf(stderr, "FAIL %s byte %u: %u != %u\n", name, i, bytes(&dst)[i], expected[i]); return 1;
	}
	vkDestroyCommandPool(dev, pool, NULL);
	if (sparse) destroy_buffer(&reserved);
	destroy_buffer(&dst);
	destroy_buffer(&src);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(instance, NULL);
	printf("OK %s: %s; all %u destination bytes checked\n", name,
		invalid ? "1024 invalid copies skipped, valid copy survived" : sparse ? "unmapped sparse reads zero/writes dropped" : "nonzero bindings and two regions copied", SIZE);
	return 0;
}
