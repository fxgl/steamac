/* STEAMAC-CG/CH (1.9.15, M4 Pro, Final Fantasy VII Rebirth): SIGSEGV in kk_gather_program
 * (ldrb w0, [x8] with x8 = state->ia = NULL) under vkCreateGraphicsPipelines, just after
 * "kk: mesh shader uses set 1 binding 1 ...". KosmicKrisp does not expose
 * VK_EXT_mesh_shader, but common pipeline creation accepts a mesh stage in place of a vertex
 * shader, and mesh pipelines have no input assembly state, which KosmicKrisp reads for the
 * topology.
 *
 *   mesh     mesh + fragment stages, no vertex input / input assembly state: creation must
 *            fail with a NULL pipeline; before the fix it faulted the process */
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static const uint32_t ms_spv[] = {
#include "sentry_cg.mesh.inc"
};
static const uint32_t fs_spv[] = {
#include "sentry_ah.frag.inc"
};

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
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkShaderModuleCreateInfo mci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(ms_spv), .pCode = ms_spv };
	VkShaderModule ms, fs;
	CK(vkCreateShaderModule(dev, &mci, NULL, &ms));
	mci.codeSize = sizeof(fs_spv);
	mci.pCode = fs_spv;
	CK(vkCreateShaderModule(dev, &mci, NULL, &fs));
	VkPipelineShaderStageCreateInfo stages[] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_MESH_BIT_EXT, .module = ms,
		  .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs,
		  .pName = "main" },
	};
	const VkFormat format = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo rendering = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = 1, .pColorAttachmentFormats = &format };
	VkViewport viewport = { 0, 0, 4, 4, 0, 1 };
	VkRect2D scissor = { { 0, 0 }, { 4, 4 } };
	VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo msaa = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState att = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &att };
	VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &rendering,
		.stageCount = 2, .pStages = stages, .pViewportState = &vp, .pRasterizationState = &rs,
		.pMultisampleState = &msaa, .pColorBlendState = &cb, .layout = layout };
	VkPipeline pipeline = VK_NULL_HANDLE;
	fflush(stdout);
	VkResult r = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &pipeline);
	if (r == VK_SUCCESS) {
		printf("FAIL mesh: a mesh pipeline was created on a driver without mesh shading\n");
		return 1;
	}
	if (pipeline != VK_NULL_HANDLE) {
		printf("FAIL mesh: creation returned %d with a non-NULL pipeline\n", r);
		return 1;
	}
	printf("OK mesh: creation of a mesh pipeline without input assembly state failed (%d)\n", r);
	return 0;
}
