/*
 * STEAMAC-2M/88 historical mgsvtpp.exe: float3 vertex outputs linked to float4 fragment inputs.
 * Exercise both directions without truncating any written producer component. Missing producer
 * lanes are undefined in Vulkan; this accommodation deliberately supplies zero. Every declared
 * consumer lane is checked, including z/w that an unsafe narrowing fix could lose.
 *
 * Plain/component-decorated varyings, arrays, interface blocks, smooth/centroid/noperspective,
 * and flat signed/unsigned integers are rendered into a 16x16 target. Every pixel must be
 * (64,128,191,255), +/-1. Pipelines sharing vertex SPIR-V alternate equal/wider/narrower consumer
 * widths in one cache, then repeat in reverse order after serializing/reloading that cache.
 * No tessellation or geometry ABI changes are required by this repro or accommodation.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)
#define W 16u
#define H 16u
static VkDevice dev;
static uint32_t family;
static VkPipelineLayout layout;

typedef struct Case { unsigned producer, consumer, kind, mode, component; } Case;

static VkShaderModule module(const char *dir, const char *name)
{
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "FAIL open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long length = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (length <= 0 || length % 4) { fprintf(stderr, "FAIL SPIR-V size %s\n", path); exit(1); }
    uint32_t *code = malloc((size_t)length);
    if (!code || fread(code, 1, (size_t)length, f) != (size_t)length) {
        fprintf(stderr, "FAIL reading %s\n", path); exit(1);
    }
    fclose(f);
    VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = (size_t)length, .pCode = code };
    VkShaderModule result;
    CK(vkCreateShaderModule(dev, &ci, NULL, &result));
    free(code);
    return result;
}

static uint32_t memory_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t t = 0; t < mp.memoryTypeCount; t++)
        if ((bits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & want) == want) return t;
    fprintf(stderr, "FAIL no memory type for bits 0x%x flags 0x%x\n", bits, want);
    exit(1);
}

static int run_pipeline(const char *dir, Case test, VkPipelineCache cache, VkQueue queue,
                        VkImage image, VkImageView view, VkBuffer buffer, const uint8_t *pixels)
{
    char vs[128], fs[128];
    snprintf(vs, sizeof(vs), "p%u-t%u-m%u-c%u.vert.spv", test.producer, test.kind, test.mode, test.component);
    snprintf(fs, sizeof(fs), "p%u-q%u-t%u-m%u-c%u.frag.spv", test.producer, test.consumer, test.kind, test.mode, test.component);
    VkPipelineShaderStageCreateInfo st[2] = {
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
            .module = module(dir, vs), .pName = "main" },
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = module(dir, fs), .pName = "main" }
    };
    VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    VkViewport vp = { 0, 0, W, H, 0, 1 };
    VkRect2D sc = { { 0, 0 }, { W, H } };
    VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
    VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
    VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &cba };
    VkFormat format = VK_FORMAT_R8G8B8A8_UNORM;
    VkPipelineRenderingCreateInfo rendering = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1, .pColorAttachmentFormats = &format };
    VkGraphicsPipelineCreateInfo gci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rendering,
        .stageCount = 2, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
        .pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms,
        .pColorBlendState = &cb, .layout = layout };
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkResult result = vkCreateGraphicsPipelines(dev, cache, 1, &gci, NULL, &pipeline);
    for (unsigned i = 0; i < 2; i++) vkDestroyShaderModule(dev, st[i].module, NULL);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "FAIL %s + %s: pipeline creation %d\n", vs, fs, result);
        return 1;
    }

    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
    VkCommandPool pool;
    CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd;
    CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
    VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CK(vkBeginCommandBuffer(cmd, &begin));
    VkImageMemoryBarrier to_color = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        0, 0, NULL, 0, NULL, 1, &to_color);
    VkRenderingAttachmentInfo attachment = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = view, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
    VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = sc, .layerCount = 1,
        .colorAttachmentCount = 1, .pColorAttachments = &attachment };
    vkCmdBeginRendering(cmd, &ri);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRendering(cmd);
    VkImageMemoryBarrier to_copy = to_color;
    to_copy.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    to_copy.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    to_copy.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    to_copy.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &to_copy);
    VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
    VkMemoryBarrier to_host = { VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
        0, 1, &to_host, 0, NULL, 0, NULL);
    CK(vkEndCommandBuffer(cmd));
    VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
    CK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
    CK(vkQueueWaitIdle(queue));
    const int expected[4] = { 64, 128, 191, 255 };
    unsigned bad = 0, first = 0;
    for (unsigned i = 0; i < W * H; i++)
        for (unsigned c = 0; c < 4; c++)
            if (abs((int)pixels[4 * i + c] - expected[c]) > 1) {
                if (!bad) first = i;
                bad++;
                break;
            }
    if (bad) fprintf(stderr, "FAIL %s: %u pixels wrong, first (%u,%u)=(%u,%u,%u,%u)\n", fs,
        bad, first % W, first / W, pixels[4 * first], pixels[4 * first + 1], pixels[4 * first + 2], pixels[4 * first + 3]);
    else printf("OK %s + %s: %u pixels\n", vs, fs, W * H);
    vkDestroyCommandPool(dev, pool, NULL);
    vkDestroyPipeline(dev, pipeline, NULL);
    return bad != 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: %s <spv-dir>\n", argv[0]); return 2; }
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance;
    CK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t count = 1;
    VkPhysicalDevice pd;
    if (vkEnumeratePhysicalDevices(instance, &count, &pd) < 0 || !count) { fprintf(stderr, "FAIL no GPU\n"); return 1; }
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, NULL);
    VkQueueFamilyProperties *families = calloc(count, sizeof(*families));
    if (!families) return 1;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, families);
    for (family = 0; family < count; family++) if (families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) break;
    free(families);
    if (family == count) { fprintf(stderr, "FAIL no graphics queue\n"); return 1; }
    VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    VkPhysicalDeviceFeatures2 features = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &v13 };
    vkGetPhysicalDeviceFeatures2(pd, &features);
    if (!v13.dynamicRendering || !v13.maintenance4) {
        fprintf(stderr, "SKIP stage_widths: dynamicRendering/maintenance4 unavailable\n");
        vkDestroyInstance(instance, NULL);
        return 0;
    }
    v13 = (VkPhysicalDeviceVulkan13Features){ VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = VK_TRUE, .maintenance4 = VK_TRUE };
    float priority = 1;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family,
        .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &v13,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    CK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue queue;
    vkGetDeviceQueue(dev, family, 0, &queue);
    VkPipelineLayoutCreateInfo lci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    CK(vkCreatePipelineLayout(dev, &lci, NULL, &layout));
    VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
    VkImage image;
    CK(vkCreateImage(dev, &imci, NULL, &image));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(dev, image, &requirements);
    VkMemoryAllocateInfo allocation = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type(pd, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    VkDeviceMemory image_memory;
    CK(vkAllocateMemory(dev, &allocation, NULL, &image_memory));
    CK(vkBindImageMemory(dev, image, image_memory, 0));
    VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = imci.format,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    VkImageView view;
    CK(vkCreateImageView(dev, &ivci, NULL, &view));
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    VkBuffer buffer;
    CK(vkCreateBuffer(dev, &bci, NULL, &buffer));
    vkGetBufferMemoryRequirements(dev, buffer, &requirements);
    allocation.allocationSize = requirements.size;
    allocation.memoryTypeIndex = memory_type(pd, requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory buffer_memory;
    CK(vkAllocateMemory(dev, &allocation, NULL, &buffer_memory));
    CK(vkBindBufferMemory(dev, buffer, buffer_memory, 0));
    uint8_t *pixels;
    CK(vkMapMemory(dev, buffer_memory, 0, VK_WHOLE_SIZE, 0, (void **)&pixels));

    Case cases[80];
    unsigned total = 0;
    const unsigned pairs[][2] = { {3,3}, {3,4}, {3,2}, {4,3}, {4,4}, {2,4}, {1,3}, {2,3} };
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned mode = 0; mode < 3; mode++)
            for (unsigned pair = 0; pair < sizeof(pairs) / sizeof(*pairs); pair++)
                cases[total++] = (Case){ pairs[pair][0], pairs[pair][1], kind, mode, 0 };
    for (unsigned kind = 0; kind < 3; kind++) {
        cases[total++] = (Case){ 2, 3, kind, 0, 1 };
        cases[total++] = (Case){ 3, 2, kind, 0, 1 };
    }
    VkPipelineCacheCreateInfo cci = { VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO };
    VkPipelineCache cache;
    CK(vkCreatePipelineCache(dev, &cci, NULL, &cache));
    unsigned failures = 0;
    for (unsigned i = 0; i < total; i++)
        failures += run_pipeline(argv[1], cases[i], cache, queue, image, view, buffer, pixels);
    size_t bytes = 0;
    CK(vkGetPipelineCacheData(dev, cache, &bytes, NULL));
    void *data = malloc(bytes);
    if (!data) return 1;
    CK(vkGetPipelineCacheData(dev, cache, &bytes, data));
    vkDestroyPipelineCache(dev, cache, NULL);
    cci.initialDataSize = bytes;
    cci.pInitialData = data;
    CK(vkCreatePipelineCache(dev, &cci, NULL, &cache));
    free(data);
    printf("Reloaded %zu-byte pipeline cache; reversing %u cases\n", bytes, total);
    for (unsigned i = total; i > 0; i--)
        failures += run_pipeline(argv[1], cases[i - 1], cache, queue, image, view, buffer, pixels);
    vkDestroyPipelineCache(dev, cache, NULL);
    vkUnmapMemory(dev, buffer_memory);
    vkDestroyBuffer(dev, buffer, NULL);
    vkFreeMemory(dev, buffer_memory, NULL);
    vkDestroyImageView(dev, view, NULL);
    vkDestroyImage(dev, image, NULL);
    vkFreeMemory(dev, image_memory, NULL);
    vkDestroyPipelineLayout(dev, layout, NULL);
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(instance, NULL);
    printf("%s stage_widths: %u draws, %u failures\n", failures ? "FAIL" : "OK", total * 2, failures);
    return failures != 0;
}
