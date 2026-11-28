/* STEAMAC-5/D3/D4 (1.9.15, M1 Max, macOS 15.6.1, appid 949230): the VM process crashed inside
 * AGX while MoltenVK encoded copyFromTexture:...toBuffer: for a vkCmdCopyImageToBuffer; nothing
 * said what was copied. MoltenVK 0060 logs every distinct copy shape once ("[mvk-copy] shape")
 * and does not encode a copy out of range of its Metal objects ("[mvk-copy] buffer span past
 * the Metal buffer").
 *
 *   valid  a 128x128 RGBA8 image cleared to (1, 2, 3, 4) read back into a 64 KiB buffer
 *   short  the same copy into a 4 KiB buffer (invalid usage): Metal API validation aborted
 *          the process before; now it is logged and skipped, the queue still works */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define SIZE 128u

static VkPhysicalDevice pd;
static VkDevice dev;

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags flags)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	printf("FAIL no memory type\n");
	exit(1);
}

static VkBuffer host_buffer(VkDeviceSize size, VkDeviceMemory *memory, uint8_t **mapped)
{
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buffer;
	CK(vkCreateBuffer(dev, &bci, NULL, &buffer));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buffer, &mr);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memory_type(mr.memoryTypeBits,
			VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	CK(vkAllocateMemory(dev, &ai, NULL, memory));
	CK(vkBindBufferMemory(dev, buffer, *memory, 0));
	CK(vkMapMemory(dev, *memory, 0, VK_WHOLE_SIZE, 0, (void **)mapped));
	memset(*mapped, 0xee, size);
	return buffer;
}

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "sentry-5-copy-range",
		.apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
		.pQueuePriorities = &priority };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UINT, .extent = { SIZE, SIZE, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT };
	VkImage image;
	CK(vkCreateImage(dev, &ii, NULL, &image));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, image, &mr);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memory_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
	VkDeviceMemory im;
	CK(vkAllocateMemory(dev, &ai, NULL, &im));
	CK(vkBindImageMemory(dev, image, im, 0));

	VkDeviceMemory full_memory, short_memory;
	uint8_t *full, *shortened;
	VkBuffer full_buffer = host_buffer(SIZE * SIZE * 4u, &full_memory, &full);
	VkBuffer short_buffer = host_buffer(4096, &short_memory, &shortened);

	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));

	for (int pass = 0; pass < 2; pass++) {
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkBeginCommandBuffer(cmd, &bi));
		VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
		VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
			.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
			.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
			.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image, .subresourceRange = range };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
			0, NULL, 0, NULL, 1, &b);
		VkClearColorValue color = { .uint32 = { 1, 2, 3, 4 } };
		vkCmdClearColorImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
		b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
		b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
			0, NULL, 0, NULL, 1, &b);
		VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
			.imageExtent = { SIZE, SIZE, 1 } };
		vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			pass == 0 ? full_buffer : short_buffer, 1, &region);
		VkMemoryBarrier host = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host,
			0, NULL, 0, NULL);
		CK(vkEndCommandBuffer(cmd));
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));
		CK(vkResetCommandBuffer(cmd, 0));
		if (pass == 0) {
			for (uint32_t i = 0; i < SIZE * SIZE * 4u; i++) {
				if (full[i] != (uint8_t)(i % 4u + 1u)) {
					printf("FAIL valid readback byte %u = %u\n", i, full[i]);
					return 1;
				}
			}
			printf("OK valid: 128x128 readback matches the clear color\n");
		} else {
			printf("OK short: the out-of-range copy did not abort; the queue completed\n");
		}
	}

	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyBuffer(dev, full_buffer, NULL);
	vkDestroyBuffer(dev, short_buffer, NULL);
	vkFreeMemory(dev, full_memory, NULL);
	vkFreeMemory(dev, short_memory, NULL);
	vkDestroyImage(dev, image, NULL);
	vkFreeMemory(dev, im, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	return 0;
}
