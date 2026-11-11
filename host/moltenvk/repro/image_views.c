/* STEAMAC-62/64/3/G: never pass empty slice ranges or incompatible formats to
 * Metal. Invalid guest views run without Vulkan validation, each in a separate
 * process. Single-layer non-array overflow counts recover the actual slice;
 * a render clear and readback check that this is a real view, not fake success.
 * Other invalid views remain rejected, with valid 2D/3D controls unchanged. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r = (x); if (r) { fprintf(stderr, "FAIL %s = %d\n", #x, r); exit(1); } } while (0)

static void check_rendered_slice(VkPhysicalDevice pd, VkDevice dev,
	VkImage image, VkImageView view, uint32_t width, uint32_t height)
{
	const VkDeviceSize bytes = (VkDeviceSize)width * height * 4;
	VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
		.size = bytes, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buffer;
	CK(vkCreateBuffer(dev, &bi, NULL, &buffer));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buffer, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t type;
	for (type = 0; type < mp.memoryTypeCount; type++)
		if ((mr.memoryTypeBits & (1u << type)) &&
		    (mp.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
			break;
	if (type == mp.memoryTypeCount) { fprintf(stderr, "FAIL no readback memory\n"); exit(1); }
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = mr.size, .memoryTypeIndex = type };
	VkDeviceMemory memory;
	CK(vkAllocateMemory(dev, &ai, NULL, &memory));
	CK(vkBindBufferMemory(dev, buffer, memory, 0));
	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &begin));
	VkImageMemoryBarrier barrier = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.image = image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
		VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
	VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
		.imageView = view, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.clearValue.color.float32 = { 1, 0, 1, 1 } };
	VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO,
		.renderArea.extent = { width, height }, .layerCount = 1,
		.colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(cmd, &ri);
	vkCmdEndRendering(cmd);
	barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
	barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
	barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
	VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
		.imageExtent = { width, height, 1 } };
	vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
	VkMemoryBarrier host = { VK_STRUCTURE_TYPE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
		VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);
	VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO,
		.commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	unsigned char *pixels;
	CK(vkMapMemory(dev, memory, 0, VK_WHOLE_SIZE, 0, (void **)&pixels));
	VkMappedMemoryRange mapped = { VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
		.memory = memory, .size = VK_WHOLE_SIZE };
	CK(vkInvalidateMappedMemoryRanges(dev, 1, &mapped));
	const unsigned char expected[] = { 255, 0, 255, 255 };
	for (VkDeviceSize i = 0; i < bytes; i++)
		if (pixels[i] != expected[i % 4]) {
			fprintf(stderr, "FAIL rendered slice byte %llu: %u expected %u\n",
				(unsigned long long)i, pixels[i], expected[i % 4]);
			exit(1);
		}
	vkUnmapMemory(dev, memory);
	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyBuffer(dev, buffer, NULL);
	vkFreeMemory(dev, memory, NULL);
}

static int run_case(const char *name)
{
	const int volume = strstr(name, "3d") != NULL;
	const int invalid = strncmp(name, "invalid-", 8) == 0;
	const int sentry = strstr(name, "sentry-") != NULL;
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3,
		.pApplicationName = "image_views", .pEngineName = "steamac repro" };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance instance;
	CK(vkCreateInstance(&ici, NULL, &instance));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(instance, &n, &pd));
	float priority = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
	const char *extensions[] = { VK_EXT_HOST_IMAGE_COPY_EXTENSION_NAME,
		VK_EXT_ATTACHMENT_FEEDBACK_LOOP_LAYOUT_EXTENSION_NAME };
	VkPhysicalDeviceHostImageCopyFeaturesEXT hic = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT,
		.hostImageCopy = VK_TRUE };
	VkPhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesEXT feedback = {
		VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ATTACHMENT_FEEDBACK_LOOP_LAYOUT_FEATURES_EXT,
		.pNext = &hic, .attachmentFeedbackLoopLayout = VK_TRUE };
	VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.pNext = &feedback, .dynamicRendering = VK_TRUE };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.pNext = sentry ? &f13 : NULL, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = sentry ? 2 : 0, .ppEnabledExtensionNames = sentry ? extensions : NULL };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.flags = volume ? VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT : VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT,
		.imageType = volume ? VK_IMAGE_TYPE_3D : VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { 16, 16, volume ? 4 : 1 },
		.mipLevels = 3, .arrayLayers = volume ? 1 : 4, .samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
	if (sentry) {
		ci.extent = (VkExtent3D){ strstr(name, "1952") ? 1952 : 1920, 288, 1 };
		ci.mipLevels = ci.arrayLayers = 1;
		ci.usage = 0x480097;
	}
	VkImage image;
	CK(vkCreateImage(dev, &ci, NULL, &image));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, image, &mr);
	uint32_t type = 0;
	while (!(mr.memoryTypeBits & (1u << type))) type++;
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = type };
	VkDeviceMemory memory;
	CK(vkAllocateMemory(dev, &ai, NULL, &memory));
	CK(vkBindImageMemory(dev, image, memory, 0));
	VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = ci.format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 1, 1, volume ? 1 : 3, VK_REMAINING_ARRAY_LAYERS } };
	if (strstr(name, "zero")) vi.subresourceRange.layerCount = 0;
	if (strstr(name, "end")) vi.subresourceRange.baseArrayLayer = volume ? 2 : 4;
	if (strstr(name, "past")) vi.subresourceRange.baseArrayLayer = volume ? 3 : 5;
	if (strstr(name, "wide")) vi.subresourceRange.layerCount = 65536;
	if (strstr(name, "format")) vi.format = VK_FORMAT_R8_UNORM;
	if (strstr(name, "array")) {
		vi.viewType = VK_IMAGE_VIEW_TYPE_2D_ARRAY;
		vi.subresourceRange.baseArrayLayer = 0;
	}
	if (strstr(name, "volume")) {
		vi.viewType = VK_IMAGE_VIEW_TYPE_3D;
		vi.subresourceRange.baseArrayLayer = 0;
	}
	VkImageViewUsageCreateInfo usage = { VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT };
	if (sentry) {
		vi.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0,
			strstr(name, "wide") ? 65536 : 1 };
		if (strstr(name, "usage")) vi.pNext = &usage;
	}
	fprintf(stderr, "image_views: %s\n", name);
	VkImageView view = VK_NULL_HANDLE;
	VkResult result = vkCreateImageView(dev, &vi, NULL, &view);
	if ((!invalid && result != VK_SUCCESS) || (invalid && result != VK_ERROR_FORMAT_NOT_SUPPORTED)) {
		fprintf(stderr, "FAIL %s: result %d, expected %d\n", name, result,
			invalid ? VK_ERROR_FORMAT_NOT_SUPPORTED : VK_SUCCESS);
		return 1;
	}
	if (result == VK_SUCCESS) {
		if (sentry) check_rendered_slice(pd, dev, image, view, ci.extent.width, ci.extent.height);
		vkDestroyImageView(dev, view, NULL);
	}
	vkDestroyImage(dev, image, NULL);
	vkFreeMemory(dev, memory, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(instance, NULL);
	printf("OK image_views %s\n", name);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 2) return run_case(argv[1]);
	const char *cases[] = { "remaining-2d", "remaining-2d-array", "remaining-3d", "remaining-3d-array", "remaining-3d-volume",
		"invalid-zero-2d", "invalid-end-2d", "invalid-past-2d", "invalid-wide-2d",
		"invalid-zero-3d", "invalid-end-3d", "invalid-past-3d", "invalid-format-2d",
		"sentry-wide-1920", "sentry-wide-1952", "sentry-wide-usage-1920",
		"invalid-sentry-format-1920", "invalid-sentry-format-1952", "invalid-sentry-format-usage-1920" };
	int failed = 0;
	for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		pid_t child = fork();
		if (child == -1) { perror("fork"); return 1; }
		if (!child) { execl(argv[0], argv[0], cases[i], (char *)NULL); perror("execl"); _exit(1); }
		int status;
		if (waitpid(child, &status, 0) == -1) { perror("waitpid"); return 1; }
		if (!WIFEXITED(status) || WEXITSTATUS(status)) {
			fprintf(stderr, "FAIL image_views %s: child status 0x%x\n", cases[i], status);
			failed = 1;
		}
	}
	return failed;
}
