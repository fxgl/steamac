/* STEAMAC-G 949d5c67: a long side-effecting selection ladder exceeds Metal's
 * 256 bracket depth when every `else if` gets another pair of braces.
 * Dispatch all 320 cases and the default; also exercise deep then branches,
 * nested loops, break/continue/return, value merges, and a long-ALU control.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CASES 320u
#define INVOCATIONS 384u
#define OUTPUTS (INVOCATIONS + 3)
#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static void reference(const char *mode, uint32_t expected[OUTPUTS])
{
	for (uint32_t key = 0; key < INVOCATIONS; ++key) {
		uint32_t index = key < CASES ? key : CASES;
		if (!strcmp(mode, "ladder")) {
			expected[index] += key + 1;
		} else if (!strcmp(mode, "jumps")) {
			uint32_t value = key + 1000;
			int returned = 0;
			for (uint32_t round = 0; round < 3; ++round) {
				uint32_t merged = 0;
				for (uint32_t j = 0; j < 4; ++j) {
					if (j == 1) continue;
					merged += key + j;
					if (j == 2) break;
				}
				expected[index] += merged + round;
				if ((key & 3) == 0) break;
				if ((key & 3) == 1) continue;
				if ((key & 3) == 2) {
					expected[322] += value + merged;
					returned = 1;
					break;
				}
				value += merged;
				value ^= round + 17;
			}
			if (!returned) expected[321] += value;
		} else if (!strcmp(mode, "nested")) {
			uint32_t value = key;
			uint32_t depth;
			for (depth = 0; depth < CASES; ++depth) {
				if (key < depth) { expected[320] += value; break; }
				value ^= depth + 1;
				expected[depth] += value;
			}
			/* Include the failed if's post-merge increment, if there was one. */
			for (uint32_t n = depth < CASES ? depth + 1 : CASES; n; --n) value += n;
			expected[321] += value;
		} else if (!strcmp(mode, "alu")) {
			uint32_t value = key;
			for (unsigned i = 0; i < 2048; ++i)
				value = (value ^ (value >> 13)) * 1664525u + 1013904223u;
			expected[key] = value;
		} else {
			fprintf(stderr, "FAIL unknown mode %s\n", mode);
			exit(2);
		}
	}
}

int main(int argc, char **argv)
{
	if (argc != 3) { fprintf(stderr, "usage: %s <shader.spv> <ladder|nested|jumps|alu>\n", argv[0]); return 2; }
	FILE *file = fopen(argv[1], "rb");
	if (!file) { perror(argv[1]); return 1; }
	if (fseek(file, 0, SEEK_END)) return 1;
	long size = ftell(file);
	if (size <= 0 || size % 4 || fseek(file, 0, SEEK_SET)) return 1;
	uint32_t *code = malloc((size_t)size);
	if (!code || fread(code, 1, (size_t)size, file) != (size_t)size) return 1;
	fclose(file);

	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "sentry-g-brackets",
		.apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CK(vkCreateInstance(&ici, NULL, &instance));
	uint32_t count = 1;
	VkPhysicalDevice physical;
	CK(vkEnumeratePhysicalDevices(instance, &count, &physical));
	if (!count) { fprintf(stderr, "FAIL no physical device\n"); return 1; }
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueCount = 1, .pQueuePriorities = &priority };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice device;
	CK(vkCreateDevice(physical, &dci, NULL, &device));
	VkQueue queue;
	vkGetDeviceQueue(device, 0, 0, &queue);

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = OUTPUTS * 4,
		.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
	VkBuffer buffer;
	CK(vkCreateBuffer(device, &bci, NULL, &buffer));
	VkMemoryRequirements requirements;
	vkGetBufferMemoryRequirements(device, buffer, &requirements);
	VkPhysicalDeviceMemoryProperties memory_properties;
	vkGetPhysicalDeviceMemoryProperties(physical, &memory_properties);
	uint32_t type;
	for (type = 0; type < memory_properties.memoryTypeCount; ++type) {
		VkMemoryPropertyFlags needed = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
		if ((requirements.memoryTypeBits & (1u << type)) &&
		    (memory_properties.memoryTypes[type].propertyFlags & needed) == needed) break;
	}
	if (type == memory_properties.memoryTypeCount) { fprintf(stderr, "FAIL no coherent memory\n"); return 1; }
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = requirements.size, .memoryTypeIndex = type };
	VkDeviceMemory memory;
	CK(vkAllocateMemory(device, &mai, NULL, &memory));
	CK(vkBindBufferMemory(device, buffer, memory, 0));
	uint32_t *mapped;
	CK(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, (void **)&mapped));
	memset(mapped, 0, OUTPUTS * 4);

	VkDescriptorSetLayoutBinding binding = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
	VkDescriptorSetLayoutCreateInfo slci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &binding };
	VkDescriptorSetLayout set_layout;
	CK(vkCreateDescriptorSetLayout(device, &slci, NULL, &set_layout));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &set_layout };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(device, &plci, NULL, &layout));
	VkDescriptorPoolSize pool_size = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size };
	VkDescriptorPool descriptor_pool;
	CK(vkCreateDescriptorPool(device, &dpci, NULL, &descriptor_pool));
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &set_layout };
	VkDescriptorSet set;
	CK(vkAllocateDescriptorSets(device, &dsai, &set));
	VkDescriptorBufferInfo buffer_info = { buffer, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet write = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set,
		.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &buffer_info };
	vkUpdateDescriptorSets(device, 1, &write, 0, NULL);
	VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = (size_t)size, .pCode = code };
	VkShaderModule module;
	CK(vkCreateShaderModule(device, &smci, NULL, &module));
	free(code);
	VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = module, .pName = "main" }, .layout = layout };
	VkPipeline pipeline;
	CK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cpci, NULL, &pipeline));

	VkCommandPoolCreateInfo pool_info = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool command_pool;
	CK(vkCreateCommandPool(device, &pool_info, NULL, &command_pool));
	VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = command_pool, .commandBufferCount = 1 };
	VkCommandBuffer command;
	CK(vkAllocateCommandBuffers(device, &cbai, &command));
	VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(command, &begin));
	vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
	vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
	vkCmdDispatch(command, INVOCATIONS / 32, 1, 1);
	VkMemoryBarrier barrier = { VK_STRUCTURE_TYPE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
		0, 1, &barrier, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(command));
	VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CK(vkCreateFence(device, &fci, NULL, &fence));
	VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command };
	CK(vkQueueSubmit(queue, 1, &submit, fence));
	CK(vkWaitForFences(device, 1, &fence, VK_TRUE, 10000000000ull));
	unsigned failures = 0;
	uint32_t expected[OUTPUTS] = { 0 };
	reference(argv[2], expected);
	for (uint32_t i = 0; i < OUTPUTS; ++i) {
		if (mapped[i] != expected[i]) {
			fprintf(stderr, "FAIL %s counter[%u] = %u, expected %u\n", argv[2], i, mapped[i], expected[i]);
			++failures;
		}
	}
	vkDestroyFence(device, fence, NULL);
	vkDestroyCommandPool(device, command_pool, NULL);
	vkDestroyPipeline(device, pipeline, NULL);
	vkDestroyShaderModule(device, module, NULL);
	vkDestroyDescriptorPool(device, descriptor_pool, NULL);
	vkDestroyPipelineLayout(device, layout, NULL);
	vkDestroyDescriptorSetLayout(device, set_layout, NULL);
	vkUnmapMemory(device, memory);
	vkDestroyBuffer(device, buffer, NULL);
	vkFreeMemory(device, memory, NULL);
	vkDestroyDevice(device, NULL);
	vkDestroyInstance(instance, NULL);
	if (failures) return 1;
	printf("OK sentry-g-brackets %s: 384 divergent invocations, all %u words match CPU reference\n", argv[2], OUTPUTS);
	return 0;
}
