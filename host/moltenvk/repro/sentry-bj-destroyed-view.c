/* STEAMAC-BJ/BK: KosmicKrisp faulted in transition_attachment+60 (ldr w8, [x8, #0x48]
 * with x8 = image_view->image = NULL) under vkCmdBeginRenderPass from DOOM (2016) on
 * the vkr ring thread. The attachment's view pointer was set; libmalloc clears freed
 * blocks, so the framebuffer named an image view destroyed before the render pass.
 *
 *   live       render pass with a live view: clears the 4x4 target to green, no log
 *   destroyed  the view is destroyed, then the render pass begins: KosmicKrisp 0100
 *              logs "not alive" naming the attachment before Mesa's common code
 *              dereferences the view (the same fault as the report follows; run.sh
 *              runs this case last and checks the log line, not the exit status) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define W 4
#define H 4

int main(int argc, char **argv)
{
	const int destroyed = argc > 1 && !strcmp(argv[1], "destroyed");
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
	VkImage image;
	CK(vkCreateImage(dev, &ii, NULL, &image));
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, image, &mr);
	uint32_t t = 0;
	while (!(mr.memoryTypeBits & (1u << t))) t++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory image_mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &image_mem));
	CK(vkBindImageMemory(dev, image, image_mem, 0));

	VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bi, NULL, &buf));
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	const VkMemoryPropertyFlags hv = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	t = 0;
	while (!(mr.memoryTypeBits & (1u << t)) || (mp.memoryTypes[t].propertyFlags & hv) != hv) t++;
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = t;
	VkDeviceMemory buf_mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &buf_mem));
	CK(vkBindBufferMemory(dev, buf, buf_mem, 0));

	VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &vci, NULL, &view));

	/* UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL: the begin transitions the attachment */
	VkAttachmentDescription att = { .format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
	VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = 1, .pColorAttachments = &ref };
	VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1,
		.pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
	VkRenderPass pass;
	CK(vkCreateRenderPass(dev, &rpci, NULL, &pass));
	VkFramebufferCreateInfo fci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass,
		.attachmentCount = 1, .pAttachments = &view, .width = W, .height = H, .layers = 1 };
	VkFramebuffer fb;
	CK(vkCreateFramebuffer(dev, &fci, NULL, &fb));

	if (destroyed) {
		/* Invalid use, as in the report: the framebuffer outlives its view */
		vkDestroyImageView(dev, view, NULL);
		fprintf(stderr, "destroyed: beginning the render pass\n");
	}

	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool cpool;
	CK(vkCreateCommandPool(dev, &pci, NULL, &cpool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo cbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &cbi));
	VkClearValue clear = { .color = { .float32 = { 0, 1, 0, 1 } } };
	VkRenderPassBeginInfo rbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = pass, .framebuffer = fb,
		.renderArea = { { 0, 0 }, { W, H } }, .clearValueCount = 1, .pClearValues = &clear };
	vkCmdBeginRenderPass(cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
	if (destroyed) {
		printf("destroyed: the render pass began without faulting\n");
		return 0;
	}
	vkCmdEndRenderPass(cmd);
	VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &copy);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	uint32_t *px;
	CK(vkMapMemory(dev, buf_mem, 0, W * H * 4, 0, (void **)&px));
	for (unsigned i = 0; i < W * H; i++) {
		if (px[i] != 0xff00ff00) { printf("FAIL live: pixel %u = %08x, expected ff00ff00\n", i, px[i]); return 1; }
	}
	printf("OK live: %u green pixels through a render pass with a live view\n", W * H);
	return 0;
}
