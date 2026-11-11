/* STEAMAC-AH: KosmicKrisp dereferenced a missing vertex shader at vkCmdBindPipeline
 * (kk_cmd_bind_shaders+128: ldr x8, [x26, #0xe8] with x26 = NULL, the vertex
 * kk_shader's depth/stencil state; the VM process faulted). KosmicKrisp exposes
 * neither graphics pipeline libraries nor shader objects, so the pipeline was
 * created from pStages without a vertex shader (VUID-VkGraphicsPipelineCreateInfo-
 * stage-02096): creation has to fail, and Venus then keeps a placeholder whose
 * draws virglrenderer drops.
 *
 *   control  vertex + fragment shader: the triangle covers the target in green
 *   missing  fragment shader only: creation must fail with a NULL pipeline; before
 *            the fix it succeeded and binding the pipeline faulted */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static const uint32_t vs_spv[] = {
#include "sentry_ah.vert.inc"
};
static const uint32_t fs_spv[] = {
#include "sentry_ah.frag.inc"
};

#define W 4
#define H 4

static VkDevice dev;
static VkPipelineLayout layout;
static const VkFormat color_format = VK_FORMAT_R8G8B8A8_UNORM;

static VkShaderModule module(const uint32_t *code, size_t size)
{
	VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = size, .pCode = code };
	VkShaderModule m;
	CK(vkCreateShaderModule(dev, &ci, NULL, &m));
	return m;
}

static VkResult pipeline(const VkPipelineShaderStageCreateInfo *stages, uint32_t count, VkPipeline *out)
{
	VkPipelineRenderingCreateInfo rendering = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = 1, .pColorAttachmentFormats = &color_format };
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport viewport = { 0, 0, W, H, 0, 1 };
	VkRect2D scissor = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState att = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &att };
	VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &rendering,
		.stageCount = count, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
		.pViewportState = &vp, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb,
		.layout = layout };
	*out = VK_NULL_HANDLE;
	return vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, out);
}

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }

	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13 };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	/* Render target and readback buffer */
	VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = color_format, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
	VkImage image;
	CK(vkCreateImage(dev, &imci, NULL, &image));
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
	VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = color_format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &ivci, NULL, &view));

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	const VkMemoryPropertyFlags hv = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	t = 0;
	while (!(mr.memoryTypeBits & (1u << t)) || (mp.memoryTypes[t].propertyFlags & hv) != hv) t++;
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = t;
	VkDeviceMemory buf_mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &buf_mem));
	CK(vkBindBufferMemory(dev, buf, buf_mem, 0));
	uint32_t *pixels;
	CK(vkMapMemory(dev, buf_mem, 0, VK_WHOLE_SIZE, 0, (void **)&pixels));

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));

	VkShaderModule vs = module(vs_spv, sizeof(vs_spv)), fs = module(fs_spv, sizeof(fs_spv));
	VkPipelineShaderStageCreateInfo stages[] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs,
		  .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs,
		  .pName = "main" },
	};

	/* control: vertex + fragment shader draw */
	VkPipeline complete;
	CK(pipeline(stages, 2, &complete));
	VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &begin));
	VkImageMemoryBarrier to_attachment = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
		.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
			     0, 0, NULL, 0, NULL, 1, &to_attachment);
	VkRenderingAttachmentInfo color = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE };
	VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } },
		.layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &color };
	vkCmdBeginRendering(cmd, &ri);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, complete);
	vkCmdDraw(cmd, 3, 1, 0, 0);
	vkCmdEndRendering(cmd);
	VkImageMemoryBarrier to_src = to_attachment;
	to_src.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
	to_src.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
	to_src.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	to_src.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
			     0, 0, NULL, 0, NULL, 1, &to_src);
	VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
		.imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &copy);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	for (uint32_t i = 0; i < W * H; i++) {
		if (pixels[i] != 0xff00ff00u) {
			printf("FAIL control: pixel %u = 0x%08x, expected 0xff00ff00\n", i, pixels[i]);
			return 1;
		}
	}
	printf("OK control: vertex + fragment shader pipeline draws the triangle\n");

	/* missing: fragment shader only */
	VkPipeline broken;
	VkResult r = pipeline(&stages[1], 1, &broken);
	if (r == VK_SUCCESS) {
		printf("FAIL missing: a graphics pipeline without a vertex shader was created; binding it:\n");
		fflush(stdout);
		CK(vkResetCommandBuffer(cmd, 0));
		CK(vkBeginCommandBuffer(cmd, &begin));
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, broken);
		CK(vkEndCommandBuffer(cmd));
		printf("FAIL missing: bound without a fault\n");
		return 1;
	}
	if (broken != VK_NULL_HANDLE) {
		printf("FAIL missing: creation returned %d with a non-NULL pipeline\n", r);
		return 1;
	}
	printf("OK missing: creation without a vertex shader failed (%d)\n", r);
	return 0;
}
