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

/// Run the NSApplication main loop
void metal_window_run_app(void);

/// Release the window
void metal_window_release(void* window);

#ifdef __cplusplus
}
#endif
