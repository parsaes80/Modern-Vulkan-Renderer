package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "core:log"
import "core:fmt"
import "vendor:cgltf"

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

print::proc{fmt.println}

shutdown :: proc() {
    // wait in case resources are in use
    vk.DeviceWaitIdle(g.device)
    
    vk.DestroyDescriptorSetLayout(g.device,g.globalDsLayout,nil)
    vk.DestroyDescriptorPool(g.device,g.descPool,nil)

    for &img in g.images{
        vk.DestroyImageView(g.device,img.imageView,nil)
        vk.DestroyImage(g.device,img.image,nil)
        vma.FreeMemory(g.allocator,img.allocation)
    }
    for sampler in g.samplers{
        vk.DestroySampler(g.device,sampler,nil)
    }
    for &buff in g.buffers{
        vk.DestroyBuffer(g.device,buff.vkBuffer,nil)
        vma.FreeMemory(g.allocator,buff.allocation)
    }
    
    // // frame / sync object cleanup
    for res in g.frameResources{
        vk.DestroySemaphore(g.device,res.imageAcquiredSemaphore,nil)
        vk.DestroyCommandPool(g.device,res.commandPool,nil)
    }
    
    vk.DestroySemaphore(g.device, g.timelineSemaphore, nil)
    
    // pipeline cleanup
    if g.pipelineLayout != 0 {
        vk.DestroyPipelineLayout(g.device, g.pipelineLayout, nil)
    }
    if g.pipeline != 0 {
        vk.DestroyPipeline(g.device, g.pipeline, nil)
    }

    // cleanup shaders
    if g.vertShaderModule != 0 {
        vk.DestroyShaderModule(g.device, g.vertShaderModule, nil)
    }
    if g.fragShaderModule != 0 {
        vk.DestroyShaderModule(g.device, g.fragShaderModule, nil)
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

    delete(g.images)
    delete(g.samplers)
    delete(g.textures)
    delete(g.buffers)
    delete(g.materials)
    delete(g.meshes)
    delete(g.vertecies)
    delete(g.indicies)
    delete(g.swapchainImages)
    delete(g.nodeWorld.nodes)
    delete(g.nodeRenderStack)
}

destroySwapchain :: proc() {
    for view in g.swapchainViews {
        vk.DestroyImageView(g.device, view, nil)
    }
    delete(g.swapchainViews)
    g.swapchainViews = nil

    // destroy render-complete semaphores
    for semaphore in g.renderCompleteSemaphores {
        vk.DestroySemaphore(g.device, semaphore, nil)
    }
    delete(g.renderCompleteSemaphores)
    g.renderCompleteSemaphores = nil

    if g.swapchain != 0 {
        vk.DestroySwapchainKHR(g.device, g.swapchain, nil)
        g.swapchain = 0
    }

    // destroy the depth buffer along with the swapchain
    if g.depthImageView != 0 {
        vk.DestroyImageView(g.device, g.depthImageView, nil)
        vma.DestroyImage(g.allocator, g.depthImage, g.depthImageAllocation)
        g.depthImageView = 0
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
    append(&requestedExtentions, "VK_EXT_swapchain_colorspace")
    //print(requestedExtentions)

    //requestedLayers := []cstring{"VK_LAYER_KHRONOS_validation"}
    requestedLayers := []cstring{}

    enabledFeatures : []vk.ValidationFeatureEnableEXT = {.GPU_ASSISTED}

    validationFeatures := vk.ValidationFeaturesEXT{
        sType                          = .VALIDATION_FEATURES_EXT,
        enabledValidationFeatureCount  = 1,
        pEnabledValidationFeatures     = &enabledFeatures[0],
    }

    debugInfo : vk.DebugUtilsMessengerCreateInfoEXT = {
        sType=.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = {.VERBOSE,.WARNING,.ERROR},
        messageType = {.VALIDATION,.PERFORMANCE},
        pfnUserCallback = debugCallback,
        //pNext = &validationFeatures
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
    g.physicalDevice = physicalDevices[0]

    // look through list and see if a dGPU exists
    for pDev in physicalDevices {
        props: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(pDev, &props)
        if props.deviceType == .DISCRETE_GPU {
            g.physicalDevice = pDev
            break
        }
    }

    // ensure the desired swapchain format is supported
    formatCount: u32 = 0
    vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physicalDevice, g.surface, &formatCount, nil)

    surfaceFormats := make([]vk.SurfaceFormatKHR, formatCount)
    defer delete(surfaceFormats)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physicalDevice, g.surface, &formatCount, raw_data(surfaceFormats))

    formatSupported := false
    for surf_format in surfaceFormats {
        if surf_format.format == g.swapchainFormat.format {
            formatSupported = true
            break
        }
    }

    if !formatSupported {
        print("Requested swapchain format is not supported by the surface")
        return false
    }

    return true
}

findGraphicsQueue::proc()->bool{
    queueFamCount :u32= 0 
    vk.GetPhysicalDeviceQueueFamilyProperties2(g.physicalDevice,&queueFamCount,nil)
    queueFamProps := make([]vk.QueueFamilyProperties2, queueFamCount)
    defer delete(queueFamProps)
    for &qf in queueFamProps {qf.sType = .QUEUE_FAMILY_PROPERTIES_2}
    vk.GetPhysicalDeviceQueueFamilyProperties2(g.physicalDevice, &queueFamCount, raw_data(queueFamProps))

    for currentFamIdx in 0 ..< len(queueFamProps) {
        // ensure it has presentation support
        hasPresentSupport: b32 = false
        vk.GetPhysicalDeviceSurfaceSupportKHR(g.physicalDevice, u32(currentFamIdx), g.surface, &hasPresentSupport)

        props := queueFamProps[currentFamIdx]
        // ensure this is a GRAPHICS queue with presentation support
        if .GRAPHICS in props.queueFamilyProperties.queueFlags && bool(hasPresentSupport) {
            g.graphicsQueueFamilyIdx = u32(currentFamIdx)
            return true
        }
    }
    return false
}

createDevice :: proc() -> bool {
    queuePriority: f32 = 1.0
    gfxQueueInfo : vk.DeviceQueueCreateInfo = {
        sType            = .DEVICE_QUEUE_CREATE_INFO,
        queueFamilyIndex = g.graphicsQueueFamilyIdx,
        queueCount       = 1,
        pQueuePriorities = &queuePriority,
    }

    // query supported features
    supported_features_14 := vk.PhysicalDeviceVulkan14Features{sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, pNext = nil}
    supported_features_13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, pNext = &supported_features_14}
    supported_features_12 := vk.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, pNext = &supported_features_13}
    supported_features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &supported_features_12}
    vk.GetPhysicalDeviceFeatures2(g.physicalDevice, &supported_features)

    if !supported_features_13.dynamicRendering || !supported_features_13.synchronization2 ||
    !supported_features_12.timelineSemaphore || !supported_features_12.bufferDeviceAddress ||
    !supported_features_12.scalarBlockLayout || !supported_features_12.descriptorIndexing ||
    !supported_features_12.descriptorBindingSampledImageUpdateAfterBind ||
    !supported_features_12.descriptorBindingPartiallyBound ||
    !supported_features_12.runtimeDescriptorArray ||
    !supported_features.features.shaderInt64 ||
    !supported_features.features.multiDrawIndirect{
		print("Physical device doesn't meet the feature requirements");
		return false;
	}

    // check if what we need is supported
    if !supported_features_13.dynamicRendering || !supported_features_13.synchronization2 ||
       !supported_features_12.timelineSemaphore {
        print("Physical device doesn't meet the feature requirements")
        return false
    }

    // produce a separate features struct chain for device creation
    features_14 : vk.PhysicalDeviceVulkan14Features = {
        sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
        hostImageCopy = true,
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
        descriptorIndexing = true,
        shaderSampledImageArrayNonUniformIndexing = true,
        descriptorBindingSampledImageUpdateAfterBind = true,
        descriptorBindingPartiallyBound = true,
        runtimeDescriptorArray =true,
        scalarBlockLayout = true,
        bufferDeviceAddress = true,
        timelineSemaphore = true,

    }
    features : vk.PhysicalDeviceFeatures2 = {
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = &features_12,
        features = {
            multiDrawIndirect = true,
            shaderInt64 = true,
            robustBufferAccess = true,
            drawIndirectFirstInstance = true, 
        }
    }

    deviceExtensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

    deviceCreateInfo : vk.DeviceCreateInfo = {
        sType                   = .DEVICE_CREATE_INFO,
        pNext                   = &features,
        queueCreateInfoCount    = 1,
        pQueueCreateInfos       = &gfxQueueInfo,
        enabledExtensionCount   = u32(len(deviceExtensions)),
        ppEnabledExtensionNames = raw_data(deviceExtensions[:]),
        pEnabledFeatures        = nil, // features struct chain is set in pNext
    }

    if vk.CreateDevice(g.physicalDevice, &deviceCreateInfo, nil, &g.device) != .SUCCESS {
        return false
    }

    // grab the VkQueue object finally
    vk.GetDeviceQueue(g.device, g.graphicsQueueFamilyIdx, 0, &g.graphicsQueue)
    if g.graphicsQueue == nil {
        print("Couldn't get the graphics queue")
        return false
    }
    vk.load_proc_addresses(g.device)
    return true
}

initializeVMA::proc()->bool{
    // Initializes a subset of Vulkan functions required by VMA
    vmaVulkanFunctions := vma.create_vulkan_functions()

    vmaCreateInfo: vma.AllocatorCreateInfo = {
        flags            = {.BUFFER_DEVICE_ADDRESS},
        instance         = g.instance,
        physicalDevice   = g.physicalDevice,
        device           = g.device,
        pVulkanFunctions = &vmaVulkanFunctions,
        vulkanApiVersion = vk.API_VERSION_1_4,
    }

    return vma.CreateAllocator(vmaCreateInfo, &g.allocator) == .SUCCESS
}

createSwapchain :: proc(width:u32,height:u32) -> bool {
    g.swapchainWidth = width
    g.swapchainHeight= height

    surfaceCaps: vk.SurfaceCapabilitiesKHR
    if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g.physicalDevice, g.surface, &surfaceCaps) != .SUCCESS do return false
    requestedImgCount := max(2, surfaceCaps.minImageCount)
    if surfaceCaps.maxImageCount > 0 do requestedImgCount = min(requestedImgCount, surfaceCaps.maxImageCount)

    swapchainCreateInfo : vk.SwapchainCreateInfoKHR =
    {
        sType            = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = g.surface,
        minImageCount    = requestedImgCount,
        imageFormat      = g.swapchainFormat.format,
        imageColorSpace  = g.swapchainFormat.colorSpace,
        imageExtent      = {g.swapchainWidth, g.swapchainHeight},
        imageArrayLayers = 1,
        imageUsage       = {.COLOR_ATTACHMENT},
        preTransform     = surfaceCaps.currentTransform,
        compositeAlpha   = {.OPAQUE},
        presentMode      = .IMMEDIATE,
    }

    if vk.CreateSwapchainKHR(g.device, &swapchainCreateInfo, nil, &g.swapchain) != .SUCCESS do return false

    fmt.printfln("created swapchain with %v images, width:%v height:%v", requestedImgCount,g.swapchainWidth,g.swapchainHeight)

    // grab the swapchain images
    imageCount: u32 = 0
    vk.GetSwapchainImagesKHR(g.device, g.swapchain, &imageCount, nil)
    g.swapchainImages = make([]vk.Image, imageCount)

    vk.GetSwapchainImagesKHR(g.device, g.swapchain, &imageCount, raw_data(g.swapchainImages))
    g.swapchainViews = make([]vk.ImageView, imageCount)

    // create the swapchain image views
    for i in 0 ..< len(g.swapchainImages) {
        imgViewInfo : vk.ImageViewCreateInfo = {
            sType    = .IMAGE_VIEW_CREATE_INFO,
            image    = g.swapchainImages[i],
            viewType = .D2,
            format   = g.swapchainFormat.format,
            subresourceRange = {
                aspectMask = {.COLOR},
                levelCount = 1,
                layerCount = 1,
            },
        }
        if vk.CreateImageView(g.device, &imgViewInfo, nil, &g.swapchainViews[i]) != .SUCCESS {
            print("Error creating swapchain image view")
            return false
        }
    }

    // semaphores used to signal render completion
    g.renderCompleteSemaphores = make([]vk.Semaphore, len(g.swapchainImages))
    for &semaphore in g.renderCompleteSemaphores {
        semaphoreInfo := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
        if vk.CreateSemaphore(g.device, &semaphoreInfo, nil, &semaphore) != .SUCCESS {
            print("Error creating the render-complete semaphore")
            return false
        }
    }

    // create depth image
    depthCreateInfo : vk.ImageCreateInfo =
    {
        sType       = .IMAGE_CREATE_INFO,
        imageType   = .D2,
        format      = g.depthFormat,
        extent      = {g.swapchainWidth, g.swapchainHeight, 1},
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
    if vma.CreateImage(g.allocator, depthCreateInfo, allocInfo, &g.depthImage, &g.depthImageAllocation, nil) != .SUCCESS {
        print("Error allocating depth image")
        return false
    }

    depthImgViewInfo : vk.ImageViewCreateInfo = {
        sType    = .IMAGE_VIEW_CREATE_INFO,
        image    = g.depthImage,
        viewType = .D2,
        format   = g.depthFormat,
        subresourceRange = {
            aspectMask = {.DEPTH},
            levelCount = 1,
            layerCount = 1,
        },
    }
    if vk.CreateImageView(g.device, &depthImgViewInfo, nil, &g.depthImageView) != .SUCCESS {
        print("Error creating depth image view")
        return false
    }
    return true
}

createShaderModule :: proc(filename: string, kind: shaderc.shaderKind) -> vk.ShaderModule {
    shaderPath := strings.concatenate({"shaders/", filename})
    defer delete(shaderPath)

    srcBytes, readOk := os.read_entire_file(shaderPath,context.allocator)

    defer delete(srcBytes)

    print("Compiling shader:", shaderPath)

    compiler := shaderc.compiler_initialize()
    defer shaderc.compiler_release(compiler)

    opts := shaderc.compile_options_initialize()
    defer shaderc.compile_options_release(opts)
    
    shaderc.compile_options_set_target_env(opts, .Vulkan, u32(shaderc.envVersion.Vulkan1_4))

    shaderc.compile_options_set_target_spirv(opts, .Spv1_6)

    shaderc.compile_options_set_optimization_level(opts, .Performance)
    //shaderc.compile_options_set_optimization_level(opts, .Zero)     
	//shaderc.compile_options_set_generate_debug_info(opts)       

    filename_cstr := strings.clone_to_cstring(filename)
    defer delete(filename_cstr)

    result := shaderc.compile_into_spv(
        compiler,
        cstring(raw_data(srcBytes)),
        len(srcBytes),
        kind,
        filename_cstr,
        "main",
        opts,
    )
    defer shaderc.result_release(result)

    if shaderc.result_get_compilation_status(result) != .Success {
        err_msg := shaderc.result_get_error_message(result)
        print("Shader Compilation Error:", err_msg)
        return 0
    }

    spvSize := shaderc.result_get_length(result)
    spvBytes := shaderc.result_get_bytes(result)

    moduleCreateInfo : vk.ShaderModuleCreateInfo = {
        sType    = .SHADER_MODULE_CREATE_INFO,
        codeSize = int(spvSize),
        pCode    = cast(^u32)spvBytes,
    }

    shaderModule: vk.ShaderModule
    if vk.CreateShaderModule(g.device, &moduleCreateInfo, nil, &shaderModule) != .SUCCESS {
        print("Error creating shader module")
        return 0
    }

    return shaderModule
}

createShaders :: proc() -> bool {
    g.vertShaderModule = createShaderModule("shader.vert", .VertexShader)
    if g.vertShaderModule == 0 {return false}
    g.fragShaderModule = createShaderModule("shader.frag", .FragmentShader)
    if g.fragShaderModule == 0 {return false}
    return true
}

createDescriptorSets :: proc() -> bool {
	poolSizes: [1]vk.DescriptorPoolSize = {{
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = MAX_TEXTURES,
	}}
	poolInfo: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = len(poolSizes),
		pPoolSizes    = &poolSizes[0],
	}
	if vk.CreateDescriptorPool(g.device, &poolInfo, nil, &g.descPool) != .SUCCESS {
		print("Unable to create descriptor pool")
		return false
	}

	// global descriptor set
	bindings: [1]vk.DescriptorSetLayoutBinding = {{
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = MAX_TEXTURES,
		stageFlags      = {.FRAGMENT},
	}}
	bindingFlags:= [?]vk.DescriptorBindingFlags{{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}}
	flagsInfo: vk.DescriptorSetLayoutBindingFlagsCreateInfo = {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = len(bindingFlags),
		pBindingFlags = &bindingFlags[0],
	}
	layoutInfo: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &flagsInfo,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = len(bindings),
		pBindings    = &bindings[0],
	}
	if vk.CreateDescriptorSetLayout(g.device, &layoutInfo, nil, &g.globalDsLayout) != .SUCCESS {
		print("Unable to create descriptor set layout")
		return false
	}

	// create the actual descriptor set
	descSetAllocInfo: vk.DescriptorSetAllocateInfo = {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = g.descPool,
		descriptorSetCount = 1,
		pSetLayouts        = &g.globalDsLayout,
	}
	if vk.AllocateDescriptorSets(g.device, &descSetAllocInfo, &g.globalDescSet) != .SUCCESS {
		print("Unable to allocate descriptor set")
		return false
	}
	return true
}

createGraphicsPipeline :: proc() -> bool {
    pushConstantsRange: vk.PushConstantRange = {
        stageFlags = {.VERTEX,.FRAGMENT},
        offset = 0,
        size = size_of(FrameConstants) 
    }
    dsLayout : [1]vk.DescriptorSetLayout = {g.globalDsLayout}

    pipelineLayoutInfo := vk.PipelineLayoutCreateInfo{
        sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount         = cast(u32)len(dsLayout),
        pSetLayouts            = &dsLayout[0],
        pushConstantRangeCount = 1,
        pPushConstantRanges = &pushConstantsRange,
    }
    if vk.CreatePipelineLayout(g.device, &pipelineLayoutInfo, nil, &g.pipelineLayout) != .SUCCESS {
        print("unable to create pipeline layout")
        return false
    }
    entryPoint: cstring = "main"
    shaderStages: [2]vk.PipelineShaderStageCreateInfo = {
        {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.VERTEX},
            module = g.vertShaderModule,
            pName  = entryPoint,
        },
        {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.FRAGMENT},
            module = g.fragShaderModule,
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
    colorAttachmentFormats: [1]vk.Format = {g.swapchainFormat.format}
    renderInfo: vk.PipelineRenderingCreateInfo = {
        sType                   = .PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount    = 1,
        pColorAttachmentFormats = raw_data(colorAttachmentFormats[:]),
        depthAttachmentFormat   = g.depthFormat,
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
        layout              = g.pipelineLayout,
        renderPass          = 0,
    }
    if vk.CreateGraphicsPipelines(g.device, 0, 1, &pipelineInfo, nil, &g.pipeline) != .SUCCESS {
        print("Error creating the pipeline")
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
    if vk.CreateSemaphore(g.device, &semaphoreInfo, nil, &g.timelineSemaphore) != .SUCCESS {
        print("Unable to create the timeline semaphore")
        return false
    }

    // per-frame image-acquire semaphores
    for &res in g.frameResources {
        // create the binary semaphores
        frame_semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
        if vk.CreateSemaphore(g.device, &frame_semaphore_info, nil, &res.imageAcquiredSemaphore) != .SUCCESS {
            print("Error creating the per-frame image-acquire semaphore")
            return false
        }
    }

    return true
}

createCommandBuffers :: proc() -> bool {
    poolInfo: vk.CommandPoolCreateInfo = {
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.TRANSIENT},
        queueFamilyIndex = g.graphicsQueueFamilyIdx,
    }

    if vk.CreateCommandPool(g.device,&poolInfo,nil,&g.commandPool) != .SUCCESS {
        print("Unable to create command pool")
        return false
    }
     
    for &res in g.frameResources {
        // we'll give each frame its own pool, faster cmd buffer resets this way
        poolInfo : vk.CommandPoolCreateInfo = {
            sType            = .COMMAND_POOL_CREATE_INFO,
            queueFamilyIndex = g.graphicsQueueFamilyIdx,
        }
        if vk.CreateCommandPool(g.device, &poolInfo, nil, &res.commandPool) != .SUCCESS {
            print("Unable to create command buffer pool")
            return false
        }

        // create the command buffer for this frame
        cmdAllocInfo : vk.CommandBufferAllocateInfo = {
            sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool        = res.commandPool,
            level              = .PRIMARY,
            commandBufferCount = 1,
        }
        if vk.AllocateCommandBuffers(g.device, &cmdAllocInfo, &res.commandBuffer) != .SUCCESS {
            print("Unable to allocate command buffer")
            return false
        }
    }
    return true
}

createIndirectDrawBuffers :: proc() -> bool {
	for &res in g.frameResources {
		// indirect drawing buffer
		indirectBuffByteSize := g.nodeWorld.maxNodes * size_of(vk.DrawIndexedIndirectCommand)
		res.indirectDrawBuffer = createBuffer({.INDIRECT_BUFFER}, indirectBuffByteSize, true, .AUTO)
		indBuffPtr: rawptr
		if vma.MapMemory(g.allocator, res.indirectDrawBuffer.allocation, &indBuffPtr) != .SUCCESS {
			print("Unable to map indirect draw buffer")
			return false
		}
		res.indirectDrawPtr = cast([^]vk.DrawIndexedIndirectCommand)indBuffPtr

		// render item buffer (per-draw data)
		renderItemByteSize := g.nodeWorld.maxNodes * size_of(RenderItem)
		res.renderItemBuffer = createBuffer({.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, renderItemByteSize, true, .AUTO)
		riBuffPtr: rawptr
		if vma.MapMemory(g.allocator, res.renderItemBuffer.allocation, &riBuffPtr) != .SUCCESS {
			print("Unable to map render item buffer")
			return false
		}
		res.renderItemPtr = cast([^]RenderItem)riBuffPtr
	}
	return true
}

initializeVulkan :: proc(){
    res : bool
    res = createVulkanInstance()           ; assert(res!=false)
    res = createSurface()                  ; assert(res!=false)
    res = findPhysicalDevice()             ; assert(res!=false)
    res = findGraphicsQueue()              ; assert(res!=false) 
    res = createDevice()                   ; assert(res!=false)
    res = initializeVMA()                  ; assert(res!=false)
    res = createSwapchain(g.width,g.height); assert(res!=false)
    res = createShaders()                  ; assert(res!=false)
    res = createDescriptorSets()           ; assert(res!=false)
    res = createGraphicsPipeline()         ; assert(res!=false)
    res = createSyncResources()            ; assert(res!=false)
    res = createCommandBuffers()           ; assert(res!=false)
    res = createIndirectDrawBuffers()      ; assert(res!=false) 
}