/*
 * 64-bit image atomics (VK_EXT_shader_image_atomic_int64), the image counterpart of atomic64.c's
 * buffer case. Vulkan's R64_UINT storage images and R64Sint are R32G32_UINT to Metal, where the
 * only 64-bit texture atomic is the void tex.atomic_max/min(coord, ulong4): the codegen must lower
 * OpAtomicUMax/OpAtomicUMin on an R64 image to a texel read followed by that void form instead of
 * the fetch form it emits for 32-bit images.
 *
 * This case checks values, not compilation:
 *
 *  image_atomic64_race.comp   512 workgroups x 64 invocations race 64-bit imageAtomicMax on one
 *                             16x16 R64_UINT storage image and imageAtomicMin on another. The CPU
 *                             recomputes every texel from the same mix() and the same coordinate
 *                             mapping: a lowering that truncates to 32 bits, drops an atomic or
 *                             lights up the wrong texel fails on the values.
 *  image_atomic64_fetch.comp  one invocation, so the value returned by the fetch form is exactly
 *                             Vulkan's "original value". The cell is preset twice, once where the
 *                             atomic changes it and once where it does not, and both the returned
 *                             value and the texel actually written are checked exactly.
 *
 * The whole case is skipped, with the capability printed, when shaderImageInt64Atomics is not
 * advertised: the suite must stay green on a driver that honestly does not offer 64-bit image
 * atomics. REPRO_FORCE=1 runs it anyway, where the pipeline then fails to compile with the
 * driver's own SPIR-V/MSL error.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define IMG_SIZE 16u
#define TEXELS (IMG_SIZE * IMG_SIZE)
#define WORKGROUPS 512u /* x 64 invocations = 32768 */
#define INVOCATIONS (WORKGROUPS * 64u)

#define NEW_MAX 0xfeedfacecafebeefUL
#define NEW_MIN 0x123456789abcdef0UL

static int force;
static VkDevice dev;
static int failures;

static void check(const char *what, int ok)
{
	printf("%-4s %s\n", ok ? "OK" : "FAIL", what);
	if (!ok)
		failures++;
}

static VkShaderModule module(const char *dir, const char *name)
{
	char path[1024];
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) { printf("FAIL open %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint32_t *code = malloc(n);
	if (fread(code, 1, n, f) != (size_t)n) { printf("FAIL read %s\n", path); exit(1); }
	fclose(f);
	VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = n, .pCode = code };
	VkShaderModule m;
	CK(vkCreateShaderModule(dev, &ci, NULL, &m));
	free(code);
	return m;
}

/* A host-visible, coherent buffer, mapped for the whole run. */
static VkBuffer host_buffer(VkPhysicalDevice pd, VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t t = 0;
	while (!(mr.memoryTypeBits & (1u << t)) ||
	       (mp.memoryTypes[t].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) !=
	           (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
		t++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, map));
	return buf;
}

/* A 16x16 R64_UINT storage image that can be filled and read back with copies. */
static VkImage storage_image(VkPhysicalDevice pd)
{
	VkImageCreateInfo ci = {
		VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R64_UINT,
		.extent = { IMG_SIZE, IMG_SIZE, 1 },
		.mipLevels = 1,
		.arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	};
	VkImage img;
	CK(vkCreateImage(dev, &ci, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t t = 0;
	while (!(mr.memoryTypeBits & (1u << t)))
		t++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindImageMemory(dev, img, mem, 0));
	return img;
}

/* The shader's mix(): a bijective 64-to-64-bit scramble, so every invocation's value is distinct. */
static uint64_t mix(uint64_t x)
{
	x ^= x >> 33;
	x *= 0xff51afd7ed558ccdUL;
	x ^= x >> 29;
	return x;
}

struct pipeline {
	VkPipelineLayout layout;
	VkPipeline pipe;
};

static struct pipeline compute_pipeline(VkDescriptorSetLayout dsl, const char *dir, const char *shader, const char *entry)
{
	struct pipeline p;
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &p.layout));
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = module(dir, shader), .pName = entry }, .layout = p.layout };
	VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p.pipe);
	printf("%-4s create %s (VkResult %d)\n", r == VK_SUCCESS ? "OK" : "FAIL", shader, r);
	if (r)
		exit(1);
	return p;
}

static VkDescriptorSetLayout descriptor_layout(int with_buffer)
{
	VkDescriptorSetLayoutBinding b[3] = {
		{ .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
		{ .binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
		{ .binding = 2, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
	};
	VkDescriptorSetLayoutCreateInfo ci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = with_buffer ? 3u : 2u, .pBindings = b };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &ci, NULL, &dsl));
	return dsl;
}

static VkCommandBuffer begin(VkCommandPool pool)
{
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &cbbi));
	return cmd;
}

static void image_barrier(VkCommandBuffer cmd, VkImage image,
                          VkImageLayout old, VkImageLayout new,
                          VkAccessFlags src_access, VkAccessFlags dst_access,
                          VkPipelineStageFlags src_stage, VkPipelineStageFlags dst_stage)
{
	VkImageMemoryBarrier b = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.srcAccessMask = src_access,
		.dstAccessMask = dst_access,
		.oldLayout = old,
		.newLayout = new,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.image = image,
		.subresourceRange = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 },
	};
	vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, NULL, 0, NULL, 1, &b);
}

static const VkBufferImageCopy region = {
	.bufferOffset = 0,
	.bufferRowLength = 0,
	.bufferImageHeight = 0,
	.imageSubresource = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
	.imageOffset = { 0, 0, 0 },
	.imageExtent = { IMG_SIZE, IMG_SIZE, 1 },
};

static void submit(VkQueue queue, VkCommandBuffer cmd)
{
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkEndCommandBuffer(cmd));
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <spv dir>\n", argv[0]); return 2; }
	const char *dir = argv[1];

	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }

	VkPhysicalDeviceShaderImageAtomicInt64FeaturesEXT ia64 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_IMAGE_ATOMIC_INT64_FEATURES_EXT };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &ia64 };
	vkGetPhysicalDeviceFeatures2(pd, &f2);
	int image64 = ia64.shaderImageInt64Atomics == VK_TRUE;
	printf("INFO shaderImageInt64Atomics=%d sparseImageInt64Atomics=%d\n", image64, ia64.sparseImageInt64Atomics);
	force = getenv("REPRO_FORCE") != NULL;

	if (!image64 && !force) {
		printf("SKIP 64-bit storage-image atomics: VK_EXT_shader_image_atomic_int64 shaderImageInt64Atomics is not advertised\n");
		return 0;
	}
	if (!image64)
		printf("INFO forcing the 64-bit storage-image atomics the driver does not advertise (REPRO_FORCE)\n");

	/* Enabling the feature when it was not advertised is what REPRO_FORCE wants: the shader then
	 * fails to compile with the driver's own error instead of silently using a different path. */
	ia64.shaderImageInt64Atomics = image64 ? VK_TRUE : VK_FALSE;
	ia64.sparseImageInt64Atomics = VK_FALSE;
	f2.features.shaderInt64 = VK_TRUE;
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

	VkDescriptorPoolSize ps[2] = {
		{ VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 8 },
		{ VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2 },
	};
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 4, .poolSizeCount = 2, .pPoolSizes = ps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));

	VkImage img_max = storage_image(pd);
	VkImage img_min = storage_image(pd);
	uint64_t *fill_max, *fill_min, *out_max, *out_min, *fetch_out;
	VkBuffer fbuf_max = host_buffer(pd, (VkDeviceSize)TEXELS * 8, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, (void **)&fill_max);
	VkBuffer fbuf_min = host_buffer(pd, (VkDeviceSize)TEXELS * 8, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, (void **)&fill_min);
	VkBuffer rbuf_max = host_buffer(pd, (VkDeviceSize)TEXELS * 8, VK_BUFFER_USAGE_TRANSFER_DST_BIT, (void **)&out_max);
	VkBuffer rbuf_min = host_buffer(pd, (VkDeviceSize)TEXELS * 8, VK_BUFFER_USAGE_TRANSFER_DST_BIT, (void **)&out_min);
	VkBuffer fetch_buf = host_buffer(pd, 16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&fetch_out);

	/* ---- contended effects on the values, 32768 invocations ------------------------------- */
	VkDescriptorSetLayout race_dsl = descriptor_layout(0);
	struct pipeline race = compute_pipeline(race_dsl, dir, "image_atomic64_race.comp.spv", "main");
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &race_dsl };
	VkDescriptorSet rset;
	CK(vkAllocateDescriptorSets(dev, &dsai, &rset));
	VkDescriptorImageInfo rii[2] = {
		{ .imageView = VK_NULL_HANDLE, .imageLayout = VK_IMAGE_LAYOUT_GENERAL },
		{ .imageView = VK_NULL_HANDLE, .imageLayout = VK_IMAGE_LAYOUT_GENERAL },
	};
	VkWriteDescriptorSet rw[2] = {
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = rset, .dstBinding = 0, .descriptorCount = 1,
		  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &rii[0] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = rset, .dstBinding = 1, .descriptorCount = 1,
		  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &rii[1] },
	};

	/* The race shader only needs the images; the descriptors are written after the views exist. */
	VkImageView view_max, view_min;
	{
		VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
			.image = img_max, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R64_UINT,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		CK(vkCreateImageView(dev, &ivci, NULL, &view_max));
		ivci.image = img_min;
		CK(vkCreateImageView(dev, &ivci, NULL, &view_min));
	}
	rii[0].imageView = view_max;
	rii[1].imageView = view_min;
	vkUpdateDescriptorSets(dev, 2, rw, 0, NULL);

	for (uint32_t i = 0; i < TEXELS; i++) {
		fill_max[i] = 0;
		fill_min[i] = ~0UL;
	}

	VkCommandBuffer cmd = begin(pool);
	image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
	              0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
	image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
	              0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
	vkCmdCopyBufferToImage(cmd, fbuf_max, img_max, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
	vkCmdCopyBufferToImage(cmd, fbuf_min, img_min, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
	image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
	              VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
	              VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
	image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
	              VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
	              VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);

	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, race.pipe);
	vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, race.layout, 0, 1, &rset, 0, NULL);
	vkCmdDispatch(cmd, WORKGROUPS, 1, 1);

	image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	              VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
	              VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
	image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	              VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
	              VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
	vkCmdCopyImageToBuffer(cmd, img_max, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rbuf_max, 1, &region);
	vkCmdCopyImageToBuffer(cmd, img_min, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rbuf_min, 1, &region);
	image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
	              VK_ACCESS_TRANSFER_READ_BIT, 0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
	image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
	              VK_ACCESS_TRANSFER_READ_BIT, 0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
	submit(queue, cmd);

	uint64_t want_max[TEXELS], want_min[TEXELS];
	for (uint32_t t = 0; t < TEXELS; t++) {
		want_max[t] = 0;
		want_min[t] = ~0UL;
	}
	for (uint32_t i = 0; i < INVOCATIONS; i++) {
		uint64_t a = mix(i);
		uint32_t t = (i & (IMG_SIZE - 1u)) + ((i >> 4u) & (IMG_SIZE - 1u)) * IMG_SIZE;
		if (a > want_max[t]) want_max[t] = a;
		if (a < want_min[t]) want_min[t] = a;
	}
	uint32_t bad_max = 0, bad_min = 0;
	for (uint32_t t = 0; t < TEXELS; t++) {
		if (out_max[t] != want_max[t]) bad_max++;
		if (out_min[t] != want_min[t]) bad_min++;
	}
	{
		char msg[160];
		snprintf(msg, sizeof(msg), "64-bit imageAtomicMax(umax) over 32768 invocations, every texel (%u bad)", bad_max);
		check(msg, bad_max == 0);
		snprintf(msg, sizeof(msg), "64-bit imageAtomicMin(umin), every texel (%u bad)", bad_min);
		check(msg, bad_min == 0);
	}

	/* ---- the fetch result, uncontended: exact semantics ----------------------------------- */
	VkDescriptorSetLayout fetch_dsl = descriptor_layout(1);
	struct pipeline fetch = compute_pipeline(fetch_dsl, dir, "image_atomic64_fetch.comp.spv", "main");
	VkDescriptorSetAllocateInfo fdsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &fetch_dsl };
	VkDescriptorSet fset;
	CK(vkAllocateDescriptorSets(dev, &fdsai, &fset));
	VkDescriptorBufferInfo fbi = { fetch_buf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet fw[3] = {
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = fset, .dstBinding = 0, .descriptorCount = 1,
		  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &rii[0] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = fset, .dstBinding = 1, .descriptorCount = 1,
		  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &rii[1] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = fset, .dstBinding = 2, .descriptorCount = 1,
		  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &fbi },
	};
	vkUpdateDescriptorSets(dev, 3, fw, 0, NULL);

	/* preset A: both atomics change their cell; preset B: neither does */
	struct { uint64_t max, min; } presets[2] = {
		{ 5, 0xfffffffffffff000UL },
		{ ~0UL, 0 },
	};
	for (int r = 0; r < 2; r++) {
		for (uint32_t i = 0; i < TEXELS; i++) {
			fill_max[i] = 0;
			fill_min[i] = ~0UL;
		}
		fill_max[0] = presets[r].max;
		fill_min[0] = presets[r].min;
		memset(fetch_out, 0xab, 16);

		cmd = begin(pool);
		image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		              VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
		              VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		              VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
		              VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		vkCmdCopyBufferToImage(cmd, fbuf_max, img_max, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
		vkCmdCopyBufferToImage(cmd, fbuf_min, img_min, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
		image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
		              VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
		              VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
		image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
		              VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
		              VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);

		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, fetch.pipe);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, fetch.layout, 0, 1, &fset, 0, NULL);
		vkCmdDispatch(cmd, 1, 1, 1);

		VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
		image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		              VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
		              VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		              VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
		              VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		vkCmdCopyImageToBuffer(cmd, img_max, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rbuf_max, 1, &region);
		vkCmdCopyImageToBuffer(cmd, img_min, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rbuf_min, 1, &region);
		image_barrier(cmd, img_max, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
		              VK_ACCESS_TRANSFER_READ_BIT, 0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
		image_barrier(cmd, img_min, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
		              VK_ACCESS_TRANSFER_READ_BIT, 0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
		submit(queue, cmd);

		uint64_t want_max_cell = presets[r].max > NEW_MAX ? presets[r].max : NEW_MAX;
		uint64_t want_min_cell = presets[r].min < NEW_MIN ? presets[r].min : NEW_MIN;
		char msg[200];
		snprintf(msg, sizeof(msg), "preset %d: imageAtomicMax returns the original value (got %llu want %llu)", r,
			(unsigned long long)fetch_out[0], (unsigned long long)presets[r].max);
		check(msg, fetch_out[0] == presets[r].max && out_max[0] == want_max_cell);
		snprintf(msg, sizeof(msg), "preset %d: imageAtomicMin returns the original value (got %llu want %llu)", r,
			(unsigned long long)fetch_out[1], (unsigned long long)presets[r].min);
		check(msg, fetch_out[1] == presets[r].min && out_min[0] == want_min_cell);
	}

	printf("%s image_atomic64: %d failure(s)\n", failures ? "FAIL" : "OK", failures);
	return failures != 0;
}
