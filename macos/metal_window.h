#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Create a Metal window (borderless or normal)
/// Returns an opaque pointer to the NSWindow
void* metal_window_create(int32_t width, int32_t height, bool borderless);

/// Get the CAMetalLayer from the window
/// Returns an opaque pointer to CAMetalLayer
void* metal_window_get_layer(void* window);

/// Get the MTLDevice from the window
/// Returns an opaque pointer to MTLDevice
void* metal_window_get_device(void* window);

/// Show the window
void metal_window_show(void* window);

/// Initialize NSApplication without running main loop
void metal_window_init_app(void);

/// Run the NSApplication main loop
void metal_window_run_app(void);

/// Check if the window is still running
bool metal_window_is_running(void* window);

/// Get next drawable from CAMetalLayer
void* metal_layer_get_next_drawable(void* layer);

/// Get texture from drawable
void* metal_drawable_get_texture(void* drawable);

/// Present drawable
void metal_drawable_present(void* drawable);

/// Process window events
void metal_window_process_events(void* window);

/// Release the window
void metal_window_release(void* window);

/// Get current mouse state
void metal_window_get_mouse_state(void* window, float* out_x, float* out_y, bool* out_down);

#ifdef __cplusplus
}
#endif
