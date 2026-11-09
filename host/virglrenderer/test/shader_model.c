/* STEAMAC-AC/AB/A0: query the exact SM 6.0 gate in Proton 11's vkd3d-proton
 * 212991fc2c266bc0d59f4c4ce8f80f7126508d71, libs/vkd3d/device.c:9736.
 * Run against a host ICD and the guest Venus ICD; no device creation or GPU work.
 * Usage: shader_model [--require-sm60]
 */
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(expr) do { VkResult result = (expr); if (result != VK_SUCCESS) { \
    fprintf(stderr, "%s: VkResult %d\n", #expr, result); return 1; } } while (0)

int main(int argc, char **argv)
{
    const int require_sm60 = argc == 2 && !strcmp(argv[1], "--require-sm60");
    if (argc > 2 || (argc == 2 && !require_sm60)) {
        fprintf(stderr, "usage: %s [--require-sm60]\n", argv[0]);
        return 2;
    }
    const VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "steamac-shader-model-probe",
        .apiVersion = VK_API_VERSION_1_3,
    };
    const VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    VkInstance instance;
    CK(vkCreateInstance(&info, NULL, &instance));
    VkPhysicalDevice device;
    uint32_t count = 1;
    VkResult result = vkEnumeratePhysicalDevices(instance, &count, &device);
    if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || !count) {
        fprintf(stderr, "no physical device (VkResult %d)\n", result);
        vkDestroyInstance(instance, NULL);
        return 1;
    }

    VkPhysicalDeviceVulkan12Features f12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    };
    VkPhysicalDeviceFeatures2 features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f12,
    };
    VkPhysicalDeviceVulkan12Properties p12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES,
    };
    VkPhysicalDeviceVulkan11Properties p11 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES, .pNext = &p12,
    };
    VkPhysicalDeviceProperties2 properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &p11,
    };
    vkGetPhysicalDeviceFeatures2(device, &features);
    vkGetPhysicalDeviceProperties2(device, &properties);

    const VkSubgroupFeatureFlags required_ops = VK_SUBGROUP_FEATURE_BASIC_BIT |
        VK_SUBGROUP_FEATURE_VOTE_BIT | VK_SUBGROUP_FEATURE_ARITHMETIC_BIT |
        VK_SUBGROUP_FEATURE_BALLOT_BIT | VK_SUBGROUP_FEATURE_SHUFFLE_BIT |
        VK_SUBGROUP_FEATURE_QUAD_BIT;
    const VkShaderStageFlags required_stages = VK_SHADER_STAGE_COMPUTE_BIT |
        VK_SHADER_STAGE_FRAGMENT_BIT;
    const unsigned missing_ops = required_ops & ~p11.subgroupSupportedOperations;
    const unsigned missing_stages = required_stages & ~p11.subgroupSupportedStages;
    const int sm60 = p11.subgroupSize >= 4 && !missing_ops && !missing_stages &&
        (f12.scalarBlockLayout || f12.uniformBufferStandardLayout) && features.features.shaderInt16;
    const int denorm = p12.denormBehaviorIndependence != VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_NONE &&
        p12.shaderDenormFlushToZeroFloat32 && p12.shaderDenormPreserveFloat32;

    printf("device=%s driver=%s %s api=%u.%u.%u\n", properties.properties.deviceName,
           p12.driverName, p12.driverInfo, VK_VERSION_MAJOR(properties.properties.apiVersion),
           VK_VERSION_MINOR(properties.properties.apiVersion), VK_VERSION_PATCH(properties.properties.apiVersion));
    printf("SM60 subgroupSize=%u (requires >=4) operations=0x%x required=0x%x missing=0x%x\n",
           p11.subgroupSize, p11.subgroupSupportedOperations, required_ops, missing_ops);
    printf("SM60 stages=0x%x required=0x%x missing=0x%x scalarBlockLayout=%u uniformBufferStandardLayout=%u shaderInt16=%u\n",
           p11.subgroupSupportedStages, required_stages, missing_stages,
           f12.scalarBlockLayout, f12.uniformBufferStandardLayout, features.features.shaderInt16);
    printf("SM60=%s; denormBehaviorIndependence=%u flush32=%u preserve32=%u -> automatic shader-model base=%s\n",
           sm60 ? "supported" : "MISSING", p12.denormBehaviorIndependence,
           p12.shaderDenormFlushToZeroFloat32, p12.shaderDenormPreserveFloat32,
           !sm60 ? "5.1" : denorm ? "6.5 (before optional 6.6+ gates)" : "6.0");
    printf("Not SM60 prerequisites: shaderInt64=%u shaderFloat16=%u shaderInt8=%u shaderBufferInt64Atomics=%u\n",
           features.features.shaderInt64, f12.shaderFloat16, f12.shaderInt8, f12.shaderBufferInt64Atomics);
    vkDestroyInstance(instance, NULL);
    return require_sm60 && !sm60 ? 1 : 0;
}
