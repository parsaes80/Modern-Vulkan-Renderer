package main

import "core:image"
import "vendor:cgltf"
import vk "vendor:vulkan"
import "core:fmt"
import vma "odin-vma"
import "core:mem"
import "core:os"
import "core:strings"
import stbi "vendor:stb/image"


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
        print("Unable to map buffer memory")
        return
    }
    dst := rawptr(uintptr(buff_ptr) + uintptr(buffer_offset))
    mem.copy(dst, data, byte_size)
    vma.UnmapMemory(g.allocator, buffer.allocation)
}

createImage :: proc(command_buffer: vk.CommandBuffer, image_data: ^byte, width: u32, height: u32, channels: int) -> (u32, GPUBuffer) {
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
        print("Error creating image")
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
        print("Error creating image view")
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

startTransientCommandBuffer::proc()-> vk.CommandBuffer {
    cmdAllocInfo :vk.CommandBufferAllocateInfo = {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = g.command_pool,
        level = .PRIMARY,
        commandBufferCount = 1 
    } 
    commandBuffer : vk.CommandBuffer
    if vk.AllocateCommandBuffers(g.device, &cmdAllocInfo, &commandBuffer) != .SUCCESS{
        print("Unable to allocate command buffer")
        return nil
    }    
    beginInfo: vk.CommandBufferBeginInfo = {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT}
    }
    if vk.BeginCommandBuffer(commandBuffer,&beginInfo) != .SUCCESS{
        print("Unable to begin command buffer")
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

loadImages :: proc(model: ^cgltf.data, image_dir: string) -> [dynamic]Image {
    images :[dynamic]Image
    resize(&images, len(model.images))
    for i in 0 ..< len(model.images) {
        img := &images[i]
        uri := string(model.images[i].uri)
        fmt.printf("Loading image %d/%d: %s\n", i + 1, len(model.images), uri)

        cpath := fmt.ctprintf("./%s/%s", image_dir, uri)
        w, h, ch: i32
        img.data = stbi.load(cpath, &w, &h, &ch, 4)
        img.width = int(w)
        img.height = int(h)
        img.channels = 4

        if img.data == nil {
            print(fmt.tprintf("Failed to load image: %s, %v", cpath, stbi.failure_reason()))
        }
    }
    return images
}

uploadImages::proc(images:[dynamic]Image)->[dynamic]u32{
    imageIds:[dynamic]u32
    resize(&imageIds, len(images))

    commandBuffer := startTransientCommandBuffer()

    stagingBuffers:[dynamic]GPUBuffer
    defer delete(stagingBuffers)
    resize(&stagingBuffers, len(images))

    for image,idx in images{
        if image.data != nil{
            imageId, stagingTexBuffer := createImage(commandBuffer,image.data,auto_cast image.width,auto_cast image.height,4)
            imageIds[idx] = imageId
            append(&stagingBuffers, stagingTexBuffer)
        }
        else do imageIds[idx] = g.white_pixel_image_id
    }

    submitTransientCommandBuffer(commandBuffer)

    for &buff in stagingBuffers{
        vma.DestroyBuffer(g.allocator,buff.vk_buffer,buff.allocation)
    }
    return imageIds
}

loadSamplers :: proc(model: ^cgltf.data) -> [dynamic]u32 {
	sampler_ids: [dynamic]u32
	resize(&sampler_ids, len(model.samplers))

	filter_info :: proc(f: cgltf.filter_type) -> (filter: vk.Filter, mipmap_mode: vk.SamplerMipmapMode, max_lod: f32) {
		#partial switch f {
		case .nearest:                return .NEAREST, .NEAREST, 0.25
		case .linear:                 return .LINEAR, .NEAREST, 0.25
		case .linear_mipmap_linear:   return .LINEAR, .LINEAR, f32(vk.LOD_CLAMP_NONE)
		case .nearest_mipmap_nearest: return .NEAREST, .NEAREST, f32(vk.LOD_CLAMP_NONE)
		case .nearest_mipmap_linear:  return .NEAREST, .LINEAR, f32(vk.LOD_CLAMP_NONE)
		case .linear_mipmap_nearest:  return .LINEAR, .NEAREST, f32(vk.LOD_CLAMP_NONE)
		}
		return .LINEAR, .LINEAR, f32(vk.LOD_CLAMP_NONE) // .undefined, or any unhandled value
	}

	wrap_conv :: proc(w: cgltf.wrap_mode) -> vk.SamplerAddressMode {
		switch w {
		case .repeat:          return .REPEAT
		case .clamp_to_edge:   return .CLAMP_TO_EDGE
		case .mirrored_repeat: return .MIRRORED_REPEAT
		}
		return .REPEAT
	}

	for &s, i in model.samplers {
		mag_filter, _, _              := filter_info(s.mag_filter)
		min_filter, mip_mode, max_lod := filter_info(s.min_filter)
		addr_u := wrap_conv(s.wrap_s)
		addr_v := wrap_conv(s.wrap_t)

		sampler_info := vk.SamplerCreateInfo{
			sType         = .SAMPLER_CREATE_INFO,
			magFilter     = mag_filter,
			minFilter     = min_filter,
			mipmapMode    = mip_mode,
			addressModeU  = addr_u,
			addressModeV  = addr_v,
			addressModeW  = .REPEAT,
			compareEnable = false,
			minLod        = 0,
			maxLod        = max_lod,
		}

		sampler: vk.Sampler
		if vk.CreateSampler(g.device, &sampler_info, nil, &sampler) != .SUCCESS {
			print("Unable to create texture sampler, using fallback texture")
			sampler_ids[i] = g.textures[0].sampler_id
		} else {
			append(&g.samplers, sampler)
			sampler_ids[i] = u32(len(g.samplers))
		}
	}
	return sampler_ids
}

loadTextures :: proc(model: ^cgltf.data, image_ids: [dynamic]u32, sampler_ids: [dynamic]u32) -> [dynamic]u32 {
	assert(len(g.textures) + len(model.textures) <= MAX_TEXTURES, "Exceeding max texture count")

	texture_ids: [dynamic]u32
	resize(&texture_ids, len(model.textures))

	images_base   := raw_data(model.images)
	samplers_base := raw_data(model.samplers)

	for &tex, i in model.textures {
		image_idx   := int(uintptr(tex.image_)   - uintptr(images_base))   / size_of(cgltf.image)
		sampler_idx := int(uintptr(tex.sampler) - uintptr(samplers_base)) / size_of(cgltf.sampler)

		append(&g.textures, Texture{
			image_id   = image_ids[image_idx],
			sampler_id = sampler_ids[sampler_idx],
		})
		texture_ids[i] = u32(len(g.textures))
	}
	return texture_ids
}

loadMaterials :: proc(model: ^cgltf.data, texture_ids: [dynamic]u32) -> [dynamic]u32 {
	material_ids: [dynamic]u32
	resize(&material_ids, len(model.materials))

	textures_base := raw_data(model.textures)

	for &mat, i in model.materials {
		pbr := mat.pbr_metallic_roughness
		tex_index: u32 = 0
		if pbr.base_color_texture.texture != nil {
			idx := int(uintptr(pbr.base_color_texture.texture) - uintptr(textures_base)) / size_of(cgltf.texture)
			tex_index = texture_ids[idx] - 1
		}

		append(&g.materials, Material{
			base_color    = Vec4(pbr.base_color_factor),
			texture_index = tex_index,
		})
		material_ids[i] = u32(len(g.materials))
	}
	return material_ids
}

loadMeshes :: proc(model: ^cgltf.data, material_ids: [dynamic]u32) -> [dynamic]u32 {
	mesh_ids: [dynamic]u32
	resize(&mesh_ids, len(model.meshes))

	materials_base := raw_data(model.materials)

	for &gltf_mesh, mi in model.meshes {
		mesh: Mesh
		mesh.name = gltf_mesh.name != nil ? string(gltf_mesh.name) : "No Name"
		mesh.sub_meshes = make([dynamic]SubMesh, len(gltf_mesh.primitives))

		for &prim, s in gltf_mesh.primitives {
			mat_idx := int(uintptr(prim.material) - uintptr(materials_base)) / size_of(cgltf.material)
			mesh.sub_meshes[s].material_id = material_ids[mat_idx]
			mesh.sub_meshes[s].vertex_start = g.vert_offset

			for &attr in prim.attributes {
				accessor := attr.data
				#partial switch attr.type {
				case .position:
					assert(accessor.type == .vec3 && accessor.component_type == .r_32f)
					assert(g.vert_offset + u64(accessor.count) <= u64(len(g.vertecies)), "Not enough space to load vertices")
					mesh.sub_meshes[s].vertex_count = u64(accessor.count)
					for idx in 0 ..< accessor.count {
						out: [3]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 3)
						g.vertecies[g.vert_offset + u64(idx)].pos = Vec3(out)
					}
				case .normal:
					assert(accessor.type == .vec3 && accessor.component_type == .r_32f)
					for idx in 0 ..< accessor.count {
						out: [3]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 3)
						g.vertecies[g.vert_offset + u64(idx)].normal = Vec3(out)
					}
				case .color:
					assert((accessor.type == .vec3 || accessor.type == .vec4) && accessor.component_type == .r_32f)
					for idx in 0 ..< accessor.count {
						out: [3]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 3) // first 3 comps, even if source is vec4
						g.vertecies[g.vert_offset + u64(idx)].color = Vec3(out)
					}
				case .texcoord:
					assert(accessor.type == .vec2 && accessor.component_type == .r_32f)
					for idx in 0 ..< accessor.count {
						out: [2]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 2)
						g.vertecies[g.vert_offset + u64(idx)].uv = Vec2(out)
					}
				}
			}
			g.vert_offset += mesh.sub_meshes[s].vertex_count

			if prim.indices != nil {
				accessor := prim.indices
				assert(g.idx_offset + u64(accessor.count) <= u64(len(g.indicies)), "Not enough space for indices")
				mesh.sub_meshes[s].index_start = g.idx_offset
				mesh.sub_meshes[s].index_count = u64(accessor.count)

				for idx in 0 ..< accessor.count {
					g.indicies[g.idx_offset + u64(idx)] = u32(cgltf.accessor_read_index(accessor, idx))
				}
				g.idx_offset += mesh.sub_meshes[s].index_count
			}
		}

		append(&g.meshes, mesh)
		mesh_ids[mi] = u32(len(g.meshes))
	}
	return mesh_ids
}

importNode :: proc(nw: ^NodeWorld, model: ^cgltf.data, gltf_node: ^cgltf.node, parent_id: u32, prev_sibling_id: u32, mesh_ids: [dynamic]u32) -> u32 {
	node, node_id := createNode(nw)
	node.parent_id = parent_id

	if gltf_node.has_matrix {
		m: matrix[4, 4]f32
		mem.copy(&m, &gltf_node.matrix_[0], size_of(m))
		setTransform(node, m)
	} else {
		t := gltf_node.translation
		r := gltf_node.rotation
		s := gltf_node.scale
		setTranslation(node, Vec3{t[0], t[1], t[2]})
		setRotation(node, quaternion(x = r[0], y = r[1], z = r[2], w = r[3]))
		setScale(node, Vec3{s[0], s[1], s[2]})
	}

	if gltf_node.mesh != nil {
		meshes_base := raw_data(model.meshes)
		mesh_idx := int(uintptr(gltf_node.mesh) - uintptr(meshes_base)) / size_of(cgltf.mesh)
		node.mesh_id = mesh_ids[mesh_idx]
	}

	if prev_sibling_id != 0 {
		getNode(nw, prev_sibling_id).next_sibling_id = node_id
	}

	last_child_id: u32 = 0
	for child in gltf_node.children {
		last_child_id = importNode(nw, model, child, node_id, last_child_id, mesh_ids)
		if node.first_child_id == 0 {
			node.first_child_id = last_child_id
		}
	}

	return node_id
}

loadGltf:: proc(path:string) -> bool{
    if !os.exists(path) do return false
    options : cgltf.options
    
    cpath := strings.clone_to_cstring(path,context.temp_allocator)
    model,res := cgltf.parse_file(options,cstring(cpath))
    
    if res!=.success {
        print("Error parsing glTF file, error: ", res)
        return false
    }
    if cgltf.load_buffers(options, model, cpath) != .success {
	    print("Error loading glTF buffers")
	return false
    }

    images := loadImages(model,"/Sponza")
    defer delete(images) 
    imageIds := uploadImages(images)

    for image in images do stbi.image_free(image.data)

    samplerIds:= loadSamplers(model)
    textureIds := loadTextures(model,imageIds,samplerIds)
    materialIds := loadMaterials(model,textureIds)
    meshIds := loadMeshes(model,materialIds)
    
	scene := model.scene
	if scene == nil && len(model.scenes) > 0 {
		scene = &model.scenes[0]
	}

	if scene != nil {
		for gltf_node in scene.nodes {
			node_id := importNode(&g.node_world, model, gltf_node, 0, g.last_root_node_id, meshIds)
			if g.root_node_id == 0 { // first root node
				g.root_node_id = node_id
			}
			g.last_root_node_id = node_id
		}
	}

	cgltf.free(model)
	free_all(context.temp_allocator)
	fmt.println("GLTF Loading Successful\n")
	return true
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
        data = cast(^u8)(&whitePixelData)
    }

    whiteImgCmdBuff := startTransientCommandBuffer()
    whiteImageId, whiteStagingBuffer := createImage(whiteImgCmdBuff,whitePixel.data,u32(whitePixel.width),u32(whitePixel.height),4)
    g.white_pixel_image_id = whiteImageId
    submitTransientCommandBuffer(whiteImgCmdBuff)
    vma.DestroyBuffer(g.allocator,whiteStagingBuffer.vk_buffer,whiteStagingBuffer.allocation)
    
    samplerInfo: vk.SamplerCreateInfo = {
        sType = .SAMPLER_CREATE_INFO,
        magFilter = .NEAREST,
        minFilter = .NEAREST,
        addressModeU = .REPEAT,
        addressModeV = .REPEAT,
        addressModeW = .REPEAT,
        compareEnable = false
    }
    sampler: vk.Sampler
    if vk.CreateSampler(g.device,&samplerInfo,nil,&sampler) != .SUCCESS {
        print("Unable to create texture sampler")
    }
    append(&g.samplers, sampler)
    append(&g.textures, Texture{g.white_pixel_image_id,0})

    loadGltf("Sponza/Sponza.gltf")
}
