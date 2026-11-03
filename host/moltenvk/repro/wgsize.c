/*
 * Workgroup size of compute shaders with OpExecutionModeId LocalSizeId and zero-initialized workgroup memory
 * (OpConstantNull initializers, VK_KHR_zero_initialize_workgroup_memory): every DXVK compute shader with groupshared
 * memory since its new shader compiler (Proton 11, v2.7.1-498). SPIRV-Cross synthesizes a gl_WorkGroupSize constant for
 * the zero initialization and sets SPIREntryPoint::workgroup_size.constant; MoltenVK's getWorkgroupSize() then reads
 * workgroup_size.x/y/z, which are 0 for LocalSizeId, and dispatches 1x1x1 threadgroups (Rogue Trader's tile min/max-Z:
 * only the first pixel of each tile).
 *
 * Each 8x8 workgroup writes index+1 per invocation and the count of a zero-initialized shared counter; 4 workgroups.
 * Each case runs with direct and indirect dispatch (STEAMAC-G diagnostic recording must not change either).
 * The .spvasm files in shaders/wgsize (assembled by run.sh, SPIR-V 1.6):
 *   wg_localsize_init.spv        LocalSize 8 8 1 + initializer (control)
 *   wg_localsizeid_noinit.spv    LocalSizeId, no initializer (control: threadgroup size only; its counter starts
 *                                from whatever the threadgroup memory held, garbage on M1)
 *   wg_localsizeid_init.spv      LocalSizeId + initializer (DXVK's pattern)
 *   wg_localsizeid_spec_init.spv LocalSizeId with specialization constant 0 (default 2, specialized to 8) + initializer
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)
#define GROUPS 4

static VkDevice dev;
static const char *dir;

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

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <spv dir>\n", argv[0]); return 2; }
	dir = argv[1];
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .shaderZeroInitializeWorkgroupMemory = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13 };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &b };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	const VkDeviceSize size = GROUPS * 65 * 4;
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size + sizeof(VkDispatchIndirectCommand),
		.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t t = 0;
	const VkMemoryPropertyFlags hv = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	while (!(mr.memoryTypeBits & (1u << t)) || (mp.memoryTypes[t].propertyFlags & hv) != hv) t++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	uint32_t *map;
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));

	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet set;
	CK(vkAllocateDescriptorSets(dev, &dsai, &set));
	VkDescriptorBufferInfo dbi = { buf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

	static const char *spv[] = { "wg_localsize_init.spv", "wg_localsizeid_noinit.spv", "wg_localsizeid_init.spv",
		"wg_localsizeid_spec_init.spv" };
	int fails = 0;
	for (size_t case_id = 0; case_id < 2 * sizeof(spv) / sizeof(spv[0]); case_id++) {
		size_t i = case_id / 2;
		int indirect = case_id % 2;
		uint32_t eight = 8;
		VkSpecializationMapEntry me = { 0, 0, 4 };
		VkSpecializationInfo si8 = { 1, &me, 4, &eight };
		VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
			.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = module(spv[i]),
			           .pName = "main", .pSpecializationInfo = strstr(spv[i], "_spec_") ? &si8 : NULL }, .layout = layout };
		VkPipeline p;
		CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p));
		memset(map, 0, size);
		VkDispatchIndirectCommand args = {GROUPS, 1, 1};
		memcpy((char *)map + size, &args, sizeof(args));
		VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
		VkCommandBuffer cmd;
		CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
		VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkBeginCommandBuffer(cmd, &cbbi));
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
		if (indirect)
			vkCmdDispatchIndirect(cmd, buf, size);
		else
			vkCmdDispatch(cmd, GROUPS, 1, 1);
		VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
		CK(vkEndCommandBuffer(cmd));
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));
		int ran = 0, bad_count = 0;
		for (int g = 0; g < GROUPS; g++) {
			for (int k = 0; k < 64; k++) ran += map[g * 65 + k] == (uint32_t)k + 1;
			bad_count += map[g * 65 + 64] != 64;
		}
		/* Without an initializer the shared counter starts undefined: only the invocations are checked. */
		const int initialized = !strstr(spv[i], "_noinit");
		int ok = ran == GROUPS * 64 && (!initialized || !bad_count);
		printf("%-4s %s (%s): %d of %d invocations ran, shared count per workgroup %u (%s)\n", ok ? "OK" : "FAIL", spv[i],
		       indirect ? "indirect" : "direct", ran, GROUPS * 64, map[64], initialized ? "want 64" : "undefined, no initializer");
		fails += !ok;
	}
	if (fails) { printf("wgsize: %d failure(s)\n", fails); return 1; }
	return 0;
}
