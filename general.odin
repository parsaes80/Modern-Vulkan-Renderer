package main
import vk "vendor:vulkan"
import "base:runtime"
import sdl "vendor:sdl3"
import vma "odin-vma" 

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

MAX_FRAMES_IN_FLIGHT :: 2
MAX_TEXTURES :: 1024

Vertex::struct{
    pos:   Vec3,
    color: Vec3,
    normal:Vec3,
    uv:    Vec2
}

Mesh:: struct{
    name:      string, 
    sub_meshes:[dynamic]SubMesh
}

SubMesh::struct {
    vertex_start:u64,
    vertex_count:u64,
    index_start :u64,
    index_count :u64,
    material_id :u32
}

Image::struct 
{
    width:    int,
    height:   int,
    channels: int,
    data:     ^byte
}

FrameConstants :: struct
{
    vertex_buffer_address  :u64,
    material_buffer_address:u64,
    render_items_address   :u64
}

GPUImage :: struct {
    image:      vk.Image,
    image_view: vk.ImageView,
    allocation: vma.Allocation,
}

GPUBuffer :: struct {
    vk_buffer:      vk.Buffer,
    device_address: vk.DeviceAddress,
    allocation:     vma.Allocation,
}

RenderItem :: struct {
    wvp:            matrix[4,4]f32,
    world_matrix:   matrix[4,4]f32,
    material_index: u32,
}

FrameResources :: struct {
    command_pool:             vk.CommandPool,
    command_buffer:           vk.CommandBuffer,
    image_acquired_semaphore: vk.Semaphore,
    desc_set:                 vk.DescriptorSet,
    indirect_draw_buffer:     GPUBuffer,
    render_item_buffer:       GPUBuffer,
    indirect_draw_ptr:        [^]vk.DrawIndexedIndirectCommand,
    render_item_ptr:          [^]RenderItem,
}

Material :: struct {
    base_color    :Vec4,
    texture_index :u32,
}

Texture :: struct {
    image_id:   u32,
    sampler_id: u32,
}

RenderStack::struct{
    node_ptr:^Node,
    mat:     matrix[4,4]f32
} 

VKGlobals :: struct {
    ctx:                runtime.Context,

    window:             ^sdl.Window,

    running:            bool,
    width:              u32,
    height:             u32,
    frame_index:        u64,
    next_signal_value:  u64,

    instance:                   vk.Instance,
    physical_device:            vk.PhysicalDevice,
    device:                     vk.Device,
    surface:                    vk.SurfaceKHR,
    graphics_queue_family_idx:  u32,
    graphics_queue:             vk.Queue,
    allocator:                  vma.Allocator,

    swapchain:                  vk.SwapchainKHR,
    swapchain_images:           []vk.Image,
    swapchain_views:            []vk.ImageView,
    swapchain_format:           vk.SurfaceFormatKHR,
    swapchain_width:            u32,
    swapchain_height:           u32,
    require_swapchain_recreate: bool,

    depth_format:               vk.Format,
    depth_image:                vk.Image,
    depth_image_allocation:     vma.Allocation,
    depth_image_view:           vk.ImageView,
    render_complete_semaphores: []vk.Semaphore,

    vert_shader_module: vk.ShaderModule,
    frag_shader_module: vk.ShaderModule,

    pipeline_layout:    vk.PipelineLayout,
    pipeline:           vk.Pipeline,

    timeline_semaphore: vk.Semaphore,
    frame_resources:    [MAX_FRAMES_IN_FLIGHT]FrameResources,

    command_pool: vk.CommandPool, 

    meshes:      [dynamic]Mesh,
    vert_offset: u64,
    idx_offset:  u64,

    white_pixel_image_id: u32,
    vertex_buffer_id:     u32,
    index_buffer_id:      u32,
    mat_buffer_id:        u32,

    
    vertecies: [dynamic]Vertex,
    indicies:  [dynamic]u32,

    images:    [dynamic]GPUImage,
    samplers:  [dynamic]vk.Sampler,
    textures:  [dynamic]Texture,
    buffers:   [dynamic]GPUBuffer,
    materials: [dynamic]Material,

    global_ds_layout: vk.DescriptorSetLayout,
    global_desc_set:  vk.DescriptorSet,
    desc_pool:        vk.DescriptorPool,

    cam_distance: f32,
    cam_yaw:      f32,
    cam_pitch:    f32,

    node_world:       NodeWorld,
    root_node_id:     u32,
    last_root_node_id:u32,
    node_render_stack:[dynamic]RenderStack
}

g :VKGlobals
