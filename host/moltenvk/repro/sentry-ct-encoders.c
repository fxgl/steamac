/* STEAMAC-G/CT (1.9.15, M4 Pro 24 GB, Black Mesa's native Linux renderer through Zink):
 * "kk: it failed with OutOfMemory and had 30721 render passes, 961 compute encoders,
 * 30720 draws (30720 indirect) ... 1 Metal command buffers", 0.0 ms on the GPU, then
 * device loss. Metal 4 fails a command buffer with too many render encoders at commit
 * and nothing in it runs; vkQueueWaitIdle still succeeds. An M1 Max runs 36,864
 * clear-only render passes in one command buffer and fails at 38,912; 20,000 render
 * passes with 20,000 compute encoders between them run.
 *
 * One Vulkan command buffer: slot 0 = seed, then CHAIN times a clear-only render pass
 * (a render encoder) and a copy of slot i to slot i+1 (a compute encoder of its own),
 * each copy after a transfer barrier. Every slot holds the seed only if all of it ran
 * and every copy ran after the one before it, across every Metal command buffer the
 * recording is split into. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define CHAIN 40000u
#define SEED 0x5eed1234u

static uint32_t memory_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags flags)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	printf("FAIL no memory type\n");
	exit(1);
}

static void transfer_barrier(VkCommandBuffer cmd, VkAccessFlags dst, VkPipelineStageFlags dst_stage)
{
	VkMemoryBarrier b = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = dst };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, dst_stage, 0, 1, &b, 0, NULL, 0, NULL);
}

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "sentry-ct-encoders",
		.apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	VkPhysicalDevice pd;
	uint32_t n = 1;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
		.pQueuePriorities = &priority };
	VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = VK_TRUE, .synchronization2 = VK_TRUE };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	const VkDeviceSize size = (CHAIN + 1u) * sizeof(uint32_t);
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
		.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buffer;
	CK(vkCreateBuffer(dev, &bci, NULL, &buffer));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buffer, &mr);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memory_type(pd, mr.memoryTypeBits,
			VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	VkDeviceMemory bm;
	CK(vkAllocateMemory(dev, &ai, NULL, &bm));
	CK(vkBindBufferMemory(dev, buffer, bm, 0));
	uint32_t *mapped;
	CK(vkMapMemory(dev, bm, 0, VK_WHOLE_SIZE, 0, (void **)&mapped));
	memset(mapped, 0, size);

	VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { 16, 16, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
	VkImage image;
	CK(vkCreateImage(dev, &ii, NULL, &image));
	vkGetImageMemoryRequirements(dev, image, &mr);
	ai.allocationSize = mr.size;
	ai.memoryTypeIndex = memory_type(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	VkDeviceMemory im;
	CK(vkAllocateMemory(dev, &ai, NULL, &im));
	CK(vkBindImageMemory(dev, image, im, 0));
	VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = ii.format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &vi, NULL, &view));

	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &bi));
	vkCmdFillBuffer(cmd, buffer, 0, sizeof(uint32_t), SEED);
	VkImageMemoryBarrier ib = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.image = image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		0, 0, NULL, 0, NULL, 1, &ib);
	for (uint32_t i = 0; i < CHAIN; i++) {
		VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
			.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = VK_ATTACHMENT_STORE_OP_STORE, .clearValue.color.float32 = { 0, 0.5f, 1, 1 } };
		VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 16, 16 } },
			.layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
		vkCmdBeginRendering(cmd, &ri);
		vkCmdEndRendering(cmd);
		transfer_barrier(cmd, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		VkBufferCopy copy = { i * sizeof(uint32_t), (i + 1u) * sizeof(uint32_t), sizeof(uint32_t) };
		vkCmdCopyBuffer(cmd, buffer, buffer, 1, &copy);
	}
	transfer_barrier(cmd, VK_ACCESS_HOST_READ_BIT, VK_PIPELINE_STAGE_HOST_BIT);
	CK(vkEndCommandBuffer(cmd));

	VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CK(vkCreateFence(dev, &fci, NULL, &fence));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, fence));
	CK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));

	uint32_t first_bad = CHAIN + 1u;
	for (uint32_t i = 0; i <= CHAIN; i++) {
		if (mapped[i] != SEED) {
			first_bad = i;
			break;
		}
	}
	if (first_bad <= CHAIN) {
		printf("FAIL sentry-ct-encoders: slot %u of %u is 0x%08x, not the seed (%s)\n", first_bad, CHAIN,
			mapped[first_bad], first_bad == 0 ? "nothing ran" : "a copy ran before the one it reads");
		return 1;
	}
	printf("OK sentry-ct-encoders: %u render passes and %u copies in one command buffer ran in order\n",
		CHAIN, CHAIN);

	vkDestroyFence(dev, fence, NULL);
	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyImageView(dev, view, NULL);
	vkDestroyImage(dev, image, NULL);
	vkFreeMemory(dev, im, NULL);
	vkUnmapMemory(dev, bm);
	vkDestroyBuffer(dev, buffer, NULL);
	vkFreeMemory(dev, bm, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	return 0;
}
