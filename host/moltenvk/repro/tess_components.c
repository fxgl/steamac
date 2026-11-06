/*
 * Vertex outputs packed by component under tessellation (steamac #49). dxil-spirv declares each output
 * signature element as its own variable: Ratchet & Clank: Rift Apart's tessellation vertex shaders have
 * POSITION (float3, location 0 components 0-2) next to TEXCOORD (float, component 3) and write POSITION one
 * component at a time. With tessellation MoltenVK runs the vertex stage as a compute kernel capturing its
 * outputs to a buffer. SPIRV-Cross 0042 already fixes the address space of component stores, so the pipeline
 * compiles, but the vertex stage packs both variables into a 16-byte float4 while the control stage reads
 * float3 POSITION and float TEXCOORD as separate members (32 bytes). Their strides disagree: patches take
 * control points from the wrong vertices and draw nothing.
 *
 * shaders/tess_components/: tc.vert writes a viewport-covering triangle into POSITION by component and
 * TEXCOORD = 0.25; tc.tesc/tc.tese pass both through (tessellation level 1). A second pipeline substitutes
 * tc_position.tesc, which reads only POSITION and supplies the same constant TEXCOORD: unused components
 * must still pad its input to the vertex output stride. tc.frag writes (TEXCOORD, 0.5, depth, 1).
 * Every pixel of each 16x16 RGBA8 target must hold (64, 128, 128, 255).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define W 16u
#define H 16u

static VkDevice dev;

static VkShaderModule module(const char *dir, const char *name)
{
	char path[1024];
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) { printf("FAIL open %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint32_t *code = malloc(n);
	if (fread(code, 1, n, f) != (size_t)n) { printf("FAIL read %s\n", path); exit(1); }
	fclose(f);
	VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = n, .pCode = code };
	VkShaderModule m;
	CK(vkCreateShaderModule(dev, &ci, NULL, &m));
	free(code);
	return m;
}

static uint32_t memory_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t t = 0; t < mp.memoryTypeCount; t++)
		if ((bits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & want) == want)
			return t;
	printf("FAIL no memory type for bits 0x%x flags 0x%x\n", bits, want);
	exit(1);
}

static int run_pipeline(const char *dir, const char *tesc, VkQueue queue, VkFormat cf,
                        VkImage img, VkImageView view, VkBuffer buf, uint8_t *px)
{
	/* tessellation pipeline */
	const char *names[4] = { "tc.vert.spv", tesc, "tc.tese.spv", "tc.frag.spv" };
	const VkShaderStageFlagBits stages[4] = { VK_SHADER_STAGE_VERTEX_BIT, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT,
		VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, VK_SHADER_STAGE_FRAGMENT_BIT };
	VkPipelineShaderStageCreateInfo st[4];
	for (int i = 0; i < 4; i++)
		st[i] = (VkPipelineShaderStageCreateInfo){ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = stages[i],
			.module = module(dir, names[i]), .pName = "main" };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_PATCH_LIST };
	VkPipelineTessellationStateCreateInfo ts = { VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO,
		.patchControlPoints = 3 };
	VkViewport vp = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cba };
	VkPipelineRenderingCreateInfo ri = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = 1, .pColorAttachmentFormats = &cf };
	VkGraphicsPipelineCreateInfo gci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &ri,
		.stageCount = 4, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pTessellationState = &ts,
		.pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb,
		.layout = layout };
	VkPipeline p;
	VkResult r = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gci, NULL, &p);
	printf("%-4s create tc.vert + %s + tc.tese + tc.frag (VkResult %d)\n",
	       r == VK_SUCCESS ? "OK" : "FAIL", tesc, r);
	for (int i = 0; i < 4; i++)
		vkDestroyShaderModule(dev, st[i].module, NULL);
	if (r) {
		vkDestroyPipelineLayout(dev, layout, NULL);
		return 1;
	}

	/* draw one patch, copy the target out */
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &cbbi));
	VkImageMemoryBarrier to_color = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
		0, NULL, 0, NULL, 1, &to_color);
	VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE };
	VkRenderingInfo rinfo = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = sc, .layerCount = 1,
		.colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(cmd, &rinfo);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
	vkCmdDraw(cmd, 3, 1, 0, 0);
	vkCmdEndRendering(cmd);
	VkImageMemoryBarrier to_src = to_color;
	to_src.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
	to_src.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
	to_src.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	to_src.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
		0, NULL, 0, NULL, 1, &to_src);
	VkBufferImageCopy rc = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &rc);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo sinfo = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &sinfo, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));

	/* (0.25, 0.5, 0.5, 1) in UNORM8, +-1 for rounding */
	const int want[4] = { 64, 128, 128, 255 };
	uint32_t bad = 0, first = ~0u;
	for (uint32_t i = 0; i < W * H; i++)
		for (int c = 0; c < 4; c++)
			if (abs(px[i * 4 + c] - want[c]) > 1) {
				if (!bad)
					first = i;
				bad++;
				break;
			}
	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyPipeline(dev, p, NULL);
	vkDestroyPipelineLayout(dev, layout, NULL);
	if (bad) {
		printf("FAIL %s: %u of %u pixels not (64, 128, 128, 255), first at (%u, %u) = (%d, %d, %d, %d)\n",
		       tesc, bad, W * H, first % W, first / W,
		       px[first * 4], px[first * 4 + 1], px[first * 4 + 2], px[first * 4 + 3]);
		return 1;
	}
	printf("OK   %s: %u pixels (64, 128, 128, 255)\n", tesc, W * H);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <spv dir>\n", argv[0]); return 2; }
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceFeatures have;
	vkGetPhysicalDeviceFeatures(pd, &have);
	if (!have.tessellationShader) { printf("SKIP tess_components: tessellationShader is not advertised\n"); return 0; }
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13,
		.features = { .tessellationShader = VK_TRUE } };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	/* color target and its readback buffer */
	VkFormat cf = VK_FORMAT_R8G8B8A8_UNORM;
	VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = cf,
		.extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
	VkImage img;
	CK(vkCreateImage(dev, &imci, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memory_type(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
	VkDeviceMemory imem;
	CK(vkAllocateMemory(dev, &mai, NULL, &imem));
	CK(vkBindImageMemory(dev, img, imem, 0));
	VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = cf, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &ivci, NULL, &view));
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = memory_type(pd, mr.memoryTypeBits,
		VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	VkDeviceMemory bmem;
	CK(vkAllocateMemory(dev, &mai, NULL, &bmem));
	CK(vkBindBufferMemory(dev, buf, bmem, 0));
	uint8_t *px;
	CK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&px));
	memset(px, 0, W * H * 4);

	int fails = run_pipeline(argv[1], "tc.tesc.spv", queue, cf, img, view, buf, px);
	fails += run_pipeline(argv[1], "tc_position.tesc.spv", queue, cf, img, view, buf, px);
	vkUnmapMemory(dev, bmem);
	vkDestroyBuffer(dev, buf, NULL);
	vkFreeMemory(dev, bmem, NULL);
	vkDestroyImageView(dev, view, NULL);
	vkDestroyImage(dev, img, NULL);
	vkFreeMemory(dev, imem, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	return fails ? 1 : 0;
}
