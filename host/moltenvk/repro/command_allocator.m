/* STEAMAC-AK/AP/AN/AX: observe real Metal 4 command allocator heap sizes
 * (not included in MTLDevice.currentAllocatedSize), without driver test exports.
 * Check bounded storage over completed render/compute recordings and readback
 * across implicit/explicit/pool resets, replay and abandoned recordings.
 * Sharing an allocator without resetting it is legal: do not assert exclusive
 * ownership or introduce a reset that could invalidate an executable sibling.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <vulkan/vulkan.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "FAIL %s = %d at %d\n", #x, r_, __LINE__); exit(1); } } while (0)
#define REQUIRE(x, text) do { if (!(x)) { fprintf(stderr, "FAIL %s\n", text); exit(1); } } while (0)
static NSMutableArray *allocators;
static IMP original_new, original_reset;
static uint64_t resets;
static VkDevice dev;
static VkQueue queue;
static VkBuffer buffer;
static VkImage image;
static VkImageView view;
static uint32_t *mapped;

static id track_new(id self, SEL selector)
{
    id allocator = ((id (*)(id, SEL))original_new)(self, selector);
    @synchronized(allocators) { if (allocator) [allocators addObject:allocator]; }
    return allocator;
}
static void track_reset(id self, SEL selector)
{
    @synchronized(allocators) { if ([allocators containsObject:self]) resets++; }
    ((void (*)(id, SEL))original_reset)(self, selector);
}
static uint64_t reset_count(void)
{
    @synchronized(allocators) { return resets; }
}
static uint64_t allocated_bytes(void)
{
    uint64_t bytes = 0;
    @synchronized(allocators) {
        for (id<MTL4CommandAllocator> allocator in allocators) bytes += allocator.allocatedSize;
    }
    return bytes;
}
static void print_interposers(void)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *p = _dyld_get_image_name(i);
        if (p && (strstr(p, "/libMTLHud.dylib") || strstr(p, "/libMetalMetricsInterpose.dylib")))
            fprintf(stderr, "command_allocator: loaded %s\n", p);
    }
}
static uint32_t memory_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags flags)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags) return i;
    REQUIRE(false, "no memory type"); return 0;
}
static void record(VkCommandBuffer cmd, VkCommandBufferUsageFlags flags, uint32_t slot, uint32_t value)
{
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = flags };
    CK(vkBeginCommandBuffer(cmd, &bi));
    const unsigned pairs = getenv("REPRO_ALLOCATOR_PAIRS") ? (unsigned)strtoul(getenv("REPRO_ALLOCATOR_PAIRS"), NULL, 10) : 64;
    REQUIRE(pairs > 0 && pairs <= 4096, "REPRO_ALLOCATOR_PAIRS must be 1..4096");
    for (unsigned i = 0; i < pairs; i++) {
        VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0, 0, NULL, 0, NULL, 1, &b);
        VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
            .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .clearValue.color.float32 = { 0, 0.5f, 1, 1 } };
        VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 16, 16 } },
            .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
        vkCmdBeginRendering(cmd, &ri); vkCmdEndRendering(cmd);
        vkCmdFillBuffer(cmd, buffer, slot * sizeof(uint32_t), sizeof(uint32_t), value);
    }
    VkMemoryBarrier host = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host, 0, NULL, 0, NULL);
    CK(vkEndCommandBuffer(cmd));
}
static void submit(VkCommandBuffer cmd, uint32_t slot, uint32_t value, bool submit2)
{
    if (submit2) {
        VkCommandBufferSubmitInfo cb = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = cmd };
        VkSubmitInfo2 si = { VK_STRUCTURE_TYPE_SUBMIT_INFO_2, .commandBufferInfoCount = 1, .pCommandBufferInfos = &cb };
        CK(vkQueueSubmit2(queue, 1, &si, VK_NULL_HANDLE));
    } else {
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
        CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    }
    CK(vkQueueWaitIdle(queue));
    REQUIRE(mapped[slot] == value, "command-buffer contents changed after a sibling reset/replay");
}
int main(void)
{
    @autoreleasepool {
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
        REQUIRE([metal supportsFamily:MTLGPUFamilyMetal4], "Metal 4 required");
        allocators = [[NSMutableArray alloc] init];
        id sample = [metal newCommandAllocator];
        Method reset = class_getInstanceMethod([sample class], @selector(reset));
        original_reset = method_setImplementation(reset, (IMP)track_reset);
        [sample release];
        Method create = class_getInstanceMethod([metal class], @selector(newCommandAllocator));
        original_new = method_setImplementation(create, (IMP)track_new);

        VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "command_allocator",
            .apiVersion = VK_API_VERSION_1_3 };
        VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
        VkInstance inst; CK(vkCreateInstance(&ici, NULL, &inst));
        VkPhysicalDevice pd; uint32_t n = 1; CK(vkEnumeratePhysicalDevices(inst, &n, &pd));
        float priority = 1;
        VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
        VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .dynamicRendering = VK_TRUE, .synchronization2 = VK_TRUE };
        VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13,
            .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
        CK(vkCreateDevice(pd, &dci, NULL, &dev)); vkGetDeviceQueue(dev, 0, 0, &queue);
        VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 4096, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
        CK(vkCreateBuffer(dev, &bci, NULL, &buffer));
        VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, buffer, &mr);
        VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
            .memoryTypeIndex = memory_type(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
        VkDeviceMemory bm; CK(vkAllocateMemory(dev, &ai, NULL, &bm)); CK(vkBindBufferMemory(dev, buffer, bm, 0));
        CK(vkMapMemory(dev, bm, 0, VK_WHOLE_SIZE, 0, (void **)&mapped)); memset(mapped, 0, 4096);
        VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {16,16,1}, .mipLevels = 1, .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
        CK(vkCreateImage(dev, &ii, NULL, &image)); vkGetImageMemoryRequirements(dev, image, &mr);
        ai.allocationSize = mr.size; ai.memoryTypeIndex = memory_type(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        VkDeviceMemory im; CK(vkAllocateMemory(dev, &ai, NULL, &im)); CK(vkBindImageMemory(dev, image, im, 0));
        VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
            .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = ii.format, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        CK(vkCreateImageView(dev, &vi, NULL, &view));
        VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
        VkCommandPool pool; CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
        VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 2 };
        VkCommandBuffer cmd[2]; CK(vkAllocateCommandBuffers(dev, &cai, cmd));
        record(cmd[0], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, 0, 101);
        record(cmd[1], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, 1, 202);
        fprintf(stderr, "command_allocator: ended siblings allocators=%lu resets=%" PRIu64 " bytes=%" PRIu64 "\n",
            (unsigned long)allocators.count, reset_count(), allocated_bytes());
        submit(cmd[0], 0, 101, false);
        CK(vkResetCommandBuffer(cmd[0], 0));
        record(cmd[0], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, 2, 303);
        submit(cmd[1], 1, 202, true); submit(cmd[0], 2, 303, false);
        uint64_t warm = 0;
        const unsigned rounds = getenv("REPRO_ALLOCATOR_ROUNDS") ? (unsigned)strtoul(getenv("REPRO_ALLOCATOR_ROUNDS"), NULL, 10) : 64;
        REQUIRE(rounds >= 4 && rounds <= 256, "REPRO_ALLOCATOR_ROUNDS must be 4..256");
        for (unsigned round = 0; round < rounds; round++) {
            if (round % 3 == 0) CK(vkResetCommandBuffer(cmd[0], 0));
            if (round % 3 == 1) CK(vkResetCommandPool(dev, pool, 0));
            record(cmd[0], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, 0, 1000 + round);
            submit(cmd[0], 0, 1000 + round, round % 2);
            if (round == 3) warm = allocated_bytes();
        }
        uint64_t final = allocated_bytes();
        fprintf(stderr, "command_allocator: %u rounds warm=%" PRIu64 " final=%" PRIu64 " resets=%" PRIu64 "\n", rounds, warm, final, reset_count());
        REQUIRE(final <= warm + 8u * 1024 * 1024,
            "allocator heaps grow across completed recordings instead of being reused");
        CK(vkResetCommandPool(dev, pool, VK_COMMAND_POOL_RESET_RELEASE_RESOURCES_BIT));
        record(cmd[0], 0, 0, 404);
        for (unsigned i = 0; i < 16; i++) submit(cmd[0], 0, 404, i % 2);
        CK(vkResetCommandPool(dev, pool, 0));
        record(cmd[0], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, 0, 505);
        vkFreeCommandBuffers(dev, pool, 1, &cmd[0]); /* Never submitted. */
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        CK(vkBeginCommandBuffer(cmd[1], &bi)); /* Destroy while still recording. */
        vkCmdFillBuffer(cmd[1], buffer, 0, 4, 606);
        vkDestroyCommandPool(dev, pool, NULL);
        CK(vkDeviceWaitIdle(dev));
        print_interposers();
        vkDestroyImageView(dev, view, NULL); vkDestroyImage(dev, image, NULL); vkFreeMemory(dev, im, NULL);
        vkUnmapMemory(dev, bm); vkDestroyBuffer(dev, buffer, NULL); vkFreeMemory(dev, bm, NULL);
        vkDestroyDevice(dev, NULL); vkDestroyInstance(inst, NULL);
        method_setImplementation(create, original_new); method_setImplementation(reset, original_reset);
        [allocators release]; [metal release];
        puts("OK command_allocator: bounded storage, readback, reset modes, replay and abandoned recordings");
    }
    return 0;
}
