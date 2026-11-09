/* STEAMAC-AD: exercise the real library/pipeline failure loggers at their byte
 * and line boundaries. Synthetic MSL only; this is not the missing Bodycam shader.
 * The pipeline case uses pipeline_oversized.comp's 46464-byte threadgroup array.
 * Direct MSL avoids translation changing the source dimensions under test.
 * Usage: sentry_ad_capture <MSL module file> <pipeline|library>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "FAIL %s = %d\n", #x, r_); exit(1); } } while (0)

int main(int argc, char **argv)
{
    if (argc != 3 || (strcmp(argv[2], "pipeline") && strcmp(argv[2], "library"))) {
        fprintf(stderr, "usage: %s <MSL module file> <pipeline|library>\n", argv[0]);
        return 2;
    }
    int library = !strcmp(argv[2], "library");
    FILE *input = fopen(argv[1], "rb");
    if (!input) { perror(argv[1]); return 1; }
    if (fseek(input, 0, SEEK_END)) return 1;
    long size = ftell(input);
    if (size < 8 || size % sizeof(uint32_t) || fseek(input, 0, SEEK_SET)) return 1;
    uint32_t *code = malloc((size_t)size);
    if (!code || fread(code, 1, (size_t)size, input) != (size_t)size) return 1;
    fclose(input);

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo instance_info = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance;
    CK(vkCreateInstance(&instance_info, NULL, &instance));
    uint32_t count = 1;
    VkPhysicalDevice physical;
    CK(vkEnumeratePhysicalDevices(instance, &count, &physical));
    if (!count) { fprintf(stderr, "FAIL no physical device\n"); return 1; }
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physical, &properties);
    if (properties.limits.maxComputeSharedMemorySize >= 46464) {
        fprintf(stderr, "FAIL diagnostic harness needs a threadgroup memory limit below 46464 bytes\n");
        return 1;
    }
    float priority = 1;
    VkDeviceQueueCreateInfo queue_info = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo device_info = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info };
    VkDevice device;
    CK(vkCreateDevice(physical, &device_info, NULL, &device));

    /* The module file starts with MoltenVK's private uint32_t MSL source magic,
     * then a null-terminated source (mvk_private_api.h). No SPIR-V reconstruction. */
    VkShaderModuleCreateInfo module_info = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = (size_t)size, .pCode = code };
    VkShaderModule module = VK_NULL_HANDLE;
    VkResult result = vkCreateShaderModule(device, &module_info, NULL, &module);
    free(code);
    if (result && (!library || result != VK_ERROR_INITIALIZATION_FAILED)) {
        fprintf(stderr, "FAIL shader module = %d\n", result);
        return 1;
    }
    if (!result) {
        VkPipelineLayoutCreateInfo layout_info = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        VkPipelineLayout layout;
        CK(vkCreatePipelineLayout(device, &layout_info, NULL, &layout));
        VkComputePipelineCreateInfo pipeline_info = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = module, .pName = "main0" },
            .layout = layout };
        VkPipeline pipeline = VK_NULL_HANDLE;
        result = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline);
        if (pipeline) vkDestroyPipeline(device, pipeline, NULL);
        vkDestroyPipelineLayout(device, layout, NULL);
    }
    if (module) vkDestroyShaderModule(device, module, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    if (result != VK_ERROR_INITIALIZATION_FAILED) {
        fprintf(stderr, "FAIL expected rejected synthetic %s shader, got %d\n", argv[2], result);
        return 1;
    }
    printf("OK rejected synthetic %s shader; checking its diagnostics separately\n", argv[2]);
    return 0;
}
