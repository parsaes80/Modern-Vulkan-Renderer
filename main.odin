package main

import vk "vendor:vulkan"
import sdl "vendor:sdl3"
import "base:runtime"
import "core:fmt"

import la "core:math/linalg"


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

    g.swapchainFormat.format = .B8G8R8A8_SRGB
    g.swapchainFormat.colorSpace = .SRGB_NONLINEAR
    
    //uncomment for HDR if supported by monitor
    //g.swapchainFormat.format = .A2B10G10R10_UNORM_PACK32
    //g.swapchainFormat.colorSpace = .HDR10_ST2084_EXT

    g.depthFormat = .D32_SFLOAT
    g.running = true
    g.width = 1920
    g.height = 1080
    g.nextSignalValue = MAX_FRAMES_IN_FLIGHT + 1


	nodeWorldInit(&g.nodeWorld, 2048)
	reserve(&g.nodeRenderStack, 256)

	g.camera = make_camera()
	g.mouse = make_mouse()

	g.ctx = context
	res := sdl.Init({.VIDEO}); assert(res, "init failed")
	g.window = sdl.CreateWindow("vk", i32(g.width), i32(g.height), {.VULKAN, .RESIZABLE}); assert(g.window != nil)
	res = sdl.SetWindowRelativeMouseMode(g.window, true) // locks + hides cursor, enables relative motion

	initializeVulkan()
	loadData()

	event: sdl.Event
	for g.running {
        for sdl.PollEvent(&event) {
            #partial switch event.type {
            case .QUIT: g.running = false
            case .WINDOW_RESIZED:
                g.width = u32(event.window.data1)
                g.height = u32(event.window.data2)
                g.requireSwapchainRecreate = true
            case .MOUSE_WHEEL:
                process_mouse_scroll(&g.camera, event.wheel.y)
            }
        }

		t := sdl.GetTicksNS()
		g.dt = t - g.t0
		g.t0 = t
		//fmt.printfln("Fps: %v ,Time: %vns",g.dt, 1e9/g.dt)

		xrel, yrel: f32
		flags := sdl.GetRelativeMouseState(&xrel, &yrel)
		process_mouse_movement(&g.camera, &g.mouse, xrel, yrel)

		keys := sdl.GetKeyboardState(nil)
		if keys[sdl.Scancode.ESCAPE] do g.running = false

		dt_sec := f32(g.dt) / 1e9
		camera_speed := 5 * dt_sec
		if keys[sdl.Scancode.W] do g.camera.pos += camera_speed * g.camera.front
		if keys[sdl.Scancode.S] do g.camera.pos -= camera_speed * g.camera.front
		if keys[sdl.Scancode.A] do g.camera.pos -= la.normalize(la.cross(g.camera.front, g.camera.up)) * camera_speed
		if keys[sdl.Scancode.D] do g.camera.pos += la.normalize(la.cross(g.camera.front, g.camera.up)) * camera_speed
        
		render()
	}

	shutdown()
}