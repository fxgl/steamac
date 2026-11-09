/* Included by metal_hud.m: keep one KK device alive while repeatedly switching
 * between Metal 4 render and compute encoders, as in STEAMAC-7Q/9X/9Y. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <vulkan/vulkan.h>
#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "FAIL %s = %d\n", #x, r_); abort(); } } while (0)

static void encoder_work(const char *shader_path, atomic_bool *stop)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "metal_hud",
		.apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	if (!n) abort();
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);
	fprintf(stderr, "metal_hud: Vulkan device=%s\n", props.deviceName);
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
		.pQueuePriorities = &priority };
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = VK_TRUE };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &v13, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	FILE *f = fopen(shader_path, "rb");
	if (!f || fseek(f, 0, SEEK_END)) abort();
	long bytes = ftell(f);
	if (bytes <= 0 || bytes % 4 || fseek(f, 0, SEEK_SET)) abort();
	uint32_t *code = malloc((size_t)bytes);
	if (!code || fread(code, 1, (size_t)bytes, f) != (size_t)bytes) abort();
	fclose(f);
	VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = (size_t)bytes, .pCode = code };
	VkShaderModule shader;
	CK(vkCreateShaderModule(dev, &smci, NULL, &shader));
	free(code);
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkComputePipelineCreateInfo pci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
			.module = shader, .pName = "main" }, .layout = layout };
	VkPipeline pipeline;
	CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &pci, NULL, &pipeline));

	VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { 16, 16, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
	VkImage image;
	CK(vkCreateImage(dev, &ii, NULL, &image));
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(dev, image, &req);
	uint32_t type = 0;
	while (!(req.memoryTypeBits & (1u << type))) type++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
		.memoryTypeIndex = type };
	VkDeviceMemory memory;
	CK(vkAllocateMemory(dev, &mai, NULL, &memory));
	CK(vkBindImageMemory(dev, image, memory, 0));
	VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = ii.format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &vi, NULL, &view));
	VkRenderingAttachmentInfo attachment = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE, .clearValue.color.float32 = { 0, 0.5f, 1, 1 } };
	VkRenderingInfo rendering = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 16, 16 } },
		.layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &attachment };
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	unsigned batches = 0;
	while (!atomic_load(stop)) {
		CK(vkResetCommandPool(dev, pool, 0));
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkBeginCommandBuffer(cmd, &bi));
		for (unsigned i = 0; i < 64; ++i) {
			VkImageMemoryBarrier barrier = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
				.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
				.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
				.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
				.image = image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
				VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
			vkCmdBeginRendering(cmd, &rendering);
			vkCmdEndRendering(cmd);
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
			vkCmdDispatch(cmd, 1, 1, 1);
		}
		CK(vkEndCommandBuffer(cmd));
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));
		batches++;
	}
	fprintf(stderr, "OK metal_hud: KK completed %u batches, %llu render + %llu compute encoders\n",
		batches, (unsigned long long)batches * 64, (unsigned long long)batches * 64);
	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyImageView(dev, view, NULL);
	vkDestroyImage(dev, image, NULL);
	vkFreeMemory(dev, memory, NULL);
	vkDestroyPipeline(dev, pipeline, NULL);
	vkDestroyPipelineLayout(dev, layout, NULL);
	vkDestroyShaderModule(dev, shader, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
}
