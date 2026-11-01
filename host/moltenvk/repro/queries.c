/*
 * Occlusion query results copied with vkCmdCopyQueryPoolResults from a later command buffer, the way Venus
 * reads every query (query feedback: one copy per ended query, 64-bit with availability and
 * VK_QUERY_RESULT_WAIT_BIT). The copy of a query other than 0 read the availability of query 0 onward and
 * skipped the "are the queries ended" check, so DXVK's occlusion queries never became available in the guest.
 *
 * v.vert + f.frag (left-half triangle) into a 16x16 target; occlusion pool of 8 queries, all reset:
 *   query 5: the triangle             -> available, samples > 0
 *   query 2: no draws                 -> available, 0 samples
 *   queries 3 and 4: never begun      -> unavailable, results untouched
 * Copies: 5 and 2 each (64-bit, availability, wait), 3..4 (64-bit, availability), 5 (32-bit, availability);
 * vkGetQueryPoolResults of query 5 must match.
 *
 * Timestamp pool of 8192 queries (vkd3d-proton's size, more than one Metal counter heap holds on KosmicKrisp: 4096):
 * creation failed, Venus lost the pool and Stellar Blade's next vkCmdResetQueryPool killed the context. Queries 0
 * and 5000 (two heaps) written, both available and non-zero, query 1 unavailable.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

enum { W = 16, H = 16 };

static VkDevice dev;
static VkPhysicalDevice pd;

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

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <spv dir>\n", argv[0]); return 2; }
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .dynamicRendering = VK_TRUE };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &v13, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
	VkImage img;
	CK(vkCreateImage(dev, &imci, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, 0) };
	VkDeviceMemory imem;
	CK(vkAllocateMemory(dev, &mai, NULL, &imem));
	CK(vkBindImageMemory(dev, img, imem, 0));
	VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &ivci, NULL, &view));

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 256, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	VkDeviceMemory bmem;
	CK(vkAllocateMemory(dev, &mai, NULL, &bmem));
	CK(vkBindBufferMemory(dev, buf, bmem, 0));
	uint8_t *map;
	CK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&map));
	memset(map, 0xab, 256);

	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineShaderStageCreateInfo stages[2] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = module(argv[1], "v.vert.spv"), .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		  .module = module(argv[1], "f.frag.spv"), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1,
		.pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1,
		.pAttachments = &cba };
	VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo prci = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1,
		.pColorAttachmentFormats = &fmt };
	VkGraphicsPipelineCreateInfo gpci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &prci, .stageCount = 2,
		.pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vps,
		.pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout };
	VkPipeline pipe;
	CK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));

	VkQueryPoolCreateInfo qpci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION, .queryCount = 8 };
	VkQueryPool qp;
	CK(vkCreateQueryPool(dev, &qpci, NULL, &qp));
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 2 };
	VkCommandBuffer cmds[2];
	CK(vkAllocateCommandBuffers(dev, &ai, cmds));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1 };

	/* The application's command buffer. */
	CK(vkBeginCommandBuffer(cmds[0], &bi));
	vkCmdResetQueryPool(cmds[0], qp, 0, 8);
	VkImageMemoryBarrier ib = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(cmds[0], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL,
	                     0, NULL, 1, &ib);
	VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE };
	VkRenderingInfo rinfo = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = sc, .layerCount = 1,
		.colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(cmds[0], &rinfo);
	vkCmdBindPipeline(cmds[0], VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
	vkCmdBeginQuery(cmds[0], qp, 5, 0);
	vkCmdDraw(cmds[0], 3, 1, 0, 0);
	vkCmdEndQuery(cmds[0], qp, 5);
	vkCmdBeginQuery(cmds[0], qp, 2, 0);
	vkCmdEndQuery(cmds[0], qp, 2);
	vkCmdEndRendering(cmds[0]);
	CK(vkEndCommandBuffer(cmds[0]));
	si.pCommandBuffers = &cmds[0];
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));

	/* Venus' query feedback, submitted after it. */
	const VkQueryResultFlags fb = VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT;
	CK(vkBeginCommandBuffer(cmds[1], &bi));
	vkCmdCopyQueryPoolResults(cmds[1], qp, 5, 1, buf, 0, 16, fb | VK_QUERY_RESULT_WAIT_BIT);
	vkCmdCopyQueryPoolResults(cmds[1], qp, 2, 1, buf, 16, 16, fb | VK_QUERY_RESULT_WAIT_BIT);
	vkCmdCopyQueryPoolResults(cmds[1], qp, 3, 2, buf, 32, 16, fb);
	vkCmdCopyQueryPoolResults(cmds[1], qp, 5, 1, buf, 64, 8, VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmds[1], VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmds[1]));
	si.pCommandBuffers = &cmds[1];
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));

	const uint64_t *r64 = (const uint64_t *)map;
	const uint32_t *r32 = (const uint32_t *)(map + 64);
	uint64_t host = 0;
	CK(vkGetQueryPoolResults(dev, qp, 5, 1, sizeof(host), &host, 8, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
	int fails = 0;
	struct { const char *what; int ok; } checks[] = {
		{ "query 5 (triangle): available, samples > 0, same as vkGetQueryPoolResults", r64[1] == 1 && r64[0] > 0 && r64[0] == host },
		{ "query 2 (no draws): available, 0 samples", r64[3] == 1 && r64[2] == 0 },
		{ "queries 3, 4 (never begun): unavailable, results untouched",
		  r64[5] == 0 && r64[7] == 0 && r64[4] == 0xababababababababull && r64[6] == 0xababababababababull },
		{ "query 5, 32-bit: available, same samples", r32[1] == 1 && r32[0] == (uint32_t)host },
	};
	for (size_t i = 0; i < sizeof(checks) / sizeof(checks[0]); i++) {
		printf("%-4s occlusion query copy from a later command buffer, %s (samples %llu, available %llu)\n",
		       checks[i].ok ? "OK" : "FAIL", checks[i].what, (unsigned long long)r64[0], (unsigned long long)r64[1]);
		fails += !checks[i].ok;
	}

	VkQueryPoolCreateInfo tpci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP,
		.queryCount = 8192 };
	VkQueryPool tp;
	VkResult tr = vkCreateQueryPool(dev, &tpci, NULL, &tp);
	uint64_t ts[3][2] = { { 0 } };
	if (tr == VK_SUCCESS) {
		VkCommandBuffer tc;
		ai.commandBufferCount = 1;
		CK(vkAllocateCommandBuffers(dev, &ai, &tc));
		CK(vkBeginCommandBuffer(tc, &bi));
		vkCmdResetQueryPool(tc, tp, 0, 8192);
		vkCmdWriteTimestamp2(tc, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, tp, 0);
		vkCmdWriteTimestamp2(tc, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, tp, 5000);
		CK(vkEndCommandBuffer(tc));
		si.pCommandBuffers = &tc;
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));
		const VkQueryResultFlags tf = VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT;
		CK(vkGetQueryPoolResults(dev, tp, 0, 1, sizeof(ts[0]), ts[0], 16, tf | VK_QUERY_RESULT_WAIT_BIT));
		CK(vkGetQueryPoolResults(dev, tp, 5000, 1, sizeof(ts[1]), ts[1], 16, tf | VK_QUERY_RESULT_WAIT_BIT));
		VkResult nr = vkGetQueryPoolResults(dev, tp, 1, 1, sizeof(ts[2]), ts[2], 16, tf);
		if (nr != VK_SUCCESS && nr != VK_NOT_READY) tr = nr;
	}
	int ts_ok = tr == VK_SUCCESS && ts[0][1] == 1 && ts[1][1] == 1 && ts[0][0] && ts[1][0] && ts[2][1] == 0;
	printf("%-4s timestamp pool of 8192 (VkResult %d): queries 0 and 5000 available (%llu, %llu), values %llu %llu, "
	       "query 1 unavailable (%llu)\n", ts_ok ? "OK" : "FAIL", tr, (unsigned long long)ts[0][1],
	       (unsigned long long)ts[1][1], (unsigned long long)ts[0][0], (unsigned long long)ts[1][0],
	       (unsigned long long)ts[2][1]);
	fails += !ts_ok;

	/* Metal allows 32 counter heaps per process (MTLCounterSampleBuffer / MTL4CounterHeap), and under virglrenderer
	 * every guest application's device lives in one process: one heap per timestamp pool left the 33rd pool of the
	 * whole VM uncreatable (Venus lost it, the guest's next use of it was a CS error). 24 pools of one query on this
	 * device and 24 on a second one, the last of each written and read back. */
	{
		VkDevice dev2;
		CK(vkCreateDevice(pd, &dci, NULL, &dev2));
		VkQueue queue2;
		vkGetDeviceQueue(dev2, 0, 0, &queue2);
		VkDevice devs[2] = { dev, dev2 };
		VkQueue queues[2] = { queue, queue2 };
		enum { NP = 24 };
		VkQueryPool tps[2][NP];
		int created = 0, ok = 1;
		VkResult cr = VK_SUCCESS;
		VkQueryPoolCreateInfo one = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP,
			.queryCount = 1 };
		for (int d = 0; d < 2; d++)
			for (int i = 0; i < NP; i++) {
				tps[d][i] = VK_NULL_HANDLE;
				if (cr == VK_SUCCESS && (cr = vkCreateQueryPool(devs[d], &one, NULL, &tps[d][i])) == VK_SUCCESS)
					created++;
				else
					tps[d][i] = VK_NULL_HANDLE;
			}
		uint64_t last[2][2] = { { 0 } };
		for (int d = 0; d < 2 && cr == VK_SUCCESS; d++) {
			VkCommandPoolCreateInfo cp = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
			VkCommandPool cpool;
			CK(vkCreateCommandPool(devs[d], &cp, NULL, &cpool));
			VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool,
				.commandBufferCount = 1 };
			VkCommandBuffer c;
			CK(vkAllocateCommandBuffers(devs[d], &cai, &c));
			CK(vkBeginCommandBuffer(c, &bi));
			vkCmdResetQueryPool(c, tps[d][NP - 1], 0, 1);
			vkCmdWriteTimestamp2(c, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, tps[d][NP - 1], 0);
			CK(vkEndCommandBuffer(c));
			VkSubmitInfo s = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c };
			CK(vkQueueSubmit(queues[d], 1, &s, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(queues[d]));
			CK(vkGetQueryPoolResults(devs[d], tps[d][NP - 1], 0, 1, sizeof(last[d]), last[d], 16,
			                         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT));
			ok &= last[d][1] == 1 && last[d][0] != 0;
			vkDestroyCommandPool(devs[d], cpool, NULL);
		}
		ok &= cr == VK_SUCCESS;
		printf("%-4s %d timestamp pools of one query on two devices, all created (%d, VkResult %d), the last of each written "
		       "(available %llu %llu, values %llu %llu)\n", ok ? "OK" : "FAIL", 2 * NP, created, cr,
		       (unsigned long long)last[0][1], (unsigned long long)last[1][1], (unsigned long long)last[0][0],
		       (unsigned long long)last[1][0]);
		fails += !ok;
		for (int d = 0; d < 2; d++)
			for (int i = 0; i < NP; i++)
				vkDestroyQueryPool(devs[d], tps[d][i], NULL);
		vkDestroyDevice(dev2, NULL);
	}

	/* KosmicKrisp kept every occlusion query of a device in one Metal visibility result buffer of 32768 (Metal's
	 * maximum visibility query offset is 256 KB): pools past 32768 live queries failed to create, and Venus' next
	 * vkCmdBeginQuery on one was a CS error (Dota 2, Counter-Strike 2). Pools of 32760 (filling the first 32768 with
	 * the pool of 8 above), 8 and 40000 (more than one buffer); one render pass draws the triangle in query 5 of the
	 * first pool, query 3 of the 8-query pool, the last query of the 32760 pool and of the 40000 pool, then
	 * query 6 of the first pool again: every query counts the same samples, read back with vkGetQueryPoolResults and
	 * vkCmdCopyQueryPoolResults. */
	{
		const uint32_t counts[3] = { 32760, 8, 40000 };
		VkQueryPool big[3] = { VK_NULL_HANDLE, VK_NULL_HANDLE, VK_NULL_HANDLE };
		VkResult br = VK_SUCCESS;
		int nbig = 0;
		for (; nbig < 3; nbig++) {
			VkQueryPoolCreateInfo bq = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION,
				.queryCount = counts[nbig] };
			if ((br = vkCreateQueryPool(dev, &bq, NULL, &big[nbig])) != VK_SUCCESS) {
				big[nbig] = VK_NULL_HANDLE;
				break;
			}
		}
		uint64_t got[5] = { 0 }, copied[10];
		memset(copied, 0, sizeof(copied));
		if (br == VK_SUCCESS) {
			struct { VkQueryPool pool; uint32_t query; } q[5] = {
				{ qp, 5 }, { big[1], 3 }, { big[0], counts[0] - 1 }, { big[2], counts[2] - 1 }, { qp, 6 } };
			VkCommandBuffer oc;
			ai.commandBufferCount = 1;
			CK(vkAllocateCommandBuffers(dev, &ai, &oc));
			CK(vkBeginCommandBuffer(oc, &bi));
			for (int i = 0; i < 5; i++)
				vkCmdResetQueryPool(oc, q[i].pool, q[i].query, 1);
			vkCmdPipelineBarrier(oc, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0,
			                     NULL, 0, NULL, 1, &ib);
			vkCmdBeginRendering(oc, &rinfo);
			vkCmdBindPipeline(oc, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
			for (int i = 0; i < 5; i++) {
				vkCmdBeginQuery(oc, q[i].pool, q[i].query, VK_QUERY_CONTROL_PRECISE_BIT);
				vkCmdDraw(oc, 3, 1, 0, 0);
				vkCmdEndQuery(oc, q[i].pool, q[i].query);
			}
			vkCmdEndRendering(oc);
			for (int i = 0; i < 5; i++)
				vkCmdCopyQueryPoolResults(oc, q[i].pool, q[i].query, 1, buf, 16 * i, 16, fb | VK_QUERY_RESULT_WAIT_BIT);
			vkCmdPipelineBarrier(oc, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
			CK(vkEndCommandBuffer(oc));
			si.pCommandBuffers = &oc;
			CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(queue));
			memcpy(copied, map, sizeof(copied));
			for (int i = 0; i < 5; i++)
				CK(vkGetQueryPoolResults(dev, q[i].pool, q[i].query, 1, 8, &got[i], 8,
				                         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
		}
		int ok = br == VK_SUCCESS && got[0] > 0;
		for (int i = 0; i < 5; i++)
			ok &= got[i] == got[0] && copied[2 * i] == got[0] && copied[2 * i + 1] == 1;
		printf("%-4s occlusion pools of %u, %u and %u queries (%d created, VkResult %d), one render pass over queries of "
		       "all of them: samples %llu %llu %llu %llu %llu, copies %llu %llu %llu %llu %llu\n", ok ? "OK" : "FAIL",
		       counts[0], counts[1], counts[2], nbig, br, (unsigned long long)got[0], (unsigned long long)got[1],
		       (unsigned long long)got[2], (unsigned long long)got[3], (unsigned long long)got[4],
		       (unsigned long long)copied[0], (unsigned long long)copied[2], (unsigned long long)copied[4],
		       (unsigned long long)copied[6], (unsigned long long)copied[8]);
		fails += !ok;
		for (int i = 0; i < 3; i++)
			vkDestroyQueryPool(dev, big[i], NULL);
	}

	/* STEAMAC-2X: vkd3d-proton takes occlusion queries from pools of 4096 (each command allocator holds the ones it
	 * used until its reset, the device keeps up to 128 free ones) and makes every D3D12 timestamp query heap a
	 * timestamp pool of the heap's size. KosmicKrisp had 524288 occlusion queries per device (128 such pools; the next
	 * failed to create) and 131072 timestamp queries per process, shared by every pool of every device; Venus lost the
	 * refused pool and Path of Exile 2's first vkCmdResetQueryPool on it was a CS error. 300 occlusion pools of 4096
	 * with 40 timestamp pools of 8192 (327680 queries) created between them; one render pass counts the triangle in
	 * queries of occlusion pools 0, 127, 128, 200 (its last query), 299 and 0 again (four visibility result buffers,
	 * back to the first), with timestamps before, inside and after it in timestamp pools 0, 20 and 39. */
	{
		enum { NOQ = 300, NTS = 40 };
		static VkQueryPool oqs[NOQ], tss[NTS];
		int noq = 0, nts = 0;
		VkResult orr = VK_SUCCESS, trr = VK_SUCCESS;
		VkQueryPoolCreateInfo o4096 = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION,
			.queryCount = 4096 };
		VkQueryPoolCreateInfo t8192 = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP,
			.queryCount = 8192 };
		for (int i = 0; i < NOQ; i++) {
			if (orr == VK_SUCCESS && (orr = vkCreateQueryPool(dev, &o4096, NULL, &oqs[i])) == VK_SUCCESS)
				noq++;
			else
				oqs[i] = VK_NULL_HANDLE;
			if (i % 7 == 0 && i / 7 < NTS) {
				if (trr == VK_SUCCESS && (trr = vkCreateQueryPool(dev, &t8192, NULL, &tss[i / 7])) == VK_SUCCESS)
					nts++;
				else
					tss[i / 7] = VK_NULL_HANDLE;
			}
		}
		uint64_t got[6] = { 0 }, copied[12], tsv[3][2] = { { 0 } };
		memset(copied, 0, sizeof(copied));
		const int ran = orr == VK_SUCCESS && trr == VK_SUCCESS;
		if (ran) {
			struct { VkQueryPool pool; uint32_t query; } q[6] = {
				{ oqs[0], 1 }, { oqs[127], 2 }, { oqs[128], 3 }, { oqs[200], 4095 }, { oqs[299], 0 }, { oqs[0], 2 } };
			struct { VkQueryPool pool; uint32_t query; } t[3] = { { tss[0], 0 }, { tss[20], 4000 }, { tss[NTS - 1], 8191 } };
			VkCommandBuffer c;
			ai.commandBufferCount = 1;
			CK(vkAllocateCommandBuffers(dev, &ai, &c));
			CK(vkBeginCommandBuffer(c, &bi));
			for (int i = 0; i < 6; i++)
				vkCmdResetQueryPool(c, q[i].pool, q[i].query, 1);
			for (int i = 0; i < 3; i++)
				vkCmdResetQueryPool(c, t[i].pool, t[i].query, 1);
			vkCmdWriteTimestamp2(c, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, t[0].pool, t[0].query);
			vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0,
			                     NULL, 0, NULL, 1, &ib);
			vkCmdBeginRendering(c, &rinfo);
			vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
			for (int i = 0; i < 6; i++) {
				vkCmdBeginQuery(c, q[i].pool, q[i].query, VK_QUERY_CONTROL_PRECISE_BIT);
				vkCmdDraw(c, 3, 1, 0, 0);
				vkCmdEndQuery(c, q[i].pool, q[i].query);
				if (i == 2)
					vkCmdWriteTimestamp2(c, VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT, t[1].pool, t[1].query);
			}
			vkCmdEndRendering(c);
			vkCmdWriteTimestamp2(c, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, t[2].pool, t[2].query);
			for (int i = 0; i < 6; i++)
				vkCmdCopyQueryPoolResults(c, q[i].pool, q[i].query, 1, buf, 16 * i, 16, fb | VK_QUERY_RESULT_WAIT_BIT);
			vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
			CK(vkEndCommandBuffer(c));
			si.pCommandBuffers = &c;
			CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(queue));
			memcpy(copied, map, sizeof(copied));
			for (int i = 0; i < 6; i++)
				CK(vkGetQueryPoolResults(dev, q[i].pool, q[i].query, 1, 8, &got[i], 8,
				                         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
			for (int i = 0; i < 3; i++)
				CK(vkGetQueryPoolResults(dev, t[i].pool, t[i].query, 1, sizeof(tsv[i]), tsv[i], 16,
				                         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT |
				                         VK_QUERY_RESULT_WAIT_BIT));
		}
		int ok = ran && got[0] > 0;
		for (int i = 0; i < 6; i++)
			ok &= got[i] == got[0] && copied[2 * i] == got[0] && copied[2 * i + 1] == 1;
		printf("%-4s %d occlusion pools of 4096 (%d created, VkResult %d), one render pass over queries of pools 0, 127, "
		       "128, 200, 299, 0: samples %llu %llu %llu %llu %llu %llu, copies %llu %llu %llu %llu %llu %llu\n",
		       ok ? "OK" : "FAIL", NOQ, noq, orr, (unsigned long long)got[0], (unsigned long long)got[1],
		       (unsigned long long)got[2], (unsigned long long)got[3], (unsigned long long)got[4],
		       (unsigned long long)got[5], (unsigned long long)copied[0], (unsigned long long)copied[2],
		       (unsigned long long)copied[4], (unsigned long long)copied[6], (unsigned long long)copied[8],
		       (unsigned long long)copied[10]);
		fails += !ok;
		int tok = ran;
		for (int i = 0; i < 3; i++)
			tok &= tsv[i][1] == 1 && tsv[i][0] != 0;
		printf("%-4s %d timestamp pools of 8192 between them (%d created, VkResult %d), written before, inside and after "
		       "the render pass: available %llu %llu %llu, values %llu %llu %llu\n", tok ? "OK" : "FAIL", NTS, nts, trr,
		       (unsigned long long)tsv[0][1], (unsigned long long)tsv[1][1], (unsigned long long)tsv[2][1],
		       (unsigned long long)tsv[0][0], (unsigned long long)tsv[1][0], (unsigned long long)tsv[2][0]);
		fails += !tok;
		for (int i = 0; i < NOQ; i++)
			vkDestroyQueryPool(dev, oqs[i], NULL);
		for (int i = 0; i < NTS; i++)
			vkDestroyQueryPool(dev, tss[i], NULL);
	}

	/* Timestamp counter heap entries belong to the recording command buffer and return to the process at its reset:
	 * 4096 command buffers write one timestamp each (query k of a pool of 8192, KosmicKrisp takes a chunk of 16 entries
	 * per command buffer: 65536), submitted together; three rounds with the command pool reset between them (196608
	 * entries, more than the 131072 Metal gives the process). Every query available and non-zero in every round. */
	{
		enum { NCB = 4096, ROUNDS = 3 };
		VkQueryPool tp2;
		VkQueryPoolCreateInfo t8192 = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP,
			.queryCount = 8192 };
		CK(vkCreateQueryPool(dev, &t8192, NULL, &tp2));
		VkCommandPoolCreateInfo rcp = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
		VkCommandPool rpool;
		CK(vkCreateCommandPool(dev, &rcp, NULL, &rpool));
		VkCommandBufferAllocateInfo rai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = rpool,
			.commandBufferCount = NCB };
		static VkCommandBuffer cbs[NCB];
		CK(vkAllocateCommandBuffers(dev, &rai, cbs));
		static uint64_t res[NCB][2];
		int rounds = 0, bad = 0;
		for (int r = 0; r < ROUNDS && !bad; r++) {
			CK(vkResetCommandPool(dev, rpool, 0));
			for (uint32_t k = 0; k < NCB; k++) {
				CK(vkBeginCommandBuffer(cbs[k], &bi));
				vkCmdResetQueryPool(cbs[k], tp2, k, 1);
				vkCmdWriteTimestamp2(cbs[k], VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, tp2, k);
				CK(vkEndCommandBuffer(cbs[k]));
			}
			VkSubmitInfo s = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = NCB, .pCommandBuffers = cbs };
			CK(vkQueueSubmit(queue, 1, &s, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(queue));
			memset(res, 0, sizeof(res));
			CK(vkGetQueryPoolResults(dev, tp2, 0, NCB, sizeof(res), res, 16,
			                         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT |
			                         VK_QUERY_RESULT_WAIT_BIT));
			for (uint32_t k = 0; k < NCB; k++)
				bad += res[k][1] != 1 || res[k][0] == 0;
			rounds += !bad;
		}
		const int ok = rounds == ROUNDS;
		printf("%-4s %d command buffers writing one timestamp each, %d rounds with the command pool reset between them: "
		       "%d rounds with every query available and non-zero, %d bad\n", ok ? "OK" : "FAIL", NCB, ROUNDS, rounds, bad);
		fails += !ok;
		vkDestroyCommandPool(dev, rpool, NULL);
		vkDestroyQueryPool(dev, tp2, NULL);
	}

	/* 16 timestamps written back to back outside a render pass (vkd3d-proton's EndQuery(TIMESTAMP) with the resets
	 * hoisted): KosmicKrisp sampled them with Metal's relaxed granularity, which sampled only the first 4 of a compute
	 * encoder; the others resolved whatever their counter heap entry held (0 or a stale sample). Every one available,
	 * non-zero and not decreasing. */
	{
		enum { NT = 16 };
		VkQueryPool tp3;
		VkQueryPoolCreateInfo t16 = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP,
			.queryCount = NT };
		CK(vkCreateQueryPool(dev, &t16, NULL, &tp3));
		VkCommandBuffer c[2];
		ai.commandBufferCount = 2;
		CK(vkAllocateCommandBuffers(dev, &ai, c));
		CK(vkBeginCommandBuffer(c[0], &bi));
		vkCmdResetQueryPool(c[0], tp3, 0, NT);
		CK(vkEndCommandBuffer(c[0]));
		CK(vkBeginCommandBuffer(c[1], &bi));
		for (uint32_t k = 0; k < NT; k++)
			vkCmdWriteTimestamp2(c[1], VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, tp3, k);
		CK(vkEndCommandBuffer(c[1]));
		VkSubmitInfo s = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 2, .pCommandBuffers = c };
		CK(vkQueueSubmit(queue, 1, &s, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));
		uint64_t res[NT][2];
		memset(res, 0, sizeof(res));
		CK(vkGetQueryPoolResults(dev, tp3, 0, NT, sizeof(res), res, 16,
		                         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT));
		int good = 0;
		for (uint32_t k = 0; k < NT; k++)
			good += res[k][1] == 1 && res[k][0] != 0 && (k == 0 || res[k][0] >= res[k - 1][0]);
		printf("%-4s %d timestamps written back to back in one command buffer: %d available, non-zero and not decreasing "
		       "(first %llu, last %llu)\n", good == NT ? "OK" : "FAIL", NT, good, (unsigned long long)res[0][0],
		       (unsigned long long)res[NT - 1][0]);
		fails += good != NT;
		vkDestroyQueryPool(dev, tp3, NULL);
	}
	/* #45: Ratchet & Clank: Rift Apart's vkd3d-proton resets and writes ~790k timestamps in one one-time-submit command
	 * buffer. KosmicKrisp encoded a counter sample, a write_u32 dispatch and a single-entry resolve per timestamp into
	 * one Metal command buffer, which Metal 4 rejects past a capacity (61680 such timestamps on an M5 Pro): 65536 read 0
	 * with VkResult 0, 786432 lost the device. One pool of 65536, then 12 (past the 131072 counter heap entries, whose
	 * extra queries read 0): the submission completes, every query is available and the first pool's are non-zero. */
	{
		enum { NQ = 65536, NP = 12 };
		static VkQueryPool bp[NP];
		VkQueryPoolCreateInfo t64k = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP,
			.queryCount = NQ };
		for (int p = 0; p < NP; p++)
			CK(vkCreateQueryPool(dev, &t64k, NULL, &bp[p]));
		VkCommandPoolCreateInfo bcp = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
		VkCommandPool bpool;
		CK(vkCreateCommandPool(dev, &bcp, NULL, &bpool));
		VkCommandBufferBeginInfo once = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
			.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
		static uint64_t res[NQ][2];
		const int npools[2] = { 1, NP };
		for (int round = 0; round < 2; round++) {
			VkCommandBufferAllocateInfo bai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = bpool,
				.commandBufferCount = 1 };
			VkCommandBuffer bc;
			CK(vkAllocateCommandBuffers(dev, &bai, &bc));
			CK(vkBeginCommandBuffer(bc, &once));
			for (int p = 0; p < npools[round]; p++) {
				vkCmdResetQueryPool(bc, bp[p], 0, NQ);
				for (uint32_t q = 0; q < NQ; q++)
					vkCmdWriteTimestamp2(bc, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, bp[p], q);
			}
			CK(vkEndCommandBuffer(bc));
			VkSubmitInfo s = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &bc };
			VkResult r = vkQueueSubmit(queue, 1, &s, VK_NULL_HANDLE);
			if (r == VK_SUCCESS)
				r = vkQueueWaitIdle(queue);
			uint64_t unavailable = 0, zero = 0;
			for (int p = 0; p < npools[round] && r == VK_SUCCESS; p++) {
				memset(res, 0, sizeof(res));
				r = vkGetQueryPoolResults(dev, bp[p], 0, NQ, sizeof(res), res, 16,
				                          VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
				for (uint32_t q = 0; q < NQ; q++) {
					unavailable += res[q][1] != 1;
					zero += res[q][1] == 1 && res[q][0] == 0 && p == 0;
				}
			}
			const int ok = r == VK_SUCCESS && !unavailable && !zero;
			printf("%-4s %d timestamp pool(s) of %d, every query written in one one-time command buffer (%d timestamps): "
			       "VkResult %d, %llu unavailable, %llu of the first pool zero\n", ok ? "OK" : "FAIL", npools[round], NQ,
			       npools[round] * NQ, r, (unsigned long long)unavailable, (unsigned long long)zero);
			fails += !ok;
			vkFreeCommandBuffers(dev, bpool, 1, &bc);
		}
		vkDestroyCommandPool(dev, bpool, NULL);
		for (int p = 0; p < NP; p++)
			vkDestroyQueryPool(dev, bp[p], NULL);
	}
	if (fails) { printf("queries: %d failure(s)\n", fails); return 1; }
	return 0;
}
