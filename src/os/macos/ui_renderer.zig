const std = @import("std");
const ui = @import("../../gui/ui.zig");
const metal = @import("metal");

/// Ring buffer configuration
/// Triple-buffering prevents CPU/GPU sync stall
const FRAMES_IN_FLIGHT = 3;
const MAX_VERTICES = 65536; // 64K vertices per frame
const MAX_INDICES = 131072; // 128K indices per frame (2x vertices for typical UI)

pub const ImGuiRenderer = struct {
    vertex_buffers: [FRAMES_IN_FLIGHT]metal.MetalBuffer,
    index_buffers: [FRAMES_IN_FLIGHT]metal.MetalBuffer,
    atlas_texture: metal.MetalTexture,
    atlas_size: u32,
    atlas_modified: usize,
    current_frame: usize,
    device: *metal.MetalDevice,

    pub fn init(device: *metal.MetalDevice, atlas_size: u32) !ImGuiRenderer {

        // Create atlas texture (grayscale R8)
        var atlas_texture = try device.createTextureWithFormat(atlas_size, atlas_size, .r8_unorm, false);
        errdefer atlas_texture.deinit();

        var ui_rndr = ImGuiRenderer{
            .vertex_buffers = undefined,
            .index_buffers = undefined,
            .atlas_texture = atlas_texture,
            .atlas_size = atlas_size,
            .atlas_modified = 0,
            .current_frame = 0,
            .device = device,
        };

        // Create triple-buffered GPU buffers
        const vertex_buffer_size = MAX_VERTICES * @sizeOf(ui.ImVertex);
        const index_buffer_size = MAX_INDICES * @sizeOf(u16);

        for (0..FRAMES_IN_FLIGHT) |i| {
            ui_rndr.vertex_buffers[i] = try device.createBuffer(@intCast(vertex_buffer_size));
            ui_rndr.index_buffers[i] = try device.createBuffer(@intCast(index_buffer_size));
        }

        return ui_rndr;
    }

    pub fn upload(self: *ImGuiRenderer, ctx: *ui.ImGui) void {

        // Did atlas GROW? (need new texture)
        if (ctx.atlas.size != self.atlas_size) {
            self.atlas_texture.deinit();
            self.atlas_texture = self.device.createTextureWithFormat(ctx.atlas.size, ctx.atlas.size, .r8_unorm, false) catch return;
            self.atlas_size = ctx.atlas.size;
            // Force re-upload of content since we have a new texture
            self.atlas_modified = 0;
        }

        // Upload atlas texture if modified
        const atlas_modified = ctx.atlas.modified.load(.monotonic);
        if (atlas_modified != self.atlas_modified) {
            self.atlas_texture.upload(
                ctx.atlas.data,
                ctx.atlas.size,
                ctx.atlas.size,
                ctx.atlas.size, // bytes per row for grayscale
            );
            self.atlas_modified = atlas_modified;
        }

        // Get current frame's buffers from ring
        var vb = &self.vertex_buffers[self.current_frame];
        var ib = &self.index_buffers[self.current_frame];

        // Upload CPU data to GPU
        const vertex_bytes = std.mem.sliceAsBytes(ctx.vertices.items);
        const index_bytes = std.mem.sliceAsBytes(ctx.indices.items);

        vb.upload(vertex_bytes);
        ib.upload(index_bytes);

        // Advance to next frame buffer
        self.current_frame = (self.current_frame + 1) % FRAMES_IN_FLIGHT;
    }

    /// Get the vertex buffer for the previous frame
    pub fn getVertexBuffer(self: *ImGuiRenderer) *metal.MetalBuffer {
        const prev_frame = (self.current_frame + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT;
        return &self.vertex_buffers[prev_frame];
    }

    /// Get the index buffer for the previous frame
    pub fn getIndexBuffer(self: *ImGuiRenderer) *metal.MetalBuffer {
        const prev_frame = (self.current_frame + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT;
        return &self.index_buffers[prev_frame];
    }

    pub fn deinit(self: *ImGuiRenderer) void {
        self.atlas_texture.deinit();

        for (0..FRAMES_IN_FLIGHT) |i| {
            self.vertex_buffers[i].deinit();
            self.index_buffers[i].deinit();
        }
    }
};
