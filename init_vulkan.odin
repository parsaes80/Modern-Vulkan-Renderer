package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "core:log"
import "core:fmt"

import vma "odin-vma" 
import shaderc "shaderc" 

debugCallback ::  proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,) -> b32 {

	context = g.ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}

shutdown :: proc() {
    // wait in case resources are in use
    vk.DeviceWaitIdle(g.device)

    // // single-use command buffer pool
    vk.DestroySemaphore(g.device, g.timeline_semaphore, nil)

    // // frame / sync object cleanup
    for res in g.frame_resources{
        vk.DestroySemaphore(g.device,res.image_acquired_semaphore,nil)
        vk.DestroyCommandPool(g.device,res.command_pool,nil)
    }

    // pipeline cleanup
    if g.pipeline_layout != 0 {
        vk.DestroyPipelineLayout(g.device, g.pipeline_layout, nil)
    }
    if g.pipeline != 0 {
        vk.DestroyPipeline(g.device, g.pipeline, nil)
    }

    // cleanup shaders
    if g.vert_shader_module != 0 {
        vk.DestroyShaderModule(g.device, g.vert_shader_module, nil)
    }
    if g.frag_shader_module != 0 {
        vk.DestroyShaderModule(g.device, g.frag_shader_module, nil)
    }

    // cleanup swapchain
    destroySwapchain()

    // VMA
    if g.allocator != nil {
        vma.DestroyAllocator(g.allocator)
    }

    // cleanup Vulkan
    if g.surface != 0 {
        vk.DestroySurfaceKHR(g.instance, g.surface, nil)
    }
    if g.device != nil {
        vk.DestroyDevice(g.device, nil)
    }
    if g.instance != nil {
        vk.DestroyInstance(g.instance, nil)
    }

    // cleanup SDL
    if g.window != nil {
        sdl.DestroyWindow(g.window)
    }
    sdl.Quit()
}

destroySwapchain :: proc() {
    for view in g.swapchain_views {
        vk.DestroyImageView(g.device, view, nil)
    }
    delete(g.swapchain_views)
    g.swapchain_views = nil

    // destroy render-complete semaphores
    for semaphore in g.render_complete_semaphores {
        vk.DestroySemaphore(g.device, semaphore, nil)
    }
    delete(g.render_complete_semaphores)
    g.render_complete_semaphores = nil

    if g.swapchain != 0 {
        vk.DestroySwapchainKHR(g.device, g.swapchain, nil)
        g.swapchain = 0
    }

    // destroy the depth buffer along with the swapchain
    if g.depth_image_view != 0 {
        vk.DestroyImageView(g.device, g.depth_image_view, nil)
        vma.DestroyImage(g.allocator, g.depth_image, g.depth_image_allocation)
        g.depth_image_view = 0
    }
}

createVulkanInstance::proc()-> bool {

    vk.load_proc_addresses(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))

    appInfo : vk.ApplicationInfo = {
        sType=.APPLICATION_INFO,
        pApplicationName="triangle",
        apiVersion=vk.API_VERSION_1_4
    }

    instExtcount :u32= 0 
    sdlExtentions := sdl.Vulkan_GetInstanceExtensions(&instExtcount)

    requestedExtentions : [dynamic]cstring
    defer delete(requestedExtentions)

    append(&requestedExtentions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
    for i:u32=0;i<instExtcount;i+=1 {
        append(&requestedExtentions, cstring(sdlExtentions[i]))
    }
    //fmt.print(requestedExtentions)

    requestedLayers := []cstring{"VK_LAYER_KHRONOS_validation"}
    defer delete(requestedLayers)
    
    debugInfo : vk.DebugUtilsMessengerCreateInfoEXT = {
        sType=.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = {.VERBOSE,.WARNING,.ERROR},
        messageType = {.VALIDATION,.PERFORMANCE},
        pfnUserCallback = debugCallback
    }

    instCreateInfo : vk.InstanceCreateInfo = {
        sType                   = .INSTANCE_CREATE_INFO,
        pNext                   = &debugInfo,
        pApplicationInfo        = &appInfo,
        enabledLayerCount       = u32(len(requestedLayers)),
        ppEnabledLayerNames     = raw_data(requestedLayers),
        enabledExtensionCount   = u32(len(requestedExtentions)),
        ppEnabledExtensionNames = raw_data(requestedExtentions),
    }

    
    vk.CreateInstance(&instCreateInfo,nil,&g.instance); assert(g.instance!=nil)
    vk.load_proc_addresses(g.instance)
    return true
}

createSurface :: proc()->bool{
    return sdl.Vulkan_CreateSurface(g.window,g.instance,nil,&g.surface)
}

findPhysicalDevice :: proc() -> bool {
    physDeviceCount: u32 = 0
    vk.EnumeratePhysicalDevices(g.instance, &physDeviceCount, nil)

    if physDeviceCount == 0 {
        return false
    }

    physicalDevices := make([]vk.PhysicalDevice, physDeviceCount)
    defer delete(physicalDevices)
    vk.EnumeratePhysicalDevices(g.instance, &physDeviceCount, raw_data(physicalDevices))

    // default to first GPU
    g.physical_device = physicalDevices[0]

    // look through list and see if a dGPU exists
    for pDev in physicalDevices {
        props: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(pDev, &props)
        if props.deviceType == .DISCRETE_GPU {
            g.physical_device = pDev
            break
        }
    }

    // ensure the desired swapchain format is supported
    format_count: u32 = 0
    vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical_device, g.surface, &format_count, nil)

    surface_formats := make([]vk.SurfaceFormatKHR, format_count)
    defer delete(surface_formats)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical_device, g.surface, &format_count, raw_data(surface_formats))

    format_supported := false
    for surf_format in surface_formats {
        if surf_format.format == g.swapchain_format.format {
            format_supported = true
            break
        }
    }

    if !format_supported {
        fmt.print("Requested swapchain format is not supported by the surface")
        return false
    }

    return true
}

findGraphicsQueue::proc()->bool{
    queueFamCount :u32= 0 
    vk.GetPhysicalDeviceQueueFamilyProperties2(g.physical_device,&queueFamCount,nil)
    queue_fam_props := make([]vk.QueueFamilyProperties2, queueFamCount)
    defer delete(queue_fam_props)
    for &qf in queue_fam_props {qf.sType = .QUEUE_FAMILY_PROPERTIES_2}
    vk.GetPhysicalDeviceQueueFamilyProperties2(g.physical_device, &queueFamCount, raw_data(queue_fam_props))

    for current_fam_idx in 0 ..< len(queue_fam_props) {
        // ensure it has presentation support
        has_present_support: b32 = false
        vk.GetPhysicalDeviceSurfaceSupportKHR(g.physical_device, u32(current_fam_idx), g.surface, &has_present_support)

        props := queue_fam_props[current_fam_idx]
        // ensure this is a GRAPHICS queue with presentation support
        if .GRAPHICS in props.queueFamilyProperties.queueFlags && bool(has_present_support) {
            g.graphics_queue_family_idx = u32(current_fam_idx)
            return true
        }
    }
    return false
}

create_device :: proc() -> bool {
    queue_priority: f32 = 1.0
    gfx_queue_info : vk.DeviceQueueCreateInfo = {
        sType            = .DEVICE_QUEUE_CREATE_INFO,
        queueFamilyIndex = g.graphics_queue_family_idx,
        queueCount       = 1,
        pQueuePriorities = &queue_priority,
    }

    // query supported features
    supported_features_14 := vk.PhysicalDeviceVulkan14Features{sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, pNext = nil}
    supported_features_13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, pNext = &supported_features_14}
    supported_features_12 := vk.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, pNext = &supported_features_13}
    supported_features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &supported_features_12}
    vk.GetPhysicalDeviceFeatures2(g.physical_device, &supported_features)

    // check if what we need is supported
    if !supported_features_13.dynamicRendering || !supported_features_13.synchronization2 ||
       !supported_features_12.timelineSemaphore {
        fmt.print("Physical device doesn't meet the feature requirements")
        return false
    }

    // produce a separate features struct chain for device creation
    features_14 : vk.PhysicalDeviceVulkan14Features = {
        sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
        pNext = nil,
    }
    features_13 : vk.PhysicalDeviceVulkan13Features = {
        sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        pNext            = &features_14,
        synchronization2 = true,
        dynamicRendering = true,
    }
    features_12 : vk.PhysicalDeviceVulkan12Features = {
        sType            = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        pNext            = &features_13,
        timelineSemaphore = true,
    }
    features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &features_12}

    device_extensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

    dev_create_info : vk.DeviceCreateInfo = {
        sType                   = .DEVICE_CREATE_INFO,
        pNext                   = &features,
        queueCreateInfoCount    = 1,
        pQueueCreateInfos       = &gfx_queue_info,
        enabledExtensionCount   = u32(len(device_extensions)),
        ppEnabledExtensionNames = raw_data(device_extensions[:]),
        pEnabledFeatures        = nil, // features struct chain is set in pNext
    }

    if vk.CreateDevice(g.physical_device, &dev_create_info, nil, &g.device) != .SUCCESS {
        return false
    }

    // grab the VkQueue object finally
    vk.GetDeviceQueue(g.device, g.graphics_queue_family_idx, 0, &g.graphics_queue)
    if g.graphics_queue == nil {
        fmt.print("Couldn't get the graphics queue")
        return false
    }
    vk.load_proc_addresses(g.device)
    return true
}

initializeVMA::proc()->bool{
    // Initializes a subset of Vulkan functions required by VMA
    vma_vulkan_functions := vma.create_vulkan_functions()

    vma_create_info: vma.AllocatorCreateInfo = {
        flags            = { .BUFFER_DEVICE_ADDRESS },
        instance         = g.instance,
        physicalDevice   = g.physical_device,
        device           = g.device,
        pVulkanFunctions = &vma_vulkan_functions,
        vulkanApiVersion = vk.API_VERSION_1_4,
    }

    return vma.CreateAllocator(vma_create_info, &g.allocator) == .SUCCESS
}

createSwapchain :: proc(width:u32,height:u32) -> bool {
    g.swapchain_width = width
    g.swapchain_height= height

    surfaceCaps: vk.SurfaceCapabilitiesKHR
    if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g.physical_device, g.surface, &surfaceCaps) != .SUCCESS do return false
    requestedImgCount := max(2, surfaceCaps.minImageCount)
    if surfaceCaps.maxImageCount > 0 do requestedImgCount = min(requestedImgCount, surfaceCaps.maxImageCount)

    swapchainCreateInfo : vk.SwapchainCreateInfoKHR =
    {
        sType            = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = g.surface,
        minImageCount    = requestedImgCount,
        imageFormat      = g.swapchain_format.format,
        imageColorSpace  = g.swapchain_format.colorSpace,
        imageExtent      = {g.swapchain_width, g.swapchain_height},
        imageArrayLayers = 1,
        imageUsage       = {.COLOR_ATTACHMENT},
        preTransform     = surfaceCaps.currentTransform,
        compositeAlpha   = {.OPAQUE},
        presentMode      = .IMMEDIATE,
    }

    if vk.CreateSwapchainKHR(g.device, &swapchainCreateInfo, nil, &g.swapchain) != .SUCCESS do return false

    fmt.printfln("created swapchain with %v images, width:%v height:%v", requestedImgCount,g.swapchain_width,g.swapchain_height)

    // grab the swapchain images
    imageCount: u32 = 0
    vk.GetSwapchainImagesKHR(g.device, g.swapchain, &imageCount, nil)
    g.swapchain_images = make([]vk.Image, imageCount)
    vk.GetSwapchainImagesKHR(g.device, g.swapchain, &imageCount, raw_data(g.swapchain_images))

    g.swapchain_views = make([]vk.ImageView, imageCount)

    // create the swapchain image views
    for i in 0 ..< len(g.swapchain_images) {
        imgViewInfo : vk.ImageViewCreateInfo = {
            sType    = .IMAGE_VIEW_CREATE_INFO,
            image    = g.swapchain_images[i],
            viewType = .D2,
            format   = g.swapchain_format.format,
            subresourceRange = {
                aspectMask = {.COLOR},
                levelCount = 1,
                layerCount = 1,
            },
        }
        if vk.CreateImageView(g.device, &imgViewInfo, nil, &g.swapchain_views[i]) != .SUCCESS {
            fmt.print("Error creating swapchain image view")
            return false
        }
    }

    // semaphores used to signal render completion
    g.render_complete_semaphores = make([]vk.Semaphore, len(g.swapchain_images))
    for &semaphore in g.render_complete_semaphores {
        semaphoreInfo := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
        if vk.CreateSemaphore(g.device, &semaphoreInfo, nil, &semaphore) != .SUCCESS {
            fmt.print("Error creating the render-complete semaphore")
            return false
        }
    }

    // create depth image
    depthCreateInfo : vk.ImageCreateInfo =
    {
        sType       = .IMAGE_CREATE_INFO,
        imageType   = .D2,
        format      = g.depth_format,
        extent      = {g.swapchain_width, g.swapchain_height, 1},
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = {._1},
        tiling      = .OPTIMAL,
        usage       = {.DEPTH_STENCIL_ATTACHMENT},
        initialLayout = .UNDEFINED,
    }
    allocInfo : vma.AllocationCreateInfo = {
        flags = {.DEDICATED_MEMORY},
        usage = .AUTO,
    }
    if vma.CreateImage(g.allocator, depthCreateInfo, allocInfo, &g.depth_image, &g.depth_image_allocation, nil) != .SUCCESS {
        fmt.print("Error allocating depth image")
        return false
    }

    depthImgViewInfo : vk.ImageViewCreateInfo = {
        sType    = .IMAGE_VIEW_CREATE_INFO,
        image    = g.depth_image,
        viewType = .D2,
        format   = g.depth_format,
        subresourceRange = {
            aspectMask = {.DEPTH},
            levelCount = 1,
            layerCount = 1,
        },
    }
    if vk.CreateImageView(g.device, &depthImgViewInfo, nil, &g.depth_image_view) != .SUCCESS {
        fmt.print("Error creating depth image view")
        return false
    }
    return true
}

create_shader_module :: proc(filename: string, kind: shaderc.shaderKind) -> vk.ShaderModule {
    shader_path := strings.concatenate({"shaders/", filename})
    defer delete(shader_path)

    src_bytes, read_ok := os.read_entire_file(shader_path,context.allocator)

    defer delete(src_bytes)

    fmt.println("Compiling shader:", shader_path)

    compiler := shaderc.compiler_initialize()
    defer shaderc.compiler_release(compiler)

    opts := shaderc.compile_options_initialize()
    defer shaderc.compile_options_release(opts)

    shaderc.compile_options_set_target_env(opts, .Vulkan, u32(shaderc.envVersion.Vulkan1_4))

    shaderc.compile_options_set_target_spirv(opts, .Spv1_6)

    shaderc.compile_options_set_optimization_level(opts, .Performance)

    filename_cstr := strings.clone_to_cstring(filename)
    defer delete(filename_cstr)

    result := shaderc.compile_into_spv(
        compiler,
        cstring(raw_data(src_bytes)),
        len(src_bytes),
        kind,
        filename_cstr,
        "main",
        opts,
    )
    defer shaderc.result_release(result)

    if shaderc.result_get_compilation_status(result) != .Success {
        err_msg := shaderc.result_get_error_message(result)
        fmt.println("Shader Compilation Error:", err_msg)
        return 0
    }

    spv_size := shaderc.result_get_length(result)
    spv_bytes := shaderc.result_get_bytes(result)

    module_create_info : vk.ShaderModuleCreateInfo = {
        sType    = .SHADER_MODULE_CREATE_INFO,
        codeSize = int(spv_size),
        pCode    = cast(^u32)spv_bytes,
    }

    shader_module: vk.ShaderModule
    if vk.CreateShaderModule(g.device, &module_create_info, nil, &shader_module) != .SUCCESS {
        fmt.println("Error creating shader module")
        return 0
    }

    return shader_module
}

createShaders :: proc() -> bool {
    g.vert_shader_module = create_shader_module("shader.vert", .VertexShader)
    if g.vert_shader_module == 0 {return false}
    g.frag_shader_module = create_shader_module("shader.frag", .FragmentShader)
    if g.frag_shader_module == 0 {return false}
    return true
}

createGraphicsPipeline :: proc() -> bool {
    pipeline_layout_info := vk.PipelineLayoutCreateInfo{
        sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount         = 0,
        pushConstantRangeCount = 0,
    }
    if vk.CreatePipelineLayout(g.device, &pipeline_layout_info, nil, &g.pipeline_layout) != .SUCCESS {
        fmt.print("unable to create pipeline layout")
        return false
    }
    entryPoint: cstring = "main"
    shaderStages: [2]vk.PipelineShaderStageCreateInfo = {
        {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.VERTEX},
            module = g.vert_shader_module,
            pName  = entryPoint,
        },
        {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.FRAGMENT},
            module = g.frag_shader_module,
            pName  = entryPoint,
        },
    }
    vertInputInfo: vk.PipelineVertexInputStateCreateInfo = {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }
    inputAssemblyInfo: vk.PipelineInputAssemblyStateCreateInfo = {
        sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }
    depthStencilInfo: vk.PipelineDepthStencilStateCreateInfo = {
        sType              = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable    = true,
        depthWriteEnable   = true,
        depthCompareOp     = .LESS,
        stencilTestEnable  = false,
    }
    viewportInfo: vk.PipelineViewportStateCreateInfo = {
        sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports    = nil,
        scissorCount  = 1,
        pScissors     = nil,
    }
    
    // rasterizer settings
    rasterInfo: vk.PipelineRasterizationStateCreateInfo = {
        sType     = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode    = {.BACK},
        frontFace   = .COUNTER_CLOCKWISE,
        lineWidth   = 1.0,
    }
    
    // no multisampling
    multiSampleInfo: vk.PipelineMultisampleStateCreateInfo = {
        sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }

    // alpha blending (disabled), still need attachment info and write mask
    attachState: vk.PipelineColorBlendAttachmentState = {
        blendEnable    = false,
        colorWriteMask = {.R, .G, .B, .A},
    }
    blendInfo: vk.PipelineColorBlendStateCreateInfo = {
        sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments    = &attachState,
    }

    // enable dynamic state
    dynamicStates: [2]vk.DynamicState = {.VIEWPORT, .SCISSOR}
    dynamicStateInfo: vk.PipelineDynamicStateCreateInfo = {
        sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamicStates)),
        pDynamicStates    = raw_data(dynamicStates[:]),
    }

    // structure required for dynamic rendering
    colorAttachmentFormats: [1]vk.Format = {g.swapchain_format.format}
    renderInfo: vk.PipelineRenderingCreateInfo = {
        sType                   = .PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount    = 1,
        pColorAttachmentFormats = raw_data(colorAttachmentFormats[:]),
        depthAttachmentFormat   = g.depth_format,
    }

    // create the graphics pipeline
    pipelineInfo: vk.GraphicsPipelineCreateInfo = 
    {
        sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext               = &renderInfo,
        stageCount          = u32(len(shaderStages)),
        pStages             = raw_data(shaderStages[:]),
        pVertexInputState   = &vertInputInfo,
        pInputAssemblyState = &inputAssemblyInfo,
        pViewportState      = &viewportInfo,
        pRasterizationState = &rasterInfo,
        pMultisampleState   = &multiSampleInfo,
        pDepthStencilState  = &depthStencilInfo,
        pColorBlendState    = &blendInfo,
        pDynamicState       = &dynamicStateInfo,
        layout              = g.pipeline_layout,
        renderPass          = 0,
    }
    if vk.CreateGraphicsPipelines(g.device, 0, 1, &pipelineInfo, nil, &g.pipeline) != .SUCCESS {
        fmt.print("Error creating the pipeline")
        return false
    }
    return true
}

createSyncResources :: proc() -> bool {
    semaphoreTypeInfo : vk.SemaphoreTypeCreateInfo = {
        sType         = .SEMAPHORE_TYPE_CREATE_INFO,
        semaphoreType = .TIMELINE,
        initialValue  = MAX_FRAMES_IN_FLIGHT,
    }
    semaphoreInfo : vk.SemaphoreCreateInfo = {
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = &semaphoreTypeInfo,
    }
    if vk.CreateSemaphore(g.device, &semaphoreInfo, nil, &g.timeline_semaphore) != .SUCCESS {
        fmt.print("Unable to create the timeline semaphore")
        return false
    }

    // per-frame image-acquire semaphores
    for &res in g.frame_resources {
        // create the binary semaphores
        frame_semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
        if vk.CreateSemaphore(g.device, &frame_semaphore_info, nil, &res.image_acquired_semaphore) != .SUCCESS {
            fmt.print("Error creating the per-frame image-acquire semaphore")
            return false
        }
    }

    return true
}

createCommandBuffers :: proc() -> bool {
    for &res in g.frame_resources {
        // we'll give each frame its own pool, faster cmd buffer resets this way
        poolInfo : vk.CommandPoolCreateInfo = {
            sType            = .COMMAND_POOL_CREATE_INFO,
            queueFamilyIndex = g.graphics_queue_family_idx,
        }
        if vk.CreateCommandPool(g.device, &poolInfo, nil, &res.command_pool) != .SUCCESS {
            fmt.print("Unable to create command buffer pool")
            return false
        }

        // create the command buffer for this frame
        cmdAllocInfo : vk.CommandBufferAllocateInfo = {
            sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool        = res.command_pool,
            level              = .PRIMARY,
            commandBufferCount = 1,
        }
        if vk.AllocateCommandBuffers(g.device, &cmdAllocInfo, &res.command_buffer) != .SUCCESS {
            fmt.print("Unable to allocate command buffer")
            return false
        }
    }
    return true
}

initializeVulkan :: proc(){
    res : bool
    res = createVulkanInstance()        ; assert(res!=false)
    res = createSurface()               ; assert(res!=false)
    res = findPhysicalDevice()          ; assert(res!=false)
    res = create_device()               ; assert(res!=false)
    res = initializeVMA()               ; assert(res!=false)
    res = createSwapchain(g.width,g.height) ; assert(res!=false)
    res = createShaders()               ; assert(res!=false)
    res = createGraphicsPipeline()      ; assert(res!=false)
    res = createSyncResources()         ; assert(res!=false)
    res = createCommandBuffers()        ; assert(res!=false)
}