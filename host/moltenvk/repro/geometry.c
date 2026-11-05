/*
 * Geometry-shader and null-pipeline checks against libMoltenVK.
 *
 *   geometry <dir with the SPIR-V of repro/shaders>
 *
 * Renders two primitives into a 16x16 RGBA8 target and checks one pixel inside each.
 * Required (exit status):
 *   v + f                          no GS, triangle list: both green
 *   v + zink_passthrough + fprim   zink-style passthrough GS (all varyings, non-block
 *                                  gl_Position input, gl_PrimitiveIDIn -> gl_PrimitiveID),
 *                                  triangle list; blue = (gl_PrimitiveID + 1) / 4
 *   strip + zink_passthrough + fprim  same GS on a triangle strip (odd-primitive order)
 *   ubo [+ zink_passthrough] + ubo  zink-style arrays of uniform buffers indexed dynamically,
 *                                  in a push-descriptor set (discrete Metal buffers) and in a
 *                                  regular set (argument buffer), with robustBufferAccess2
 *   v + zink_primid2 + fprim       GS with two PrimitiveId input variables (zink)
 *   voff + zink_passthrough + fprim  GS with vkCmdDraw firstVertex, vkCmdDrawIndirect and
 *                                  vkCmdDrawIndexedIndirect (firstIndex, vertexOffset); voff + f
 *                                  without GS as reference
 *   vattr + zink_passthrough + fprim GS with vertex buffer input: static stride, and pipeline stride
 *                                  0 with VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE (zink)
 *   vinst + zink_passthrough + f   2 instances with a per-instance attribute (glamor's instanced
 *                                  rectangles); vinst + f without GS as reference
 *   ladj + ladj + f                LINE_LIST_WITH_ADJACENCY, GS emitting two triangles (zink GL_QUADS)
 *   tsadj + tsadj + f              TRIANGLE_STRIP_WITH_ADJACENCY, 2 triangles (strip adjacency order)
 *   vfmt + zink_passthrough + f    GS with SSCALED16 / SNORM16 / SNORM8 positions and UNORM8 colors (glamor's
 *                                  GL_SHORT vertices); vfmt + f without GS as reference
 *   ladj + zink_passthrough + fprim  TRIANGLE_FAN with a GS (zink GL_TRIANGLE_FAN), static and with a
 *                                  TRIANGLE_LIST pipeline + dynamic TRIANGLE_FAN topology
 *   ubo + zink_passthrough + ubo   also with vertex bindings 0..7, {0, 10}, 0..15 and {30} declared (and
 *                                  {30} without GS): buffer-size constants (robust UBO arrays), the GS
 *                                  DrawInfo buffer and vertex buffers must not share a Metal index
 *   lines + zink_lines + fprim     GS with line input (line list), lines expanded to quads
 *   VK_NULL_HANDLE bound as graphics and compute pipeline (what a guest did through Venus
 *   when the host failed to create a pipeline), then draw + dispatch: no crash, nothing drawn
 *   (MoltenVK only: virglrenderer patch 0014 no longer passes these binds to the driver;
 *   Mesa drivers dereference the pipeline)
 *   v + f, polygonMode LINE        wireframe (DXVK requires fillModeNonSolid): the two triangles' interiors
 *                                  stay clear, only their edges are drawn
 *   v + msl_type_names             fragment shader with textures named "sampler" and "array"
 *                                  (pipeline creation only)
 *   v + prim + fprim               GS that reads only some vertex outputs (location-based payload)
 *   v + glin + f                   glslang-style GS reading positions from the gl_in[] block
 *   v + garr + farr                GS writing an array varying (vec4[2] at location 2) and one after it at
 *                                  location 4 (Stellar Blade's cube map GS): Metal mesh vertices cannot hold
 *                                  arrays, the elements must be separate outputs at locations 2 and 3
 *   v + ghelpers + f              GS with float/uint/vector-returning helpers and nested value-returning
 *                                  helpers that emit vertices (DXVK's dxbc-spirv helper signatures)
 *   vinactive/vduplicate + glin + f  GS object wrapper calling a vertex shader with unused/non-interface
 *                                  builtin inputs, or two active variables for the same builtin (STEAMAC-1E)
 *   sentry-41-payload + sentry-41-payload + f  point-to-quad with a scalar payload location;
 *                                  partial object_data vector stores crashed Apple's compiler (41/R)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define W 16
#define H 16

#define CK(x)                                                                          \
	do {                                                                               \
		VkResult r_ = (x);                                                             \
		if (r_ != VK_SUCCESS) {                                                        \
			fprintf(stderr, "%s failed: %d (line %d)\n", #x, r_, __LINE__);            \
			exit(2);                                                                   \
		}                                                                              \
	} while (0)

static VkPhysicalDevice pd;
static VkDevice dev;
static VkQueue queue;
static VkCommandPool pool;
static VkPipelineLayout layout;
static const char *dir;

static VkShaderModule module(const char *name)
{
	char path[4096];
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		exit(2);
	}
	fseek(f, 0, SEEK_END);
	size_t size = (size_t)ftell(f);
	rewind(f);
	uint32_t *code = malloc(size);
	if (fread(code, 1, size, f) != size)
		exit(2);
	fclose(f);
	VkShaderModuleCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = size, .pCode = code };
	VkShaderModule m;
	CK(vkCreateShaderModule(dev, &ci, NULL, &m));
	free(code);
	return m;
}

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags flags)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	exit(2);
}

static VkDeviceMemory alloc(VkMemoryRequirements mr, VkMemoryPropertyFlags flags)
{
	VkMemoryAllocateInfo ai = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, flags),
	};
	VkDeviceMemory m;
	CK(vkAllocateMemory(dev, &ai, NULL, &m));
	return m;
}

/* Vertex input of the next pipeline: none, binding 0 with a static stride of 16, or binding 0 with
 * stride 0 in the pipeline and VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE (what zink does). */
enum vertex_input { VI_NONE, VI_STATIC_STRIDE, VI_DYNAMIC_STRIDE, VI_INSTANCE, VI_SSCALED16, VI_SNORM16, VI_SNORM8,
                    VI_HIGH_BINDINGS };
static enum vertex_input vertex_input;
/* Vertex bindings declared (without attributes) for VI_HIGH_BINDINGS. */
static const uint32_t *high_bindings;
static uint32_t high_binding_count;
/* Whether the next pipeline has VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY (zink). */
static int dynamic_topology;
/* Rasterization polygon mode of the next pipeline (DRAW_WIREFRAME: LINE). */
static VkPolygonMode polygon_mode = VK_POLYGON_MODE_FILL;

static VkPipeline graphics(const char *vs, const char *gs, const char *fs, VkPrimitiveTopology topology,
                           VkPipelineLayout pl)
{
	VkPipelineShaderStageCreateInfo st[3] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = module(vs), .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = module(fs), .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_GEOMETRY_BIT, .pName = "main" },
	};
	if (gs)
		st[2].module = module(gs);
	/* VI_INSTANCE: binding 0 per-vertex vec2 (stride 16), binding 1 per-instance vec2 at location 2 (stride 8). */
	VkVertexInputBindingDescription vib[2] = {
		{ 0, vertex_input == VI_DYNAMIC_STRIDE ? 0 : 16, VK_VERTEX_INPUT_RATE_VERTEX },
		{ 1, 8, VK_VERTEX_INPUT_RATE_INSTANCE } };
	VkVertexInputAttributeDescription via[2] = { { 0, 0, VK_FORMAT_R32G32_SFLOAT, 0 }, { 2, 1, VK_FORMAT_R32G32_SFLOAT, 0 } };
	/* VI_SSCALED16 / VI_SNORM16 / VI_SNORM8: one binding, stride 8: position (location 0) at offset 0,
	 * R8G8B8A8_UNORM color (location 1) at offset 4. */
	if (vertex_input >= VI_SSCALED16) {
		vib[0].stride = 8;
		via[0].format = vertex_input == VI_SSCALED16 ? VK_FORMAT_R16G16_SSCALED :
		                vertex_input == VI_SNORM16 ? VK_FORMAT_R16G16_SNORM : VK_FORMAT_R8G8_SNORM;
		via[1] = (VkVertexInputAttributeDescription){ 1, 0, VK_FORMAT_R8G8B8A8_UNORM, 4 };
	}
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	/* VI_HIGH_BINDINGS: vertex bindings declared without attributes (high_bindings), as zink and DXVK
	 * declare them; the implicit buffers (buffer sizes, GS DrawInfo ...) must avoid their indices. */
	VkVertexInputBindingDescription high_vib[32];
	for (uint32_t b = 0; b < high_binding_count; b++)
		high_vib[b] = (VkVertexInputBindingDescription){ high_bindings[b], 16, VK_VERTEX_INPUT_RATE_VERTEX };
	if (vertex_input == VI_HIGH_BINDINGS) {
		vi.vertexBindingDescriptionCount = high_binding_count;
		vi.pVertexBindingDescriptions = high_vib;
	} else if (vertex_input >= VI_SSCALED16) {
		vi.vertexBindingDescriptionCount = 1;
		vi.pVertexBindingDescriptions = vib;
		vi.vertexAttributeDescriptionCount = 2;
		vi.pVertexAttributeDescriptions = via;
	} else if (vertex_input != VI_NONE) {
		vi.vertexBindingDescriptionCount = vertex_input == VI_INSTANCE ? 2 : 1;
		vi.pVertexBindingDescriptions = vib;
		vi.vertexAttributeDescriptionCount = vertex_input == VI_INSTANCE ? 2 : 1;
		vi.pVertexAttributeDescriptions = via;
	}
	VkDynamicState dyn[2];
	uint32_t ndyn = 0;
	if (vertex_input == VI_DYNAMIC_STRIDE)
		dyn[ndyn++] = VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE;
	if (dynamic_topology)
		dyn[ndyn++] = VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY;
	VkPipelineDynamicStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		.dynamicStateCount = ndyn, .pDynamicStates = dyn };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = topology };
	VkViewport vp = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = polygon_mode, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cba };
	VkFormat cf = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo ri = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = 1, .pColorAttachmentFormats = &cf };
	VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &ri,
		.stageCount = gs ? 3 : 2, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
		.pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb,
		.pDynamicState = &ds, .layout = pl };
	VkPipeline p = VK_NULL_HANDLE;
	VkResult r = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
	printf("%-4s create %s + %s + %s (VkResult %d)\n", r == VK_SUCCESS ? "OK" : "FAIL", vs, gs ? gs : "-", fs, r);
	return p;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <spv dir>\n", argv[0]);
		return 2;
	}
	dir = argv[1];

	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
	VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv };
	vkGetPhysicalDeviceProperties2(pd, &p2);
	const int moltenvk = drv.driverID == VK_DRIVER_ID_MOLTENVK;
	/* Features zink enables that matter here: robustness2 (robust buffer access on UBO arrays),
	 * scalar block layout, push descriptors. */
	VkPhysicalDeviceRobustness2FeaturesEXT rb2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		.robustBufferAccess2 = VK_TRUE, .robustImageAccess2 = VK_TRUE, .nullDescriptor = VK_TRUE };
	VkPhysicalDeviceVulkan12Features v12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &rb2, .scalarBlockLayout = VK_TRUE };
	VkPhysicalDeviceVulkan13Features v13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.pNext = &v12, .dynamicRendering = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &v13,
		.features = { .geometryShader = VK_TRUE, .robustBufferAccess = VK_TRUE,
		              .shaderUniformBufferArrayDynamicIndexing = VK_TRUE } };
	const char *exts[] = { VK_EXT_ROBUSTNESS_2_EXTENSION_NAME, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME };
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
		.pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = 2,
		.ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	PFN_vkCmdPushDescriptorSetKHR push_descriptor_set =
		(PFN_vkCmdPushDescriptorSetKHR)vkGetDeviceProcAddr(dev, "vkCmdPushDescriptorSetKHR");
	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));

	/* set 0: push-descriptor set (Metal: discrete buffers), set 1: regular set (Metal: argument
	 * buffer); each binding 0 = array of 2 uniform buffers, as zink declares them. */
	const VkShaderStageFlags all = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_GEOMETRY_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
	VkDescriptorSetLayoutBinding ubo_binding = { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2, all, NULL };
	VkDescriptorSetLayoutCreateInfo dslci[2] = {
		{ .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		  .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR, .bindingCount = 1, .pBindings = &ubo_binding },
		{ .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &ubo_binding },
	};
	VkDescriptorSetLayout dsl[2];
	CK(vkCreateDescriptorSetLayout(dev, &dslci[0], NULL, &dsl[0]));
	CK(vkCreateDescriptorSetLayout(dev, &dslci[1], NULL, &dsl[1]));
	VkPushConstantRange pcr = { all, 0, 4 };
	VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 2,
		.pSetLayouts = dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	/* Uniform buffers: [0] and [1] in each set. Set 0 element 1 holds the vertex colour
	 * (0, 1, 0.5, 1) in _m0[0..3]; set 1 element 1 holds the fragment multiplier (1, 1, 1, 1) in
	 * _m0[4..7] (index idx * 4). Element 0 of both is zero, so a wrong descriptor index draws black. */
	VkBufferCreateInfo ubci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 64,
		.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT };
	VkBuffer ubos[2][2];
	for (int s = 0; s < 2; s++)
		for (int e = 0; e < 2; e++) {
			CK(vkCreateBuffer(dev, &ubci, NULL, &ubos[s][e]));
			VkMemoryRequirements umr;
			vkGetBufferMemoryRequirements(dev, ubos[s][e], &umr);
			VkDeviceMemory um = alloc(umr, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
			CK(vkBindBufferMemory(dev, ubos[s][e], um, 0));
			float *f;
			CK(vkMapMemory(dev, um, 0, VK_WHOLE_SIZE, 0, (void **)&f));
			memset(f, 0, 64);
			if (e == 1 && s == 0) {
				f[0] = 0.0f; f[1] = 1.0f; f[2] = 0.5f; f[3] = 1.0f;
			} else if (e == 1 && s == 1) {
				f[4] = f[5] = f[6] = f[7] = 1.0f;
			}
		}
	VkDescriptorBufferInfo ubo_info[2][2];
	for (int s = 0; s < 2; s++)
		for (int e = 0; e < 2; e++)
			ubo_info[s][e] = (VkDescriptorBufferInfo){ ubos[s][e], 0, VK_WHOLE_SIZE };
	VkDescriptorPoolSize dps = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2 };
	VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
		.poolSizeCount = 1, .pPoolSizes = &dps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
	VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl[1] };
	VkDescriptorSet set1;
	CK(vkAllocateDescriptorSets(dev, &dsai, &set1));
	VkWriteDescriptorSet set1_write = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set1,
		.dstBinding = 0, .descriptorCount = 2, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
		.pBufferInfo = ubo_info[1] };
	vkUpdateDescriptorSets(dev, 1, &set1_write, 0, NULL);
	VkWriteDescriptorSet set0_write = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 0,
		.descriptorCount = 2, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = ubo_info[0] };

	VkImageCreateInfo ici2 = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
	VkImage img;
	CK(vkCreateImage(dev, &ici2, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	CK(vkBindImageMemory(dev, img, alloc(mr, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0));
	VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &vci, NULL, &view));
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkDeviceMemory bm = alloc(mr, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	CK(vkBindBufferMemory(dev, buf, bm, 0));
	uint8_t *px;
	CK(vkMapMemory(dev, bm, 0, VK_WHOLE_SIZE, 0, (void **)&px));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));

	/* Draw arguments for the firstVertex / vertexOffset / indirect cases (voff.vert: vertices 1..6).
	 * Indirect buffer: VkDrawIndirectCommand at 0, VkDrawIndexedIndirectCommand at 64.
	 * Index buffer (uint16): two junk indices, then 0..5 (firstIndex = 2, vertexOffset = 1). */
	/* Vertex buffer (vattr.vert): v.vert's six positions, 16 bytes per vertex, padding = junk. */
	enum draw_mode { DRAW_DIRECT, DRAW_FIRST_VERTEX, DRAW_INDIRECT, DRAW_INDEXED_INDIRECT, DRAW_STATIC_STRIDE,
	                 DRAW_DYNAMIC_STRIDE, DRAW_INSTANCED, DRAW_DYNAMIC_FAN, DRAW_SSCALED16, DRAW_SNORM16, DRAW_SNORM8,
	                 DRAW_HIGH_BINDINGS, DRAW_BINDINGS_0_10, DRAW_BINDINGS_0_15, DRAW_BINDING_30, DRAW_WIREFRAME };
	static const uint32_t bindings_0_7[] = { 0, 1, 2, 3, 4, 5, 6, 7 }, bindings_0_10[] = { 0, 10 },
		bindings_0_15[] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, bindings_30[] = { 30 };
	VkBufferCreateInfo argbci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 128,
		.usage = VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT };
	VkBuffer indirect_buf, index_buf, vertex_buf, fmt_buf;
	CK(vkCreateBuffer(dev, &argbci, NULL, &indirect_buf));
	CK(vkCreateBuffer(dev, &argbci, NULL, &index_buf));
	CK(vkCreateBuffer(dev, &argbci, NULL, &vertex_buf));
	VkBufferCreateInfo fmtbci = argbci;
	fmtbci.size = 256;
	CK(vkCreateBuffer(dev, &fmtbci, NULL, &fmt_buf));
	VkBuffer arg_bufs[4] = { indirect_buf, index_buf, vertex_buf, fmt_buf };
	void *arg_maps[4];
	for (int k = 0; k < 4; k++) {
		VkMemoryRequirements amr;
		vkGetBufferMemoryRequirements(dev, arg_bufs[k], &amr);
		VkDeviceMemory am = alloc(amr, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
		CK(vkBindBufferMemory(dev, arg_bufs[k], am, 0));
		CK(vkMapMemory(dev, am, 0, VK_WHOLE_SIZE, 0, &arg_maps[k]));
	}
	*(VkDrawIndirectCommand *)arg_maps[0] = (VkDrawIndirectCommand){ 6, 1, 1, 0 };
	*(VkDrawIndexedIndirectCommand *)((char *)arg_maps[0] + 64) = (VkDrawIndexedIndirectCommand){ 6, 1, 2, 1, 0 };
	const uint16_t indices[8] = { 7, 7, 0, 1, 2, 3, 4, 5 };
	memcpy(arg_maps[1], indices, sizeof(indices));
	const float vertices[6][4] = { { -1, -1, 9, 9 }, { 0, -1, 9, 9 }, { -1, 1, 9, 9 },
	                               { 0, -1, 9, 9 }, { 1, -1, 9, 9 }, { 0, 1, 9, 9 } };
	memcpy(arg_maps[2], vertices, sizeof(vertices));
	/* Per-instance offsets for DRAW_INSTANCED, after the vertices: instance 0 at (0, 0), instance 1 at
	 * (1, 0), then junk that a per-vertex fetch of vertex 2 would read. */
	const float instance_offsets[3][2] = { { 0, 0 }, { 1, 0 }, { -9, -9 } };
	memcpy((char *)arg_maps[2] + 96, instance_offsets, sizeof(instance_offsets));
	/* Format buffer: v.vert's six positions, 8 bytes per vertex: position at 0, (0, 128, 0, 255) at 4.
	 * Offset 0: R16G16_SSCALED (-1/0/1); offset 48: R16G16_SNORM (+-32767); offset 96: R8G8_SNORM (+-127). */
	{
		static const int p[6][2] = { { -1, -1 }, { 0, -1 }, { -1, 1 }, { 0, -1 }, { 1, -1 }, { 0, 1 } };
		uint8_t *fb = arg_maps[3];
		for (int v = 0; v < 6; v++) {
			int16_t s16[2] = { (int16_t)p[v][0], (int16_t)p[v][1] };
			int16_t n16[2] = { (int16_t)(p[v][0] * 32767), (int16_t)(p[v][1] * 32767) };
			memcpy(fb + v * 8, s16, 4);
			memcpy(fb + 48 + v * 8, n16, 4);
			const uint8_t c[4] = { 0, 128, 0, 255 };
			int8_t n8[2] = { (int8_t)(p[v][0] * 127), (int8_t)(p[v][1] * 127) };
			memcpy(fb + 96 + v * 8, n8, 2);
			memcpy(fb + v * 8 + 4, c, 4);
			memcpy(fb + 48 + v * 8 + 4, c, 4);
			memcpy(fb + 96 + v * 8 + 4, c, 4);
		}
	}

	struct {
		const char *vs, *gs, *fs;
		VkPrimitiveTopology topology;
		uint32_t vertex_count;
		int px[2][2];       /* a pixel inside primitive 0 and one inside primitive 1 */
		uint8_t want[2][4]; /* expected RGBA there */
		int null_pipeline;
		int known_limitation;
		int draw_mode;      /* see enum draw_mode */
	} tests[] = {
		{ "v.vert.spv", NULL, "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_DIRECT },
		{ "v.vert.spv", NULL, "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 4 }, { 10, 2 } },
		  { { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }, 0, 0, DRAW_WIREFRAME },
		{ "v.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "strip.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 4,
		  { { 2, 2 }, { 6, 13 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "ubo.vert.spv", NULL, "ubo.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 0, 255, 128, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "ubo.vert.spv", "zink_passthrough.geom.spv", "ubo.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 128, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "ubo.vert.spv", "zink_passthrough.geom.spv", "ubo.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 128, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_HIGH_BINDINGS },
		{ "ubo.vert.spv", "zink_passthrough.geom.spv", "ubo.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 128, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_BINDINGS_0_10 },
		{ "ubo.vert.spv", "zink_passthrough.geom.spv", "ubo.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 128, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_BINDINGS_0_15 },
		{ "ubo.vert.spv", "zink_passthrough.geom.spv", "ubo.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 128, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_BINDING_30 },
		{ "ubo.vert.spv", NULL, "ubo.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 128, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_BINDING_30 },
		{ "v.vert.spv", "zink_primid2.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "lines.vert.spv", "zink_lines.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_LINE_LIST, 4,
		  { { 4, 4 }, { 12, 4 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ NULL, NULL, NULL, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }, 1, 0, DRAW_DIRECT },
		{ "v.vert.spv", "prim.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "v.vert.spv", "glin.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_DIRECT },
		{ "v.vert.spv", "ghelpers.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_DIRECT },
		{ "vinactive.vert.spv", "glin.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_STATIC_STRIDE },
		{ "vduplicate.vert.spv", "glin.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_STATIC_STRIDE },
		{ "v.vert.spv", "garr.geom.spv", "farr.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6, { { 2, 2 }, { 10, 2 } },
		  { { 128, 255, 128, 255 }, { 128, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "voff.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_FIRST_VERTEX },
		{ "voff.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_INDIRECT },
		{ "voff.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_INDEXED_INDIRECT },
		{ "voff.vert.spv", NULL, "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_INDEXED_INDIRECT },
		{ "vattr.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_STATIC_STRIDE },
		{ "vattr.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DYNAMIC_STRIDE },
		{ "vattr.vert.spv", NULL, "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_DYNAMIC_STRIDE },
		{ "vinst.vert.spv", "zink_passthrough.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 3,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_INSTANCED },
		{ "vinst.vert.spv", NULL, "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 3,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_INSTANCED },
		{ "ladj.vert.spv", "ladj.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_LINE_LIST_WITH_ADJACENCY, 4,
		  { { 2, 2 }, { 6, 13 } }, { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_DIRECT },
		{ "tsadj.vert.spv", "tsadj.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP_WITH_ADJACENCY, 8,
		  { { 2, 2 }, { 6, 13 } }, { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_DIRECT },
		{ "ladj.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, 4,
		  { { 2, 2 }, { 2, 13 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DIRECT },
		{ "ladj.vert.spv", "zink_passthrough.geom.spv", "fprim.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 4,
		  { { 2, 2 }, { 2, 13 } }, { { 0, 255, 64, 255 }, { 0, 255, 128, 255 } }, 0, 0, DRAW_DYNAMIC_FAN },
		{ "vfmt.vert.spv", "zink_passthrough.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 128, 0, 255 }, { 0, 128, 0, 255 } }, 0, 0, DRAW_SSCALED16 },
		{ "vfmt.vert.spv", "zink_passthrough.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 128, 0, 255 }, { 0, 128, 0, 255 } }, 0, 0, DRAW_SNORM16 },
		{ "vfmt.vert.spv", "zink_passthrough.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 128, 0, 255 }, { 0, 128, 0, 255 } }, 0, 0, DRAW_SNORM8 },
		{ "sentry-41-payload.vert.spv", "sentry-41-payload.geom.spv", "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_POINT_LIST, 1,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 255, 0, 255 }, { 0, 255, 0, 255 } }, 0, 0, DRAW_DIRECT },
		{ "vfmt.vert.spv", NULL, "f.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, 6,
		  { { 2, 2 }, { 10, 2 } }, { { 0, 128, 0, 255 }, { 0, 128, 0, 255 } }, 0, 0, DRAW_SSCALED16 },
	};
	int fails = 0;
	for (size_t t = 0; t < sizeof(tests) / sizeof(tests[0]); t++) {
		const char *verdict_fail = tests[t].known_limitation ? "KNOWN" : "FAIL";
		VkPipeline p = VK_NULL_HANDLE;
		if (tests[t].null_pipeline && !moltenvk) {
			printf("SKIP draw + dispatch with VK_NULL_HANDLE pipelines bound (%s: virglrenderer drops them)\n",
			       drv.driverName);
			continue;
		}
		if (!tests[t].null_pipeline) {
			vertex_input = tests[t].draw_mode == DRAW_STATIC_STRIDE ? VI_STATIC_STRIDE :
			               tests[t].draw_mode == DRAW_DYNAMIC_STRIDE ? VI_DYNAMIC_STRIDE :
			               tests[t].draw_mode == DRAW_INSTANCED ? VI_INSTANCE : VI_NONE;
			dynamic_topology = tests[t].draw_mode == DRAW_DYNAMIC_FAN;
			polygon_mode = tests[t].draw_mode == DRAW_WIREFRAME ? VK_POLYGON_MODE_LINE : VK_POLYGON_MODE_FILL;
			if (tests[t].draw_mode == DRAW_SSCALED16) vertex_input = VI_SSCALED16;
			if (tests[t].draw_mode == DRAW_SNORM16) vertex_input = VI_SNORM16;
			if (tests[t].draw_mode == DRAW_SNORM8) vertex_input = VI_SNORM8;
			if (tests[t].draw_mode >= DRAW_HIGH_BINDINGS && tests[t].draw_mode <= DRAW_BINDING_30) {
				vertex_input = VI_HIGH_BINDINGS;
				high_bindings = tests[t].draw_mode == DRAW_HIGH_BINDINGS ? bindings_0_7 :
				                tests[t].draw_mode == DRAW_BINDINGS_0_10 ? bindings_0_10 :
				                tests[t].draw_mode == DRAW_BINDINGS_0_15 ? bindings_0_15 : bindings_30;
				high_binding_count = tests[t].draw_mode == DRAW_HIGH_BINDINGS ? 8 :
				                     tests[t].draw_mode == DRAW_BINDINGS_0_10 ? 2 :
				                     tests[t].draw_mode == DRAW_BINDINGS_0_15 ? 16 : 1;
			}
			p = graphics(tests[t].vs, tests[t].gs, tests[t].fs, tests[t].topology, layout);
			if (!p) {
				printf("%-4s render %s + %s + %s: pipeline creation failed\n", verdict_fail, tests[t].vs,
				       tests[t].gs ? tests[t].gs : "-", tests[t].fs);
				fails += !tests[t].known_limitation;
				continue;
			}
		}
		CK(vkResetCommandBuffer(cmd, 0));
		VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkBeginCommandBuffer(cmd, &bi));
		VkImageMemoryBarrier b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
			.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
			.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
			.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
		                     0, NULL, 0, NULL, 1, &b);
		VkRenderingAttachmentInfo ca = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
			.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = VK_ATTACHMENT_STORE_OP_STORE };
		VkRenderingInfo rinfo = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } },
			.layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &ca };
		vkCmdBeginRendering(cmd, &rinfo);
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
		if (p) {
			int idx = 1;
			vkCmdPushConstants(cmd, layout, all, 0, sizeof(idx), &idx);
			push_descriptor_set(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set0_write);
			vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 1, 1, &set1, 0, NULL);
		}
		switch (tests[t].draw_mode) {
		case DRAW_DIRECT:
		case DRAW_WIREFRAME:
			vkCmdDraw(cmd, tests[t].vertex_count, 1, 0, 0);
			break;
		case DRAW_FIRST_VERTEX:
			vkCmdDraw(cmd, tests[t].vertex_count, 1, 1, 0);
			break;
		case DRAW_INDIRECT:
			vkCmdDrawIndirect(cmd, indirect_buf, 0, 1, sizeof(VkDrawIndirectCommand));
			break;
		case DRAW_INDEXED_INDIRECT:
			vkCmdBindIndexBuffer(cmd, index_buf, 0, VK_INDEX_TYPE_UINT16);
			vkCmdDrawIndexedIndirect(cmd, indirect_buf, 64, 1, sizeof(VkDrawIndexedIndirectCommand));
			break;
		case DRAW_STATIC_STRIDE: {
			VkDeviceSize off = 0;
			vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buf, &off);
			vkCmdDraw(cmd, tests[t].vertex_count, 1, 0, 0);
			break;
		}
		case DRAW_DYNAMIC_STRIDE: {
			VkDeviceSize off = 0, stride = 16;
			vkCmdBindVertexBuffers2(cmd, 0, 1, &vertex_buf, &off, NULL, &stride);
			vkCmdDraw(cmd, tests[t].vertex_count, 1, 0, 0);
			break;
		}
		case DRAW_SSCALED16:
		case DRAW_SNORM16:
		case DRAW_SNORM8: {
			VkDeviceSize off = tests[t].draw_mode == DRAW_SNORM16 ? 48 : tests[t].draw_mode == DRAW_SNORM8 ? 96 : 0;
			vkCmdBindVertexBuffers(cmd, 0, 1, &fmt_buf, &off);
			vkCmdDraw(cmd, tests[t].vertex_count, 1, 0, 0);
			break;
		}
		case DRAW_HIGH_BINDINGS:
		case DRAW_BINDINGS_0_10:
		case DRAW_BINDINGS_0_15:
		case DRAW_BINDING_30:
			vkCmdDraw(cmd, tests[t].vertex_count, 1, 0, 0);
			break;
		case DRAW_DYNAMIC_FAN:
			vkCmdSetPrimitiveTopology(cmd, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN);
			vkCmdDraw(cmd, tests[t].vertex_count, 1, 0, 0);
			break;
		case DRAW_INSTANCED: {
			VkBuffer bufs[2] = { vertex_buf, vertex_buf };
			VkDeviceSize offs[2] = { 0, 96 };
			vkCmdBindVertexBuffers(cmd, 0, 2, bufs, offs);
			vkCmdDraw(cmd, tests[t].vertex_count, 2, 0, 0);
			break;
		}
		}
		vkCmdEndRendering(cmd);
		if (tests[t].null_pipeline) {
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, VK_NULL_HANDLE);
			vkCmdDispatch(cmd, 1, 1, 1);
		}
		b.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
		b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
		b.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
		b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0,
		                     NULL, 0, NULL, 1, &b);
		VkBufferImageCopy rc = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
		vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &rc);
		CK(vkEndCommandBuffer(cmd));
		VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));

		int ok = 1;
		for (int k = 0; k < 2; k++) {
			const uint8_t *got = px + (tests[t].px[k][1] * W + tests[t].px[k][0]) * 4;
			for (int c = 0; c < 4; c++)
				if (abs((int)got[c] - (int)tests[t].want[k][c]) > 2)
					ok = 0;
			printf("     primitive %d pixel: %3u %3u %3u %3u (want %3u %3u %3u %3u)\n", k, got[0], got[1], got[2],
			       got[3], tests[t].want[k][0], tests[t].want[k][1], tests[t].want[k][2], tests[t].want[k][3]);
		}
		if (tests[t].draw_mode == DRAW_WIREFRAME) {
			/* Filled, the two triangles cover half of the 16x16 target (128 pixels). */
			int lit = 0;
			for (int i = 0; i < W * H; i++)
				lit += px[i * 4 + 1] > 128;
			if (lit < 8 || lit >= 100)
				ok = 0;
			printf("     %d edge pixels lit (want 8..99; 128 when filled)\n", lit);
		}
		if (tests[t].null_pipeline)
			printf("%-4s draw + dispatch with VK_NULL_HANDLE pipelines bound: no crash, nothing drawn\n",
			       ok ? "OK" : "FAIL");
		else
			printf("%-4s render %s + %s + %s (%s, %s)\n", ok ? "OK" : verdict_fail, tests[t].vs,
			       tests[t].gs ? tests[t].gs : "-", tests[t].fs,
			       tests[t].topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP ? "strip" :
			       tests[t].topology == VK_PRIMITIVE_TOPOLOGY_LINE_LIST_WITH_ADJACENCY ? "line list with adjacency" :
			       tests[t].topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP_WITH_ADJACENCY ? "triangle strip with adjacency" :
			       tests[t].topology == VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN ? "fan" : "list",
			       (const char *[]){ "vkCmdDraw", "vkCmdDraw firstVertex=1", "vkCmdDrawIndirect firstVertex=1",
			                         "vkCmdDrawIndexedIndirect firstIndex=2 vertexOffset=1",
			                         "vertex buffer, static stride 16",
			                         "vertex buffer, pipeline stride 0 + dynamic stride 16",
			                         "2 instances, per-instance offset attribute",
			                         "pipeline TRIANGLE_LIST + dynamic TRIANGLE_FAN",
			                         "R16G16_SSCALED positions, R8G8B8A8_UNORM colors",
			                         "R16G16_SNORM positions, R8G8B8A8_UNORM colors",
			                         "R8G8_SNORM positions, R8G8B8A8_UNORM colors",
			                         "vertex bindings 0..7 declared (implicit buffers moved down)",
			                         "vertex bindings {0, 10} declared", "vertex bindings 0..15 declared",
			                         "vertex binding 30 declared", "polygonMode LINE" }[tests[t].draw_mode]);
		if (!tests[t].known_limitation)
			fails += !ok;
		if (p)
			vkDestroyPipeline(dev, p, NULL);
	}

	/* Combined image samplers named like MSL types ("sampler", "array"): pipeline must compile. */
	VkDescriptorSetLayoutBinding tex_bindings[2] = {
		{ 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL },
		{ 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2, VK_SHADER_STAGE_FRAGMENT_BIT, NULL },
	};
	VkDescriptorSetLayoutCreateInfo tex_dslci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 2, .pBindings = tex_bindings };
	VkDescriptorSetLayout tex_dsl;
	CK(vkCreateDescriptorSetLayout(dev, &tex_dslci, NULL, &tex_dsl));
	VkPipelineLayoutCreateInfo tex_plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &tex_dsl };
	VkPipelineLayout tex_layout;
	CK(vkCreatePipelineLayout(dev, &tex_plci, NULL, &tex_layout));
	VkPipeline names = graphics("v.vert.spv", NULL, "msl_type_names.frag.spv", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	                            tex_layout);
	fails += !names;
	if (names)
		vkDestroyPipeline(dev, names, NULL);

	vkDeviceWaitIdle(dev);
	return fails != 0;
}
