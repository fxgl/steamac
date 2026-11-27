/* STEAMAC-3/D8/D9 (1.9.15, M4, appid 1043240): SIGABRT `_addResidencySets:387: failed assertion`
 * under MVKQueue::initMTLCommandQueue <- vkCreateDevice. Metal allows 32 residency sets per
 * MTLCommandQueue; MoltenVK caches its MTLCommandQueues per physical device, shares them between
 * all VkDevices and added every device's residency set to the shared queue, so the 33rd live
 * VkDevice aborted the process.
 *
 *   live      40 VkDevices alive at once on one physical device; each fills its own device-local
 *             buffer on the GPU and copies it to a host-visible one, checked per device
 *   recreate  destroy every other device, create replacements, all submit again
 * Before the fix device 33 aborts; after, all devices render their own values. */
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define DEVICES 40
#define WORDS 1024

struct dev {
	VkDevice device;
	VkQueue queue;
	VkBuffer local, host;
	VkDeviceMemory local_mem, host_mem;
	VkCommandPool pool;
	VkCommandBuffer cmd;
	uint32_t *mapped;
};

static VkPhysicalDevice pd;
static VkPhysicalDeviceMemoryProperties mp;

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags flags)
{
	for (uint32_t t = 0; t < mp.memoryTypeCount; t++)
		if ((bits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & flags) == flags)
			return t;
	printf("FAIL no memory type 0x%x for 0x%x\n", bits, flags);
	exit(1);
}

static void buffer(struct dev *d, VkBufferUsageFlags usage, VkMemoryPropertyFlags flags, VkBuffer *buf, VkDeviceMemory *mem)
{
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = WORDS * 4, .usage = usage };
	CK(vkCreateBuffer(d->device, &bci, NULL, buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(d->device, *buf, &mr);
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memory_type(mr.memoryTypeBits, flags) };
	CK(vkAllocateMemory(d->device, &mai, NULL, mem));
	CK(vkBindBufferMemory(d->device, *buf, *mem, 0));
}

static void create(struct dev *d)
{
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &d->device));
	vkGetDeviceQueue(d->device, 0, 0, &d->queue);
	buffer(d, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
	       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &d->local, &d->local_mem);
	buffer(d, VK_BUFFER_USAGE_TRANSFER_DST_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
	       &d->host, &d->host_mem);
	CK(vkMapMemory(d->device, d->host_mem, 0, VK_WHOLE_SIZE, 0, (void **)&d->mapped));
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	CK(vkCreateCommandPool(d->device, &cpci, NULL, &d->pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = d->pool,
		.commandBufferCount = 1 };
	CK(vkAllocateCommandBuffers(d->device, &cai, &d->cmd));
}

static void destroy(struct dev *d)
{
	vkDestroyCommandPool(d->device, d->pool, NULL);
	vkDestroyBuffer(d->device, d->local, NULL);
	vkDestroyBuffer(d->device, d->host, NULL);
	vkFreeMemory(d->device, d->local_mem, NULL);
	vkFreeMemory(d->device, d->host_mem, NULL);
	vkDestroyDevice(d->device, NULL);
}

/* GPU fill of the device-local buffer, copied to the host-visible one */
static void submit(struct dev *d, uint32_t value)
{
	CK(vkResetCommandBuffer(d->cmd, 0));
	VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(d->cmd, &begin));
	vkCmdFillBuffer(d->cmd, d->local, 0, VK_WHOLE_SIZE, value);
	VkBufferMemoryBarrier b = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .buffer = d->local, .size = VK_WHOLE_SIZE };
	vkCmdPipelineBarrier(d->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 1, &b, 0, NULL);
	VkBufferCopy copy = { .size = WORDS * 4 };
	vkCmdCopyBuffer(d->cmd, d->local, d->host, 1, &copy);
	CK(vkEndCommandBuffer(d->cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &d->cmd };
	CK(vkQueueSubmit(d->queue, 1, &si, VK_NULL_HANDLE));
}

static int check(struct dev *d, uint32_t value, const char *phase, int i)
{
	CK(vkQueueWaitIdle(d->queue));
	for (uint32_t w = 0; w < WORDS; w++) {
		if (d->mapped[w] != value) {
			printf("FAIL %s: device %d word %u = 0x%08x, expected 0x%08x\n", phase, i + 1, w, d->mapped[w], value);
			return 1;
		}
	}
	return 0;
}

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_2 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);

	static struct dev devs[DEVICES];
	for (int i = 0; i < DEVICES; i++) {
		fprintf(stderr, "creating device %d\n", i + 1);
		create(&devs[i]);
	}
	for (int i = 0; i < DEVICES; i++) submit(&devs[i], 0xa5000000u + i);
	for (int i = 0; i < DEVICES; i++)
		if (check(&devs[i], 0xa5000000u + i, "live", i)) return 1;
	printf("OK live: %d VkDevices alive at once each filled and read back their own buffer\n", DEVICES);

	for (int i = 0; i < DEVICES; i += 2) {
		destroy(&devs[i]);
		create(&devs[i]);
	}
	for (int i = 0; i < DEVICES; i++) submit(&devs[i], 0x5a000000u + i);
	for (int i = 0; i < DEVICES; i++)
		if (check(&devs[i], 0x5a000000u + i, "recreate", i)) return 1;
	printf("OK recreate: %d replaced devices and %d survivors submit and read back\n", DEVICES / 2, DEVICES / 2);
	for (int i = 0; i < DEVICES; i++) destroy(&devs[i]);
	vkDestroyInstance(inst, NULL);
	return 0;
}
