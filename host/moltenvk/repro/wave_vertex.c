/*
 * Wave ops in the vertex stage, the second of Dragon's Dogma 2's two shader gaps. KosmicKrisp
 * declares gl_SubGroupInvocationID as 'uint gl_SubGroupInvocation [[thread_index_in_simdgroup]]',
 * and Metal rejects that attribute in a vertex function ("invalid 'thread_index_in_simdgroup'
 * attribute for input declaration in a vertex function"), so 36 of DD2's pipelines do not compile.
 *
 * What Metal does allow in a vertex function is every SIMD-group *function* (ballot, scans,
 * shuffles, quad ops) — so a lane id can be recovered there (see msl-metal-facts.md). This case
 * checks the values such a recovery has to reproduce, on a real draw:
 *
 *   dd2_wave.vert            writes, per vertex, the lane id, sub group ballot(true) and the
 *                            exclusive scan of 1 (both Metal functions a recovery would use), plus
 *                            subgroupBroadcastFirst(vertex index) so the host can group records by
 *                            SIMD group without assuming how vertices map to lanes.
 *   dd2_wave_frag.frag       the same ops in the fragment stage — a control that must pass on both
 *                            drivers today, including the attribute KosmicKrisp uses there.
 *
 * Per record the host checks: lane < subgroupSize; the lane's bit is set in its own ballot mask;
 * the exclusive scan equals the number of set bits below the lane (the property that makes the
 * recovery exact); inside one SIMD group with a full mask, the lanes are distinct and the group
 * holds subgroupSize vertices. A driver that reports the wrong lane id, a mask inconsistent with
 * it, or a group that is not a real SIMD group fails.
 *
 * Skipped, with the capability printed, when subgroupSupportedStages has no VERTEX: an honest
 * driver that does not offer vertex subgroups must keep the suite green (KosmicKrisp today, until
 * the advertisement is fixed).
 *
 * REPRO_FORCE=1 runs the vertex pipeline anyway, which reproduces the DD2 failure on the host:
 *
 *	Failed to create MTLLibrary: program_source:15:34: error: invalid 'thread_index_in_simdgroup'
 *	attribute for input declaration in a vertex function
 *	    uint gl_SubGroupInvocation [[thread_index_in_simdgroup]],
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

/* Three full SIMD groups. A multiple of 3 so that every vertex belongs to a complete triangle:
 * with a triangle-list draw whose count is not a multiple of 3, KosmicKrisp (Metal's vertex fetch)
 * does not run the shader for the trailing vertices, which is observable in a storage buffer and
 * would make this case depend on that behaviour. */
#define DRAW_VERTS 96u
#define TAIL_VERTS 3u /* a partial SIMD group */
#define RECORDS (DRAW_VERTS + TAIL_VERTS) /* the tail draw's records follow the first draw's */
#define EDGE 64u
#define SENTINEL 0xdeadbeefu

static VkDevice dev;
static int failures;

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

static VkBuffer host_buffer(VkPhysicalDevice pd, VkDeviceSize size, void **map)
{
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t t = 0;
	while (!(mr.memoryTypeBits & (1u << t)) ||
	       (mp.memoryTypes[t].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) !=
	           (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
		t++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, map));
	return buf;
}

/* One record: lane, ballot(true) mask, exclusive scan of 1, first vertex of the SIMD group. */
struct rec { uint32_t lane, mask, scan, group; };

/* The invariants a lane id derived from Metal's vertex-legal functions must satisfy.
 * check_groups additionally requires full masks to be real SIMD groups of subgroup_size distinct
 * lanes sharing one group key — true for vertex draws, meaningless for fragments, where a whole
 * SIMD group can span many quads (Metal ballots 32 active lanes there). */
static int check_records(const char *what, const struct rec *r, uint32_t count, uint32_t subgroup_size,
	int require_full_group, int check_groups)
{
	uint32_t bad_bit = 0, bad_scan = 0, bad_lane = 0, unwritten = 0, full = 0;
	for (uint32_t i = 0; i < count; i++) {
		if (r[i].lane == SENTINEL) { unwritten++; continue; }
		if (r[i].lane >= subgroup_size) bad_lane++;
		if (!((r[i].mask >> (r[i].lane & 31)) & 1u)) bad_bit++;
		uint32_t below = (r[i].lane >= 32) ? 0 : r[i].mask & ((1u << r[i].lane) - 1u);
		uint32_t want = 0;
		for (uint32_t b = 0; b < 32; b++)
			want += (below >> b) & 1u;
		if (r[i].scan != want) bad_scan++;
		if (r[i].mask == 0xffffffffu) full++;
	}
	/* Full masks must be real SIMD groups: distinct lanes per group key, one lane per vertex. */
	uint32_t dup = 0;
	if (check_groups) {
		for (uint32_t i = 0; i < count; i++) {
			if (r[i].lane == SENTINEL || r[i].mask != 0xffffffffu)
				continue;
			uint32_t same = 0;
			for (uint32_t j = 0; j < count; j++)
				if (j != i && r[j].group == r[i].group && r[j].mask == 0xffffffffu)
					same++;
			if (same + 1 != subgroup_size)
				dup++;
		}
	}
	int ok = !bad_lane && !bad_bit && !bad_scan && !dup && !unwritten && (!require_full_group || full);
	printf("%-4s %s (%u records, %u full groups, %u bad lane, %u lane bit unset, %u scan, %u group size, %u unwritten)\n",
		ok ? "OK" : "FAIL", what, count, full, bad_lane, bad_bit, bad_scan, dup, unwritten);
	if (!ok) {
		/* Name what failed: a lane that is wrong, a mask that does not contain it, a scan that is
		 * not its position among the active lanes, a group that is not a full SIMD group. */
		for (uint32_t i = 0, shown = 0; i < count && shown < 8; i++) {
			uint32_t below = (r[i].lane >= 32) ? 0 : r[i].mask & ((1u << r[i].lane) - 1u);
			uint32_t want = 0;
			for (uint32_t b = 0; b < 32; b++)
				want += (below >> b) & 1u;
			int anomaly = r[i].lane == SENTINEL || r[i].lane >= subgroup_size ||
				((r[i].mask >> (r[i].lane & 31)) & 1u) == 0 || r[i].scan != want;
			if (!anomaly && check_groups && r[i].mask == 0xffffffffu) {
				uint32_t same = 0;
				for (uint32_t j = 0; j < count; j++)
					if (j != i && r[j].group == r[i].group && r[j].mask == 0xffffffffu)
						same++;
				if (same + 1 != subgroup_size)
					anomaly = 1;
			}
			if (anomaly) {
				uint32_t same = 0;
				for (uint32_t j = 0; j < count; j++)
					if (j != i && r[j].group == r[i].group && r[j].mask == 0xffffffffu)
						same++;
				printf("     [%u] lane=%u mask=0x%08x scan=%u (want %u) group=%u full-group-members=%u\n",
					i, r[i].lane, r[i].mask, r[i].scan, want, r[i].group, r[i].lane == SENTINEL ? 0 : same + 1);
				shown++;
			}
		}
	}
	if (!ok)
		failures++;
	return ok;
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <spv dir>\n", argv[0]); return 2; }
	const char *dir = argv[1];

	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }

	VkPhysicalDeviceSubgroupProperties sub = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES };
	VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &sub };
	vkGetPhysicalDeviceProperties2(pd, &p2);
	printf("INFO %s: subgroupSize=%u subgroupSupportedStages=0x%x (vertex=%d)\n", p2.properties.deviceName,
		sub.subgroupSize, sub.supportedStages, (sub.supportedStages & VK_SHADER_STAGE_VERTEX_BIT) != 0);

	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

	/* ---- the vertex-stage pipeline (created even without VERTEX support, to record the
	 *      driver's behaviour, but only checked when it claims support) ---------------------- */
	struct rec *verts, *frags;
	VkBuffer vbuf = host_buffer(pd, RECORDS * sizeof(struct rec), (void **)&verts);
	VkBuffer fbuf = host_buffer(pd, EDGE * EDGE * sizeof(struct rec), (void **)&frags);

	VkDescriptorSetLayoutBinding bindings[2] = {
		{ .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1,
		  .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT },
		{ .binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1,
		  .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT },
	};
	VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = bindings };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2 };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet set;
	CK(vkAllocateDescriptorSets(dev, &dsai, &set));
	VkDescriptorBufferInfo bis[2] = { { vbuf, 0, VK_WHOLE_SIZE }, { fbuf, 0, VK_WHOLE_SIZE } };
	VkWriteDescriptorSet w[2] = {
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1,
		  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bis[0] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 1, .descriptorCount = 1,
		  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bis[1] },
	};
	vkUpdateDescriptorSets(dev, 2, w, 0, NULL);

	VkAttachmentDescription att = { .format = VK_FORMAT_R8G8B8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkAttachmentReference ar = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription sp = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ar };
	VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att,
		.subpassCount = 1, .pSubpasses = &sp };
	VkRenderPass rp;
	CK(vkCreateRenderPass(dev, &rpci, NULL, &rp));
	VkImageCreateInfo ici2 = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { EDGE, EDGE, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	VkImage img;
	CK(vkCreateImage(dev, &ici2, NULL, &img));
	VkMemoryRequirements imr;
	vkGetImageMemoryRequirements(dev, img, &imr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t mt = 0;
	while (!(imr.memoryTypeBits & (1u << mt)))
		mt++;
	VkMemoryAllocateInfo imai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = imr.size, .memoryTypeIndex = mt };
	VkDeviceMemory imem;
	CK(vkAllocateMemory(dev, &imai, NULL, &imem));
	CK(vkBindImageMemory(dev, img, imem, 0));
	VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &ivci, NULL, &view));
	VkFramebufferCreateInfo fbci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
		.attachmentCount = 1, .pAttachments = &view, .width = EDGE, .height = EDGE, .layers = 1 };
	VkFramebuffer fb;
	CK(vkCreateFramebuffer(dev, &fbci, NULL, &fb));

	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineShaderStageCreateInfo stages[2] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = module(dir, "dd2_wave.vert.spv"), .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		  .module = module(dir, "dd2_wave.frag.spv"), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, EDGE, EDGE, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { EDGE, EDGE } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cba };
	VkGraphicsPipelineCreateInfo gpci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		.stageCount = 2, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
		.pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms,
		.pColorBlendState = &cb, .layout = layout, .renderPass = rp };
	VkPipeline pipe;
	VkResult pr = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe);
	int vertex_supported = (sub.supportedStages & VK_SHADER_STAGE_VERTEX_BIT) != 0;
	if (pr == VK_SUCCESS)
		printf("OK   create dd2_wave.vert + fragment control pipeline\n");
	else
		printf("%-4s create dd2_wave.vert + fragment control pipeline (VkResult %d)%s\n",
			vertex_supported || getenv("REPRO_FORCE") ? "FAIL" : "SKIP", pr,
			vertex_supported ? "" : " — the driver does not advertise vertex subgroups");

	if (!vertex_supported)
		printf("SKIP vertex-stage wave ops: subgroupSupportedStages has no VERTEX\n");
	if (pr != VK_SUCCESS && (vertex_supported || getenv("REPRO_FORCE"))) {
		printf("FAIL wave_vertex: the pipeline does not compile (%s)\n",
			vertex_supported ? "the driver advertises vertex subgroups" : "REPRO_FORCE");
		return 1;
	}

	for (uint32_t i = 0; i < EDGE * EDGE; i++) frags[i].lane = frags[i].mask = frags[i].scan = frags[i].group = SENTINEL;

	if (pr == VK_SUCCESS) {
		for (uint32_t i = 0; i < RECORDS; i++) verts[i].lane = verts[i].mask = verts[i].scan = verts[i].group = SENTINEL;
		VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
		VkCommandBuffer cmd;
		CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
		VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkBeginCommandBuffer(cmd, &cbbi));
		VkClearValue clear = { .color = { { 0, 0, 0, 1 } } };
		VkRenderPassBeginInfo rpbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp, .framebuffer = fb,
			.renderArea = { { 0, 0 }, { EDGE, EDGE } }, .clearValueCount = 1, .pClearValues = &clear };
		vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, NULL);
		vkCmdDraw(cmd, DRAW_VERTS, 1, 0, 0);
		VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
		/* A partial SIMD group, whose records follow the first draw's (the shader writes by
		 * gl_VertexIndex, so the tail draw starts at vertex DRAW_VERTS). */
		vkCmdDraw(cmd, TAIL_VERTS, 1, DRAW_VERTS, 0);
		vkCmdEndRenderPass(cmd);
		VkMemoryBarrier hb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &hb, 0, NULL, 0, NULL);
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkEndCommandBuffer(cmd));
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));

		check_records("vertex-stage wave values (lane, ballot, scan, group)", verts, DRAW_VERTS, sub.subgroupSize, 1, 1);
		check_records("vertex-stage tail draw (3 of 32 lanes active)", verts + DRAW_VERTS, TAIL_VERTS,
			sub.subgroupSize, 0, 0);
	}

	/* The same ops in the fragment stage: Metal has the attribute there, so this must pass on both
	 * drivers today — it is what makes the vertex-stage verdict meaningful. Independent of the
	 * vertex pipeline: pass.vert has no subgroup ops. */
	{
		VkPipelineShaderStageCreateInfo fstages[2] = {
			{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
			  .module = module(dir, "pass.vert.spv"), .pName = "main" },
			{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
			  .module = module(dir, "dd2_wave_frag.frag.spv"), .pName = "main" },
		};
		VkGraphicsPipelineCreateInfo gp = gpci;
		gp.pStages = fstages;
		VkPipeline fpipe;
		VkResult fr = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp, NULL, &fpipe);
		if (fr != VK_SUCCESS) {
			printf("FAIL create fragment-subgroup pipeline (VkResult %d)\n", fr);
			failures++;
		} else {
			VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
			VkCommandBuffer cmd;
			CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
			VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
			CK(vkBeginCommandBuffer(cmd, &cbbi));
			VkClearValue clear = { .color = { { 0, 0, 0, 1 } } };
			VkRenderPassBeginInfo rpbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp, .framebuffer = fb,
				.renderArea = { { 0, 0 }, { EDGE, EDGE } }, .clearValueCount = 1, .pClearValues = &clear };
			vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, fpipe);
			vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, NULL);
			vkCmdDraw(cmd, DRAW_VERTS, 1, 0, 0);
			vkCmdEndRenderPass(cmd);
			VkMemoryBarrier hb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
				.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &hb, 0, NULL, 0, NULL);
			VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
			CK(vkEndCommandBuffer(cmd));
			CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(queue));
			uint32_t written = 0;
			for (uint32_t i = 0; i < EDGE * EDGE; i++)
				if (frags[i].lane != SENTINEL)
					written++;
			if (!written) {
				printf("FAIL fragment-stage wave values: no fragment ran\n");
				failures++;
			} else {
				check_records("fragment-stage wave values [control]", frags, EDGE * EDGE, sub.subgroupSize, 0, 0);
			}
		}
	}

	printf("%s wave_vertex: %d failure(s)\n", failures ? "FAIL" : "OK", failures);
	return failures != 0;
}
