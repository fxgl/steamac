/* STEAMAC-67: 12 vertex buffers + 18 discrete SSBO descriptors leave only one
 * Metal auxiliary slot; buffer lengths must fit without reserving unused helpers.
 * STEAMAC-3A/X: invalid blending on integer targets must return an error, not abort.
 * STEAMAC-57: a legal 32 KiB shared-memory shader must compile at the advertised limit.
 * STEAMAC-83: reject unsupported tessellation+geometry, never emit buffer(255).
 * STEAMAC-8J: sample-rate projected texture sampling must link on M1.
 * Usage: pipeline_limits <shader dir> buffers|blend|shared|oversized|tessgeom|projected
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#define CK(x) do { VkResult r = (x); if (r) { printf("FAIL %s = %d\n", #x, r); exit(1); } } while (0)
static VkDevice dev;
static const char *dir;
static VkShaderModule shader(const char *name) {
    char path[1024]; snprintf(path, sizeof(path), "%s/%s.spv", dir, name);
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    uint32_t *code = malloc(n); if (fread(code, 1, n, f) != (size_t)n) exit(1); fclose(f);
    VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = n, .pCode = code };
    VkShaderModule m; CK(vkCreateShaderModule(dev, &ci, NULL, &m)); free(code); return m;
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    dir = argv[1]; int buffers = !strcmp(argv[2], "buffers"), blend = !strcmp(argv[2], "blend");
    int tessgeom = !strcmp(argv[2], "tessgeom");
    int projected = !strcmp(argv[2], "projected");
    VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai };
    VkInstance inst; CK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t count = 1; VkPhysicalDevice pd; CK(vkEnumeratePhysicalDevices(inst, &count, &pd));
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
    float priority = 1;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &priority };
    VkPhysicalDeviceFeatures features = { .robustBufferAccess = VK_TRUE };
    features.tessellationShader = tessgeom;
    features.geometryShader = tessgeom;
    features.sampleRateShading = projected;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .pEnabledFeatures = &features };
    CK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkDescriptorSetLayoutBinding bindings[18];
    for (uint32_t i = 0; i < 18; i++) bindings[i] = (VkDescriptorSetLayoutBinding) { i, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_VERTEX_BIT };
    if (!buffers) bindings[0].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    if (projected) bindings[0] = (VkDescriptorSetLayoutBinding) { 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT };
    VkDescriptorSetLayoutCreateInfo dsci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = buffers ? 18 : blend || tessgeom ? 0 : 1, .pBindings = bindings };
    VkDescriptorSetLayout set; CK(vkCreateDescriptorSetLayout(dev, &dsci, NULL, &set));
    VkPipelineLayoutCreateInfo lci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = blend || tessgeom ? 0 : 1, .pSetLayouts = &set };
    VkPipelineLayout layout; CK(vkCreatePipelineLayout(dev, &lci, NULL, &layout));
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkResult result;
    if (tessgeom) {
        VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS };
        VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .subpassCount = 1, .pSubpasses = &sub };
        VkRenderPass pass; CK(vkCreateRenderPass(dev, &rpci, NULL, &pass));
        VkPipelineShaderStageCreateInfo stages[] = {
            { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader("sentry-83-tessgeom.vert"), .pName = "main" },
            { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT, .module = shader("sentry-83-tessgeom.tesc"), .pName = "main" },
            { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, .module = shader("sentry-83-tessgeom.tese"), .pName = "main" },
            { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_GEOMETRY_BIT, .module = shader("sentry-83-tessgeom.geom"), .pName = "main" }
        };
        VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
        VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_PATCH_LIST };
        VkPipelineTessellationStateCreateInfo ts = { VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO, .patchControlPoints = 3 };
        VkViewport viewport = { 0, 0, 4, 4, 0, 1 }; VkRect2D scissor = { { 0, 0 }, { 4, 4 } };
        VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
        VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL, .lineWidth = 1 };
        VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
        VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 4, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pTessellationState = &ts, .pViewportState = &vp, .pRasterizationState = &rs, .pMultisampleState = &ms, .layout = layout, .renderPass = pass };
        result = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &pipeline);
        int good = result == VK_ERROR_FEATURE_NOT_PRESENT && !pipeline;
        printf("%s unsupported tessellation+geometry is rejected before Metal compilation: %d\n", good ? "OK" : "FAIL", result);
        result = good ? VK_SUCCESS : VK_ERROR_UNKNOWN;
        for (unsigned i = 0; i < 4; i++) vkDestroyShaderModule(dev, stages[i].module, NULL);
        vkDestroyRenderPass(dev, pass, NULL);
    } else if (!buffers && !blend && !projected) {
        if (props.limits.maxComputeSharedMemorySize < 32768) { printf("SKIP shared limit %u\n", props.limits.maxComputeSharedMemorySize); return 0; }
        int oversized = !strcmp(argv[2], "oversized");
        VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .layout = layout,
            .stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = shader(oversized ? "pipeline_oversized.comp" : "pipeline_shared.comp"), .pName = "main" } };
        result = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &pipeline);
        int good = oversized ? result == VK_ERROR_INITIALIZATION_FAILED && !pipeline : result == VK_SUCCESS && pipeline;
        printf("%s shared %u bytes (advertised %u): %d\n", good ? "OK" : "FAIL", oversized ? 46464 : 32768, props.limits.maxComputeSharedMemorySize, result);
        result = good ? VK_SUCCESS : VK_ERROR_UNKNOWN;
    } else {
        VkSampleCountFlagBits samples = projected ? VK_SAMPLE_COUNT_4_BIT : VK_SAMPLE_COUNT_1_BIT;
        VkAttachmentDescription att = { .format = projected ? VK_FORMAT_R8G8B8A8_UNORM : VK_FORMAT_R32_UINT, .samples = samples, .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ref };
        VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
        VkRenderPass pass; CK(vkCreateRenderPass(dev, &rpci, NULL, &pass));
        VkPipelineShaderStageCreateInfo stages[] = {
            { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = shader(buffers ? "pipeline_buffers.vert" : projected ? "sentry-8j-projected.vert" : "msaa.vert"), .pName = "main" },
            { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = shader(projected ? "sentry-8j-projected.frag" : "pipeline_uint.frag"), .pName = "main" }
        };
        VkVertexInputBindingDescription vb[12]; VkVertexInputAttributeDescription va[12];
        for (uint32_t i = 0; i < 12; i++) {
            vb[i] = (VkVertexInputBindingDescription) { i, 16, VK_VERTEX_INPUT_RATE_VERTEX };
            va[i] = (VkVertexInputAttributeDescription) { i, i, VK_FORMAT_R32G32B32A32_SFLOAT, 0 };
        }
        VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .vertexBindingDescriptionCount = buffers ? 12 : 0, .pVertexBindingDescriptions = vb, .vertexAttributeDescriptionCount = buffers ? 12 : 0, .pVertexAttributeDescriptions = va };
        VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
        VkViewport viewport = { 0, 0, 4, 4, 0, 1 }; VkRect2D scissor = { { 0, 0 }, { 4, 4 } };
        VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor };
        VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL, .lineWidth = 1 };
        VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = samples };
        VkPipelineColorBlendAttachmentState ba = { .blendEnable = blend, .srcColorBlendFactor = VK_BLEND_FACTOR_ONE, .dstColorBlendFactor = VK_BLEND_FACTOR_ZERO, .colorBlendOp = VK_BLEND_OP_ADD, .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO, .alphaBlendOp = VK_BLEND_OP_ADD, .colorWriteMask = 15 };
        VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &ba };
        VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vp, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout, .renderPass = pass };
        result = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &pipeline);
        int good = blend ? result == VK_ERROR_INITIALIZATION_FAILED && !pipeline : result == VK_SUCCESS && pipeline;
        printf("%s %s: %d\n", good ? "OK" : "FAIL", argv[2], result);
        result = good ? VK_SUCCESS : VK_ERROR_UNKNOWN;
        vkDestroyRenderPass(dev, pass, NULL);
    }
    vkDestroyPipeline(dev, pipeline, NULL); vkDestroyPipelineLayout(dev, layout, NULL); vkDestroyDescriptorSetLayout(dev, set, NULL);
    vkDestroyDevice(dev, NULL); vkDestroyInstance(inst, NULL);
    return result ? 1 : 0;
}
