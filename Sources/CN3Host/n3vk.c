#include "n3host.h"
#include "libretro.h"
#include <vulkan/vulkan.h>
#include "libretro_vulkan.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static struct {
    bool wanted, active;
    struct retro_hw_render_callback hw;
    const struct retro_hw_render_context_negotiation_interface_vulkan *negotiation;
    VkInstance instance;
    struct retro_vulkan_context ctx;
    struct retro_hw_render_interface_vulkan iface;
    struct retro_vulkan_image image;
    bool has_image;
    pthread_mutex_t queue_lock;
    VkCommandPool pool;
    VkCommandBuffer cmd;
    VkFence fence;
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize buffer_size;
    void *mapped;
} vk = {.queue_lock = PTHREAD_MUTEX_INITIALIZER};

bool n3vk_active(void) { return vk.active; }

/* ---- functions the core calls through retro_hw_render_interface_vulkan ---- */

static void set_image(void *handle, const struct retro_vulkan_image *image, uint32_t num_semaphores,
                      const VkSemaphore *semaphores, uint32_t src_queue_family) {
    (void)handle; (void)num_semaphores; (void)semaphores; (void)src_queue_family;
    vk.image = *image;
    vk.has_image = true;
}
static uint32_t get_sync_index(void *handle) { (void)handle; return 0; }
static uint32_t get_sync_index_mask(void *handle) { (void)handle; return 1; }
static void set_command_buffers(void *handle, uint32_t n, const VkCommandBuffer *cmd) { (void)handle; (void)n; (void)cmd; }
static void wait_sync_index(void *handle) { (void)handle; }
static void lock_queue(void *handle) { (void)handle; pthread_mutex_lock(&vk.queue_lock); }
static void unlock_queue(void *handle) { (void)handle; pthread_mutex_unlock(&vk.queue_lock); }
static void set_signal_semaphore(void *handle, VkSemaphore s) { (void)handle; (void)s; }

/* ---- environment commands for Vulkan ---- */

bool n3vk_environment(unsigned cmd, void *data, bool *handled) {
    *handled = true;
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
        *(unsigned *)data = RETRO_HW_CONTEXT_VULKAN;
        return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        struct retro_hw_render_callback *cb = data;
        if (cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        vk.hw = *cb;
        vk.wanted = true;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE:
        vk.negotiation = data;
        return vk.negotiation->interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        if (!vk.active) return false;
        *(const struct retro_hw_render_interface **)data = (const struct retro_hw_render_interface *)&vk.iface;
        return true;
    default:
        *handled = false;
        return false;
    }
}

/* ---- start: instance, device (made by the core), readback resources ---- */

#define FAIL(...) do { snprintf(err, err_len, __VA_ARGS__); return 1; } while (0)

int n3vk_start(char *err, size_t err_len) {
    if (!vk.wanted) return 0;                       /* software renderer: nothing to do */
    if (!vk.negotiation || !vk.negotiation->create_device) FAIL("the core gave no Vulkan negotiation interface");

    const VkApplicationInfo *app = vk.negotiation->get_application_info ? vk.negotiation->get_application_info() : NULL;
    VkApplicationInfo fallback = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "Nasty3DS",
                                  .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = app ? app : &fallback};
    VkResult r = vkCreateInstance(&ici, NULL, &vk.instance);
    if (r != VK_SUCCESS) FAIL("vkCreateInstance failed: %d", r);

    uint32_t count = 1;
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    vkEnumeratePhysicalDevices(vk.instance, &count, &gpu);
    if (gpu == VK_NULL_HANDLE) FAIL("no Vulkan GPU found");

    VkPhysicalDeviceFeatures features = {0};
    if (!vk.negotiation->create_device(&vk.ctx, vk.instance, gpu, VK_NULL_HANDLE, vkGetInstanceProcAddr,
                                       NULL, 0, NULL, 0, &features))
        FAIL("the core could not create a Vulkan device");

    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                   .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                                   .queueFamilyIndex = vk.ctx.queue_family_index};
    if (vkCreateCommandPool(vk.ctx.device, &pci, NULL, &vk.pool) != VK_SUCCESS) FAIL("command pool failed");
    VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = vk.pool,
                                       .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    if (vkAllocateCommandBuffers(vk.ctx.device, &cai, &vk.cmd) != VK_SUCCESS) FAIL("command buffer failed");
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    if (vkCreateFence(vk.ctx.device, &fci, NULL, &vk.fence) != VK_SUCCESS) FAIL("fence failed");

    vk.iface = (struct retro_hw_render_interface_vulkan){
        .interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN,
        .interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION,
        .handle = &vk,
        .instance = vk.instance,
        .gpu = vk.ctx.gpu,
        .device = vk.ctx.device,
        .get_device_proc_addr = vkGetDeviceProcAddr,
        .get_instance_proc_addr = vkGetInstanceProcAddr,
        .queue = vk.ctx.queue,
        .queue_index = vk.ctx.queue_family_index,
        .set_image = set_image,
        .get_sync_index = get_sync_index,
        .get_sync_index_mask = get_sync_index_mask,
        .set_command_buffers = set_command_buffers,
        .wait_sync_index = wait_sync_index,
        .lock_queue = lock_queue,
        .unlock_queue = unlock_queue,
        .set_signal_semaphore = set_signal_semaphore,
    };
    vk.active = true;
    if (vk.hw.context_reset) vk.hw.context_reset();
    return 0;
}

/* ---- per frame: copy the core's image to CPU memory ---- */

static bool ensure_buffer(VkDeviceSize size) {
    if (vk.buffer_size >= size) return true;
    if (vk.buffer) {
        vkUnmapMemory(vk.ctx.device, vk.memory);
        vkDestroyBuffer(vk.ctx.device, vk.buffer, NULL);
        vkFreeMemory(vk.ctx.device, vk.memory, NULL);
        vk.buffer = VK_NULL_HANDLE;
        vk.buffer_size = 0;
    }
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                              .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    if (vkCreateBuffer(vk.ctx.device, &bci, NULL, &vk.buffer) != VK_SUCCESS) return false;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(vk.ctx.device, vk.buffer, &req);
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(vk.ctx.gpu, &props);
    const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint32_t type = UINT32_MAX;
    for (uint32_t i = 0; i < props.memoryTypeCount; i++) {
        if ((req.memoryTypeBits & (1u << i)) && (props.memoryTypes[i].propertyFlags & want) == want) { type = i; break; }
    }
    if (type == UINT32_MAX) return false;
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
                                .memoryTypeIndex = type};
    if (vkAllocateMemory(vk.ctx.device, &mai, NULL, &vk.memory) != VK_SUCCESS) return false;
    vkBindBufferMemory(vk.ctx.device, vk.buffer, vk.memory, 0);
    if (vkMapMemory(vk.ctx.device, vk.memory, 0, size, 0, &vk.mapped) != VK_SUCCESS) return false;
    vk.buffer_size = size;
    return true;
}

static void transition(VkImage image, VkImageLayout from, VkImageLayout to) {
    VkImageMemoryBarrier b = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                              .srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
                              .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
                              .oldLayout = from, .newLayout = to,
                              .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                              .image = image,
                              .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(vk.cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
                         0, NULL, 0, NULL, 1, &b);
}

// ponytail: one GPU-to-CPU copy per frame, and it waits for the GPU. Cheap at 1x (400x480).
// If higher resolution factors make this the slow part, present with a CAMetalLayer swapchain
// on the Mac and keep the readback only for the phone stream (Part 2).
void n3vk_readback(unsigned width, unsigned height, n3_video_fn out) {
    if (!vk.active || !vk.has_image || !out) return;
    if (width == 0 || height == 0 || width > 8192 || height > 8192) return;   /* a bad size from the core must not crash the copy */
    const VkDeviceSize size = (VkDeviceSize)width * height * 4;
    if (!ensure_buffer(size)) return;
    const VkImage image = vk.image.create_info.image;
    const VkImageLayout layout = vk.image.image_layout;

    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkResetCommandBuffer(vk.cmd, 0);
    vkBeginCommandBuffer(vk.cmd, &begin);
    transition(image, layout, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
    VkBufferImageCopy region = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                .imageExtent = {width, height, 1}};
    vkCmdCopyImageToBuffer(vk.cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk.buffer, 1, &region);
    transition(image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, layout);
    vkEndCommandBuffer(vk.cmd);

    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &vk.cmd};
    pthread_mutex_lock(&vk.queue_lock);
    vkResetFences(vk.ctx.device, 1, &vk.fence);
    const VkResult sent = vkQueueSubmit(vk.ctx.queue, 1, &submit, vk.fence);
    pthread_mutex_unlock(&vk.queue_lock);
    if (sent != VK_SUCCESS) return;   /* the fence would never signal: skip this frame, do not wait forever */
    vkWaitForFences(vk.ctx.device, 1, &vk.fence, VK_TRUE, UINT64_MAX);

    const VkFormat f = vk.image.create_info.format;
    if (f == VK_FORMAT_R8G8B8A8_UNORM || f == VK_FORMAT_R8G8B8A8_SRGB) {   /* swap to B, G, R, X */
        uint8_t *p = vk.mapped;
        for (VkDeviceSize i = 0; i < size; i += 4) { uint8_t t = p[i]; p[i] = p[i + 2]; p[i + 2] = t; }
    }
    out(vk.mapped, width, height, (size_t)width * 4);
}

/* Step 1 of shutdown, before retro_unload_game. */
void n3vk_context_destroy(void) {
    if (!vk.active) return;
    vkDeviceWaitIdle(vk.ctx.device);
    if (vk.hw.context_destroy) vk.hw.context_destroy();
}

/* Step 2 of shutdown, after retro_unload_game and retro_deinit: the core frees its own Vulkan
   objects in those calls, so the device must still be alive until they return. */
void n3vk_stop(void) {
    if (!vk.active) return;
    vkDeviceWaitIdle(vk.ctx.device);
    if (vk.buffer) {
        vkUnmapMemory(vk.ctx.device, vk.memory);
        vkDestroyBuffer(vk.ctx.device, vk.buffer, NULL);
        vkFreeMemory(vk.ctx.device, vk.memory, NULL);
    }
    vkDestroyFence(vk.ctx.device, vk.fence, NULL);
    vkDestroyCommandPool(vk.ctx.device, vk.pool, NULL);
    /* the core made the device; the libretro contract says the frontend destroys it */
    vkDestroyDevice(vk.ctx.device, NULL);
    vkDestroyInstance(vk.instance, NULL);
    vk.active = false;
    vk.has_image = false;
    vk.wanted = false;
    vk.buffer = VK_NULL_HANDLE;
    vk.buffer_size = 0;
}
