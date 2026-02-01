const std = @import("std");

/// LayoutRect
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const SizePolicy = union(enum) {
    fixed: f32, // exact pixel size
    fill: f32, // weight for remaining space (1.0 = equal share)
    percent: f32, // percentage of parent (0.0 - 1.0)
    text_content, // sized to fit text (future)
    children_sum, // sized to fit children (future)
};

const ChildEntry = struct {
    width_policy: SizePolicy,
    height: f32, // keep height simple/fixed for now
    resolved_rect: Rect, // filled in during solve()
};

pub const HStack = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    x_cursor: f32,
    /// spacing/gutter between elems
    gutter: f32,

    children: [32]ChildEntry,
    child_count: usize,

    pub fn init(x: f32, y: f32, width: f32, height: f32, gutter: f32) HStack {
        return .{
            .x = x,
            .y = y,
            .w = width,
            .h = height,

            .x_cursor = x,
            .gutter = gutter,

            .children = undefined,
            .child_count = 0,
        };
    }

    /// Add Child to Array at child_count idx
    pub fn add(self: *HStack, width: SizePolicy, height: f32) void {
        const ce = ChildEntry{
            .width_policy = width,
            .height = height,
            .resolved_rect = undefined,
        };
        self.children[self.child_count] = ce;

        self.child_count += 1;
    }

    pub fn solve(self: *HStack) void {
        // Step 1: resolve fixed + percent widths, sum them
        var total_fixed: f32 = 0;
        var total_percent: f32 = 0;
        var total_fill_weight: f32 = 0;

        for (self.children[0..self.child_count]) |*child| {
            switch (child.width_policy) {
                .fixed => |val| {
                    total_fixed += val;
                    child.resolved_rect.w = val;
                },
                .percent => |percent| {
                    const w = percent * self.w;
                    total_percent += w;
                    child.resolved_rect.w = w;
                },
                .fill => |weight| {
                    total_fill_weight += weight;
                    // resolve once all weigths are accumulated
                },
                else => {},
            }
        }

        const total_gutter = @as(f32, @floatFromInt(self.child_count - 1)) * self.gutter;
        const remaining = self.w - total_fixed - total_percent - total_gutter;

        // Step 2: distribute remaining to fill children
        for (self.children[0..self.child_count]) |*child| {
            switch (child.width_policy) {
                .fill => |weight| {
                    child.resolved_rect.w = (remaining * (weight / total_fill_weight));
                },
                else => {},
            }
        }

        // Step 3: walk cursor left-to-right assigning positions
        for (self.children[0..self.child_count]) |*child| {
            // Add Spacing if not first elem
            if (self.x != self.x_cursor) {
                self.x_cursor += self.gutter;
            }

            child.resolved_rect.x = self.x_cursor;
            child.resolved_rect.y = self.y;
            child.resolved_rect.h = child.height;

            // Advance the cursor
            self.x_cursor += child.resolved_rect.w;

            // Max the Stacks height per what the caller asks for
            self.h = @max(self.h, child.height);
        }
    }

    pub fn get(self: *HStack, index: usize) Rect {
        return self.children[index].resolved_rect;
    }

    /// Deprecated in favour of Add
    pub fn next(self: *HStack, req_width: SizePolicy, req_height: f32) Rect {

        // Add Spacing if not first elem
        if (self.x != self.x_cursor) {
            self.x_cursor += self.gutter;
        }

        const x = self.x_cursor;
        const y = self.y;

        // Advance the cursor
        self.x_cursor += req_width;

        // Max the Stacks height per what the caller asks for
        self.h = @max(self.h, req_height);

        return .{
            .x = x,
            .y = y,
            .w = req_width,
            .h = req_height,
        };
    }
};

pub const VStack = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    y_cursor: f32,

    pub fn init(x: f32, y: f32, width: f32, height: f32) VStack {
        return .{
            .x = x,
            .y = y,
            .w = width,
            .h = height,
            .y_cursor = y,
        };
    }

    pub fn next(self: *VStack, req_width: f32, req_height: f32) Rect {
        const x = self.x;
        const y = self.y_cursor;

        // Advance the cursor and max the height according requested contents
        self.y_cursor += req_height;
        self.w = @max(self.w, req_width);

        return .{
            .x = x,
            .y = y,
            .w = req_width,
            .h = req_height,
        };
    }
};
