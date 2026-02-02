const std = @import("std");

/// LayoutRect
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const SizePolicy = union(enum) {
    /// Exact pixel size
    pixels: f32,
    /// Weight for remaining space (1.0 = equal share)
    fill: f32,
    /// Percentage of parent (0.0 - 1.0)
    percent: f32,
    /// Sized to fit text (future)
    text_content,
    /// Sized to fit children (future)
    children_sum,
};

const ChildEntry = struct {
    width_policy: SizePolicy,
    height_policy: SizePolicy,
    resolved_rect: Rect, // filled in during solve()
    strictness: f32,
};

pub const HStack = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    /// spacing/gutter between elems
    gutter: f32,
    x_cursor: f32,

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
    pub fn add(self: *HStack, width: SizePolicy, height: SizePolicy) void {
        const ce = ChildEntry{
            .width_policy = width,
            .height_policy = height,
            .resolved_rect = undefined,
        };
        self.children[self.child_count] = ce;

        self.child_count += 1;
    }

    pub fn solve(self: *HStack) void {
        // Step 1: resolve pixels + percent widths, sum them
        var total_pixels: f32 = 0;
        var total_percent: f32 = 0;
        var total_fill_weight: f32 = 0;

        for (self.children[0..self.child_count]) |*child| {
            switch (child.width_policy) {
                .pixels => |val| {
                    total_pixels += val;
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
        const remaining = self.w - total_pixels - total_percent - total_gutter;

        // Step 2: distribute remaining to fill children
        for (self.children[0..self.child_count]) |*child| {
            switch (child.width_policy) {
                .fill => |weight| {
                    child.resolved_rect.w = (remaining * (weight / total_fill_weight));
                },
                else => {},
            }
        }

        // Step 2.5 - Strictness
        // FIXME: WIP WIP WIP
        var resolved_total = 0;

        for (self.children[0..self.child_count]) |*child| {
            resolved_total += child.resolved_rect.w;
        }

        const amount: isize = resolved_total - self.w;
        if (amount > 0) {
            // Violation: We need to reduce the total by capture via strictness.
            var split_count = 0;
            var actionable_strictness = 0;

            for (self.children[0..self.child_count]) |*child| {
                if (child.strictness != 1.0) {
                    actionable_strictness += child.strictness;
                    split_count += 1;
                }
            }

            for (self.children[0..self.child_count]) |*child| {
                if (child.strictness != 1.0) {
                    const working_strictness = child.strictness * actionable_strictness;
                    const new_width = child.resolved_rect.w / working_strictness;
                    // ??
                }
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

            // child.height_policy;
            child.resolved_rect.h = switch (child.height_policy) {
                .pixels => |val| val,
                .fill => self.h,
                .percent => |pct| pct * self.h,
                else => 0,
            };

            // Advance the cursor
            self.x_cursor += child.resolved_rect.w;

            // Max the Stacks height per what the caller asks for
            self.h = @max(self.h, child.resolved_rect.h);
        }
    }

    pub fn get(self: *HStack, index: usize) Rect {
        return self.children[index].resolved_rect;
    }
};

pub const VStack = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    /// spacing/gutter between elems
    gutter: f32,
    y_cursor: f32,

    children: [32]ChildEntry,
    child_count: usize,

    pub fn init(x: f32, y: f32, width: f32, height: f32, gutter: f32) VStack {
        return .{
            .x = x,
            .y = y,
            .w = width,
            .h = height,

            .y_cursor = y,
            .gutter = gutter,

            .children = undefined,
            .child_count = 0,
        };
    }

    /// Add Child to Array at child_count idx
    pub fn add(self: *VStack, width: SizePolicy, height: SizePolicy) void {
        const ce = ChildEntry{
            .width_policy = width,
            .height_policy = height,
            .resolved_rect = undefined,
        };
        self.children[self.child_count] = ce;

        self.child_count += 1;
    }

    pub fn solve(self: *VStack) void {
        // Step 1: resolve pixels + percent heights, sum them
        var total_pixels: f32 = 0;
        var total_percent: f32 = 0;
        var total_fill_weight: f32 = 0;

        for (self.children[0..self.child_count]) |*child| {
            switch (child.height_policy) {
                .pixels => |val| {
                    total_pixels += val;
                    child.resolved_rect.h = val;
                },
                .percent => |percent| {
                    const h = percent * self.h;
                    total_percent += h;
                    child.resolved_rect.h = h;
                },
                .fill => |weight| {
                    total_fill_weight += weight;
                    // resolve once all weigths are accumulated
                },
                else => {},
            }
        }

        const total_gutter = @as(f32, @floatFromInt(self.child_count - 1)) * self.gutter;
        const remaining = self.h - total_pixels - total_percent - total_gutter;

        // Step 2: distribute remaining to fill children
        for (self.children[0..self.child_count]) |*child| {
            switch (child.height_policy) {
                .fill => |weight| {
                    child.resolved_rect.h = (remaining * (weight / total_fill_weight));
                },
                else => {},
            }
        }

        // Step 3: walk cursor left-to-right assigning positions
        for (self.children[0..self.child_count]) |*child| {
            // Add Spacing if not first elem
            if (self.y != self.y_cursor) {
                self.y_cursor += self.gutter;
            }

            child.resolved_rect.y = self.y_cursor;
            child.resolved_rect.x = self.x;

            // child.weight_policy;
            child.resolved_rect.w = switch (child.width_policy) {
                .pixels => |val| val,
                .fill => self.h,
                .percent => |pct| pct * self.w,
                else => 0,
            };

            // Advance the cursor
            self.y_cursor += child.resolved_rect.h;

            // Max the Stacks height per what the caller asks for
            self.w = @max(self.w, child.resolved_rect.w);
        }
    }

    pub fn get(self: *VStack, index: usize) Rect {
        return self.children[index].resolved_rect;
    }
};
