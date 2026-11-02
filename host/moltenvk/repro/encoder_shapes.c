/* KosmicKrisp logs each new render/copy encoder descriptor shape on Apple9+
 * (0073; MESA_KK_DEBUG=shapes on any GPU). Its direct-mapped 64-slot cache
 * evicted alternating shapes: Steam's UI renders eleven framebuffers a frame,
 * several shared a slot, and M3/M5 Macs logged every encoder of every frame
 * (~1800 lines/s; STEAMAC-74, STEAMAC-73).
 *
 * encoder_shapes <passes> <frames>: <passes> clears of 1-pixel-high images of
 * widths 1..<passes> (one shape each) per command buffer, <frames> command
 * buffers. run.sh counts the shape lines on stderr: they must not grow with
 * the frame count, and a thread logs at most 256 shapes. */
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "FAIL %s = %d\n", #x, r_); exit(1); } } while (0)

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <passes> <frames>\n", argv[0]);
		return 2;
	}
	const uint32_t passes = (uint32_t)atoi(argv[1]), frames = (uint32_t)atoi(argv[2]);

	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "encoder_shapes",
		.apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));

	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
		.pQueuePriorities = &prio };
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = VK_TRUE };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &v13, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkImage *images = calloc(passes, sizeof(*images));
	VkImageView *views = calloc(passes, sizeof(*views));
	VkDeviceMemory *mems = calloc(passes, sizeof(*mems));
	for (uint32_t i = 0; i < passes; i++) {
		VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
			.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { i + 1, 1, 1 }, .mipLevels = 1, .arrayLayers = 1,
			.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
			.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
		CK(vkCreateImage(dev, &ii, NULL, &images[i]));
		VkMemoryRequirements req;
		vkGetImageMemoryRequirements(dev, images[i], &req);
		uint32_t type = 0;
		while (!(req.memoryTypeBits & (1u << type)))
			type++;
		VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
			.memoryTypeIndex = type };
		CK(vkAllocateMemory(dev, &mai, NULL, &mems[i]));
		CK(vkBindImageMemory(dev, images[i], mems[i], 0));
		VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = images[i],
			.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = ii.format,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		CK(vkCreateImageView(dev, &vi, NULL, &views[i]));
	}

	VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CK(vkCreateFence(dev, &fci, NULL, &fence));

	for (uint32_t f = 0; f < frames; f++) {
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
			.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
		CK(vkBeginCommandBuffer(cmd, &bi));
		for (uint32_t i = 0; i < passes; i++) {
			VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
				.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
				.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
				.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
				.image = images[i], .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
				VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &b);
			VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = views[i],
				.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
				.storeOp = VK_ATTACHMENT_STORE_OP_STORE, .clearValue.color.float32 = { 0, 0.5f, 1, 1 } };
			VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { i + 1, 1 } },
				.layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
			vkCmdBeginRendering(cmd, &ri);
			vkCmdEndRendering(cmd);
		}
		CK(vkEndCommandBuffer(cmd));
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkQueueSubmit(queue, 1, &si, fence));
		CK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
		CK(vkResetFences(dev, 1, &fence));
	}

	vkDestroyFence(dev, fence, NULL);
	vkDestroyCommandPool(dev, pool, NULL);
	for (uint32_t i = 0; i < passes; i++) {
		vkDestroyImageView(dev, views[i], NULL);
		vkDestroyImage(dev, images[i], NULL);
		vkFreeMemory(dev, mems[i], NULL);
	}
	free(images);
	free(views);
	free(mems);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	printf("OK encoder_shapes passes=%u frames=%u\n", passes, frames);
	return 0;
}
