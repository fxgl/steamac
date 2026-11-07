/* STEAMAC-57: valid std430 <=32KiB workgroup structs must compile and preserve values.
 * Usage: sentry_57_shared <shader.spv>... [--pointer <variable-pointer-shader.spv>]
 * Companion shaders use local_size_x=968, LDS_Layout[1][968], whole struct/helper/vector
 * and dynamic component stores, nested arrays, zero initialization, and an SSBO alias.
 * --pointer uses one shared element and a real Workgroup float3 pointer parameter.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define COUNT 968u
#define CK(x) do { VkResult r = (x); if (r != VK_SUCCESS) { \
    fprintf(stderr, "FAIL %s = %d (line %d)\n", #x, r, __LINE__); exit(1); } } while (0)

struct Buffer { VkBuffer buffer; VkDeviceMemory memory; float *map; };

static struct Buffer make_buffer(VkPhysicalDevice physical, VkDevice device, VkDeviceSize size)
{
    struct Buffer result = {0};
    VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
    CK(vkCreateBuffer(device, &ci, NULL, &result.buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(device, result.buffer, &requirements);
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(physical, &properties);
    const VkMemoryPropertyFlags flags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint32_t type;
    for (type = 0; type < properties.memoryTypeCount; type++)
        if ((requirements.memoryTypeBits & (1u << type)) &&
            (properties.memoryTypes[type].propertyFlags & flags) == flags) break;
    if (type == properties.memoryTypeCount) { fprintf(stderr, "FAIL no coherent host memory\n"); exit(1); }
    VkMemoryAllocateInfo allocation = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size, .memoryTypeIndex = type };
    CK(vkAllocateMemory(device, &allocation, NULL, &result.memory));
    CK(vkBindBufferMemory(device, result.buffer, result.memory, 0));
    CK(vkMapMemory(device, result.memory, 0, VK_WHOLE_SIZE, 0, (void **)&result.map));
    return result;
}

static VkShaderModule read_module(VkDevice device, const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file || fseek(file, 0, SEEK_END)) { fprintf(stderr, "FAIL open %s\n", path); exit(1); }
    long size = ftell(file);
    if (size <= 0 || size % 4 || fseek(file, 0, SEEK_SET)) { fprintf(stderr, "FAIL size %s\n", path); exit(1); }
    uint32_t *words = malloc((size_t)size);
    if (!words || fread(words, 1, (size_t)size, file) != (size_t)size) { fprintf(stderr, "FAIL read %s\n", path); exit(1); }
    fclose(file);
    VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = (size_t)size, .pCode = words };
    VkShaderModule module;
    CK(vkCreateShaderModule(device, &ci, NULL, &module));
    free(words);
    return module;
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <shader.spv>... [--pointer <shader.spv>]\n", argv[0]); return 2; }
    VkApplicationInfo application = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo instance_info = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &application };
    VkInstance instance;
    CK(vkCreateInstance(&instance_info, NULL, &instance));
    VkPhysicalDevice physical;
    uint32_t count = 1;
    CK(vkEnumeratePhysicalDevices(instance, &count, &physical));
    if (!count) { fprintf(stderr, "FAIL no physical device\n"); return 1; }
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physical, &properties);
    printf("device=%s maxComputeSharedMemorySize=%u maxComputeWorkGroupInvocations=%u\n",
        properties.deviceName, properties.limits.maxComputeSharedMemorySize, properties.limits.maxComputeWorkGroupInvocations);
    printf("LDS_Layout: logical-payload=%u std430-upper-bound=%u captured-unpacked-MSL=%u bytes\n",
        COUNT * 20u, COUNT * 32u, COUNT * 48u);
    if (properties.limits.maxComputeSharedMemorySize < COUNT * 32u ||
        properties.limits.maxComputeWorkGroupInvocations < COUNT || properties.limits.maxComputeWorkGroupSize[0] < COUNT) {
        fprintf(stderr, "FAIL device cannot support the captured shader's valid Vulkan limits\n"); return 1;
    }
    VkPhysicalDeviceVulkan13Features available13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    VkPhysicalDeviceVulkan11Features available11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &available13 };
    VkPhysicalDeviceFeatures2 available = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &available11 };
    vkGetPhysicalDeviceFeatures2(physical, &available);
    VkPhysicalDeviceVulkan13Features features13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .shaderZeroInitializeWorkgroupMemory = available13.shaderZeroInitializeWorkgroupMemory };
    VkPhysicalDeviceVulkan11Features features11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &features13,
        .variablePointersStorageBuffer = available11.variablePointersStorageBuffer, .variablePointers = available11.variablePointers };
    uint32_t family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, NULL);
    VkQueueFamilyProperties *families = calloc(family_count, sizeof(*families));
    if (!families) return 1;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, families);
    uint32_t family;
    for (family = 0; family < family_count; family++)
        if (families[family].queueFlags & VK_QUEUE_COMPUTE_BIT) break;
    free(families);
    if (family == family_count) { fprintf(stderr, "FAIL no compute queue\n"); return 1; }
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo device_info = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &features11,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info };
    VkDevice device;
    CK(vkCreateDevice(physical, &device_info, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);
    struct Buffer buffers[2] = { make_buffer(physical, device, COUNT * 16u), make_buffer(physical, device, COUNT * 32u) };
    VkDescriptorSetLayoutBinding bindings[2] = {
        { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
        { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL }
    };
    VkDescriptorSetLayoutCreateInfo set_info = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = bindings };
    VkDescriptorSetLayout set_layout;
    CK(vkCreateDescriptorSetLayout(device, &set_info, NULL, &set_layout));
    VkPipelineLayoutCreateInfo layout_info = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &set_layout };
    VkPipelineLayout layout;
    CK(vkCreatePipelineLayout(device, &layout_info, NULL, &layout));
    VkDescriptorPoolSize pool_size = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2 };
    VkDescriptorPoolCreateInfo descriptor_pool_info = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size };
    VkDescriptorPool descriptor_pool;
    CK(vkCreateDescriptorPool(device, &descriptor_pool_info, NULL, &descriptor_pool));
    VkDescriptorSetAllocateInfo set_allocation = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &set_layout };
    VkDescriptorSet set;
    CK(vkAllocateDescriptorSets(device, &set_allocation, &set));
    VkDescriptorBufferInfo buffer_info[2] = { { buffers[0].buffer, 0, COUNT * 16u }, { buffers[1].buffer, 0, COUNT * 32u } };
    VkWriteDescriptorSet writes[2];
    for (unsigned i = 0; i < 2; i++) writes[i] = (VkWriteDescriptorSet){ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set, .dstBinding = i, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &buffer_info[i] };
    vkUpdateDescriptorSets(device, 2, writes, 0, NULL);
    VkCommandPoolCreateInfo command_pool_info = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
    VkCommandPool command_pool;
    CK(vkCreateCommandPool(device, &command_pool_info, NULL, &command_pool));
    for (int argument = 1; argument < argc; argument++) {
        int pointer = !strcmp(argv[argument], "--pointer");
        if (pointer && ++argument == argc) return 2;
        if (pointer && !features11.variablePointers) { fprintf(stderr, "FAIL variablePointers unavailable\n"); return 1; }
        const char *path = argv[argument];
        VkShaderModule module = read_module(device, path);
        VkComputePipelineCreateInfo pipeline_info = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
                .module = module, .pName = "main" }, .layout = layout };
        VkPipeline pipeline;
        CK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline));
        memset(buffers[0].map, 0xff, COUNT * 16u);
        memset(buffers[1].map, 0xff, COUNT * 32u);
        VkCommandBufferAllocateInfo command_allocation = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = command_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        VkCommandBuffer command;
        CK(vkAllocateCommandBuffers(device, &command_allocation, &command));
        VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        CK(vkBeginCommandBuffer(command, &begin));
        vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
        vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        vkCmdDispatch(command, 1, 1, 1);
        VkMemoryBarrier barrier = { VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
        CK(vkEndCommandBuffer(command));
        VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command };
        CK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
        CK(vkQueueWaitIdle(queue));
        unsigned external = !pointer && strstr(path, "external") != NULL;
        for (unsigned i = 0; i < COUNT; i++) {
            unsigned t = pointer ? 0 : (i + 1u) % COUNT;
            float expected[4] = { t + 2.0f, 3.0f * t + 72.0f, t + 7.0f, t + 27.0f + (t % 3u == 1) };
            for (unsigned c = 0; c < 4; c++) if (buffers[0].map[4u * i + c] != expected[c]) {
                fprintf(stderr, "FAIL %s result[%u][%u]=%g expected %g\n", path, i, c, buffers[0].map[4u * i + c], expected[c]); return 1;
            }
            if (external) {
                float expected_struct[5] = { t + 2.0f, t + 11.0f + (t % 3u == 0),
                    t + 27.0f + (t % 3u == 1), t + 33.0f + (t % 3u == 2), t + 7.0f };
                const unsigned offset[5] = { 0, 4, 5, 6, 7 };
                for (unsigned c = 0; c < 5; c++) if (buffers[1].map[8u * i + offset[c]] != expected_struct[c]) {
                    fprintf(stderr, "FAIL %s std430[%u]+%u=%g expected %g\n", path, i, 4u * offset[c],
                        buffers[1].map[8u * i + offset[c]], expected_struct[c]); return 1;
                }
            }
        }
        printf("PASS %s: %u invocations, shared struct/helper/vector/component%s readback\n", path, COUNT, external ? " and std430 SSBO" : "");
        vkFreeCommandBuffers(device, command_pool, 1, &command);
        vkDestroyPipeline(device, pipeline, NULL);
        vkDestroyShaderModule(device, module, NULL);
    }
    vkDestroyCommandPool(device, command_pool, NULL);
    vkDestroyDescriptorPool(device, descriptor_pool, NULL);
    vkDestroyPipelineLayout(device, layout, NULL);
    vkDestroyDescriptorSetLayout(device, set_layout, NULL);
    for (unsigned i = 0; i < 2; i++) {
        vkUnmapMemory(device, buffers[i].memory);
        vkDestroyBuffer(device, buffers[i].buffer, NULL);
        vkFreeMemory(device, buffers[i].memory, NULL);
    }
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    return 0;
}
