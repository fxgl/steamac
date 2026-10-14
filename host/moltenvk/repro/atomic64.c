/*
 * 64-bit atomic min/max (VK_KHR_shader_atomic_int64), the first of Dragon's Dogma 2's two shader
 * gaps. DD2 does atomic_fetch_max on an atomic_ulong; the MSL KosmicKrisp generates for it does
 * not compile ("no matching function for call to 'atomic_fetch_max_explicit'"), the pipeline is
 * skipped, and the game cannot boot.
 *
 * This case checks values, not compilation:
 *
 *  dd2_atomic64.comp        512 workgroups x 64 invocations hammer one buffer with 64-bit
 *                           OpAtomicUMax/UMin (and a 32-bit control). Every
 *                           expectation is recomputed on the CPU from the same mix(). Each
 *                           invocation also stores the value its fetch form returned, and every
 *                           one of those must be a value some invocation wrote (or the initial
 *                           one) — a lowering that truncates to 32 bits, returns a constant or
 *                           reads an uninitialized temp fails here even though it compiles.
 *  dd2_atomic64_fetch.comp  one invocation, so the fetch result is exactly Vulkan's "original
 *                           value"; preset twice, once where the atomic changes the cell and once
 *                           where it does not, and every returned value is checked exactly.
 *  dd2_atomic64_signed.comp signed 64-bit min/max in its own pipeline: MSL has no atomic_long at
 *                           all, so this half is not lowerable and is reported as such rather than
 *                           failing the unsigned half (Dragon's Dogma 2's failing op is unsigned).
 *  dd2_atomic64_shared.comp workgroup-memory 64-bit min/max (shaderSharedAtomicInt64): MSL has no
 *                           threadgroup 64-bit atomic at all, so this half is expected to stay
 *                           unadvertised — the case reports it and only verifies values if the
 *                           driver advertises shaderSharedInt64Atomics.
 *
 * Both sub-cases are skipped, with the capability printed, when the feature is not advertised:
 * the suite must stay green on a driver that honestly does not offer 64-bit atomics.
 *
 * REPRO_FORCE=1 runs them anyway: the pipeline then fails to compile with the driver's own MSL
 * error, which reproduces Dragon's Dogma 2's failure on the host in about a second:
 *
 *	Failed to create MTLLibrary: program_source:133:15: error: no matching function for call to
 *	'atomic_fetch_max_explicit'
 *	    t45 = atomic_fetch_max_explicit((device atomic_ulong*)t42, as_type<ulong>(t24), memory_order_relaxed);
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define WORKGROUPS 512u /* x 64 invocations = 32768 */
#define INVOCATIONS (WORKGROUPS * 64u)
#define SHARED_WORKGROUPS 8u

/* REPRO_FORCE=1 runs the sub-cases a driver does not advertise anyway: the pipeline then fails to
 * compile with the driver's own MSL error, which is how Dragon's Dogma 2's failure looks on the
 * host without booting the VM. */
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
static VkBuffer host_buffer(VkPhysicalDevice pd, VkDeviceSize size, void **map)
{
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
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

/* The shader's mix(): a bijective 64-to-64-bit scramble, so every invocation's value is distinct. */
static uint64_t mix(uint64_t x)
{
	x ^= x >> 33;
	x *= 0xff51afd7ed558ccdUL;
	x ^= x >> 29;
	return x;
}

static int cmp64(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return x < y ? -1 : x > y ? 1 : 0;
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

static VkDescriptorSetLayout descriptor_layout(uint32_t count)
{
	VkDescriptorSetLayoutBinding b[2] = {
		{ .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
		{ .binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
	};
	VkDescriptorSetLayoutCreateInfo ci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = count, .pBindings = b };
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

	VkPhysicalDeviceShaderAtomicInt64Features a64 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_ATOMIC_INT64_FEATURES };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &a64 };
	vkGetPhysicalDeviceFeatures2(pd, &f2);
	int buffer64 = a64.shaderBufferInt64Atomics == VK_TRUE;
	int shared64 = a64.shaderSharedInt64Atomics == VK_TRUE;
	printf("INFO shaderBufferInt64Atomics=%d shaderSharedInt64Atomics=%d\n", buffer64, shared64);
	force = getenv("REPRO_FORCE") != NULL;

	a64.shaderBufferInt64Atomics = buffer64 ? VK_TRUE : VK_FALSE;
	a64.shaderSharedInt64Atomics = shared64 ? VK_TRUE : VK_FALSE;
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

	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 8 };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 8, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));

	/* ---- contended effects + fetch results on a storage buffer ---------------------------- */
	if (!buffer64 && !force) {
		printf("SKIP 64-bit storage-buffer atomics: VK_KHR_shader_atomic_int64 shaderBufferInt64Atomics is not advertised\n");
	} else {
		if (!buffer64)
			printf("INFO forcing the 64-bit storage-buffer atomics the driver does not advertise (REPRO_FORCE)\n");
		/* the field order must match shaders/dd2_atomic64.comp's block exactly */
		struct { uint64_t umax, umin, fetch_umax, fetch_umin; uint32_t umax32, pad; } *c;
		uint64_t *sink;
		VkBuffer cbuf = host_buffer(pd, 64, (void **)&c);
		VkBuffer sbuf = host_buffer(pd, (VkDeviceSize)INVOCATIONS * 2 * 8, (void **)&sink);
		memset(c, 0, 64);
		memset(sink, 0xab, (size_t)INVOCATIONS * 2 * 8);
		c->umin = ~0UL;
		c->fetch_umin = ~0UL;

		VkDescriptorSetLayout dsl = descriptor_layout(2);
		struct pipeline p = compute_pipeline(dsl, dir, "dd2_atomic64.comp.spv", "main");
		VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
		VkDescriptorSet set;
		CK(vkAllocateDescriptorSets(dev, &dsai, &set));
		VkDescriptorBufferInfo bis[2] = { { cbuf, 0, VK_WHOLE_SIZE }, { sbuf, 0, VK_WHOLE_SIZE } };
		VkWriteDescriptorSet w[2] = {
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bis[0] },
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 1, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bis[1] },
		};
		vkUpdateDescriptorSets(dev, 2, w, 0, NULL);
		VkCommandBuffer cmd = begin(pool);
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.pipe);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, &set, 0, NULL);
		vkCmdDispatch(cmd, WORKGROUPS, 1, 1);
		VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkEndCommandBuffer(cmd));
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));

		uint64_t umax = 0, umin = ~0UL;
		uint32_t umax32 = 0;
		uint64_t *aset = malloc(INVOCATIONS * 8), *asetinv = malloc(INVOCATIONS * 8);
		for (uint32_t i = 0; i < INVOCATIONS; i++) {
			uint64_t a = mix(i);
			if (a > umax) umax = a;
			if (a < umin) umin = a;
			if ((uint32_t)a > umax32) umax32 = (uint32_t)a;
			aset[i] = a;
			asetinv[i] = ~a;
		}
		qsort(aset, INVOCATIONS, 8, cmp64);
		qsort(asetinv, INVOCATIONS, 8, cmp64);

		check("64-bit atomicMax(umax) over 32768 invocations", c->umax == umax);
		check("64-bit atomicMin(umin)", c->umin == umin);
		check("32-bit atomicMax(umax32) [control]", c->umax32 == umax32);

		uint32_t bad1 = 0, bad2 = 0;
		for (uint32_t i = 0; i < INVOCATIONS; i++) {
			uint64_t o1 = sink[i * 2 + 0], o2 = sink[i * 2 + 1];
			if (o1 != 0 && !bsearch(&o1, aset, INVOCATIONS, 8, cmp64)) bad1++;
			if (o2 != ~0UL && !bsearch(&o2, asetinv, INVOCATIONS, 8, cmp64)) bad2++;
		}
		char msg[128];
		snprintf(msg, sizeof(msg), "fetch atomicMax returned a written value (%u of %u bad)", bad1, INVOCATIONS);
		check(msg, bad1 == 0);
		snprintf(msg, sizeof(msg), "fetch atomicMin/UMin returned a written value (%u bad)", bad2);
		check(msg, bad2 == 0);
		free(aset); free(asetinv);
	}

	/* ---- the fetch result, uncontended: exact semantics ----------------------------------- */
	if (!buffer64 && !force) {
		printf("SKIP exact fetch-result check: shaderBufferInt64Atomics is not advertised\n");
	} else {
		struct { uint64_t umax_val, umax_old, umin_val, umin_old; } *f;
		VkBuffer fbuf = host_buffer(pd, 32, (void **)&f);
		VkDescriptorSetLayout dsl = descriptor_layout(1);
		struct pipeline p = compute_pipeline(dsl, dir, "dd2_atomic64_fetch.comp.spv", "main");
		VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
		VkDescriptorSet set;
		CK(vkAllocateDescriptorSets(dev, &dsai, &set));
		VkDescriptorBufferInfo bi = { fbuf, 0, VK_WHOLE_SIZE };
		VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0,
			.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi };
		vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);

		/* preset A: both atomics change their cell; preset B: neither does */
		struct { uint64_t umax_val, umin_val; } presets[2] = {
			{ 5, 0xfffffffffffff000UL },
			{ 0xffffffffffffffffUL, 0 },
		};
		for (int r = 0; r < 2; r++) {
			memset(f, 0, 32);
			f->umax_val = presets[r].umax_val;
			f->umin_val = presets[r].umin_val;
			VkCommandBuffer cmd = begin(pool);
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.pipe);
			vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, &set, 0, NULL);
			vkCmdDispatch(cmd, 1, 1, 1);
			VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
				.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
			VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
			CK(vkEndCommandBuffer(cmd));
			CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(queue));

			uint64_t want_max = presets[r].umax_val > 0xfeedfacecafebeefUL ? presets[r].umax_val : 0xfeedfacecafebeefUL;
			uint64_t want_min = presets[r].umin_val < 0x123456789abcdef0UL ? presets[r].umin_val : 0x123456789abcdef0UL;
			char msg[160];
			snprintf(msg, sizeof(msg), "preset %d: atomicMax returns the original value (got %llu want %llu)", r,
				(unsigned long long)f->umax_old, (unsigned long long)presets[r].umax_val);
			check(msg, f->umax_old == presets[r].umax_val && f->umax_val == want_max);
			snprintf(msg, sizeof(msg), "preset %d: atomicMin returns the original value", r);
			check(msg, f->umin_old == presets[r].umin_val && f->umin_val == want_min);
		}
	}

	/* ---- signed 64-bit min/max: not expressible in MSL ------------------------------------ */
	if (buffer64) {
		VkDescriptorSetLayout dsl = descriptor_layout(1);
		VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
		VkPipelineLayout layout;
		CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
		VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
			.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
			           .module = module(dir, "dd2_atomic64_signed.comp.spv"), .pName = "main" }, .layout = layout };
		VkPipeline p;
		VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
		if (r != VK_SUCCESS) {
			printf("SKIP signed 64-bit atomic min/max (VkResult %d): MSL has no atomic_long, so OpAtomicSMax/SMin\n", r);
			printf("     cannot be lowered; the driver still advertises the feature for the unsigned ops DD2 uses\n");
		} else {
			int64_t *s;
			VkBuffer sbuf2 = host_buffer(pd, 16, (void **)&s);
			VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
			VkDescriptorSet set;
			CK(vkAllocateDescriptorSets(dev, &dsai, &set));
			VkDescriptorBufferInfo bi = { sbuf2, 0, VK_WHOLE_SIZE };
			VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0,
				.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi };
			vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
			s[0] = INT64_MIN;
			s[1] = INT64_MAX;
			VkCommandBuffer cmd = begin(pool);
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
			vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
			vkCmdDispatch(cmd, WORKGROUPS, 1, 1);
			VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
				.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
			VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
			CK(vkEndCommandBuffer(cmd));
			CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(queue));
			int64_t emax = INT64_MIN, emin = INT64_MAX;
			for (uint32_t i = 0; i < INVOCATIONS; i++) {
				int64_t sa = (int64_t)(mix((uint64_t)i + 0x100000000UL) >> 1) - (int64_t)0x4000000000000000L;
				if (sa > emax) emax = sa;
				if (sa < emin) emin = sa;
			}
			check("signed 64-bit atomicMax", s[0] == emax);
			check("signed 64-bit atomicMin", s[1] == emin);
		}
	}

	/* ---- workgroup-memory 64-bit atomics --------------------------------------------------- */
	if (!shared64 && !force) {
		printf("SKIP 64-bit workgroup atomics: VK_KHR_shader_atomic_int64 shaderSharedInt64Atomics is not advertised\n");
	} else {
		if (!shared64)
			printf("INFO forcing the 64-bit workgroup atomics the driver does not advertise (REPRO_FORCE)\n");
		uint64_t *mxs, *mns;
		VkBuffer bmax = host_buffer(pd, SHARED_WORKGROUPS * 8, (void **)&mxs);
		VkBuffer bmin = host_buffer(pd, SHARED_WORKGROUPS * 8, (void **)&mns);
		memset(mxs, 0, SHARED_WORKGROUPS * 8);
		memset(mns, 0xff, SHARED_WORKGROUPS * 8);
		VkDescriptorSetLayout dsl = descriptor_layout(2);
		struct pipeline p = compute_pipeline(dsl, dir, "dd2_atomic64_shared.comp.spv", "main");
		VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
		VkDescriptorSet set;
		CK(vkAllocateDescriptorSets(dev, &dsai, &set));
		VkDescriptorBufferInfo bis[2] = { { bmax, 0, VK_WHOLE_SIZE }, { bmin, 0, VK_WHOLE_SIZE } };
		VkWriteDescriptorSet w[2] = {
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bis[0] },
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 1, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bis[1] },
		};
		vkUpdateDescriptorSets(dev, 2, w, 0, NULL);
		VkCommandBuffer cmd = begin(pool);
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.pipe);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, &set, 0, NULL);
		vkCmdDispatch(cmd, SHARED_WORKGROUPS, 1, 1);
		VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkEndCommandBuffer(cmd));
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));

		int ok = 1;
		for (uint32_t g = 0; g < SHARED_WORKGROUPS; g++) {
			uint64_t emax = 0, emin = ~0UL;
			for (uint32_t i = 0; i < 64; i++) {
				uint64_t a = mix((uint64_t)g * 64u + i);
				if (a > emax) emax = a;
				if (a < emin) emin = a;
			}
			if (mxs[g] != emax || mns[g] != emin) {
				printf("     workgroup %u: max %llu (want %llu), min %llu (want %llu)\n", g,
					(unsigned long long)mxs[g], (unsigned long long)emax, (unsigned long long)mns[g], (unsigned long long)emin);
				ok = 0;
			}
		}
		check("64-bit atomicMax/Min in workgroup memory, 8 workgroups", ok);
	}

	printf("%s atomic64: %d failure(s)\n", failures ? "FAIL" : "OK", failures);
	return failures != 0;
}
