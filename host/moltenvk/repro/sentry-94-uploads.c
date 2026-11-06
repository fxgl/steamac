/* STEAMAC-94: Ori's last retained uploads use Metal fmt=134 = BC3_UNORM,
 * 64/128/256/512 square images, complete mip chains, 256-aligned buffer offsets,
 * and 16-byte rows for the sub-block tails. ASTC is a control, not observed Ori
 * evidence. Exercises many uploads, encoder barriers, command-buffer replay,
 * timeline queue waits/signals and a finite fence wait; compares every block.
 * Build like sentry-image-copy.c; run with VK_DRIVER_FILES=<private ICD JSON>
 * and MTL_DEBUG_LAYER=1. Optional first argument: rounds (default 128).
 * This has no game shaders and is not a reproduction of Ori's complete frame.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "FAIL %s: %d at %d\n", #x, r_, __LINE__); exit(1); } } while (0)
#define BUFFER_SIZE (4u * 1024 * 1024)
#define TEXTURES 4
#define MIPS 10
static VkDevice dev;
static VkPhysicalDeviceMemoryProperties mp;
struct image { VkImage handle; VkDeviceMemory memory; uint32_t edge, levels; };
struct buffer { VkBuffer handle; VkDeviceMemory memory; unsigned char *map; };
struct delayed_signal { VkSemaphore semaphore; uint64_t value; };
static void *signal_later(void *arg) {
    struct delayed_signal *s = arg;
    const struct timespec delay = { .tv_sec = 1, .tv_nsec = 200000000 };
    nanosleep(&delay, NULL);
    VkSemaphoreSignalInfo info = { VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO, .semaphore = s->semaphore, .value = s->value };
    CK(vkSignalSemaphore(dev, &info));
    return NULL;
}
static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags flags) {
    for (uint32_t i = 0; i < mp.memoryTypeCount; ++i)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags) return i;
    fprintf(stderr, "FAIL memory type\n"); exit(1);
}
static struct buffer buffer(void) {
    struct buffer b;
    VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = BUFFER_SIZE,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    CK(vkCreateBuffer(dev, &ci, NULL, &b.handle));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, b.handle, &mr);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
        .memoryTypeIndex = memory_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    CK(vkAllocateMemory(dev, &ai, NULL, &b.memory)); CK(vkBindBufferMemory(dev, b.handle, b.memory, 0));
    CK(vkMapMemory(dev, b.memory, 0, VK_WHOLE_SIZE, 0, (void **)&b.map));
    return b;
}
static struct image image(VkFormat format, uint32_t edge) {
    struct image out = { .edge = edge };
    for (uint32_t n = edge; n; n >>= 1) out.levels++;
    VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = {edge,edge,1},
        .mipLevels = out.levels, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT };
    CK(vkCreateImage(dev, &ci, NULL, &out.handle));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, out.handle, &mr);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = memory_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    CK(vkAllocateMemory(dev, &ai, NULL, &out.memory)); CK(vkBindImageMemory(dev, out.handle, out.memory, 0));
    return out;
}
static void transfer_barrier(VkCommandBuffer cmd) {
    VkMemoryBarrier b = { VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &b, 0, NULL, 0, NULL);
}
int main(int argc, char **argv) {
    unsigned rounds = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : 128;
    if (!rounds) return 2;
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "sentry-94-uploads", .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst; CK(vkCreateInstance(&ici, NULL, &inst));
    VkPhysicalDevice pd; uint32_t count = 1; CK(vkEnumeratePhysicalDevices(inst, &count, &pd));
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    VkPhysicalDeviceFeatures features; vkGetPhysicalDeviceFeatures(pd, &features);
    VkPhysicalDeviceTimelineSemaphoreFeatures timeline = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES, .timelineSemaphore = VK_TRUE };
    float priority = 1;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &timeline,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .pEnabledFeatures = &features };
    CK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue queue; vkGetDeviceQueue(dev, 0, 0, &queue);
    VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    VkCommandPool pool; CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 2 };
    VkCommandBuffer cmd[2]; CK(vkAllocateCommandBuffers(dev, &cai, cmd));
    VkSemaphoreTypeCreateInfo st = { VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE };
    VkSemaphoreCreateInfo sci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &st };
    VkSemaphore sem; CK(vkCreateSemaphore(dev, &sci, NULL, &sem));
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; CK(vkCreateFence(dev, &fci, NULL, &fence));
    struct buffer src = buffer(), dst = buffer();
    uint64_t value = 0;
    const VkFormat formats[] = { VK_FORMAT_BC3_UNORM_BLOCK, VK_FORMAT_ASTC_4x4_UNORM_BLOCK };
    for (unsigned format = 0; format < 2; ++format) {
        if (!(format ? features.textureCompressionASTC_LDR : features.textureCompressionBC)) {
            printf("SKIP %s unsupported\n", format ? "ASTC" : "BC3"); continue;
        }
        struct image images[TEXTURES];
        VkBufferImageCopy regions[TEXTURES][MIPS] = {0};
        size_t sizes[TEXTURES][MIPS] = {0};
        size_t offset = 0;
        for (unsigned t = 0; t < TEXTURES; ++t) {
            images[t] = image(formats[format], 64u << t);
            for (unsigned m = 0; m < images[t].levels; ++m) {
                uint32_t edge = images[t].edge >> m;
                uint32_t blocks = (edge + 3) / 4;
                offset = (offset + 255) & ~(size_t)255;
                regions[t][m] = (VkBufferImageCopy){ .bufferOffset = offset,
                    .bufferRowLength = edge < 4 ? 4 : edge,
                    .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, m, 0, 1 }, .imageExtent = {edge,edge,1} };
                sizes[t][m] = (size_t)blocks * blocks * 16;
                offset += sizes[t][m];
            }
        }
        if (offset > BUFFER_SIZE) abort();
        for (size_t j = 0; j < offset; ++j) src.map[j] = (unsigned char)(j * 17 + 31);
        memset(dst.map, 0, offset);
        for (unsigned c = 0; c < 2; ++c) {
            CK(vkResetCommandBuffer(cmd[c], 0));
            VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
            CK(vkBeginCommandBuffer(cmd[c], &begin));
            for (unsigned t = 0; t < TEXTURES; ++t) {
                VkImageMemoryBarrier ib = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
                    .oldLayout = c ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
                    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                    .image = images[t].handle, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, images[t].levels, 0, 1 } };
                vkCmdPipelineBarrier(cmd[c], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
                /* Odd mip levels before even ones also cover DXVK's non-monotonic uploads. */
                for (unsigned parity = 0; parity < 2; ++parity)
                    for (unsigned m = 1 - parity; m < images[t].levels; m += 2) {
                        if (c) vkCmdCopyImageToBuffer(cmd[c], images[t].handle, VK_IMAGE_LAYOUT_GENERAL, dst.handle, 1, &regions[t][m]);
                        else vkCmdCopyBufferToImage(cmd[c], src.handle, images[t].handle, VK_IMAGE_LAYOUT_GENERAL, 1, &regions[t][m]);
                        transfer_barrier(cmd[c]);
                    }
            }
            VkMemoryBarrier host = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
            if (c) vkCmdPipelineBarrier(cmd[c], VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host, 0, NULL, 0, NULL);
            CK(vkEndCommandBuffer(cmd[c]));
        }
        for (unsigned round = 0; round < rounds; ++round) {
            for (size_t j = 0; j < offset; ++j) src.map[j] = (unsigned char)(j * 17 + round * 23 + 31);
            memset(dst.map, 0, offset);
            uint64_t uploaded = ++value;
            VkTimelineSemaphoreSubmitInfo ts = { VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO, .signalSemaphoreValueCount = 1, .pSignalSemaphoreValues = &uploaded };
            VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .pNext = &ts, .commandBufferCount = 1, .pCommandBuffers = &cmd[0], .signalSemaphoreCount = 1, .pSignalSemaphores = &sem };
            CK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
            VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            uint64_t readback = ++value;
            ts.waitSemaphoreValueCount = 1; ts.pWaitSemaphoreValues = &uploaded; ts.pSignalSemaphoreValues = &readback;
            submit.waitSemaphoreCount = 1; submit.pWaitSemaphores = &sem; submit.pWaitDstStageMask = &stage; submit.pCommandBuffers = &cmd[1];
            CK(vkQueueSubmit(queue, 1, &submit, fence));
            CK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 5ull * 1000 * 1000 * 1000));
            VkSemaphoreWaitInfo wi = { VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, .semaphoreCount = 1, .pSemaphores = &sem, .pValues = &readback };
            CK(vkWaitSemaphores(dev, &wi, 5ull * 1000 * 1000 * 1000));
            CK(vkResetFences(dev, 1, &fence));
            for (unsigned t = 0; t < TEXTURES; ++t) for (unsigned m = 0; m < images[t].levels; ++m) {
                size_t at = regions[t][m].bufferOffset;
                if (memcmp(src.map + at, dst.map + at, sizes[t][m])) {
                    fprintf(stderr, "FAIL format=%u round=%u edge=%u mip=%u\n", formats[format], round, images[t].edge, m); return 1;
                }
            }
        }
        CK(vkQueueWaitIdle(queue));
        for (unsigned t = 0; t < TEXTURES; ++t) { vkDestroyImage(dev, images[t].handle, NULL); vkFreeMemory(dev, images[t].memory, NULL); }
        printf("PASS %s %u rounds, 34 mips/round, every compressed block, fence + timeline\n", format ? "ASTC4x4" : "BC3", rounds);
    }
    uint64_t target = ++value;
    VkSemaphoreWaitInfo slow = { VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, .semaphoreCount = 1, .pSemaphores = &sem, .pValues = &target };
    if (vkWaitSemaphores(dev, &slow, 1100000000ull) != VK_TIMEOUT) {
        fprintf(stderr, "FAIL unsignalled finite wait did not time out\n"); return 1;
    }
    struct delayed_signal signal = {sem, target};
    pthread_t thread;
    if (pthread_create(&thread, NULL, signal_later, &signal)) return 1;
    CK(vkWaitSemaphores(dev, &slow, UINT64_MAX));
    if (pthread_join(thread, NULL)) return 1;
    puts("PASS finite CPU wait timeout and delayed CPU signal");
    CK(vkDeviceWaitIdle(dev));
    vkUnmapMemory(dev, src.memory); vkUnmapMemory(dev, dst.memory);
    vkDestroyBuffer(dev, src.handle, NULL); vkDestroyBuffer(dev, dst.handle, NULL);
    vkFreeMemory(dev, src.memory, NULL); vkFreeMemory(dev, dst.memory, NULL);
    vkDestroyFence(dev, fence, NULL); vkDestroySemaphore(dev, sem, NULL);
    vkDestroyCommandPool(dev, pool, NULL); vkDestroyDevice(dev, NULL); vkDestroyInstance(inst, NULL);
    return 0;
}
