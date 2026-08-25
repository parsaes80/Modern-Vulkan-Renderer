package main

import vk "vendor:vulkan"
import "core:math"
import la "core:math/linalg"


make_camera :: proc() -> Camera {
	cam := Camera{
		pos   = {0, 0, 3},
		up    = {0, 1, 0},
		yaw   = -90,
		pitch = 0,
		fov   = 45,
	}
	update_camera_vectors(&cam)
	return cam
}

make_mouse :: proc() -> Mouse {
	return Mouse{sensitivity = 0.1, first_move = true}
}

update_camera_vectors :: proc(cam: ^Camera) {
	yaw_r := math.to_radians(cam.yaw)
	pitch_r := math.to_radians(cam.pitch)
	front := Vec3{
		math.cos(yaw_r) * math.cos(pitch_r),
		math.sin(pitch_r),
		math.sin(yaw_r) * math.cos(pitch_r),
	}
	cam.front = la.normalize(front)
}

process_mouse_movement :: proc(cam: ^Camera, mouse: ^Mouse, xrel, yrel: f32) {
	cam.yaw += xrel * mouse.sensitivity
	cam.pitch -= yrel * mouse.sensitivity // subtract: SDL's +y is downward on screen
	cam.pitch = clamp(cam.pitch, -89, 89)
	update_camera_vectors(cam)
}

process_mouse_scroll :: proc(cam: ^Camera, yoffset: f32) {
	cam.fov -= yoffset
	cam.fov = clamp(cam.fov, 1, 90)
}
render :: proc() {
	// first check if our swapchain is still valid
	if g.requireSwapchainRecreate {
		vk.DeviceWaitIdle(g.device)
		destroySwapchain()
		createSwapchain(g.width, g.height)
		g.requireSwapchainRecreate = false
	}

	frameResIndex := u32(g.frameIndex) % MAX_FRAMES_IN_FLIGHT
	g.frameIndex += 1
	signalValue := g.nextSignalValue
	g.nextSignalValue += 1
	waitValue := signalValue - MAX_FRAMES_IN_FLIGHT

	waitInfo: vk.SemaphoreWaitInfo = {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &g.timelineSemaphore,
		pValues        = &waitValue,
	}
	vk.WaitSemaphores(g.device, &waitInfo, max(u64))

	// now its safe to start recording commands
	res := &g.frameResources[frameResIndex]
	vk.ResetCommandPool(g.device, res.commandPool, {})

	// get the resources for this frame
	imageAcquireSemaphore := res.imageAcquiredSemaphore

	imageIndex: u32 = 0
	acquireResult := vk.AcquireNextImageKHR(g.device, g.swapchain, max(u64), imageAcquireSemaphore, 0, &imageIndex)

	// handle resize and out-of-date images, may need swapchain recreate
	if acquireResult == .ERROR_OUT_OF_DATE_KHR {
		g.requireSwapchainRecreate = true
		return
	} else if acquireResult == .SUBOPTIMAL_KHR {
		// can render this frame, recreate next time around
		g.requireSwapchainRecreate = true
	}

	// traverse entire scene and record MDI draw commands
	viewMatrix := la.matrix4_look_at_f32(g.camera.pos, g.camera.pos + g.camera.front, g.camera.up)
	aspectRatio := f32(g.width) / f32(g.height)
	projMatrix := la.matrix4_perspective_f32(math.to_radians_f32(g.camera.fov), aspectRatio, 0.01, 1000)
	viewProjMatrix := projMatrix * viewMatrix

	// push root nodes to render-stack
	clear(&g.nodeRenderStack)
	nodeId := g.rootNodeId
	for nodeId != 0 {
		node := getNode(&g.nodeWorld, nodeId)
		append(&g.nodeRenderStack, RenderStackLayer{nodePtr = node, mat = la.MATRIX4F32_IDENTITY})
		nodeId = node.nextSiblingId
	}

	drawIndex: u32 = 0
	for len(g.nodeRenderStack) > 0 {
		layer := pop(&g.nodeRenderStack)
		node := layer.nodePtr
		matWorld := layer.mat * getTransform(node)

		// draw the associated mesh
		if node.meshId != 0 {
			mesh := &g.meshes[node.meshId - 1]
			for &subMesh in mesh.subMeshes {
				// indirect draw command
				res.indirectDrawPtr[drawIndex] = vk.DrawIndexedIndirectCommand{
					indexCount    = u32(subMesh.indexCount),
					instanceCount = 1,
					firstIndex    = u32(subMesh.indexStart),
					vertexOffset  = i32(subMesh.vertexStart),
					firstInstance = drawIndex,
				}
				// per render-item data
				res.renderItemPtr[drawIndex] = RenderItem{
					wvp            = viewProjMatrix * matWorld,
					worldMatrix    = matWorld,
					materialIndex  = subMesh.materialId - 1,
				}
				drawIndex += 1
			}
		}

		// child nodes for processing
		childNodeId := node.firstChildId
		for childNodeId != 0 {
			child := getNode(&g.nodeWorld, childNodeId)
			append(&g.nodeRenderStack, RenderStackLayer{nodePtr = child, mat = matWorld})
			childNodeId = child.nextSiblingId
		}
	}

	// begin recording commands
	cmdBeginInfo := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(res.commandBuffer, &cmdBeginInfo)

	// transition the color and depth images
	layoutBarriers: [2]vk.ImageMemoryBarrier2 = {
		{
			sType         = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
			oldLayout     = .UNDEFINED,
			newLayout     = .COLOR_ATTACHMENT_OPTIMAL,
			image         = g.swapchainImages[imageIndex],
			subresourceRange = {
				aspectMask     = {.COLOR},
				baseMipLevel   = 0,
				levelCount     = 1,
				baseArrayLayer = 0,
				layerCount     = 1,
			},
		},
		{
			sType         = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask  = {.EARLY_FRAGMENT_TESTS},
			srcAccessMask = {},
			dstStageMask  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			oldLayout     = .UNDEFINED,
			newLayout     = .DEPTH_ATTACHMENT_OPTIMAL,
			image         = g.depthImage,
			subresourceRange = {
				aspectMask     = {.DEPTH},
				baseMipLevel   = 0,
				levelCount     = 1,
				baseArrayLayer = 0,
				layerCount     = 1,
			},
		},
	}
	depInfo: vk.DependencyInfo = {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = u32(len(layoutBarriers)),
		pImageMemoryBarriers    = raw_data(layoutBarriers[:]),
	}
	vk.CmdPipelineBarrier2(res.commandBuffer, &depInfo)

	// setup the attachments (color and depth) and begin rendering (dynamic)
	colorAttachInfo: vk.RenderingAttachmentInfo = {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = g.swapchainViews[imageIndex],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = {color = {float32 = {0.3, 0.3, 1, 1}}},
	}
	depthAttachInfo: vk.RenderingAttachmentInfo = {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = g.depthImageView,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .DONT_CARE,
		clearValue  = {depthStencil = {depth = 1.0, stencil = 0}},
	}
	renderingInfo: vk.RenderingInfo = {
		sType = .RENDERING_INFO,
		renderArea = {
			offset = {x = 0, y = 0},
			extent = {width = g.swapchainWidth, height = g.swapchainHeight},
		},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &colorAttachInfo,
		pDepthAttachment     = &depthAttachInfo,
	}

	// setup frame data
	vk.CmdBindDescriptorSets(res.commandBuffer, .GRAPHICS, g.pipelineLayout, 0, 1, &g.globalDescSet, 0, nil)

	frameConsts: FrameConstants
	vertBuffer := &g.buffers[g.vertexBufferId - 1]
	materialBuffer := &g.buffers[g.matBufferId - 1]
	frameConsts.vertexBufferAddress = cast(u64)vertBuffer.deviceAddress
	frameConsts.materialBufferAddress = cast(u64)materialBuffer.deviceAddress
	frameConsts.renderItemsAddress = cast(u64)res.renderItemBuffer.deviceAddress
	vk.CmdPushConstants(res.commandBuffer, g.pipelineLayout, {.VERTEX, .FRAGMENT}, 0, size_of(FrameConstants), &frameConsts)

	idxBuffer := &g.buffers[g.indexBufferId - 1]
	vk.CmdBindIndexBuffer(res.commandBuffer, idxBuffer.vkBuffer, 0, .UINT32)

	// begin dynamic rendering
	vk.CmdBeginRendering(res.commandBuffer, &renderingInfo)
	{
		// set the viewport and scissor state -- negative height flips Y to match glTF/GLM's convention
		viewport: vk.Viewport = {
			x        = 0,
			y        = f32(g.swapchainHeight),
			width    = f32(g.swapchainWidth),
			height   = -f32(g.swapchainHeight),
			minDepth = 0,
			maxDepth = 1,
		}
		vk.CmdSetViewport(res.commandBuffer, 0, 1, &viewport)

		scissor: vk.Rect2D = {
			offset = {x = 0, y = 0},
			extent = {width = g.swapchainWidth, height = g.swapchainHeight},
		}
		vk.CmdSetScissor(res.commandBuffer, 0, 1, &scissor)

		vk.CmdBindPipeline(res.commandBuffer, .GRAPHICS, g.pipeline)
		vk.CmdDrawIndexedIndirect(res.commandBuffer, res.indirectDrawBuffer.vkBuffer, 0, drawIndex, size_of(vk.DrawIndexedIndirectCommand))
	}
	// end dynamic rendering
	vk.CmdEndRendering(res.commandBuffer)

	// transition the image from color attachment to presentation so we can show it
	presentLayoutBarrier: vk.ImageMemoryBarrier2 = {
		sType         = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask  = {},
		dstAccessMask = {},
		oldLayout     = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout     = .PRESENT_SRC_KHR,
		image         = g.swapchainImages[imageIndex],
		subresourceRange = {
			aspectMask     = {.COLOR},
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}
	presentDepInfo: vk.DependencyInfo = {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &presentLayoutBarrier,
	}
	vk.CmdPipelineBarrier2(res.commandBuffer, &presentDepInfo)

	vk.EndCommandBuffer(res.commandBuffer)

	// ensure swapchain image is actually available to start color output
	imageAcquireWaitInfo: vk.SemaphoreSubmitInfo = {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = imageAcquireSemaphore,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	semaphoreSignals: [2]vk.SemaphoreSubmitInfo = {
		{
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = g.renderCompleteSemaphores[imageIndex],
			stageMask = {.ALL_GRAPHICS},
		},
		{
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = g.timelineSemaphore,
			value     = signalValue,
			stageMask = {.ALL_COMMANDS},
		},
	}
	cmdSubmitInfo: vk.CommandBufferSubmitInfo = {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = res.commandBuffer,
	}
	submitInfo: vk.SubmitInfo2 = {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &imageAcquireWaitInfo,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmdSubmitInfo,
		signalSemaphoreInfoCount = u32(len(semaphoreSignals)),
		pSignalSemaphoreInfos    = raw_data(semaphoreSignals[:]),
	}
	vk.QueueSubmit2(g.graphicsQueue, 1, &submitInfo, 0)

	// present the image
	presentInfo: vk.PresentInfoKHR = {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &g.renderCompleteSemaphores[imageIndex],
		swapchainCount     = 1,
		pSwapchains        = &g.swapchain,
		pImageIndices      = &imageIndex,
		pResults           = nil,
	}

	vk.QueuePresentKHR(g.graphicsQueue, &presentInfo)
}