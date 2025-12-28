const std = @import("std");

pub const Tree = struct {
    nodes: []const Node.Data,

    pub const Node = enum(u32) {
        root = 0,
        invalid = std.math.maxInt(u32),
        _,

        pub const Data = struct {
            parent: Node,
            children: struct {
                index: u32,
                count: u32,
            },
        };
    };

    fn get(tree: *const Tree, node: Node) Node.Data {
        return tree.nodes[@intFromEnum(node)];
    }

    pub fn parent(tree: *const Tree, node: Node) ?Node {
        const result = tree.get(node).parent;
        return if (result == .invalid) null else result;
    }

    pub fn children(tree: *const Tree, node: Node) []const Node.Data {
        const data = tree.get(node);
        const range = data.children;
        return tree.nodes[range.index..][0..range.count];
    }
};

fn traverseDepthFirst(tree: *const Tree, node: Tree.Node) void {
    // Process current node
    const data = tree.get(node);
    std.debug.print("Visiting node {}\n", .{@intFromEnum(node)});

    // Get children range
    const range = data.children;

    // Loop through each child
    for (0..range.count) |offset| {
        const child_idx: Tree.Node = @enumFromInt(range.index + offset);

        // Recursively visit
        traverseDepthFirst(tree, child_idx);
    }
}

// Start from root
fn traverseTree(tree: *const Tree) void {
    traverseDepthFirst(tree, .root); // .root is defined as 0
}

fn buildAndTraverse() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build a tree: root with 2 children, first child has 1 child
    var nodes = std.ArrayList(Tree.Node.Data){};
    defer nodes.deinit(allocator);

    // Node 0: root (no parent, children at 1-2)
    try nodes.append(allocator, .{
        .parent = .invalid,
        .children = .{ .index = 1, .count = 2 },
    });

    // Node 1: first child (parent=0, one child at 3)
    try nodes.append(allocator, .{
        .parent = @enumFromInt(0),
        .children = .{ .index = 3, .count = 1 },
    });

    // Node 2: second child (parent=0, no children)
    try nodes.append(allocator, .{
        .parent = @enumFromInt(0),
        .children = .{ .index = 0, .count = 0 }, // no children
    });

    // Node 3: grandchild (parent=1, no children)
    try nodes.append(allocator, .{
        .parent = @enumFromInt(1),
        .children = .{ .index = 0, .count = 0 },
    });

    const tree = Tree{ .nodes = nodes.items };

    // Now traverse!
    traverseDepthFirst(&tree, .root);
}

pub fn main() !void {
    try buildAndTraverse();
}
