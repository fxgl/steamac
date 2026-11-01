/*
 * Atomics on vector components behind buffer device addresses. The MSL took the address of a vector
 * element: 'atomic_fetch_add_explicit((device atomic_uint*)&region_buffer->region_count[0u], ...)' ("address
 * of vector element requested"). vkd3d-proton creates such a pipeline (cs_emit_nv_memory_decompression_regions)
 * on every D3D12 device creation, so D3D12CreateDevice failed.
 *
 * bda_vec_atomic.comp, 8 workgroups x 32 invocations, pointers in push constants:
 *   scalar-layout uvec3 count (pointer value in a function variable, vkd3d's pattern): atomicAdd on .x hands
 *   out slots 0..255, each slot gets id + 1; atomicMax on .z; .y and the following uint stay untouched
 *   std430 uvec4 counters: atomicAdd on [id & 3] (dynamic component); ivec2: atomicMin on .y, .x untouched
 *
 * bda_uvec2_atomic.spvasm, 8 workgroups x 32 invocations: an atomic through an address held as a uvec2,
 * bitcast straight to a uint pointer in a helper (dxil-spirv's RobustPhysicalAtomicCounter, Ratchet & Clank:
 * Rift Apart, steamac #49). The MSL took the address of the cast, an rvalue ('cannot take the address of an
 * rvalue of type 'device uint *''): invocations 0..127 count and get 1000..1127 once each, 128..255 pass a
 * zero address and get 0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define INVOCATIONS 256u
#define ALIGNED_OFFSET 2048u
#define UVEC2_COUNTER_OFFSET 2560u
#define UVEC2_RESULTS_OFFSET 3072u

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
	VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.bufferDeviceAddress = VK_TRUE, .scalarBlockLayout = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12, .features = { .shaderInt64 = VK_TRUE } };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 4096,
		.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT };
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
	VkMemoryAllocateFlagsInfo mafi = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, .flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT };
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &mafi, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	uint8_t *map;
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));
	VkBufferDeviceAddressInfo bdai = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, .buffer = buf };
	VkDeviceAddress va = vkGetBufferDeviceAddress(dev, &bdai);

	/* packed_t at 0: uvec3 count, uint reserved, uint slots[]; aligned_t at ALIGNED_OFFSET: uvec4 counters, ivec2 low */
	uint32_t *packed = (uint32_t *)map;
	uint32_t *counters = (uint32_t *)(map + ALIGNED_OFFSET);
	int32_t *low = (int32_t *)(map + ALIGNED_OFFSET + 16);
	memset(map, 0, 4096);
	packed[1] = 77;
	packed[3] = 0x1234;
	low[0] = 11;
	uint32_t *u2_counter = (uint32_t *)(map + UVEC2_COUNTER_OFFSET);
	uint32_t *u2_results = (uint32_t *)(map + UVEC2_RESULTS_OFFSET);
	for (uint32_t i = 0; i < INVOCATIONS; i++)
		u2_results[i] = 0xdeadbeef;

	VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 16 };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pushConstantRangeCount = 1,
		.pPushConstantRanges = &pcr };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = module(argv[1], "bda_vec_atomic.comp.spv"), .pName = "main" }, .layout = layout };
	VkPipeline p, p2;
	VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
	printf("%-4s create bda_vec_atomic.comp.spv (VkResult %d)\n", r == VK_SUCCESS ? "OK" : "FAIL", r);
	if (r) return 1;
	ci.stage.module = module(argv[1], "bda_uvec2_atomic.spv");
	r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p2);
	printf("%-4s create bda_uvec2_atomic.spv (VkResult %d)\n", r == VK_SUCCESS ? "OK" : "FAIL", r);
	if (r) return 1;

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &cbbi));
	uint64_t pc[2] = { va, va + ALIGNED_OFFSET };
	vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), pc);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
	vkCmdDispatch(cmd, INVOCATIONS / 32, 1, 1);
	/* uvec2 addresses: { counter, results } as two 32-bit halves each */
	uint64_t pc2[2] = { va + UVEC2_COUNTER_OFFSET, va + UVEC2_RESULTS_OFFSET };
	vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc2), pc2);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p2);
	vkCmdDispatch(cmd, INVOCATIONS / 32, 1, 1);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo sinfo = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &sinfo, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));

	int fails = 0;
#define EXPECT(name, got, want) do { \
		long long g_ = (got), w_ = (want); \
		printf("%-4s %s = %lld (expected %lld)\n", g_ == w_ ? "OK" : "FAIL", name, g_, w_); \
		fails += g_ != w_; \
	} while (0)
	EXPECT("count.x", packed[0], INVOCATIONS);
	EXPECT("count.y (untouched)", packed[1], 77);
	EXPECT("count.z (max)", packed[2], INVOCATIONS - 1);
	EXPECT("reserved (untouched)", packed[3], 0x1234);
	uint8_t seen[INVOCATIONS] = { 0 };
	uint32_t bad_slots = 0;
	for (uint32_t i = 0; i < INVOCATIONS; i++) {
		uint32_t v = packed[4 + i];
		if (v < 1 || v > INVOCATIONS || seen[v - 1]++)
			bad_slots++;
	}
	EXPECT("slots not holding each id + 1 once", bad_slots, 0);
	for (uint32_t i = 0; i < 4; i++) {
		char name[32];
		snprintf(name, sizeof(name), "counters[%u]", i);
		EXPECT(name, counters[i], INVOCATIONS / 4);
	}
	EXPECT("low.x (untouched)", low[0], 11);
	EXPECT("low.y (min)", low[1], -(int32_t)(INVOCATIONS - 1));
	EXPECT("uvec2 counter", *u2_counter, INVOCATIONS / 2);
	uint8_t seen2[INVOCATIONS / 2] = { 0 };
	uint32_t bad_counted = 0, bad_zero = 0;
	for (uint32_t i = 0; i < INVOCATIONS / 2; i++) {
		uint32_t v = u2_results[i];
		if (v < 1000 || v >= 1000 + INVOCATIONS / 2 || seen2[v - 1000]++)
			bad_counted++;
	}
	for (uint32_t i = INVOCATIONS / 2; i < INVOCATIONS; i++)
		bad_zero += u2_results[i] != 0;
	EXPECT("uvec2 results 0..127 not holding 1000..1127 once each", bad_counted, 0);
	EXPECT("uvec2 results 128..255 (zero address) not 0", bad_zero, 0);
	if (fails) { printf("device_address: %d failure(s)\n", fails); return 1; }
	return 0;
}
