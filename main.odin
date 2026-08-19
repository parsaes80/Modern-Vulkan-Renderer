package main

import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "core:log"
import "base:runtime"
import "core:fmt"


main :: proc() {
    context.logger = log.create_console_logger()

    g.swapchain_format.format = .B8G8R8A8_SRGB
    g.swapchain_format.colorSpace = .SRGB_NONLINEAR
    
    //uncomment for HDR triangle if supported by monitor
    g.swapchain_format.format = .A2B10G10R10_UNORM_PACK32
    g.swapchain_format.colorSpace = .HDR10_ST2084_EXT

    g.depth_format = .D32_SFLOAT
    g.running = true
    g.width = 1080
    g.height = 1080
    g.next_signal_value = MAX_FRAMES_IN_FLIGHT + 1

    g.ctx = context
    res := sdl.Init({.VIDEO}); assert(res, "init failed")
    g.window = sdl.CreateWindow("vk", i32(g.width), i32(g.height), {.VULKAN, .RESIZABLE}); assert(g.window != nil)

    initializeVulkan()
    loadData()
    
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

        //uncomment to print framerate, for higher fps remove VK_LAYER_KHRONOS_validation
        //fmt.printf("dt: %d ns | fps: %.1f\n", dt, fps)

        render()
    }

    shutdown()
}
