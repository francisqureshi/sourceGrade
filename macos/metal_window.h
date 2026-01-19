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

/// Release drawable (balance passRetained from get_next_drawable)
void metal_drawable_release(void* drawable);

/// Release texture (balance passRetained from get_texture)
void metal_texture_release(void* texture);

/// Process window events
void metal_window_process_events(void* window);

/// Release the window
void metal_window_release(void* window);

/// Get current mouse state
void metal_window_get_mouse_state(void* window, float* out_x, float* out_y, bool* out_down);

/// Set the pixel format for the CAMetalLayer
void metal_layer_set_pixel_format(void* layer, uint32_t pixel_format);

/// Get the backing scale factor (1.0 for non-Retina, 2.0 for Retina, etc.)
double metal_window_get_backing_scale(void* window);

/// CVDisplayLink functions for vsync
/// Runs on separate thread, independent of runloop
/// Callback signature: void (*callback)(void* userdata)
void* metal_displaylink_create(void* window);
void metal_displaylink_set_callback(void* displaylink, void (*callback)(void*), void* userdata);
void metal_displaylink_start(void* displaylink);
void metal_displaylink_stop(void* displaylink);
void metal_displaylink_release(void* displaylink);

/// ProRes video reader functions
/// Create a video reader for the given file path
void* video_reader_create(const char* filepath, void* metal_device);

/// Get next frame as Metal texture (returns null at end of file)
void* video_reader_get_next_frame(void* reader);

/// Restart reading from the beginning
void video_reader_restart(void* reader);

/// Get video properties
void video_reader_get_info(void* reader, int32_t* out_width, int32_t* out_height,
                          double* out_duration, double* out_framerate);

/// Release resources
void video_reader_release(void* reader);
void video_texture_release(void* texture);

#ifdef __cplusplus
}
#endif
