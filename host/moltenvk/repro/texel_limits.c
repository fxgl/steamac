/* STEAMAC-9E/79: Rift Apart requested a texture-buffer width of 536346624,
 * exceeding Metal's 268435456 limit and Vulkan's advertised 67108864.
 * Reject oversized explicit/VK_WHOLE_SIZE views before lazy Metal construction.
 * On an unfixed driver, descriptor update reaches the original Metal assertion.
 * Controls exercise the advertised maximum, including an emulated alignment prefix.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r = (x); if (r) { fprintf(stderr, "FAIL %s = %d\n", #x, r); exit(1); } } while (0)

int main(int argc, char **argv)
{
	const char *name = argc == 2 ? argv[1] : "captured";
	const int captured = !strcmp(name, "captured");
	const int valid = !strcmp(name, "boundary") || !strcmp(name, "partial");
	const int partial = !strcmp(name, "partial");
	const int whole = captured || !strcmp(name, "whole") || valid;
	if (!captured && !valid && strcmp(name, "whole") && strcmp(name, "explicit")) return 2;
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CK(vkCreateInstance(&ici, NULL, &instance));
	uint32_t count = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(instance, &count, &pd));
	VkPhysicalDeviceProperties props;
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceProperties(pd, &props);
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	const VkDeviceSize offset = captured ? 524288 : valid ? 12 : 0;
	const VkDeviceSize range = captured ? 536346624 : partial ? 11 :
		(VkDeviceSize)props.limits.maxTexelBufferElements + !valid;
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = offset + range,
		.usage = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT };
	VkBuffer buffer;
	CK(vkCreateBuffer(dev, &bci, NULL, &buffer));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buffer, &mr);
	uint32_t type = 0;
	while (type < mp.memoryTypeCount && !(mr.memoryTypeBits & (1u << type))) type++;
	if (type == mp.memoryTypeCount) return 1;
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = type };
	VkDeviceMemory memory;
	CK(vkAllocateMemory(dev, &ai, NULL, &memory));
	CK(vkBindBufferMemory(dev, buffer, memory, 0));
	VkBufferViewCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .buffer = buffer,
		.format = partial ? VK_FORMAT_R32_UINT : VK_FORMAT_R8_UINT,
		.offset = offset, .range = whole ? VK_WHOLE_SIZE : range };
	VkBufferView view = VK_NULL_HANDLE;
	printf("TEST texel_limits %s: offset %llu range %llu, maxTexelBufferElements %u\n",
		name, (unsigned long long)offset, (unsigned long long)range, props.limits.maxTexelBufferElements);
	fflush(stdout);
	VkResult result = vkCreateBufferView(dev, &ci, NULL, &view);
	if (result == VK_SUCCESS && view) {
		VkDescriptorSetLayoutBinding binding = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER,
			.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
		VkDescriptorSetLayoutCreateInfo slci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &binding };
		VkDescriptorSetLayout layout;
		CK(vkCreateDescriptorSetLayout(dev, &slci, NULL, &layout));
		VkDescriptorPoolSize size = { VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1 };
		VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &size };
		VkDescriptorPool pool;
		CK(vkCreateDescriptorPool(dev, &dpci, NULL, &pool));
		VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool,
			.descriptorSetCount = 1, .pSetLayouts = &layout };
		VkDescriptorSet set;
		CK(vkAllocateDescriptorSets(dev, &dsai, &set));
		VkWriteDescriptorSet write = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0,
			.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &view };
		vkUpdateDescriptorSets(dev, 1, &write, 0, NULL);
		vkDestroyDescriptorPool(dev, pool, NULL);
		vkDestroyDescriptorSetLayout(dev, layout, NULL);
		vkDestroyBufferView(dev, view, NULL);
	}
	const int ok = valid ? result == VK_SUCCESS && view != VK_NULL_HANDLE :
		result == VK_ERROR_OUT_OF_DEVICE_MEMORY && view == VK_NULL_HANDLE;
	printf("%s texel_limits %s: VkResult %d, handle %s\n", ok ? "OK" : "FAIL", name, result, view ? "non-null" : "null");
	vkDestroyBuffer(dev, buffer, NULL);
	vkFreeMemory(dev, memory, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(instance, NULL);
	return !ok;
}
