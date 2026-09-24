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

Vertex::struct #packed{
    pos:   Vec3,
    color: Vec3,
    normal:Vec3,
    uv:    Vec2
}

Mesh:: struct {
    name:      string, 
    subMeshes: [dynamic]SubMesh
}

SubMesh::struct{
    vertexStart:u64,
    vertexCount:u64,
    indexStart :u64,
    indexCount :u64,
    materialId :u32
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
    vertexBufferAddress  :u64,
    materialBufferAddress:u64,
    renderItemsAddress   :u64
}

GPUImage :: struct {
    image:      vk.Image,
    imageView:  vk.ImageView,
    allocation: vma.Allocation,
}

GPUBuffer :: struct {
    vkBuffer:      vk.Buffer,
    deviceAddress: vk.DeviceAddress,
    allocation:    vma.Allocation,
}

RenderItem :: struct #packed{
    wvp:            matrix[4,4]f32,
    worldMatrix:   matrix[4,4]f32,
    materialIndex: u32,
}

FrameResources :: struct {
    commandPool:            vk.CommandPool,
    commandBuffer:          vk.CommandBuffer,
    imageAcquiredSemaphore: vk.Semaphore,
    descSet:                vk.DescriptorSet,
    indirectDrawBuffer:     GPUBuffer,
    renderItemBuffer:       GPUBuffer,
    indirectDrawPtr:        [^]vk.DrawIndexedIndirectCommand,
    renderItemPtr:          [^]RenderItem,
}

Material :: struct #packed{
    baseColor:    Vec4,
    textureIndex: u32,
}

Texture :: struct {
    imageId:   u32,
    samplerId: u32,
}

NodeRenderStackLayer::struct {
    nodePtr:^Node,
    mat:     matrix[4,4]f32
} 

Camera :: struct {
	pos:   Vec3,
	front: Vec3,
	up:    Vec3,
	yaw:   f32,
	pitch: f32,
	fov:   f32,
}

Mouse :: struct {
	sensitivity: f32,
	first_move:  bool,
}

VKGlobals :: struct {
    ctx:              runtime.Context,

    window:           ^sdl.Window,

    running:          bool,
    width:            u32,
    height:           u32,
    frameIndex:       u64,
    nextSignalValue:  u64,

    instance:                  vk.Instance,
    physicalDevice:            vk.PhysicalDevice,
    device:                    vk.Device,
    surface:                   vk.SurfaceKHR,
    graphicsQueueFamilyIdx:    u32,
    graphicsQueue:             vk.Queue,
    
    allocator:                 vma.Allocator,

    swapchain:                vk.SwapchainKHR,
    swapchainImages:          []vk.Image,
    swapchainViews:           []vk.ImageView,
    swapchainFormat:          vk.SurfaceFormatKHR,
    swapchainWidth:           u32,
    swapchainHeight:          u32,
    requireSwapchainRecreate: bool,

    depthFormat:              vk.Format,
    depthImage:               vk.Image,
    depthImageAllocation:     vma.Allocation,
    depthImageView:           vk.ImageView,
    
    renderCompleteSemaphores: []vk.Semaphore,

    vertShaderModule:  vk.ShaderModule,
    fragShaderModule:  vk.ShaderModule,

    pipelineLayout:    vk.PipelineLayout,
    pipeline:          vk.Pipeline,

    timelineSemaphore: vk.Semaphore,
    frameResources:    [MAX_FRAMES_IN_FLIGHT]FrameResources,

    commandPool:       vk.CommandPool, 

    meshes:            [dynamic]Mesh,
    vertOffset:        u64,
    idxOffset:         u64,

    whitePixelImageId: u32,
    vertexBufferId:    u32,
    indexBufferId:     u32,
    matBufferId:       u32,
    
    vertecies:        [dynamic]Vertex,
    indicies:         [dynamic]u32,
    
    images:           [dynamic]GPUImage,
    samplers:         [dynamic]vk.Sampler,
    textures:         [dynamic]Texture,
    buffers:          [dynamic]GPUBuffer,
    materials:        [dynamic]Material,

    globalDsLayout:  vk.DescriptorSetLayout,
    globalDescSet:   vk.DescriptorSet,
    descPool:        vk.DescriptorPool,
     
    camera:          Camera,
    mouse:           Mouse,

    nodeWorld:       NodeWorld,
    rootNodeId:      u32,
    lastRootNodeId:  u32,
    nodeRenderStack: [dynamic]NodeRenderStackLayer,

    dt: u64,
    t0: u64
}

g :VKGlobals
