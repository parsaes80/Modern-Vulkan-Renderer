package main

import vk "vendor:vulkan"
import "core:fmt"
import vma "odin-vma"
import "core:mem"

createBuffer :: proc(usage: vk.BufferUsageFlags, byte_size: int, mappable: bool, memory_usage: vma.MemoryUsage) -> GPUBuffer {
	// create buffer and vma allocation
	buff_info := vk.BufferCreateInfo{
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(byte_size),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	alloc_info := vma.AllocationCreateInfo{
		flags = mappable ? {.HOST_ACCESS_SEQUENTIAL_WRITE} : {},
		usage = memory_usage,
	}
	gpu_buff: GPUBuffer
	if vma.CreateBuffer(g.allocator, buff_info, alloc_info, &gpu_buff.vk_buffer, &gpu_buff.allocation, nil) != .SUCCESS {
		return GPUBuffer{}
	}

	// BDA Send Device Pointer
	if .SHADER_DEVICE_ADDRESS in usage {
		vert_bda_info := vk.BufferDeviceAddressInfo{
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = gpu_buff.vk_buffer,
		}
		gpu_buff.device_address = vk.GetBufferDeviceAddress(g.device, &vert_bda_info)
	}
	return gpu_buff
}

mapCopyBufferData :: proc(buffer: GPUBuffer, buffer_offset: int, data: rawptr, byte_size: int) {
	// map and write buffer data
	buff_ptr: rawptr
	if vma.MapMemory(g.allocator, buffer.allocation, &buff_ptr) != .SUCCESS {
		fmt.println("Unable to map buffer memory")
		return
	}
	dst := rawptr(uintptr(buff_ptr) + uintptr(buffer_offset))
	mem.copy(dst, data, byte_size)
	vma.UnmapMemory(g.allocator, buffer.allocation)
}

createImage :: proc(command_buffer: vk.CommandBuffer, image_data: [^]u32, width: u32, height: u32, channels: int) -> (u32, GPUBuffer) {
	// create vk image and allocation
	image_format := vk.Format.R8G8B8A8_SRGB
	image_info := vk.ImageCreateInfo{
		sType       = .IMAGE_CREATE_INFO,
		imageType   = .D2,
		format      = image_format,
		extent      = {width, height, 1},
		mipLevels   = 1,
		arrayLayers = 1,
		samples     = {._1},
		tiling      = .OPTIMAL,
		usage       = {.TRANSFER_DST, .SAMPLED},
		initialLayout = .UNDEFINED,
	}
	alloc_info := vma.AllocationCreateInfo{usage = .AUTO}
	gpu_image: GPUImage
	if vma.CreateImage(g.allocator, image_info, alloc_info, &gpu_image.image, &gpu_image.allocation, nil) != .SUCCESS {
		fmt.println("Error creating image")
		return 0, GPUBuffer{}
	}

	img_view_info := vk.ImageViewCreateInfo{
		sType    = .IMAGE_VIEW_CREATE_INFO,
		image    = gpu_image.image,
		viewType = .D2,
		format   = image_format,
		subresourceRange = {
			aspectMask = {.COLOR},
			levelCount = 1,
			layerCount = 1,
		},
	}
	if vk.CreateImageView(g.device, &img_view_info, nil, &gpu_image.image_view) != .SUCCESS {
		fmt.println("Error creating image view")
		return 0, GPUBuffer{}
	}

	// transition the image to transfer-DST
	transfer_barrier := vk.ImageMemoryBarrier2{
		sType         = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask  = {},
		srcAccessMask = {},
		dstStageMask  = {.COPY},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout     = .UNDEFINED,
		newLayout     = .TRANSFER_DST_OPTIMAL,
		image         = gpu_image.image,
		subresourceRange = {
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}
	transfer_dep_info := vk.DependencyInfo{
		sType                    = .DEPENDENCY_INFO,
		imageMemoryBarrierCount  = 1,
		pImageMemoryBarriers     = &transfer_barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &transfer_dep_info)

	// create staging buffer and issue record copy operation
	byte_size := int(width) * int(height) * channels
	stage_buff := createBuffer({.TRANSFER_SRC}, byte_size, true, .AUTO_PREFER_HOST)
	mapCopyBufferData(stage_buff, 0, image_data, byte_size)

	buff_img_copy := vk.BufferImageCopy{
		imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		imageExtent      = {width, height, 1},
	}
	vk.CmdCopyBufferToImage(command_buffer, stage_buff.vk_buffer, gpu_image.image, .TRANSFER_DST_OPTIMAL, 1, &buff_img_copy)

	// transition image for shader read/sampling
	shader_read_barrier := vk.ImageMemoryBarrier2{
		sType         = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask  = {.COPY},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask  = {.FRAGMENT_SHADER},
		dstAccessMask = {.SHADER_READ},
		oldLayout     = .TRANSFER_DST_OPTIMAL,
		newLayout     = .SHADER_READ_ONLY_OPTIMAL,
		image         = gpu_image.image,
		subresourceRange = {
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}
	shader_read_dep_info := vk.DependencyInfo{
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &shader_read_barrier,
	}
	vk.CmdPipelineBarrier2(command_buffer, &shader_read_dep_info)

	append(&g.images, gpu_image)
	image_id := u32(len(g.images))
	return image_id, stage_buff
}

startTransientCommandBuffer::proc()-> vk.CommandBuffer 
{
    cmdAllocInfo :vk.CommandBufferAllocateInfo = {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = g.command_pool,
        level = .PRIMARY,
        commandBufferCount = 1 
    } 
    commandBuffer : vk.CommandBuffer
    if vk.AllocateCommandBuffers(g.device, &cmdAllocInfo, &commandBuffer) != .SUCCESS{
        fmt.print("Unable to allocate command buffer")
        return nil
    }    
    beginInfo: vk.CommandBufferBeginInfo = {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT}
    }
    if vk.BeginCommandBuffer(commandBuffer,&beginInfo) != .SUCCESS{
        fmt.print("Unable to begin command buffer")
        vk.FreeCommandBuffers(g.device,g.command_pool,1,&commandBuffer)
        return nil
    }
    return commandBuffer
}

submitTransientCommandBuffer :: proc(command_buffer: vk.CommandBuffer) {
	command_buffer := command_buffer
	vk.EndCommandBuffer(command_buffer)

	// TODO: Submit on a transfer queue
	submit_info := vk.SubmitInfo{
		sType               = .SUBMIT_INFO,
		commandBufferCount  = 1,
		pCommandBuffers     = &command_buffer,
	}

	vk.QueueSubmit(g.graphics_queue, 1, &submit_info, 0)
	vk.QueueWaitIdle(g.graphics_queue)
	vk.FreeCommandBuffers(g.device, g.command_pool, 1, &command_buffer)
}

loadData::proc(){
    vertexBufferBytes := 64*1024*1024 //64 MB
    indexBufferBytes := 32*1024*1024 //32 MB
    totalVerts := vertexBufferBytes / size_of(Vertex)
    totalIndicies := indexBufferBytes / size_of(u32)
    resize(&g.vertecies, totalVerts)
    resize(&g.indicies, totalIndicies)

    whitePixelData : u32 = 0xFFFFFFFF

    whitePixel : Image = {
        width = 1,
        height = 1,
        channels = 4,
        data = &whitePixelData
    }

    whiteImgCmdBuff := startTransientCommandBuffer()
    whiteImageId, whiteStagingBuffer := createImage(whiteImgCmdBuff,whitePixel.data,u32(whitePixel.width),u32(whitePixel.height),4)
    g.white_pixel_image_id = whiteImageId
    submitTransientCommandBuffer(whiteImgCmdBuff)
    vma.DestroyBuffer(g.allocator,whiteStagingBuffer.vk_buffer,whiteStagingBuffer.allocation)
    
}