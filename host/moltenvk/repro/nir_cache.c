/* STEAMAC-6M/6K: a bad precompiled NIR dereference must be a cache miss,
 * not a host crash in glsl_get_struct_field. This intentionally corrupts Mesa's
 * private VkPipelineCache payload (never valid Vulkan input) to exercise driver
 * robustness. The original reports contain no shader/cache blob: this does not
 * claim their corruption source is known. Keep the unmodified payload control.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r = (x); if (r != VK_SUCCESS) { fprintf(stderr, "FAIL %s: %d at %d\n", #x, r, __LINE__); exit(1); } } while (0)
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL %s at %d\n", #x, __LINE__); exit(1); } } while (0)
static uint32_t u32(const void *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t u64(const void *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void put32(void *p, uint32_t v) { memcpy(p, &v, 4); }

int main(int argc, char **argv)
{
	REQUIRE(argc == 3);
	setvbuf(stdout, NULL, _IONBF, 0);
	unsigned mode = (unsigned)strtoul(argv[2], NULL, 10);
	REQUIRE(mode <= 6);
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "nir_cache regression", .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CK(vkCreateInstance(&ici, NULL, &instance));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(instance, &n, &pd));
	REQUIRE(n == 1);
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);
	FILE *f = fopen(argv[1], "rb");
	REQUIRE(f);
	REQUIRE(!fseek(f, 0, SEEK_END));
	long length = ftell(f);
	REQUIRE(length > 0 && !(length % 4));
	rewind(f);
	uint32_t *code = malloc((size_t)length);
	REQUIRE(code && fread(code, 1, (size_t)length, f) == (size_t)length);
	fclose(f);
	VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = (size_t)length, .pCode = code };
	VkShaderModule module;
	CK(vkCreateShaderModule(dev, &smci, NULL, &module));
	free(code);
	VkDescriptorSetLayoutBinding binding = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo slci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &binding };
	VkDescriptorSetLayout sl;
	CK(vkCreateDescriptorSetLayout(dev, &slci, NULL, &sl));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &sl };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineCacheCreateInfo pcci = { VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO };
	VkPipelineCache cache;
	CK(vkCreatePipelineCache(dev, &pcci, NULL, &cache));
	VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = module, .pName = "main" }, .layout = layout };
	VkPipeline pipeline;
	CK(vkCreateComputePipelines(dev, cache, 1, &cpci, NULL, &pipeline));
	size_t size = 0;
	CK(vkGetPipelineCacheData(dev, cache, &size, NULL));
	uint8_t *data = malloc(size);
	REQUIRE(data);
	CK(vkGetPipelineCacheData(dev, cache, &size, data));
	vkDestroyPipeline(dev, pipeline, NULL);
	vkDestroyPipelineCache(dev, cache, NULL);

	/* Mesa cache: Vulkan header, count, {type,key size,data size,key,pad,data}.
	 * Keep only precompiled NIR, not translated MSL. Recognize both the shipped
	 * format and the integrity format so the same corruption fails before the
	 * patch. 0076 adds a version word, alignment padding and a 32-byte BLAKE3.
	 */
	size_t header = u32(data), off = header + 4, entry = 0, entry_end = 0, payload = 0;
	size_t nir_offset = 0, size_offset = 0;
	REQUIRE(header == 32 && size >= off);
	uint32_t count = u32(data + header);
	for (uint32_t i = 0; i < count; i++) {
		REQUIRE(off + 12 <= size);
		size_t begin = off;
		uint32_t keys = u32(data + off + 4), bytes = u32(data + off + 8);
		off = (off + 12 + keys + 7) & ~(size_t)7;
		REQUIRE(off <= size && bytes <= size - off);
		bool integrity = bytes >= 80 && u32(data + off) == 0x4e495201u;
		size_t prefix = integrity ? 80 : 40;
		size_t stage_offset = integrity ? 4 : 0;
		size_t length_offset = integrity ? 40 : 32;
		if (bytes > prefix && u32(data + off + stage_offset) == 5 &&
		    u32(data + off + stage_offset + 28) == 0 &&
		    u64(data + off + length_offset) == bytes - prefix) {
			REQUIRE(!entry);
			entry = begin; entry_end = off + bytes; payload = off;
			nir_offset = prefix; size_offset = length_offset;
		}
		off += bytes;
	}
	REQUIRE(entry && payload);
	unsigned matches = 0;
	for (size_t pos = payload + nir_offset; pos + 12 <= entry_end; pos += 4) {
		/* NIR's packed struct deref: instruction 1, deref kind 4, with a
		 * 1x64-bit definition. This shader selects struct member 1. */
		if (u32(data + pos) == 0xd0000041 && u32(data + pos + 8) == 1) {
			matches++;
			if (mode == 1) put32(data + pos + 4, 0); /* variable, not SSA def */
			if (mode == 2) put32(data + pos + 4, 0x003ffffc); /* absent object */
			if (mode == 3) put32(data + pos + 8, UINT32_MAX); /* struct member */
		}
	}
	REQUIRE(matches == 1);
	if (mode >= 4) {
		REQUIRE(nir_offset == 80);
		if (mode == 4)
			data[payload + 48] ^= 1; /* checksum, not NIR */
		if (mode == 5) {
			/* A current-format entry without its hash is a miss. */
			memmove(data + payload + 48, data + payload + 80, entry_end - payload - 80);
			entry_end -= 32;
		}
		if (mode == 6) {
			/* Old entries must not become trusted by merely using a new UUID. */
			uint64_t nir_bytes = u64(data + payload + size_offset);
			memmove(data + payload, data + payload + 4, 32);
			memcpy(data + payload + 32, &nir_bytes, 8);
			memmove(data + payload + 40, data + payload + 80, (size_t)nir_bytes);
			entry_end -= 40;
		}
		put32(data + entry + 8, (uint32_t)(entry_end - payload));
	}
	size_t kept = entry_end - entry;
	/* The first entry starts at offset 36; retain original alignment by moving
	 * the selected entry to that same offset (all keys are 32 bytes). */
	memmove(data + header + 4, data + entry, kept);
	put32(data + header, 1);
	pcci.initialDataSize = header + 4 + kept;
	pcci.pInitialData = data;
	printf("nir_cache %u: loading %s precompiled NIR (%zu bytes)\n",
	       mode, mode ? "corrupted" : "unmodified", pcci.initialDataSize);
	CK(vkCreatePipelineCache(dev, &pcci, NULL, &cache));
	free(data);
	CK(vkCreateComputePipelines(dev, cache, 1, &cpci, NULL, &pipeline));
	/* A second lookup must not retry the rejected entry or repeat its log. */
	vkDestroyPipeline(dev, pipeline, NULL);
	CK(vkCreateComputePipelines(dev, cache, 1, &cpci, NULL, &pipeline));

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 8, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
	VkBuffer buffer;
	CK(vkCreateBuffer(dev, &bci, NULL, &buffer));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, buffer, &req);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t mt;
	for (mt = 0; mt < mp.memoryTypeCount; mt++)
		if ((req.memoryTypeBits & (1u << mt)) && (mp.memoryTypes[mt].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) break;
	REQUIRE(mt < mp.memoryTypeCount);
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = mt };
	VkDeviceMemory memory;
	CK(vkAllocateMemory(dev, &mai, NULL, &memory));
	CK(vkBindBufferMemory(dev, buffer, memory, 0));
	uint32_t *mapped;
	CK(vkMapMemory(dev, memory, 0, VK_WHOLE_SIZE, 0, (void **)&mapped));
	mapped[0] = 5; mapped[1] = 0;
	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool pool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &pool));
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &sl };
	VkDescriptorSet set;
	CK(vkAllocateDescriptorSets(dev, &dsai, &set));
	VkDescriptorBufferInfo bi = { buffer, 0, 8 };
	VkWriteDescriptorSet wr = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi };
	vkUpdateDescriptorSets(dev, 1, &wr, 0, NULL);
	VkCommandPoolCreateInfo ci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool commands;
	CK(vkCreateCommandPool(dev, &ci, NULL, &commands));
	VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = commands, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &ai, &cmd));
	VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &begin));
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
	vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
	vkCmdDispatch(cmd, 1, 1, 1);
	VkMemoryBarrier barrier = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	REQUIRE(mapped[1] == 42);
	printf("OK nir_cache %u: %s; dispatch readback 42\n", mode, mode ? "bad precompiled NIR rejected and SPIR-V recompiled" : "valid precompiled NIR retained");
	vkDestroyCommandPool(dev, commands, NULL);
	vkDestroyDescriptorPool(dev, pool, NULL);
	vkUnmapMemory(dev, memory);
	vkDestroyBuffer(dev, buffer, NULL);
	vkFreeMemory(dev, memory, NULL);
	vkDestroyPipeline(dev, pipeline, NULL);
	vkDestroyPipelineCache(dev, cache, NULL);
	vkDestroyPipelineLayout(dev, layout, NULL);
	vkDestroyDescriptorSetLayout(dev, sl, NULL);
	vkDestroyShaderModule(dev, module, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(instance, NULL);
	return 0;
}
