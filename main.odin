#+feature dynamic-literals
package main

import "core:strings"
import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "core:log"
import "base:runtime"
import "core:fmt"

render :: proc() {
    // first check if our swapchain is still valid
    if g.require_swapchain_recreate {
        vk.DeviceWaitIdle(g.device)
        destroySwapchain()
        createSwapchain(g.width, g.height)
        g.require_swapchain_recreate = false
    }

    frameResIndex := u32(g.frame_index) % MAX_FRAMES_IN_FLIGHT
    g.frame_index += 1
    signalValue := g.next_signal_value
    g.next_signal_value += 1
    waitValue := signalValue - MAX_FRAMES_IN_FLIGHT

    waitInfo : vk.SemaphoreWaitInfo = {
        sType          = .SEMAPHORE_WAIT_INFO,
        semaphoreCount = 1,
        pSemaphores    = &g.timeline_semaphore,
        pValues        = &waitValue,
    }
    vk.WaitSemaphores(g.device, &waitInfo, max(u64))

    // now its safe to start recording commands
    res := &g.frame_resources[frameResIndex]
    vk.ResetCommandPool(g.device, res.command_pool, {})

    // get the resources for this frame
    imageAcquireSemaphore := res.image_acquired_semaphore

    imageIndex: u32 = 0
    acquireResult := vk.AcquireNextImageKHR(g.device, g.swapchain, max(u64), imageAcquireSemaphore, 0, &imageIndex)

    // handle resize and out-of-date images, may need swapchain recreate
    if acquireResult == .ERROR_OUT_OF_DATE_KHR {
        g.require_swapchain_recreate = true
        return
    } else if acquireResult == .SUBOPTIMAL_KHR {
        // can render this frame, recreate next time around
        g.require_swapchain_recreate = true
    }

    // begin recording commands
    cmdBeginInfo := vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }
    vk.BeginCommandBuffer(res.command_buffer, &cmdBeginInfo)

    // transition the color and depth images
    layoutBarriers : [2]vk.ImageMemoryBarrier2 =
    {
        {
            sType         = .IMAGE_MEMORY_BARRIER_2,
            srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
            srcAccessMask = {},
            dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
            dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
            oldLayout     = .UNDEFINED,
            newLayout     = .COLOR_ATTACHMENT_OPTIMAL,
            image         = g.swapchain_images[imageIndex],
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
            dstStageMask  = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}, // both specified to control memory access at both stages (write)
            dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
            oldLayout     = .UNDEFINED,
            newLayout     = .DEPTH_ATTACHMENT_OPTIMAL,
            image         = g.depth_image,
            subresourceRange = {
                aspectMask     = {.DEPTH},
                baseMipLevel   = 0,
                levelCount     = 1,
                baseArrayLayer = 0,
                layerCount     = 1,
            },
        },
    }
    depInfo : vk.DependencyInfo = {
        sType                    = .DEPENDENCY_INFO,
        imageMemoryBarrierCount  = u32(len(layoutBarriers)),
        pImageMemoryBarriers     = raw_data(layoutBarriers[:]),
    }
    vk.CmdPipelineBarrier2(res.command_buffer, &depInfo)

    // setup the attachments (color and depth) and begin rendering (dynamic)
    colorAttachInfo : vk.RenderingAttachmentInfo = {
        sType       = .RENDERING_ATTACHMENT_INFO,
        imageView   = g.swapchain_views[imageIndex],
        imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
        loadOp      = .CLEAR, // clear the image
        storeOp     = .STORE, // keep data for presentation
        clearValue  = {color = {float32 = {0.01, 0.01, 0.01, 1}}},
    }
    depthAttachInfo : vk.RenderingAttachmentInfo = {
        sType       = .RENDERING_ATTACHMENT_INFO,
        imageView   = g.depth_image_view,
        imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
        loadOp      = .CLEAR,      // clear the depth data
        storeOp     = .DONT_CARE,  // don't care after rendering
        clearValue  = {depthStencil = {depth = 1.0, stencil = 0}},
    }
    renderingInfo : vk.RenderingInfo = {
        sType = .RENDERING_INFO,
        renderArea = {
            offset = {x = 0, y = 0},
            extent = {width = g.swapchain_width, height = g.swapchain_height},
        },
        layerCount           = 1,
        colorAttachmentCount = 1,
        pColorAttachments    = &colorAttachInfo,
        pDepthAttachment     = &depthAttachInfo,
    }

    // begin dynamic rendering
    vk.CmdBeginRendering(res.command_buffer, &renderingInfo)

    {
        // set the viewport and scissor state
        viewport : vk.Viewport = {
            x      = 0,
            y      = 0,
            width  = f32(g.swapchain_width),
            height = f32(g.swapchain_height),
        }
        vk.CmdSetViewport(res.command_buffer, 0, 1, &viewport)

        scissor : vk.Rect2D = {
            offset = {x = 0, y = 0},
            extent = {width = g.swapchain_width, height = g.swapchain_height},
        }
        vk.CmdSetScissor(res.command_buffer, 0, 1, &scissor)

        // draw our triangle
        vk.CmdBindPipeline(res.command_buffer, .GRAPHICS, g.pipeline)
        vk.CmdDraw(res.command_buffer, 3, 1, 0, 0)
    }
    // end dynamic rendering
    vk.CmdEndRendering(res.command_buffer)

    // transition the image from color attachment to presentation so we can show it
    presentLayoutBarrier : vk.ImageMemoryBarrier2 = {
        sType         = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
        srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
        dstStageMask  = {}, // nothing is waiting, but the cache is flushed and layout is transitioned
        dstAccessMask = {},
        oldLayout     = .COLOR_ATTACHMENT_OPTIMAL,
        newLayout     = .PRESENT_SRC_KHR,
        image         = g.swapchain_images[imageIndex],
        subresourceRange = {
            aspectMask     = {.COLOR},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }
    presentDepInfo : vk.DependencyInfo = {
        sType                   = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers    = &presentLayoutBarrier,
    }
    vk.CmdPipelineBarrier2(res.command_buffer, &presentDepInfo)

    vk.EndCommandBuffer(res.command_buffer)

    // ensure swapchain image is actually available to start color output
    imageAcquireWaitInfo : vk.SemaphoreSubmitInfo = {
        sType     = .SEMAPHORE_SUBMIT_INFO,
        semaphore = imageAcquireSemaphore,
        stageMask = {.COLOR_ATTACHMENT_OUTPUT}, // wait before drawing to image
    }
    // signal that the image can be presented
    semaphoreSignals : [2]vk.SemaphoreSubmitInfo = {
        { // render work completion signal
            sType     = .SEMAPHORE_SUBMIT_INFO,
            semaphore = g.render_complete_semaphores[imageIndex],
            stageMask = {.ALL_GRAPHICS},
        },
        { // entire frame is completed (timeline)
            sType     = .SEMAPHORE_SUBMIT_INFO,
            semaphore = g.timeline_semaphore,
            value     = signalValue,
            stageMask = {.ALL_COMMANDS},
        },
    }
    cmdSubmitInfo : vk.CommandBufferSubmitInfo = {
        sType         = .COMMAND_BUFFER_SUBMIT_INFO,
        commandBuffer = res.command_buffer,
    }
    submitInfo : vk.SubmitInfo2 = {
        sType                     = .SUBMIT_INFO_2,
        waitSemaphoreInfoCount    = 1,
        pWaitSemaphoreInfos       = &imageAcquireWaitInfo, // ensure the image is ready
        commandBufferInfoCount    = 1,
        pCommandBufferInfos       = &cmdSubmitInfo,
        signalSemaphoreInfoCount  = u32(len(semaphoreSignals)),
        pSignalSemaphoreInfos     = raw_data(semaphoreSignals[:]),
    }
    vk.QueueSubmit2(g.graphics_queue, 1, &submitInfo, 0)

    // present the image
    presentInfo : vk.PresentInfoKHR = {
        sType              = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &g.render_complete_semaphores[imageIndex], // render work completed semaphore
        swapchainCount     = 1,
        pSwapchains        = &g.swapchain,
        pImageIndices      = &imageIndex,
        pResults           = nil,
    }

    vk.QueuePresentKHR(g.graphics_queue, &presentInfo)
}

main :: proc() {
    context.logger = log.create_console_logger()

    g.swapchain_format.format = .B8G8R8A8_SRGB
    g.swapchain_format.colorSpace = .SRGB_NONLINEAR
    
    //uncomment for HDR triangle if supported by monitor
    //g.swapchain_format.format = .A2B10G10R10_UNORM_PACK32
    //g.swapchain_format.colorSpace = .HDR10_ST2084_EXT

    g.depth_format = .D32_SFLOAT
    g.running = true
    g.width = 1080
    g.height = 1080
    g.next_signal_value = MAX_FRAMES_IN_FLIGHT + 1

    g.ctx = context
    res := sdl.Init({.VIDEO}); assert(res, "init failed")
    g.window = sdl.CreateWindow("vk", i32(g.width), i32(g.height), {.VULKAN, .RESIZABLE}); assert(g.window != nil)

    initializeVulkan()

    t_last: u64 = sdl.GetTicksNS()

    event: sdl.Event
    for g.running {
        for sdl.PollEvent(&event) {
            if event.type == sdl.EventType.QUIT {
                g.running = false
            } else if event.type == .WINDOW_RESIZED {
                g.width = u32(event.window.data1)
                g.height = u32(event.window.data2)
                g.require_swapchain_recreate = true
            }
        }

        t_now := sdl.GetTicksNS()
        dt := t_now - t_last
        t_last = t_now

        fps := 1e9 / f64(dt)

        //uncomment to print framerate for higher fps remove VK_LAYER_KHRONOS_validation
        //fmt.printf("dt: %d ns | fps: %.1f\n", dt, fps)

        render()
    }

    shutdown()
}
