/*
 * Metal 4 residency of attachments (KosmicKrisp only; STEAMAC-G).
 *
 * Metal 4 makes only what a residency set of the command buffer or queue holds resident. Its API validation accepts an
 * attachment only when the attachment's base texture object is in such a set: the heap it was placed in, the buffer
 * (host pointer import) it was made from, or the view that is bound do not count ("Attachment texture ... is not added
 * to any residency set on the command buffer or command queue", a warning, so assert mode never failed on it). A
 * boot printed it 9033 times from Steam's first client render pass on (zink's 4x MSAA targets in private heaps of
 * host-imported memory, tiled-heap BGRA8 images, gamescope/Xwayland linear host-buffer images); M3 and later GPUs lose
 * the device with MTL4CommandQueueErrorTimeout there.
 *
 * Renders (dynamic rendering, clear + store) into every kind of attachment KosmicKrisp makes, each followed by meta
 * clears/copies and, for single-sample color, a readback of the cleared value:
 *   memory: device-local type, host-visible type (both heaps), host pointer imports (tiled: the private heap made at
 *   bind; LINEAR: a texture of the imported buffer, with INPUT_ATTACHMENT usage a 2D array view of it), sparse binding
 *   (placement sparse texture); 4x MSAA color resolved into a single-sample image and 4x MSAA depth/stencil (also in
 *   host-imported memory); depth/stencil; views with another format, of a layer, of a 3D image's slice (2D array alias);
 *   two images bound at offsets of one allocation; a blit into a LINEAR host import (gamescope's scanout copy).
 * run.sh runs it with MTL_DEBUG_LAYER_WARNING_MODE=nslog and fails on any "not added to any residency set" line.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)
#define W 64
#define H 64

static VkPhysicalDevice pd;
static VkDevice dev;
static VkQueue queue;
static uint32_t family;
static VkCommandPool pool;
static VkPhysicalDeviceMemoryProperties mp;
static VkDeviceSize host_align;
static PFN_vkGetMemoryHostPointerPropertiesEXT get_host_ptr_props;
static int failures;

enum mem_kind { MEM_DEVICE_LOCAL, MEM_HOST_VISIBLE, MEM_HOST_IMPORT, MEM_SPARSE };
static const char *const mem_names[] = { "device-local", "host-visible", "host-import", "sparse" };

struct image {
	VkImage image;
	VkDeviceMemory mem;
	void *host;
	VkDeviceSize host_size;
};

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags avoid)
{
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want &&
		    !(mp.memoryTypes[i].propertyFlags & avoid))
			return i;
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	printf("FAIL no memory type 0x%x in 0x%x\n", want, bits);
	exit(1);
}

static int supported(const VkImageCreateInfo *ci)
{
	VkImageFormatProperties p;
	if (vkGetPhysicalDeviceImageFormatProperties(pd, ci->format, ci->imageType, ci->tiling, ci->usage, ci->flags, &p))
		return 0;
	return (p.sampleCounts & ci->samples) != 0;
}

/* image of ci in memory of kind; 0 when the driver does not support the combination */
static int create_image(VkImageCreateInfo ci, enum mem_kind kind, struct image *img)
{
	*img = (struct image){ 0 };
	VkExternalMemoryImageCreateInfo ext = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	/* Model vkr's non-shared HOST_VISIBLE imports: optimal images have no
	 * external sharing marker and still need the private tiled heap. */
	if (kind == MEM_HOST_IMPORT && ci.tiling != VK_IMAGE_TILING_OPTIMAL)
		ci.pNext = &ext;
	if (kind == MEM_SPARSE)
		ci.flags |= VK_IMAGE_CREATE_SPARSE_BINDING_BIT;
	if (!supported(&ci))
		return 0;
	CK(vkCreateImage(dev, &ci, NULL, &img->image));
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(dev, img->image, &req);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size };
	VkImportMemoryHostPointerInfoEXT import = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
		.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	switch (kind) {
	case MEM_DEVICE_LOCAL:
	case MEM_SPARSE:
		ai.memoryTypeIndex = mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
					      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
		break;
	case MEM_HOST_VISIBLE:
		ai.memoryTypeIndex = mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
		break;
	case MEM_HOST_IMPORT: {
		img->host_size = (req.size + host_align - 1) / host_align * host_align;
		img->host = mmap(NULL, img->host_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
		if (img->host == MAP_FAILED) { printf("FAIL mmap\n"); exit(1); }
		VkMemoryHostPointerPropertiesEXT hp = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
		CK(get_host_ptr_props(dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, img->host, &hp));
		ai.memoryTypeIndex = mem_type(req.memoryTypeBits & hp.memoryTypeBits, 0, 0);
		ai.allocationSize = img->host_size;
		import.pHostPointer = img->host;
		ai.pNext = &import;
		break;
	}
	}
	CK(vkAllocateMemory(dev, &ai, NULL, &img->mem));
	if (kind == MEM_SPARSE) {
		VkSparseMemoryBind bind = { .resourceOffset = 0, .size = req.size, .memory = img->mem };
		VkSparseImageOpaqueMemoryBindInfo opaque = { img->image, 1, &bind };
		VkBindSparseInfo bi = { VK_STRUCTURE_TYPE_BIND_SPARSE_INFO, .imageOpaqueBindCount = 1, .pImageOpaqueBinds = &opaque };
		CK(vkQueueBindSparse(queue, 1, &bi, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));
	} else {
		CK(vkBindImageMemory(dev, img->image, img->mem, 0));
	}
	return 1;
}

static void destroy_image(struct image *img)
{
	vkDestroyImage(dev, img->image, NULL);
	vkFreeMemory(dev, img->mem, NULL);
	if (img->host)
		munmap(img->host, img->host_size);
	*img = (struct image){ 0 };
}

static VkImageView create_view(VkImage image, VkImageViewType type, VkFormat format, VkImageAspectFlags aspect,
			       uint32_t layer, uint32_t layers)
{
	VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image, .viewType = type,
		.format = format, .subresourceRange = { aspect, 0, 1, layer, layers } };
	VkImageView view;
	CK(vkCreateImageView(dev, &vi, NULL, &view));
	return view;
}

static VkCommandBuffer begin(void)
{
	VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &ai, &cmd));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &bi));
	return cmd;
}

static void submit(VkCommandBuffer cmd)
{
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	vkFreeCommandBuffers(dev, pool, 1, &cmd);
}

static void barrier(VkCommandBuffer cmd, VkImage image, VkImageAspectFlags aspect, VkImageLayout from, VkImageLayout to,
		    uint32_t layers)
{
	VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
		.oldLayout = from, .newLayout = to, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image, .subresourceRange = { aspect, 0, 1, 0, layers } };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL,
			     1, &b);
}

/* color value of the first texel of layer of a single-sample color image (RGBA8/BGRA8: 4 bytes) */
static uint32_t read_texel(VkImage image, uint32_t layer)
{
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, buf, &req);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
		.memoryTypeIndex = mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
					    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, 0) };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &ai, NULL, &mem));
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	VkCommandBuffer cmd = begin();
	VkBufferImageCopy copy = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, layer, 1 }, .imageExtent = { 1, 1, 1 } };
	vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &copy);
	submit(cmd);
	uint32_t *p;
	CK(vkMapMemory(dev, mem, 0, 4, 0, (void **)&p));
	uint32_t v = *p;
	vkUnmapMemory(dev, mem);
	vkDestroyBuffer(dev, buf, NULL);
	vkFreeMemory(dev, mem, NULL);
	return v;
}

struct rcase {
	const char *name;
	enum mem_kind kind;
	VkFormat format, view_format;
	VkImageTiling tiling;
	VkSampleCountFlagBits samples;
	VkImageUsageFlags extra_usage;
	VkImageCreateFlags flags;
	uint32_t layers, layer;     /* image layers, rendered layer */
	int image_3d;               /* 3D image (depth 4), rendered slice through a 2D view */
};

static void finish_case(const char *name, int ok)
{
	printf("%s attachment %s\n", ok ? "OK  " : "FAIL", name);
	fflush(stdout);
	failures += !ok;
}

static void run_case(const struct rcase *c)
{
	const VkFormat vf = c->view_format ? c->view_format : c->format;
	const int depth = c->format == VK_FORMAT_D32_SFLOAT_S8_UINT || c->format == VK_FORMAT_D32_SFLOAT ||
			  c->format == VK_FORMAT_S8_UINT;
	const VkImageAspectFlags aspect = !depth ? VK_IMAGE_ASPECT_COLOR_BIT :
		c->format == VK_FORMAT_D32_SFLOAT_S8_UINT ? VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT :
		c->format == VK_FORMAT_S8_UINT ? VK_IMAGE_ASPECT_STENCIL_BIT : VK_IMAGE_ASPECT_DEPTH_BIT;
	const uint32_t layers = c->layers ? c->layers : 1;
	VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .flags = c->flags,
		.imageType = c->image_3d ? VK_IMAGE_TYPE_3D : VK_IMAGE_TYPE_2D, .format = c->format,
		.extent = { W, H, c->image_3d ? 4 : 1 }, .mipLevels = 1, .arrayLayers = layers,
		.samples = c->samples ? c->samples : VK_SAMPLE_COUNT_1_BIT, .tiling = c->tiling,
		.usage = (depth ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) |
			 VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | c->extra_usage,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	if (ci.samples != VK_SAMPLE_COUNT_1_BIT)
		ci.usage &= ~(VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
	char name[160];
	snprintf(name, sizeof(name), "%s (%s memory)", c->name, mem_names[c->kind]);
	struct image img, resolve = { 0 };
	if (!create_image(ci, c->kind, &img)) {
		printf("SKIP attachment %s: not supported\n", name);
		return;
	}
	const int msaa_color = ci.samples != VK_SAMPLE_COUNT_1_BIT && !depth;
	if (msaa_color) {
		VkImageCreateInfo rci = ci;
		rci.samples = VK_SAMPLE_COUNT_1_BIT;
		rci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
		rci.flags = 0;
		if (!create_image(rci, c->kind == MEM_SPARSE ? MEM_DEVICE_LOCAL : c->kind, &resolve)) {
			printf("FAIL attachment %s: resolve image not supported\n", name);
			failures++;
			destroy_image(&img);
			return;
		}
	}
	const VkImageViewType vt = layers > 1 || c->image_3d ? VK_IMAGE_VIEW_TYPE_2D_ARRAY : VK_IMAGE_VIEW_TYPE_2D;
	VkImageView view = create_view(img.image, vt, vf, aspect, c->layer, 1);
	VkImageView rview = resolve.image ? create_view(resolve.image, VK_IMAGE_VIEW_TYPE_2D, vf, aspect, 0, 1) : VK_NULL_HANDLE;

	const VkImageLayout att_layout = depth ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL :
						 VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	const uint32_t img_layers = c->image_3d ? 1 : layers;
	VkCommandBuffer cmd = begin();
	barrier(cmd, img.image, aspect, VK_IMAGE_LAYOUT_UNDEFINED, att_layout, img_layers);
	if (resolve.image)
		barrier(cmd, resolve.image, aspect, VK_IMAGE_LAYOUT_UNDEFINED, att_layout, 1);
	const VkClearValue clear = depth ? (VkClearValue){ .depthStencil = { 0.25f, 0x5a } } :
					   (VkClearValue){ .color = { .float32 = { 1, 0, 0, 1 } } };
	VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = att_layout, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.clearValue = clear };
	if (rview) {
		att.resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT;
		att.resolveImageView = rview;
		att.resolveImageLayout = att_layout;
	}
	VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } }, .layerCount = 1 };
	if (!depth) {
		ri.colorAttachmentCount = 1;
		ri.pColorAttachments = &att;
	} else {
		if (aspect & VK_IMAGE_ASPECT_DEPTH_BIT)
			ri.pDepthAttachment = &att;
		if (aspect & VK_IMAGE_ASPECT_STENCIL_BIT)
			ri.pStencilAttachment = &att;
	}
	vkCmdBeginRendering(cmd, &ri);
	vkCmdEndRendering(cmd);
	/* meta: a clear of the image (KosmicKrisp renders it through its own attachment views) */
	if (ci.samples == VK_SAMPLE_COUNT_1_BIT) {
		barrier(cmd, img.image, aspect, att_layout, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, img_layers);
		VkImageSubresourceRange range = { aspect, 0, 1, 0, img_layers };
		if (depth)
			vkCmdClearDepthStencilImage(cmd, img.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear.depthStencil, 1, &range);
		else
			vkCmdClearColorImage(cmd, img.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear.color, 1, &range);
		barrier(cmd, img.image, aspect, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			img_layers);
	}
	if (resolve.image)
		barrier(cmd, resolve.image, aspect, att_layout, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, 1);
	submit(cmd);

	int ok = 1;
	VkImage check = resolve.image ? resolve.image : !depth && ci.samples == VK_SAMPLE_COUNT_1_BIT ? img.image : VK_NULL_HANDLE;
	if (check) {
		/* red: RGBA8 0xff0000ff, BGRA8 0xffff0000, R8 0xff (sRGB/UNORM views of 1.0 agree) */
		const int r8 = c->format == VK_FORMAT_R8_UNORM;
		const uint32_t want = r8 ? 0xffu : c->format == VK_FORMAT_B8G8R8A8_UNORM ? 0xffff0000u : 0xff0000ffu;
		const uint32_t got = read_texel(check, check == img.image && !c->image_3d ? c->layer : 0) & (r8 ? 0xffu : ~0u);
		if (got != want) {
			printf("FAIL attachment %s: texel 0x%08x, expected 0x%08x\n", name, got, want);
			ok = 0;
		}
	}
	vkDestroyImageView(dev, view, NULL);
	if (rview)
		vkDestroyImageView(dev, rview, NULL);
	destroy_image(&img);
	if (resolve.image)
		destroy_image(&resolve);
	finish_case(name, ok);
}

/* two images at offsets of one allocation, and a blit into a LINEAR host import (gamescope's scanout copy) */
static void run_shared_and_blit(void)
{
	VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_B8G8R8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT };
	VkImage a, b;
	CK(vkCreateImage(dev, &ci, NULL, &a));
	CK(vkCreateImage(dev, &ci, NULL, &b));
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(dev, a, &req);
	const VkDeviceSize off = (req.size + req.alignment - 1) / req.alignment * req.alignment;
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = off * 2,
		.memoryTypeIndex = mem_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0) };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &ai, NULL, &mem));
	CK(vkBindImageMemory(dev, a, mem, 0));
	CK(vkBindImageMemory(dev, b, mem, off));

	struct image dst;
	ci.tiling = VK_IMAGE_TILING_LINEAR;
	if (!create_image(ci, MEM_HOST_IMPORT, &dst)) {
		printf("FAIL attachment blit into a LINEAR host import: not supported\n");
		failures++;
		return;
	}
	VkImageView views[2] = { create_view(a, VK_IMAGE_VIEW_TYPE_2D, ci.format, VK_IMAGE_ASPECT_COLOR_BIT, 0, 1),
				 create_view(b, VK_IMAGE_VIEW_TYPE_2D, ci.format, VK_IMAGE_ASPECT_COLOR_BIT, 0, 1) };
	VkCommandBuffer cmd = begin();
	for (int i = 0; i < 2; i++) {
		VkImage im = i ? b : a;
		barrier(cmd, im, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, 1);
		VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = views[i],
			.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
			.storeOp = VK_ATTACHMENT_STORE_OP_STORE,
			.clearValue = { .color = { .float32 = { i ? 0.0f : 1.0f, i ? 1.0f : 0.0f, 0, 1 } } } };
		VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } }, .layerCount = 1,
			.colorAttachmentCount = 1, .pColorAttachments = &att };
		vkCmdBeginRendering(cmd, &ri);
		vkCmdEndRendering(cmd);
		barrier(cmd, im, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
			VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, 1);
	}
	barrier(cmd, dst.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1);
	VkImageBlit blit = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .srcOffsets = { { 0, 0, 0 }, { W, H, 1 } },
		.dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .dstOffsets = { { 0, 0, 0 }, { W, H, 1 } } };
	vkCmdBlitImage(cmd, b, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
		       VK_FILTER_NEAREST);
	barrier(cmd, dst.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, 1);
	submit(cmd);
	const uint32_t ga = read_texel(a, 0), gb = read_texel(b, 0), gd = read_texel(dst.image, 0);
	const int ok = ga == 0xffff0000u && gb == 0xff00ff00u && gd == 0xff00ff00u;
	if (!ok)
		printf("FAIL attachment shared allocation + blit: texels 0x%08x 0x%08x 0x%08x, expected 0xffff0000 0xff00ff00 "
		       "0xff00ff00\n", ga, gb, gd);
	vkDestroyImageView(dev, views[0], NULL);
	vkDestroyImageView(dev, views[1], NULL);
	vkDestroyImage(dev, a, NULL);
	vkDestroyImage(dev, b, NULL);
	vkFreeMemory(dev, mem, NULL);
	destroy_image(&dst);
	finish_case("two images at offsets of one allocation, blit into a LINEAR host import", ok);
}

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	VkPhysicalDeviceExternalMemoryHostPropertiesEXT hostp = {
		VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT };
	VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &hostp };
	vkGetPhysicalDeviceProperties2(pd, &props);
	host_align = hostp.minImportedHostPointerAlignment;
	if (host_align < 16384)
		host_align = 16384;
	VkPhysicalDeviceFeatures f;
	vkGetPhysicalDeviceFeatures(pd, &f);

	n = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, NULL);
	VkQueueFamilyProperties qp[8];
	n = n > 8 ? 8 : n;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, qp);
	family = UINT32_MAX;
	for (uint32_t i = 0; i < n && family == UINT32_MAX; i++)
		if ((qp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && (qp[i].queueFlags & VK_QUEUE_SPARSE_BINDING_BIT))
			family = i;
	if (family == UINT32_MAX) { printf("FAIL no graphics queue with sparse binding\n"); return 1; }
	if (!f.sparseBinding) { printf("FAIL no sparseBinding\n"); return 1; }

	const char *exts[] = { VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family,
		.queueCount = 1, .pQueuePriorities = &prio };
	VkPhysicalDeviceFeatures enabled = { .sparseBinding = VK_TRUE };
	VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.dynamicRendering = VK_TRUE };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f13, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = exts,
		.pEnabledFeatures = &enabled };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, family, 0, &queue);
	get_host_ptr_props = (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(dev, "vkGetMemoryHostPointerPropertiesEXT");
	if (!get_host_ptr_props) { printf("FAIL no vkGetMemoryHostPointerPropertiesEXT\n"); return 1; }
	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));

	const VkImageTiling OPT = VK_IMAGE_TILING_OPTIMAL, LIN = VK_IMAGE_TILING_LINEAR;
	const VkSampleCountFlagBits S4 = VK_SAMPLE_COUNT_4_BIT;
	const struct rcase cases[] = {
		{ "RGBA8", MEM_DEVICE_LOCAL, VK_FORMAT_R8G8B8A8_UNORM, 0, OPT },
		{ "RGBA8", MEM_HOST_VISIBLE, VK_FORMAT_R8G8B8A8_UNORM, 0, OPT },
		{ "BGRA8 tiled (private heap)", MEM_HOST_IMPORT, VK_FORMAT_B8G8R8A8_UNORM, 0, OPT },
		{ "BGRA8 LINEAR (texture of the imported buffer)", MEM_HOST_IMPORT, VK_FORMAT_B8G8R8A8_UNORM, 0, LIN },
		{ "BGRA8 LINEAR input attachment (2D array view of a buffer texture)", MEM_HOST_IMPORT,
		  VK_FORMAT_B8G8R8A8_UNORM, 0, LIN, .extra_usage = VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT },
		{ "RGBA8 4x MSAA resolved", MEM_DEVICE_LOCAL, VK_FORMAT_R8G8B8A8_UNORM, 0, OPT, S4 },
		{ "RGBA8 4x MSAA resolved", MEM_HOST_IMPORT, VK_FORMAT_R8G8B8A8_UNORM, 0, OPT, S4 },
		{ "R8 4x MSAA 2-layer array, layer 1", MEM_HOST_IMPORT, VK_FORMAT_R8_UNORM, 0, OPT, S4, .layers = 2, .layer = 1 },
		{ "S8 4x MSAA", MEM_HOST_IMPORT, VK_FORMAT_S8_UINT, 0, OPT, S4 },
		{ "D32S8 4x MSAA", MEM_DEVICE_LOCAL, VK_FORMAT_D32_SFLOAT_S8_UINT, 0, OPT, S4 },
		{ "D32S8", MEM_DEVICE_LOCAL, VK_FORMAT_D32_SFLOAT_S8_UINT, 0, OPT },
		{ "D32S8", MEM_HOST_IMPORT, VK_FORMAT_D32_SFLOAT_S8_UINT, 0, OPT },
		{ "D32", MEM_HOST_VISIBLE, VK_FORMAT_D32_SFLOAT, 0, OPT },
		{ "RGBA8 through an sRGB view", MEM_DEVICE_LOCAL, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_SRGB, OPT,
		  .flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT },
		{ "BGRA8 LINEAR through an sRGB view", MEM_HOST_IMPORT, VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB, LIN,
		  .flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT },
		{ "RGBA8 4-layer array, layer 2", MEM_DEVICE_LOCAL, VK_FORMAT_R8G8B8A8_UNORM, 0, OPT, .layers = 4, .layer = 2 },
		{ "RGBA8 3D, slice 2 (2D array alias)", MEM_DEVICE_LOCAL, VK_FORMAT_R8G8B8A8_UNORM, 0, OPT, .layer = 2,
		  .image_3d = 1, .flags = VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT },
		{ "RGBA8 sparse binding (placement sparse texture)", MEM_SPARSE, VK_FORMAT_R8G8B8A8_UNORM, 0, OPT },
		{ "D32 sparse binding", MEM_SPARSE, VK_FORMAT_D32_SFLOAT, 0, OPT },
	};
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
		run_case(&cases[i]);
	run_shared_and_blit();

	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	return failures != 0;
}
