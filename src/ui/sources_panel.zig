const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui.zig");
const layout = @import("layout.zig");
const Core = @import("../core.zig").Core;
const Session = @import("../playback/session.zig").Session;
const SourceMedia = @import("../io/media/media.zig").SourceMedia;
const Viewer = @import("viewer.zig").Viewer;

pub fn draw(
    imgui: *ui.ImGui,
    rect: *layout.Rect,
    core: *Core,
    current_source: *SourceMedia,
    source_viewer: *Viewer,
    allocator: Allocator,
    io: Io,
) !void {
    const transparent = ui.ImGui.packColor(0, 0, 0, 0);

    var vstack = layout.VStack.init(rect.x, rect.y, rect.w, rect.h, 0);
    const titlebar = vstack.add(.{ .fill = 1.0 }, .{ .pixels = 20 }, 1.0);
    const pane = vstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 1.0);
    vstack.solve();

    try imgui.textLabel(
        titlebar.x,
        titlebar.y,
        titlebar.w,
        titlebar.h,
        "Sources",
        transparent,
        .{ 255, 255, 255, 255 },
        .left,
    );

    const row_height: f32 = 24.0;
    const source_keys = core.sources.map.keys();
    const source_values = core.sources.map.values();

    const dummy_count = 38;
    const row_count = dummy_count + source_keys.len;
    const content_height: f32 = @as(f32, @floatFromInt(row_count)) * row_height;

    const scroll_y = try imgui.beginScrollView(
        1,
        pane.x,
        pane.y,
        pane.w,
        pane.h,
        content_height,
    );

    for (source_keys, source_values, 0..) |uuid, sm, i| {
        const y_offset = pane.y + @as(f32, @floatFromInt(i)) * row_height - scroll_y;
        const is_selected = current_source == sm;
        const button_id: u32 = 1000 + @as(u32, @intCast(i));

        if (is_selected) {
            try imgui.addRect(pane.x, y_offset, pane.w, row_height, ui.ImGui.packColor(0.3, 0.3, 0.5, 1.0));
        }

        if (try imgui.textButton(button_id, pane.x, y_offset, pane.w, row_height, sm.file_name)) {
            if (core.sessions.get(uuid)) |existing| {
                source_viewer.session = existing;
            } else {
                const new_session = try allocator.create(Session);
                new_session.* = .{ .source = undefined };
                try new_session.source.init(sm, io, allocator);
                try core.sessions.put(allocator, uuid, new_session);
                source_viewer.session = new_session;
            }
        }
    }

    // WARN: DUMMY ROWS
    var label_buf: [32]u8 = undefined;
    for (0..dummy_count) |i| {
        const y_offset = pane.y + @as(f32, @floatFromInt(i + source_keys.len)) * row_height - scroll_y;
        const label = try std.fmt.bufPrint(&label_buf, "Source {d}", .{i + 1});
        try imgui.textLabel(pane.x, y_offset, pane.w, row_height, label, transparent, .{ 255, 255, 255, 255 }, .left);
    }
    // WARN: DUMMY ROWS

    imgui.endScrollView();

    try imgui.addRectOutline(rect.x, rect.y, rect.w, rect.h, ui.ImGui.packColor(1, 1, 1, 1), 0.5);
}
