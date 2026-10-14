/*
 * How long does this host Vulkan driver take to compile pipelines?
 *
 * A game's first run is dominated by driver-side shader compilation, and "wait 45 minutes for
 * Dragon's Dogma 2 to reach its menu" is not a benchmark loop. This does the same work on a
 * synthetic pipeline set of a chosen size:
 *
 *   cold       one pipeline per SPIR-V module, timed one at a time (compile latency)
 *   warm       the same modules again (the driver's cache of the compiled program)
 *   threaded   a *second*, distinct set of modules across THREADS threads — a distinct set because
 *              re-creating a compiled program is cached and would measure nothing
 *   variants   VARIANTS pipelines from *one* module with distinct specialization constants: a
 *              title's shape (one shader, many pipeline variants), where a driver that resolves
 *              the constant at compile time pays a compile per variant
 *
 * Usage: compile_bench <spv dir> [modules per set]        THREADS=4 by default
 *
 * The directory must hold twice the modules (see run.sh): the first half is the cold/warm set, the
 * second the threaded set. Nothing is dispatched; the cost measured is pipeline creation (in
 * KosmicKrisp: NIR -> MSL -> Metal library compile).
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkDevice dev;
static VkPipelineLayout layout;
static VkShaderModule *modules;
static uint32_t module_count;

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y ? 1 : 0;
}

static void report(const char *what, double *times, uint32_t n, double wall)
{
	double *sorted = malloc(n * sizeof(*sorted));
	memcpy(sorted, times, n * sizeof(*sorted));
	qsort(sorted, n, sizeof(*sorted), cmp_double);
	printf("  %-9s %5u pipelines  wall %8.1f ms  per-pipeline median %7.1f ms  p95 %7.1f ms  throughput %6.2f pipelines/s\n",
	       what, n, wall, sorted[n / 2], sorted[(uint32_t)(n * 0.95) < n ? (uint32_t)(n * 0.95) : n - 1],
	       n / (wall / 1000.0));
	free(sorted);
}

/* BENCH_DRAIN=1: destroy a phase's pipelines at its end and count the wait in its wall. A driver
 * that compiles in the background (KosmicKrisp patch 0051) returns from vkCreate*Pipelines before
 * the Metal compile, and destroying a pipeline waits for it; without the drain the benchmark times
 * only the front end and abandons the queued compiles at exit. Each phase also prints its
 * CLOCK_MONOTONIC bounds ("phase <name> t <start> <end>") to line up with MESA_KK_DEBUG=compiles. */
static int drain_enabled;
static double drain(const char *what, VkPipeline *p, uint32_t n, double start, double created)
{
	if (drain_enabled) {
		for (uint32_t i = 0; i < n; i++)
			vkDestroyPipeline(dev, p[i], NULL);
	}
	double end = now_ms();
	if (drain_enabled)
		printf("  %-9s drained  wall %8.1f ms  (create %.1f + wait %.1f)  throughput %6.2f pipelines/s\n", what,
		       end - start, created - start, end - created, n / ((end - start) / 1000.0));
	printf("phase %s t %.3f %.3f\n", what, start, end);
	return end - start;
}

static void create_one(VkPipeline *out, uint32_t index)
{
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = modules[index], .pName = "main" }, .layout = layout };
	CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, out));
}

static void create_variant(VkPipeline *out, float spec)
{
	VkSpecializationMapEntry entry = { .constantID = 0, .offset = 0, .size = sizeof(float) };
	VkSpecializationInfo spec_info = { .mapEntryCount = 1, .pMapEntries = &entry,
		.dataSize = sizeof(float), .pData = &spec };
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = modules[0], .pName = "main", .pSpecializationInfo = &spec_info },
		.layout = layout };
	CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, out));
}

struct thread_arg { uint32_t first, count; VkPipeline *out; pthread_t id; };

static void *thread_main(void *arg)
{
	struct thread_arg *t = arg;
	for (uint32_t i = 0; i < t->count; i++)
		create_one(&t->out[i], t->first + i);
	return NULL;
}

static void load_modules(const char *dir, uint32_t limit)
{
	char list_path[1024];
	snprintf(list_path, sizeof(list_path), "%s/modules.txt", dir);
	FILE *list = fopen(list_path, "r");
	if (!list) { printf("FAIL open %s\n", list_path); exit(1); }

	modules = calloc(limit, sizeof(*modules));
	char name[512];
	while (module_count < limit && fscanf(list, "%511s", name) == 1) {
		char path[1600];
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
		CK(vkCreateShaderModule(dev, &ci, NULL, &modules[module_count]));
		free(code);
		module_count++;
	}
	fclose(list);
	if (module_count < 2) { printf("FAIL need at least two modules in %s\n", dir); exit(1); }
}

int main(int argc, char **argv)
{
	if (argc < 2 || argc > 3) { fprintf(stderr, "usage: %s <spv dir> [modules per set]\n", argv[0]); return 2; }
	uint32_t limit = argc == 3 ? (uint32_t)strtoul(argv[2], NULL, 10) : 200u;
	drain_enabled = getenv("BENCH_DRAIN") && atoi(getenv("BENCH_DRAIN"));
	uint32_t threads = getenv("THREADS") ? (uint32_t)strtoul(getenv("THREADS"), NULL, 10) : 4u;
	if (!threads)
		threads = 1;

	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);

	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));

	VkDescriptorSetLayoutBinding binding = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
	VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &binding };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1, .pSetLayouts = &dsl };
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	load_modules(argv[1], limit * 2);
	uint32_t set = module_count / 2;
	printf("device: %s  (driver %u, Vulkan %u.%u.%u), %u modules per set, THREADS=%u\n", props.deviceName,
	       props.driverVersion, VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion),
	       VK_VERSION_PATCH(props.apiVersion), set, threads);

	double *times = malloc(module_count * sizeof(*times));
	VkPipeline *pipes = malloc(module_count * sizeof(*pipes));

	double start = now_ms();
	for (uint32_t i = 0; i < set; i++) {
		double t = now_ms();
		create_one(&pipes[i], i);
		times[i] = now_ms() - t;
	}
	double cold_wall = now_ms() - start;
	double cold_throughput = set / (cold_wall / 1000.0);
	report("cold", times, set, cold_wall);
	drain("cold", pipes, set, start, start + cold_wall);

	start = now_ms();
	for (uint32_t i = 0; i < set; i++) {
		double t = now_ms();
		create_one(&pipes[i], i);
		times[i] = now_ms() - t;
	}
	double warm_wall = now_ms() - start;
	double warm_throughput = set / (warm_wall / 1000.0);
	report("warm", times, set, warm_wall);
	drain("warm", pipes, set, start, start + warm_wall);

	struct thread_arg *args = calloc(threads, sizeof(*args));
	uint32_t per = (set + threads - 1) / threads;
	start = now_ms();
	for (uint32_t t = 0; t < threads; t++) {
		args[t].first = set + t * per; /* the second set: never compiled before */
		args[t].count = t * per < set ? (t * per + per <= set ? per : set - t * per) : 0;
		args[t].out = calloc(args[t].count ? args[t].count : 1, sizeof(VkPipeline));
		pthread_create(&args[t].id, NULL, thread_main, &args[t]);
	}
	for (uint32_t t = 0; t < threads; t++)
		pthread_join(args[t].id, NULL);
	double wall = now_ms() - start;
	double threaded_throughput = set / (wall / 1000.0);
	printf("  %-9s %5u pipelines  wall %8.1f ms  throughput %6.2f pipelines/s\n",
	       "threaded", set, wall, threaded_throughput);
	if (drain_enabled) {
		double created = now_ms();
		for (uint32_t t = 0; t < threads; t++)
			for (uint32_t i = 0; i < args[t].count; i++)
				vkDestroyPipeline(dev, args[t].out[i], NULL);
		double end = now_ms();
		printf("  %-9s drained  wall %8.1f ms  (create %.1f + wait %.1f)  throughput %6.2f pipelines/s\n",
		       "threaded", end - start, created - start, end - created, set / ((end - start) / 1000.0));
		printf("phase threaded t %.3f %.3f\n", start, end);
	} else
		printf("phase threaded t %.3f %.3f\n", start, start + wall);
	printf("summary: cold %.2f/s (%.1f ms each), warm %.2f/s (%.2f ms each), threaded(%u) %.2f/s = %.2fx cold\n",
	       cold_throughput, cold_wall / set, warm_throughput, warm_wall / set, threads,
	       threaded_throughput, threaded_throughput / cold_throughput);

	/* A title's shape: one module, many pipeline variants. Each distinct specialization constant
	 * is a distinct MSL program for a driver that resolves it at compile time. */
	uint32_t variants = getenv("VARIANTS") ? (uint32_t)strtoul(getenv("VARIANTS"), NULL, 10) : 50u;
	if (variants) {
		VkPipeline *v = calloc(variants, sizeof(*v));
		double *vt = malloc(variants * sizeof(*vt));
		start = now_ms();
		for (uint32_t i = 0; i < variants; i++) {
			double t = now_ms();
			create_variant(&v[i], 0.5f + 0.01f * (float)i);
			vt[i] = now_ms() - t;
		}
		double vwall = now_ms() - start;
		report("variants", vt, variants, vwall);
		drain("variants", v, variants, start, start + vwall);
		printf("  variants  %5u from 1 module  %.1f ms each  (a title's pipeline set is one module times many variants)\n",
		       variants, vwall / variants);
	}
	return 0;
}
