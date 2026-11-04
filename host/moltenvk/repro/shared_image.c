/* #58: two Vulkan devices, one exported/imported shm allocation, independent
 * host mappings and image bindings. This models virglrenderer's macOS dma-buf
 * emulation: the fd is exported by the renderer, NOT vkGetMemoryFdKHR (neither
 * Metal driver implements OPAQUE_FD). HOST_ALLOCATION is the sharing marker the
 * renderer must preserve on VkImageCreateInfo. A clears, B reads; then B clears,
 * A reads. OPTIMAL failed with 0016's per-import private heap; LINEAR is a control.
 * Dedicated/non-dedicated imports both tested. No shaders or VM required. */
/* On Linux the same test uses real Vulkan OPAQUE_FD export/import (Venus).
 * Build: cc -O1 shared_image.c -lvulkan -o shared_image. */
#include <vulkan/vulkan.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CK(x) do { VkResult r = (x); if (r != VK_SUCCESS) { fprintf(stderr, "FAIL %s: %d (line %d)\n", #x, r, __LINE__); exit(1); } } while (0)
#define W 64
#define BYTES (W * W * 4)
#ifdef __linux__
#define SHARED_HANDLE VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT
#define SHARED_EXTENSION VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME
#else
#define SHARED_HANDLE VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT
#define SHARED_EXTENSION VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME
#endif
static VkPhysicalDevice pd;
static VkPhysicalDeviceMemoryProperties mp;
static uint32_t family;
struct side {
	VkDevice dev;
	VkQueue queue;
	VkCommandPool pool;
	VkCommandBuffer cmd;
	VkImage image;
	VkDeviceMemory image_mem, read_mem;
	VkBuffer read;
	void *ptr;
};
static void sysck(int ok, const char *what) {
	if (!ok) { perror(what); exit(1); }
}
static uint32_t memory_type(uint32_t bits) {
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags &
		    (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
		    (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) return i;
	fprintf(stderr, "FAIL no coherent host memory type in 0x%x\n", bits); exit(1);
}
static void init(struct side *s) {
	const char *ext = SHARED_EXTENSION;
	float priority = 1;
	VkDeviceQueueCreateInfo qi = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
	VkDeviceCreateInfo di = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qi, .enabledExtensionCount = 1, .ppEnabledExtensionNames = &ext };
	CK(vkCreateDevice(pd, &di, NULL, &s->dev));
	vkGetDeviceQueue(s->dev, family, 0, &s->queue);
	VkCommandPoolCreateInfo pi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = family };
	CK(vkCreateCommandPool(s->dev, &pi, NULL, &s->pool));
	VkCommandBufferAllocateInfo ci = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = s->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	CK(vkAllocateCommandBuffers(s->dev, &ci, &s->cmd));
	VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = BYTES,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	CK(vkCreateBuffer(s->dev, &bi, NULL, &s->read));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(s->dev, s->read, &req);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = req.size, .memoryTypeIndex = memory_type(req.memoryTypeBits) };
	CK(vkAllocateMemory(s->dev, &ai, NULL, &s->read_mem));
	CK(vkBindBufferMemory(s->dev, s->read, s->read_mem, 0));
}
static void begin(struct side *s) {
	CK(vkResetCommandBuffer(s->cmd, 0));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(s->cmd, &bi));
}
static void submit(struct side *s) {
	CK(vkEndCommandBuffer(s->cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &s->cmd };
	CK(vkQueueSubmit(s->queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(s->queue));
}
static void barrier(struct side *s, int acquire, int first) {
	VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.srcAccessMask = acquire ? 0 : VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT,
		.dstAccessMask = acquire ? VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT : 0,
		.oldLayout = first ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_GENERAL,
		.newLayout = VK_IMAGE_LAYOUT_GENERAL,
		.srcQueueFamilyIndex = first ? VK_QUEUE_FAMILY_IGNORED : acquire ? VK_QUEUE_FAMILY_EXTERNAL : family,
		.dstQueueFamilyIndex = first ? VK_QUEUE_FAMILY_IGNORED : acquire ? family : VK_QUEUE_FAMILY_EXTERNAL,
		.image = s->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(s->cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
		0, 0, NULL, 0, NULL, 1, &b);
}
static unsigned roundtrip(struct side *writer, struct side *reader, int first, int reverse) {
	begin(writer);
	barrier(writer, 1, first);
	VkClearColorValue color = { .float32 = { reverse ? 0.75f : 0.25f, 0.5f, reverse ? 0.25f : 0.75f, 1 } };
	VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
	vkCmdClearColorImage(writer->cmd, writer->image, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range);
	barrier(writer, 0, 0);
	submit(writer);
	begin(reader);
	barrier(reader, 1, 0);
	VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, W, 1 } };
	vkCmdCopyImageToBuffer(reader->cmd, reader->image, VK_IMAGE_LAYOUT_GENERAL, reader->read, 1, &copy);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(reader->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
		0, 1, &mb, 0, NULL, 0, NULL);
	barrier(reader, 0, 0);
	submit(reader);
	uint8_t *pixels;
	CK(vkMapMemory(reader->dev, reader->read_mem, 0, VK_WHOLE_SIZE, 0, (void **)&pixels));
	unsigned match = 0;
	for (unsigned i = 0; i < W * W; i++) {
		uint8_t *p = pixels + i * 4;
		match += abs((int)p[0] - (reverse ? 191 : 64)) <= 1 && abs((int)p[1] - 128) <= 1 &&
		         abs((int)p[2] - (reverse ? 64 : 191)) <= 1 && p[3] == 255;
	}
	vkUnmapMemory(reader->dev, reader->read_mem);
	return match;
}
int main(void) {
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ii = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CK(vkCreateInstance(&ii, NULL, &instance));
	uint32_t count = 1;
	CK(vkEnumeratePhysicalDevices(instance, &count, &pd));
	if (!count) { fprintf(stderr, "FAIL no physical device\n"); return 1; }
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	VkQueueFamilyProperties qp[32]; count = 32;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, qp);
	for (family = 0; family < count; family++) if (qp[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) break;
	if (family == count) { fprintf(stderr, "FAIL no graphics queue\n"); return 1; }
	VkPhysicalDeviceDriverProperties driver = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
	VkPhysicalDeviceExternalMemoryHostPropertiesEXT hp = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT,
		.pNext = &driver };
	VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &hp };
	vkGetPhysicalDeviceProperties2(pd, &props);
	printf("shared_image: %s\n", props.properties.deviceName);
	int failed = 0;
	for (int linear = 0; linear < 2; linear++) for (int dedicated = 0; dedicated < 2; dedicated++) {
		/* MoltenVK advertises this combination, but its imported OPTIMAL image
		 * currently aborts Metal bytesPerRow validation. Do not crash a test run.
		 * This is not a PASS and must not mask a KosmicKrisp regression. */
		if (!linear && driver.driverID == VK_DRIVER_ID_MOLTENVK) {
			printf("SKIP OPTIMAL %s: MoltenVK imported-image row-pitch limitation\n",
				dedicated ? "dedicated" : "plain");
			continue;
		}
		VkPhysicalDeviceExternalImageFormatInfo ext = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
			.handleType = SHARED_HANDLE };
		VkPhysicalDeviceImageFormatInfo2 fi = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, &ext,
			.format = VK_FORMAT_R8G8B8A8_UNORM, .type = VK_IMAGE_TYPE_2D,
			.tiling = linear ? VK_IMAGE_TILING_LINEAR : VK_IMAGE_TILING_OPTIMAL,
			.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT };
		/* handleType=0 must behave exactly as if the external struct is absent.
		 * Mesa 386f3238 fixes a Venus null dereference in this valid query. */
		ext.handleType = 0;
		VkImageFormatProperties2 zero = { VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 };
		VkImageFormatProperties2 absent = { VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 };
		CK(vkGetPhysicalDeviceImageFormatProperties2(pd, &fi, &zero));
		fi.pNext = NULL;
		CK(vkGetPhysicalDeviceImageFormatProperties2(pd, &fi, &absent));
		if (memcmp(&zero.imageFormatProperties, &absent.imageFormatProperties,
		           sizeof(zero.imageFormatProperties))) {
			fprintf(stderr, "FAIL zero handleType differs from absent external info\n"); return 1;
		}
		fi.pNext = &ext;
		ext.handleType = SHARED_HANDLE;
		VkExternalImageFormatProperties ep = { VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES };
		VkImageFormatProperties2 fp = { VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, &ep };
		VkResult supported = vkGetPhysicalDeviceImageFormatProperties2(pd, &fi, &fp);
		if (supported == VK_ERROR_FORMAT_NOT_SUPPORTED) {
			printf("SKIP %s %s: external image format not supported\n",
				linear ? "LINEAR" : "OPTIMAL", dedicated ? "dedicated" : "plain");
			continue;
		}
		CK(supported);
		if (!(ep.externalMemoryProperties.externalMemoryFeatures & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT)) {
			fprintf(stderr, "FAIL image not importable\n"); return 1;
		}
		if (driver.driverID == VK_DRIVER_ID_MESA_KOSMICKRISP &&
		    (fp.imageFormatProperties.maxMipLevels != 1 ||
		     fp.imageFormatProperties.maxArrayLayers != 1 ||
		     fp.imageFormatProperties.sampleCounts != VK_SAMPLE_COUNT_1_BIT)) {
			fprintf(stderr, "FAIL shared KK image query must advertise bounded linear limits\n");
			return 1;
		}
		struct side s[2] = {0};
		VkMemoryRequirements req[2];
		VkExternalMemoryImageCreateInfo emi = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
			.handleTypes = ext.handleType };
		VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &emi,
			.imageType = fi.type, .format = fi.format, .extent = { W, W, 1 }, .mipLevels = 1, .arrayLayers = 1,
			.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = fi.tiling, .usage = fi.usage };
		for (unsigned i = 0; i < 2; i++) {
			init(&s[i]);
			CK(vkCreateImage(s[i].dev, &ci, NULL, &s[i].image));
			vkGetImageMemoryRequirements(s[i].dev, s[i].image, &req[i]);
		}
		sysck(req[0].size == req[1].size, "image requirement mismatch");
#ifdef __linux__
		int fd = -1;
		for (unsigned i = 0; i < 2; i++) {
			VkMemoryDedicatedAllocateInfo da = { VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
				.image = s[i].image };
			VkExportMemoryAllocateInfo exp = { VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
				.pNext = dedicated ? &da : NULL, .handleTypes = SHARED_HANDLE };
			VkImportMemoryFdInfoKHR imp = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
				.pNext = dedicated ? &da : NULL, .handleType = SHARED_HANDLE, .fd = fd };
			VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
				.pNext = i ? (void *)&imp : (void *)&exp, .allocationSize = req[i].size,
				.memoryTypeIndex = memory_type(req[0].memoryTypeBits & req[1].memoryTypeBits) };
			CK(vkAllocateMemory(s[i].dev, &ai, NULL, &s[i].image_mem));
			CK(vkBindImageMemory(s[i].dev, s[i].image, s[i].image_mem, 0));
			if (!i) {
				PFN_vkGetMemoryFdKHR getfd = (PFN_vkGetMemoryFdKHR)vkGetDeviceProcAddr(s[i].dev, "vkGetMemoryFdKHR");
				VkMemoryGetFdInfoKHR gi = { VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
					.memory = s[i].image_mem, .handleType = SHARED_HANDLE };
				CK(getfd(s[i].dev, &gi, &fd));
				sysck(fd >= 0 && fcntl(fd, F_GETFD) >= 0, "Vulkan export fd");
			}
		}
#else
		uint64_t align = hp.minImportedHostPointerAlignment;
		if (align < (uint64_t)getpagesize()) align = getpagesize();
		uint64_t size = (req[0].size + align - 1) / align * align;
		char name[32]; snprintf(name, sizeof(name), "/shared-%d-%x", getpid(), arc4random());
		int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
		sysck(fd >= 0, "shm_open"); shm_unlink(name);
		sysck(ftruncate(fd, size) == 0, "ftruncate");
		int imported_fd = dup(fd); sysck(imported_fd >= 0, "export shm fd");
		for (unsigned i = 0; i < 2; i++) {
			s[i].ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, i ? imported_fd : fd, 0);
			sysck(s[i].ptr != MAP_FAILED, "mmap");
			sysck((uintptr_t)s[i].ptr % align == 0, "host pointer alignment");
			PFN_vkGetMemoryHostPointerPropertiesEXT gethp = (PFN_vkGetMemoryHostPointerPropertiesEXT)
				vkGetDeviceProcAddr(s[i].dev, "vkGetMemoryHostPointerPropertiesEXT");
			VkMemoryHostPointerPropertiesEXT pp = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
			CK(gethp(s[i].dev, ext.handleType, s[i].ptr, &pp));
			VkMemoryDedicatedAllocateInfo da = { VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = s[i].image };
			VkImportMemoryHostPointerInfoEXT imp = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
				.pNext = dedicated ? &da : NULL, .handleType = ext.handleType, .pHostPointer = s[i].ptr };
			VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &imp,
				.allocationSize = size, .memoryTypeIndex = memory_type(req[i].memoryTypeBits & pp.memoryTypeBits) };
			CK(vkAllocateMemory(s[i].dev, &ai, NULL, &s[i].image_mem));
			CK(vkBindImageMemory(s[i].dev, s[i].image, s[i].image_mem, 0));
		}
#endif
		unsigned ab = roundtrip(&s[0], &s[1], 1, 0);
		unsigned ba = roundtrip(&s[1], &s[0], 0, 1);
		int ok = ab == W * W && ba == W * W;
		printf("%s %s %s: A->B %u/%u, B->A %u/%u pixels\n", ok ? "OK  " : "FAIL",
			linear ? "LINEAR " : "OPTIMAL", dedicated ? "dedicated" : "plain    ", ab, W * W, ba, W * W);
		failed |= !ok;
		for (unsigned i = 0; i < 2; i++) {
			vkDestroyImage(s[i].dev, s[i].image, NULL); vkFreeMemory(s[i].dev, s[i].image_mem, NULL);
			vkDestroyBuffer(s[i].dev, s[i].read, NULL); vkFreeMemory(s[i].dev, s[i].read_mem, NULL);
			vkDestroyCommandPool(s[i].dev, s[i].pool, NULL); vkDestroyDevice(s[i].dev, NULL);
#ifndef __linux__
			munmap(s[i].ptr, size);
#endif
		}
#ifndef __linux__
		close(imported_fd); close(fd);
#endif
	}
	vkDestroyInstance(instance, NULL);
	return failed;
}
