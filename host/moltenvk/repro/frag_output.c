/*
 * Fragment outputs whose numeric type differs from their color attachment's. Vulkan leaves the values written
 * undefined (KosmicKrisp writes the output's bits), Metal fails such render pipelines: "output of
 * type uint4 is not compatible with a MTLPixelFormatR32Sint color attachment" (STEAMAC-2C, a Left 4 Dead 2
 * pipeline through DXVK; Venus skipped its draws). Every pipeline must be created and write the output's bits:
 * signedness changes, a scalar output (padded to four components), an output at location 1 next to a matching
 * one, an output array indexed dynamically, and two outputs packed into the components of one location. Float
 * to an unsigned and int to a normalized attachment are bit cast on MoltenVK; other drivers may convert the
 * values (KosmicKrisp does), so there only the pipeline and the draw are checked and the values printed.
 *
 *   frag_output <spv dir>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define W 4
#define H 4

static VkDevice dev;
static VkPhysicalDevice pd;
static VkQueue queue;
static VkCommandPool pool;
static const char *dir;
static int moltenvk;
static VkPipelineCache pipeline_cache;

static VkShaderModule module(const char *name)
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

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t t = 0; t < mp.memoryTypeCount; t++)
		if ((bits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & want) == want)
			return t;
	printf("FAIL no memory type\n");
	exit(1);
}

static VkDeviceMemory alloc(VkMemoryRequirements mr, VkMemoryPropertyFlags want)
{
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, want) };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	return mem;
}

struct attachment {
	VkFormat format;
	int unorm8;		/* RGBA8_UNORM: expect holds bytes, compared within 1 */
	uint32_t ncomp;		/* components written */
	uint32_t expect[4];	/* 32-bit components: their bits */
	int moltenvk_only;	/* bit cast between float and integer: expect checked on MoltenVK only */
};

struct test {
	const char *what;
	const char *shader;
	uint32_t natt;
	struct attachment att[2];
	const VkPipelineColorBlendAttachmentState *blend;
};

static const struct test tests[] = {
	{ "uvec4 -> R32_SINT", "fo_uvec4.frag.spv", 1,
	  { { VK_FORMAT_R32_SINT, 0, 1, { 0xfffffffe } } } },
	{ "uint -> R32_SINT", "fo_uint.frag.spv", 1,
	  { { VK_FORMAT_R32_SINT, 0, 1, { 0x80000001 } } } },
	{ "vec4 -> RGBA8_UNORM at 0, ivec4 -> R32G32B32A32_UINT at 1", "fo_mixed.frag.spv", 2,
	  { { VK_FORMAT_R8G8B8A8_UNORM, 1, 4, { 255, 0, 0, 255 } },
	    { VK_FORMAT_R32G32B32A32_UINT, 0, 4, { 0xffffffff, 0xfffffffe, 3, 4 } } } },
	{ "uvec4[2] -> R32_SINT, R32_SINT", "fo_array.frag.spv", 2,
	  { { VK_FORMAT_R32_SINT, 0, 1, { 0xfffffff0 } }, { VK_FORMAT_R32_SINT, 0, 1, { 0xfffffff1 } } } },
	{ "vec4 -> R32_UINT at 0, ivec4 -> RGBA8_UNORM at 1", "fo_float.frag.spv", 2,
	  { { VK_FORMAT_R32_UINT, 0, 1, { 0x3f800000 }, 1 }, { VK_FORMAT_R8G8B8A8_UNORM, 1, 4, { 255, 0, 128, 255 }, 1 } } },
	{ "uint components 0 and 1 -> R32G32_SINT", "fo_components.frag.spv", 1,
	  { { VK_FORMAT_R32G32_SINT, 0, 2, { 0xfffffffd, 5 } } } },
};

static const VkPipelineColorBlendAttachmentState missing_dst_blend = {
	.blendEnable = VK_TRUE, .srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
	.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
	.srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC1_ALPHA,
	.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR, .colorWriteMask = 15,
};
static const VkPipelineColorBlendAttachmentState missing_src_blend = {
	.blendEnable = VK_TRUE, .srcColorBlendFactor = VK_BLEND_FACTOR_SRC1_COLOR,
	.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR,
	.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
	.dstAlphaBlendFactor = VK_BLEND_FACTOR_SRC1_ALPHA, .colorWriteMask = 15,
};
static const VkPipelineColorBlendAttachmentState present_blend = {
	.blendEnable = VK_TRUE, .srcColorBlendFactor = VK_BLEND_FACTOR_SRC1_COLOR,
	.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO,
	.srcAlphaBlendFactor = VK_BLEND_FACTOR_SRC1_ALPHA,
	.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO, .colorWriteMask = 15,
};
/* Vulkan framebuffer-dsb permits an absent secondary value. MoltenVK chooses zero.
 * A Location=1 output must not be mistaken for Location=0, Index=1 (STEAMAC-75). */
static const struct test dual_tests[] = {
	{ "missing secondary: source ONE, destination ONE_MINUS_SRC1_ALPHA", "sentry-75-secondary-absent.frag.spv", 1,
	  { { VK_FORMAT_R8G8B8A8_UNORM, 1, 4, { 96, 191, 223, 64 }, 1 } }, &missing_dst_blend },
	{ "missing secondary: source SRC1_COLOR, destination ONE_MINUS_SRC1_COLOR", "sentry-75-secondary-absent.frag.spv", 1,
	  { { VK_FORMAT_R8G8B8A8_UNORM, 1, 4, { 32, 64, 32, 128 }, 1 } }, &missing_src_blend },
	{ "masked Location=1 is not a secondary source", "sentry-75-secondary-masked.frag.spv", 1,
	  { { VK_FORMAT_R8G8B8A8_UNORM, 1, 4, { 96, 191, 223, 64 }, 1 } }, &missing_dst_blend },
	{ "packed Index=1 retains real secondary source", "sentry-75-dual-source.frag.spv", 1,
	  { { VK_FORMAT_R8G8B8A8_UNORM, 1, 4, { 32, 32, 191, 32 } } }, &present_blend },
	{ "array Index=1 retains real secondary source", "sentry-75-secondary-array.frag.spv", 1,
	  { { VK_FORMAT_R8G8B8A8_UNORM, 1, 4, { 32, 32, 191, 32 } } }, &present_blend },
};

static int run(const struct test *t, VkShaderModule vs)
{
	VkImage img[2];
	VkImageView view[2];
	VkAttachmentDescription ad[2];
	VkAttachmentReference ref[2];
	VkPipelineColorBlendAttachmentState cba[2];
	VkClearValue clear[2];
	memset(clear, 0, sizeof(clear));
	for (uint32_t a = 0; a < t->natt; a++) {
		VkImageCreateInfo ici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
			.format = t->att[a].format, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
			.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
			.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
		CK(vkCreateImage(dev, &ici, NULL, &img[a]));
		VkMemoryRequirements mr;
		vkGetImageMemoryRequirements(dev, img[a], &mr);
		CK(vkBindImageMemory(dev, img[a], alloc(mr, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0));
		VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img[a], .viewType = VK_IMAGE_VIEW_TYPE_2D,
			.format = t->att[a].format, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		CK(vkCreateImageView(dev, &ivci, NULL, &view[a]));
		ad[a] = (VkAttachmentDescription){ 0, t->att[a].format, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
			VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
			VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
		ref[a] = (VkAttachmentReference){ a, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
		cba[a] = (VkPipelineColorBlendAttachmentState){ .colorWriteMask = 0xf };
		if (t->blend) {
			cba[a] = *t->blend;
			clear[a].color = (VkClearColorValue) { .float32 = { 0.125f, 0.25f, 0.125f, 0.25f } };
		}
	}
	VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = t->natt, .pColorAttachments = ref };
	VkSubpassDependency dep = { 0, VK_SUBPASS_EXTERNAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, 0 };
	VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = t->natt,
		.pAttachments = ad, .subpassCount = 1, .pSubpasses = &sub, .dependencyCount = 1, .pDependencies = &dep };
	VkRenderPass rp;
	CK(vkCreateRenderPass(dev, &rpci, NULL, &rp));
	VkFramebufferCreateInfo fbci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
		.attachmentCount = t->natt, .pAttachments = view, .width = W, .height = H, .layers = 1 };
	VkFramebuffer fb;
	CK(vkCreateFramebuffer(dev, &fbci, NULL, &fb));

	VkPushConstantRange pcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, 4 };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineShaderStageCreateInfo stages[2] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = module(t->shader), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = t->natt, .pAttachments = cba };
	VkGraphicsPipelineCreateInfo gpci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = stages,
		.pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vps, .pRasterizationState = &rs,
		.pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout, .renderPass = rp };
	VkPipeline p;
	VkResult r = vkCreateGraphicsPipelines(dev, pipeline_cache, 1, &gpci, NULL, &p);
	if (r) {
		printf("FAIL %s: vkCreateGraphicsPipelines = %d\n", t->what, r);
		return 1;
	}

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 2 * 256, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkDeviceMemory mem = alloc(mr, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	uint8_t *map;
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));

	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &cbbi));
	VkRenderPassBeginInfo rpbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp, .framebuffer = fb,
		.renderArea = { { 0, 0 }, { W, H } }, .clearValueCount = t->natt, .pClearValues = clear };
	vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
	int32_t n = 2;
	vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 4, &n);
	vkCmdDraw(cmd, 3, 1, 0, 0);
	vkCmdEndRenderPass(cmd);
	for (uint32_t a = 0; a < t->natt; a++) {
		VkBufferImageCopy bic = { .bufferOffset = 256 * a, .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
			.imageExtent = { 1, 1, 1 } };
		vkCmdCopyImageToBuffer(cmd, img[a], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &bic);
	}
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));

	int bad = 0, unchecked = 0;
	char got[256] = "";
	for (uint32_t a = 0; a < t->natt; a++) {
		const struct attachment *at = &t->att[a];
		int check = moltenvk || !at->moltenvk_only;
		unchecked += !check;
		for (uint32_t c = 0; c < at->ncomp; c++) {
			uint32_t v;
			if (at->unorm8) {
				v = map[256 * a + c];
				bad += check && (v + 1 < at->expect[c] || v > at->expect[c] + 1);
			} else {
				memcpy(&v, map + 256 * a + 4 * c, 4);
				bad += check && v != at->expect[c];
			}
			snprintf(got + strlen(got), sizeof(got) - strlen(got), "%s%s0x%x", c ? " " : "", c || !a ? "" : " | ", v);
		}
	}
	printf("%-4s %s: %s%s\n", bad ? "FAIL" : "OK", t->what, got, unchecked ? " (values not checked: undefined, bit cast on MoltenVK)" : "");
	return bad != 0;
}

int main(int argc, char **argv)
{
	int dual = argc == 3 && !strcmp(argv[2], "dual-source");
	if (argc != 2 && !dual) { fprintf(stderr, "usage: %s <spv dir> [dual-source]\n", argv[0]); return 2; }
	dir = argv[1];
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkPhysicalDeviceFeatures features = { .dualSrcBlend = dual };
	dci.pEnabledFeatures = &features;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	VkPhysicalDeviceDriverProperties driver = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
	VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &driver };
	vkGetPhysicalDeviceProperties2(pd, &props);
	moltenvk = driver.driverID == VK_DRIVER_ID_MOLTENVK;
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

	VkShaderModule vs = module("msaa.vert.spv");
	int fails = 0;
	if (dual) {
		VkPipelineCacheCreateInfo cache_info = { VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO };
		CK(vkCreatePipelineCache(dev, &cache_info, NULL, &pipeline_cache));
		for (unsigned round = 0; round < 2; round++) {
			printf("dual-source pipelines: %s cache\n", round ? "serialized" : "cold");
			for (size_t i = 0; i < sizeof(dual_tests) / sizeof(dual_tests[0]); i++)
				fails += run(&dual_tests[i], vs);
			if (!round) {
				size_t size = 0;
				CK(vkGetPipelineCacheData(dev, pipeline_cache, &size, NULL));
				void *data = malloc(size);
				CK(vkGetPipelineCacheData(dev, pipeline_cache, &size, data));
				vkDestroyPipelineCache(dev, pipeline_cache, NULL);
				cache_info.initialDataSize = size;
				cache_info.pInitialData = data;
				CK(vkCreatePipelineCache(dev, &cache_info, NULL, &pipeline_cache));
				free(data);
			}
		}
		vkDestroyPipelineCache(dev, pipeline_cache, NULL);
	} else {
		for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++)
			fails += run(&tests[i], vs);
	}
	if (fails) { printf("frag_output: %d failure(s)\n", fails); return 1; }
	return 0;
}
