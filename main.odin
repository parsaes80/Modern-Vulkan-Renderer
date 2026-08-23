package main

import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "core:log"
import "base:runtime"
import "core:fmt"
import "core:mem"

main :: proc() {
    
    // track: mem.Tracking_Allocator
    // mem.tracking_allocator_init(&track, context.allocator)
    // context.allocator = mem.tracking_allocator(&track)  
    // defer {
    //     if len(track.allocation_map) > 0 {
    //         fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
    //         for _, entry in track.allocation_map {
    //             fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
    //         }
    //     }
    //     if len(track.bad_free_array) > 0 {
    //         fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
    //         for entry in track.bad_free_array {
    //             fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
    //         }
    //     }
    //     mem.tracking_allocator_destroy(&track)
    // }

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

    nodeWorldInit(&g.node_world,2048)
    reserve(&g.node_render_stack,256)

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

        keys := sdl.GetKeyboardState(nil)
        if keys[sdl.Scancode.ESCAPE] do g.running = false

        t_now := sdl.GetTicksNS()
        dt := t_now - t_last
        t_last = t_now
        fps := 1e9 / f64(dt)

        //uncomment to print framerate, for higher fps remove VK_LAYER_KHRONOS_validation
        //print(" fps: %.1f\n", fps)

        render()
    }

    shutdown()
}
