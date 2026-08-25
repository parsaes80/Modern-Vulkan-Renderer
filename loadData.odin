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

addBuffer :: proc(buffer: GPUBuffer) -> u32 {
	append(&g.buffers, buffer)
	return u32(len(g.buffers))
}

createBuffer :: proc(usage: vk.BufferUsageFlags, byte_size: int, mappable: bool, memory_usage: vma.MemoryUsage) -> GPUBuffer {
    // create buffer and vma allocation
    buffInfo := vk.BufferCreateInfo{
        sType       = .BUFFER_CREATE_INFO,
        size        = cast(vk.DeviceSize)byte_size,
        usage       = usage,
        sharingMode = .EXCLUSIVE,
    }
    allocInfo := vma.AllocationCreateInfo{
        flags = mappable ? {.HOST_ACCESS_SEQUENTIAL_WRITE} : {},
        usage = memory_usage,
    }
    gpuBuff: GPUBuffer
    if vma.CreateBuffer(g.allocator, buffInfo, allocInfo, &gpuBuff.vkBuffer, &gpuBuff.allocation, nil) != .SUCCESS {
        return GPUBuffer{}
    }

    // BDA Send Device Pointer
    if .SHADER_DEVICE_ADDRESS in usage {
        vert_bda_info := vk.BufferDeviceAddressInfo{
            sType  = .BUFFER_DEVICE_ADDRESS_INFO,
            buffer = gpuBuff.vkBuffer,
        }
        gpuBuff.deviceAddress = vk.GetBufferDeviceAddress(g.device, &vert_bda_info)
    }
    return gpuBuff
}

mapCopyBufferData :: proc(buffer: GPUBuffer, buffer_offset: int, data: rawptr, byte_size: int) {
    // map and write buffer data
    buffPtr: rawptr
    if vma.MapMemory(g.allocator, buffer.allocation, &buffPtr) != .SUCCESS {
        print("Unable to map buffer memory")
        return
    }
    dst := rawptr(uintptr(buffPtr) + uintptr(buffer_offset))
    mem.copy(dst, data, byte_size)
    vma.UnmapMemory(g.allocator, buffer.allocation)
}

createImage :: proc(command_buffer: vk.CommandBuffer, image_data: ^byte, width: u32, height: u32, channels: int) -> (u32, GPUBuffer) {
    // create vk image and allocation
    imageFormat := vk.Format.R8G8B8A8_SRGB
    imageInfo := vk.ImageCreateInfo{
        sType       = .IMAGE_CREATE_INFO,
        imageType   = .D2,
        format      = imageFormat,
        extent      = {width, height, 1},
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = {._1},
        tiling      = .OPTIMAL,
        usage       = {.TRANSFER_DST, .SAMPLED},
        initialLayout = .UNDEFINED,
    }
    allocInfo := vma.AllocationCreateInfo{usage = .AUTO}
    gpuImage: GPUImage
    if vma.CreateImage(g.allocator, imageInfo, allocInfo, &gpuImage.image, &gpuImage.allocation, nil) != .SUCCESS {
        print("Error creating image")
        return 0, GPUBuffer{}
    }

    imgViewInfo := vk.ImageViewCreateInfo{
        sType    = .IMAGE_VIEW_CREATE_INFO,
        image    = gpuImage.image,
        viewType = .D2,
        format   = imageFormat,
        subresourceRange = {
            aspectMask = {.COLOR},
            levelCount = 1,
            layerCount = 1,
        },
    }
    if vk.CreateImageView(g.device, &imgViewInfo, nil, &gpuImage.imageView) != .SUCCESS {
        print("Error creating image view")
        return 0, GPUBuffer{}
    }

    // transition the image to transfer-DST
    transferBarrier := vk.ImageMemoryBarrier2{
        sType         = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = {},
        srcAccessMask = {},
        dstStageMask  = {.COPY},
        dstAccessMask = {.TRANSFER_WRITE},
        oldLayout     = .UNDEFINED,
        newLayout     = .TRANSFER_DST_OPTIMAL,
        image         = gpuImage.image,
        subresourceRange = {
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }
    transferDepInfo := vk.DependencyInfo{
        sType                    = .DEPENDENCY_INFO,
        imageMemoryBarrierCount  = 1,
        pImageMemoryBarriers     = &transferBarrier,
    }
    vk.CmdPipelineBarrier2(command_buffer, &transferDepInfo)

    // create staging buffer and issue record copy operation
    byteSize := int(width) * int(height) * channels
    stageBuff := createBuffer({.TRANSFER_SRC}, byteSize, true, .AUTO_PREFER_HOST)
    mapCopyBufferData(stageBuff, 0, image_data, byteSize)

    buffImgCopy := vk.BufferImageCopy{
        imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
        imageExtent      = {width, height, 1},
    }
    vk.CmdCopyBufferToImage(command_buffer, stageBuff.vkBuffer, gpuImage.image, .TRANSFER_DST_OPTIMAL, 1, &buffImgCopy)

    // transition image for shader read/sampling
    shaderReadBarrier := vk.ImageMemoryBarrier2{
        sType         = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = {.COPY},
        srcAccessMask = {.TRANSFER_WRITE},
        dstStageMask  = {.FRAGMENT_SHADER},
        dstAccessMask = {.SHADER_READ},
        oldLayout     = .TRANSFER_DST_OPTIMAL,
        newLayout     = .SHADER_READ_ONLY_OPTIMAL,
        image         = gpuImage.image,
        subresourceRange = {
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }
    shaderReadDepInfo := vk.DependencyInfo{
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers    = &shaderReadBarrier,
    }
    vk.CmdPipelineBarrier2(command_buffer, &shaderReadDepInfo)

    append(&g.images, gpuImage)
    imageId := u32(len(g.images))
    return imageId, stageBuff
}

startTransientCommandBuffer::proc()-> vk.CommandBuffer {
    cmdAllocInfo :vk.CommandBufferAllocateInfo = {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = g.commandPool,
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
        vk.FreeCommandBuffers(g.device,g.commandPool,1,&commandBuffer)
        return nil
    }
    return commandBuffer
}

submitTransientCommandBuffer :: proc(command_buffer: vk.CommandBuffer) {
    commandBuffer := command_buffer
    vk.EndCommandBuffer(commandBuffer)

    // TODO: Submit on a transfer queue
    submitInfo := vk.SubmitInfo{
        sType               = .SUBMIT_INFO,
        commandBufferCount  = 1,
        pCommandBuffers     = &commandBuffer,
    }

    vk.QueueSubmit(g.graphicsQueue, 1, &submitInfo, 0)
    vk.QueueWaitIdle(g.graphicsQueue)
    vk.FreeCommandBuffers(g.device, g.commandPool, 1, &commandBuffer)
}

loadImages :: proc(model: ^cgltf.data, image_dir: string) -> [dynamic]Image {
    images := make([dynamic]Image,len(model.images), context.temp_allocator)

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
    imageIds:= make([dynamic]u32,len(images), context.temp_allocator)

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
        else do imageIds[idx] = g.whitePixelImageId
    }

    submitTransientCommandBuffer(commandBuffer)

    for &buff in stagingBuffers{
        vma.DestroyBuffer(g.allocator,buff.vkBuffer,buff.allocation)
    }
    return imageIds
}

loadSamplers :: proc(model: ^cgltf.data) -> [dynamic]u32 {
	samplerIds:= make([dynamic]u32,len(model.samplers), context.temp_allocator)

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

		samplerInfo := vk.SamplerCreateInfo{
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
		if vk.CreateSampler(g.device, &samplerInfo, nil, &sampler) != .SUCCESS {
			print("Unable to create texture sampler, using fallback texture")
			samplerIds[i] = g.textures[0].samplerId
		} else {
			append(&g.samplers, sampler)
			samplerIds[i] = u32(len(g.samplers))
		}
	}
	return samplerIds
}

loadTextures :: proc(model: ^cgltf.data, image_ids: [dynamic]u32, sampler_ids: [dynamic]u32) -> [dynamic]u32 {
	assert(len(g.textures) + len(model.textures) <= MAX_TEXTURES, "Exceeding max texture count")

	textureIds := make([dynamic]u32,len(model.textures), context.temp_allocator)

	imagesBase   := raw_data(model.images)
	samplersBase := raw_data(model.samplers)

	for &tex, i in model.textures {
		image_id: u32 = g.whitePixelImageId
		if tex.image_ != nil {
			image_idx := int(uintptr(tex.image_) - uintptr(imagesBase)) / size_of(cgltf.image)
			image_id = image_ids[image_idx]
		}

		samplerId: u32 = 1 // your first-created (fallback/default) sampler, from loadData
		if tex.sampler != nil {
			sampler_idx := int(uintptr(tex.sampler) - uintptr(samplersBase)) / size_of(cgltf.sampler)
			samplerId = sampler_ids[sampler_idx]
		}

		append(&g.textures, Texture{imageId = image_id, samplerId = samplerId})
		textureIds[i] = u32(len(g.textures))
	}
	return textureIds
}

loadMaterials :: proc(model: ^cgltf.data, texture_ids: [dynamic]u32) -> [dynamic]u32 {
	materialIds := make([dynamic]u32,len(model.materials), context.temp_allocator)

	texturesBase := raw_data(model.textures)

	for &mat, i in model.materials {
		pbr := mat.pbr_metallic_roughness
		tex_index: u32 = 0
		if pbr.base_color_texture.texture != nil {
			idx := int(uintptr(pbr.base_color_texture.texture) - uintptr(texturesBase)) / size_of(cgltf.texture)
			tex_index = texture_ids[idx] - 1
		}

		append(&g.materials, Material{
			baseColor    = Vec4(pbr.base_color_factor),
			textureIndex = tex_index,
		})
		materialIds[i] = u32(len(g.materials))
	}
	return materialIds
}

loadMeshes :: proc(model: ^cgltf.data, material_ids: [dynamic]u32) -> [dynamic]u32 {
	meshIds := make([dynamic]u32,len(model.meshes), context.temp_allocator)
	materialsBase := raw_data(model.materials)

	for &gltfMesh, mi in model.meshes {
		mesh: Mesh
		mesh.name = gltfMesh.name != nil ? string(gltfMesh.name) : "No Name"
		mesh.subMeshes = make([dynamic]SubMesh, len(gltfMesh.primitives))

		for &prim, s in gltfMesh.primitives {
			mat_idx: int = -1
            if prim.material != nil {
                mat_idx = int(uintptr(prim.material) - uintptr(materialsBase)) / size_of(cgltf.material)
            }
            mesh.subMeshes[s].materialId = mat_idx >= 0 ? material_ids[mat_idx] : 0
			mesh.subMeshes[s].materialId = material_ids[mat_idx]
			mesh.subMeshes[s].vertexStart = g.vertOffset

			for &attr in prim.attributes {
				accessor := attr.data
				#partial switch attr.type {
				case .position:
					assert(accessor.type == .vec3 && accessor.component_type == .r_32f)
					assert(g.vertOffset + u64(accessor.count) <= u64(len(g.vertecies)), "Not enough space to load vertices")
					mesh.subMeshes[s].vertexCount = u64(accessor.count)
					for idx in 0 ..< accessor.count {
						out: [3]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 3)
						g.vertecies[g.vertOffset + u64(idx)].pos = Vec3(out)
					}
				case .normal:
					assert(accessor.type == .vec3 && accessor.component_type == .r_32f)
					for idx in 0 ..< accessor.count {
						out: [3]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 3)
						g.vertecies[g.vertOffset + u64(idx)].normal = Vec3(out)
					}
				case .color:
					assert((accessor.type == .vec3 || accessor.type == .vec4) && accessor.component_type == .r_32f)
					for idx in 0 ..< accessor.count {
						out: [3]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 3) // first 3 comps, even if source is vec4
						g.vertecies[g.vertOffset + u64(idx)].color = Vec3(out)
					}
				case .texcoord:
					assert(accessor.type == .vec2 && accessor.component_type == .r_32f)
					for idx in 0 ..< accessor.count {
						out: [2]f32
						num := cgltf.accessor_read_float(accessor, idx, &out[0], 2)
						g.vertecies[g.vertOffset + u64(idx)].uv = Vec2(out)
					}
				}
			}
			g.vertOffset += mesh.subMeshes[s].vertexCount

			if prim.indices != nil {
				accessor := prim.indices
				assert(g.idxOffset + u64(accessor.count) <= u64(len(g.indicies)), "Not enough space for indices")
				mesh.subMeshes[s].indexStart = g.idxOffset
				mesh.subMeshes[s].indexCount = u64(accessor.count)

				for idx in 0 ..< accessor.count {
					g.indicies[g.idxOffset + u64(idx)] = u32(cgltf.accessor_read_index(accessor, idx))
				}
				g.idxOffset += mesh.subMeshes[s].indexCount
			}
		}

		append(&g.meshes, mesh)
		meshIds[mi] = u32(len(g.meshes))
	}

    for &v in g.vertecies {v.color = Vec3{1, 1, 1}} //fix no material causing black rendering

	return meshIds
}

importNode :: proc(nw: ^NodeWorld, model: ^cgltf.data, gltf_node: ^cgltf.node, parent_id: u32, prev_sibling_id: u32, mesh_ids: [dynamic]u32) -> u32 {
	node, node_id := createNode(nw)
	node.parentId = parent_id

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
		node.meshId = mesh_ids[mesh_idx]
	}

	if prev_sibling_id != 0 {
		getNode(nw, prev_sibling_id).nextSiblingId = node_id
	}

	last_child_id: u32 = 0
	for child in gltf_node.children {
		last_child_id = importNode(nw, model, child, node_id, last_child_id, mesh_ids)
		if node.firstChildId == 0 {
			node.firstChildId = last_child_id
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
			node_id := importNode(&g.nodeWorld, model, gltf_node, 0, g.lastRootNodeId, meshIds)
			if g.rootNodeId == 0 { // first root node
				g.rootNodeId = node_id
			}
			g.lastRootNodeId = node_id
		}
	}

	cgltf.free(model)
	free_all(context.temp_allocator)
	fmt.println("GLTF Loading Successful\n")
	return true
}

updateTextureDescriptors :: proc() {
	// create combined image & sampler descriptor writes for all textures
	imageDescriptors := make([]vk.DescriptorImageInfo, len(g.textures), context.temp_allocator)
	for texture, i in g.textures {
		imageDescriptors[i] = vk.DescriptorImageInfo{
			sampler     = g.samplers[texture.samplerId - 1],
			imageView   = g.images[texture.imageId - 1].imageView,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
	}
	descSetWrite := vk.WriteDescriptorSet{
		sType            = .WRITE_DESCRIPTOR_SET,
		dstSet           = g.globalDescSet,
		dstBinding       = 0,
		dstArrayElement  = 0,
		descriptorCount  = u32(len(imageDescriptors)),
		descriptorType   = .COMBINED_IMAGE_SAMPLER,
		pImageInfo       = raw_data(imageDescriptors),
	}
	vk.UpdateDescriptorSets(g.device, 1, &descSetWrite, 0, nil)
}

loadData :: proc() -> bool {
	vertexBufferSizeInBytes := 64 * 1024 * 1024 // 64 MB
	indexBufferSizeInBytes := 32 * 1024 * 1024  // 32 MB
	totalVerts := vertexBufferSizeInBytes / size_of(Vertex)
	totalIndicies := indexBufferSizeInBytes / size_of(u32)
	resize(&g.vertecies, totalVerts)
	resize(&g.indicies, totalIndicies)

	whitePixelData: u32 = 0xFFFFFFFF
	whitePixel: Image = {
		width    = 1,
		height   = 1,
		channels = 4,
		data     = cast(^u8)(&whitePixelData),
	}

	whiteImgCmdBuff := startTransientCommandBuffer()
	whiteImageId, whiteStagingBuffer := createImage(whiteImgCmdBuff, whitePixel.data, u32(whitePixel.width), u32(whitePixel.height), 4)
	g.whitePixelImageId = whiteImageId
	submitTransientCommandBuffer(whiteImgCmdBuff)
	vma.DestroyBuffer(g.allocator, whiteStagingBuffer.vkBuffer, whiteStagingBuffer.allocation)

	samplerInfo: vk.SamplerCreateInfo = {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = .NEAREST,
		minFilter     = .NEAREST,
		addressModeU  = .REPEAT,
		addressModeV  = .REPEAT,
		addressModeW  = .REPEAT,
		compareEnable = false,
	}
	sampler: vk.Sampler
	if vk.CreateSampler(g.device, &samplerInfo, nil, &sampler) != .SUCCESS {
		print("Unable to create texture sampler")
		return false
	}
	append(&g.samplers, sampler)
	whiteSamplerId := u32(len(g.samplers))
	append(&g.textures, Texture{g.whitePixelImageId, whiteSamplerId})

	loadGltf("Sponza/Sponza.gltf")

	root := getNode(&g.nodeWorld, g.rootNodeId)
	setScale(root, Vec3{0.01, 0.01, 0.01})
	setTranslation(root, Vec3{0, -5, 0})

	vertexBufferStage := createBuffer({.TRANSFER_SRC}, vertexBufferSizeInBytes, true, .AUTO)
	if vertexBufferStage.vkBuffer == 0 {
		print("Error creating vertex staging buffer")
		return false
	}
	indexBufferStage := createBuffer({.TRANSFER_SRC}, indexBufferSizeInBytes, true, .AUTO)
	if indexBufferStage.vkBuffer == 0 {
		print("Error creating index staging buffer")
		return false
	}

	vertexBuffer := createBuffer({.TRANSFER_DST, .SHADER_DEVICE_ADDRESS}, vertexBufferSizeInBytes, false, .AUTO)
	if vertexBuffer.vkBuffer == 0 {
		print("Error creating vertex Buffer")
		return false
	}
	g.vertexBufferId = addBuffer(vertexBuffer)
	mapCopyBufferData(vertexBufferStage, 0, raw_data(g.vertecies), vertexBufferSizeInBytes)

	indexBuffer := createBuffer({.TRANSFER_DST, .INDEX_BUFFER}, indexBufferSizeInBytes, false, .AUTO)
	if indexBuffer.vkBuffer == 0 {
		print("Error creating index Buffer")
		return false
	}
	g.indexBufferId = addBuffer(indexBuffer)
	mapCopyBufferData(indexBufferStage, 0, raw_data(g.indicies), indexBufferSizeInBytes)

	// copy staged geo data to VRAM
	geoCmdBuffer := startTransientCommandBuffer()
	buffCopyVerts := vk.BufferCopy{srcOffset = 0, dstOffset = 0, size = vk.DeviceSize(vertexBufferSizeInBytes)}
	vk.CmdCopyBuffer(geoCmdBuffer, vertexBufferStage.vkBuffer, vertexBuffer.vkBuffer, 1, &buffCopyVerts)
	buffCopyIndices := vk.BufferCopy{srcOffset = 0, dstOffset = 0, size = vk.DeviceSize(indexBufferSizeInBytes)}
	vk.CmdCopyBuffer(geoCmdBuffer, indexBufferStage.vkBuffer, indexBuffer.vkBuffer, 1, &buffCopyIndices)
	submitTransientCommandBuffer(geoCmdBuffer)

	vma.DestroyBuffer(g.allocator, vertexBufferStage.vkBuffer, vertexBufferStage.allocation)
	vma.DestroyBuffer(g.allocator, indexBufferStage.vkBuffer, indexBufferStage.allocation)

	updateTextureDescriptors()

	// material buffer
	matDataBytes := len(g.materials) * size_of(Material)
	matBuffer := createBuffer({.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, matDataBytes, true, .AUTO)
	if matBuffer.vkBuffer == 0 {
		print("Error creating material buffer")
		return false
	}
	g.matBufferId = addBuffer(matBuffer)
	mapCopyBufferData(matBuffer, 0, raw_data(g.materials), matDataBytes)

	return true
}