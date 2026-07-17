package main
import vk "vendor:vulkan"
import "base:runtime"
import sdl "vendor:sdl3"
import vma "odin-vma" 

MAX_FRAMES_IN_FLIGHT :: 2

FrameResources :: struct {
    command_pool:             vk.CommandPool,
    command_buffer:           vk.CommandBuffer,
    image_acquired_semaphore: vk.Semaphore,
}

VKGlobals :: struct {
    ctx: runtime.Context,

    window:              ^sdl.Window,

    running:            bool,
    width:              u32,
    height:             u32,
    frame_index:        u64,
    next_signal_value:  u64,

    instance:        vk.Instance,
    physical_device: vk.PhysicalDevice,
    device:          vk.Device,
    surface:         vk.SurfaceKHR,
    graphics_queue_family_idx: u32,
    graphics_queue:  vk.Queue,
    allocator:       vma.Allocator,

    swapchain:                  vk.SwapchainKHR,
    swapchain_images:           []vk.Image,
    swapchain_views:            []vk.ImageView,
    swapchain_format:           vk.SurfaceFormatKHR,
    swapchain_width:            u32,
    swapchain_height:           u32,
    require_swapchain_recreate: bool,

    depth_format:           vk.Format,
    depth_image:            vk.Image,
    depth_image_allocation: vma.Allocation,
    depth_image_view:       vk.ImageView,
    render_complete_semaphores: []vk.Semaphore,

    vert_shader_module: vk.ShaderModule,
    frag_shader_module: vk.ShaderModule,

    pipeline_layout: vk.PipelineLayout,
    pipeline:        vk.Pipeline,

    timeline_semaphore: vk.Semaphore,
    frame_resources:    [MAX_FRAMES_IN_FLIGHT]FrameResources,
}

g :VKGlobals

