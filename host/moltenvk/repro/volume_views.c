/* STEAMAC-76/77: Venus imports host allocations even for optimal images.
 * A 2D render view of a 3D image needs placement-heap aliasing, not a standalone
 * Metal texture. Clear slice 1 and read back through the original 3D image. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r = (x); if (r) { fprintf(stderr, "FAIL %s = %d\n", #x, r); exit(1); } } while (0)

int main(int argc, char **argv)
{
    const int imported = argc == 1 || strcmp(argv[1], "plain");
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance;
    CK(vkCreateInstance(&ici, NULL, &instance));
    VkPhysicalDevice pd;
    uint32_t count = 1;
    CK(vkEnumeratePhysicalDevices(instance, &count, &pd));
    VkPhysicalDeviceExternalMemoryHostPropertiesEXT hp = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT };
    VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &hp };
    vkGetPhysicalDeviceProperties2(pd, &props);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    float priority = 1;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
    VkPhysicalDeviceDynamicRenderingFeatures dynamic = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES, .dynamicRendering = VK_TRUE };
    const char *ext = VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &dynamic,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1, .ppEnabledExtensionNames = &ext };
    VkDevice dev;
    CK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue queue;
    vkGetDeviceQueue(dev, 0, 0, &queue);
    /* Like vkr's ordinary HOST_VISIBLE allocation: imported memory, but no
     * external image sharing marker (shared images have different limits). */
    VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .flags = VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT, .imageType = VK_IMAGE_TYPE_3D,
        .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { 16, 16, 4 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT };
    VkImage image;
    CK(vkCreateImage(dev, &ci, NULL, &image));
    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, image, &mr);
    size_t alignment = hp.minImportedHostPointerAlignment;
    if (alignment < 16384) alignment = 16384;
    size_t size = (mr.size + alignment - 1) / alignment * alignment;
    void *ptr = NULL;
    if (imported && posix_memalign(&ptr, alignment, size)) return 1;
    VkMemoryHostPointerPropertiesEXT hostProps = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
    if (imported) {
        memset(ptr, 0, size);
        PFN_vkGetMemoryHostPointerPropertiesEXT get = (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(dev, "vkGetMemoryHostPointerPropertiesEXT");
        CK(get(dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, ptr, &hostProps));
        mr.memoryTypeBits &= hostProps.memoryTypeBits;
    }
    uint32_t type = 0;
    while (type < mp.memoryTypeCount && (!(mr.memoryTypeBits & (1u << type)) ||
        (imported && !(mp.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)))) type++;
    if (type == mp.memoryTypeCount) return 1;
    VkImportMemoryHostPointerInfoEXT import = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, .pHostPointer = ptr };
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = imported ? &import : NULL,
        .allocationSize = size, .memoryTypeIndex = type };
    VkDeviceMemory memory;
    CK(vkAllocateMemory(dev, &ai, NULL, &memory));
    CK(vkBindImageMemory(dev, image, memory, 0));
    VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = ci.format,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1, 1 } };
    VkImageView view;
    CK(vkCreateImageView(dev, &vi, NULL, &view));
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 16 * 16 * 4 * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    VkBuffer buffer;
    CK(vkCreateBuffer(dev, &bi, NULL, &buffer));
    vkGetBufferMemoryRequirements(dev, buffer, &mr);
    type = 0;
    while (type < mp.memoryTypeCount && (!(mr.memoryTypeBits & (1u << type)) ||
        (mp.memoryTypes[type].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) !=
        (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))) type++;
    if (type == mp.memoryTypeCount) return 1;
    ai.pNext = NULL; ai.allocationSize = mr.size; ai.memoryTypeIndex = type;
    VkDeviceMemory readback;
    CK(vkAllocateMemory(dev, &ai, NULL, &readback));
    CK(vkBindBufferMemory(dev, buffer, readback, 0));
    VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    VkCommandPool pool;
    CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd;
    CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
    VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CK(vkBeginCommandBuffer(cmd, &begin));
    VkImageMemoryBarrier barrier = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    VkClearColorValue black = { .float32 = { 0, 0, 0, 0 } };
    vkCmdClearColorImage(cmd, image, VK_IMAGE_LAYOUT_GENERAL, &black, 1, &barrier.subresourceRange);
    barrier.oldLayout = barrier.newLayout; barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    VkRenderingAttachmentInfo attachment = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue.color.float32 = { 0, 1, 0, 1 } };
    VkRenderingInfo rendering = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea.extent = { 16, 16 }, .layerCount = 1,
        .colorAttachmentCount = 1, .pColorAttachments = &attachment };
    vkCmdBeginRendering(cmd, &rendering);
    vkCmdEndRendering(cmd);
    barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = ci.extent };
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &copy);
    CK(vkEndCommandBuffer(cmd));
    VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
    CK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
    CK(vkQueueWaitIdle(queue));
    unsigned char *pixels;
    CK(vkMapMemory(dev, readback, 0, VK_WHOLE_SIZE, 0, (void **)&pixels));
    for (unsigned z = 0; z < 4; z++) for (unsigned p = 0; p < 16 * 16; p++) {
        const unsigned char expect[4] = { 0, z == 1 ? 255 : 0, 0, z == 1 ? 255 : 0 };
        if (memcmp(pixels + (z * 256 + p) * 4, expect, 4)) {
            fprintf(stderr, "FAIL slice %u pixel %u: %u,%u,%u,%u\n", z, p,
                pixels[(z * 256 + p) * 4], pixels[(z * 256 + p) * 4 + 1], pixels[(z * 256 + p) * 4 + 2], pixels[(z * 256 + p) * 4 + 3]);
            return 1;
        }
    }
    vkUnmapMemory(dev, readback);
    vkDestroyCommandPool(dev, pool, NULL);
    vkDestroyBuffer(dev, buffer, NULL); vkFreeMemory(dev, readback, NULL);
    vkDestroyImageView(dev, view, NULL); vkDestroyImage(dev, image, NULL); vkFreeMemory(dev, memory, NULL);
    free(ptr); vkDestroyDevice(dev, NULL); vkDestroyInstance(instance, NULL);
    printf("OK volume_views %s: rendered slice aliases original 3D image\n", imported ? "imported" : "plain");
    return 0;
}
