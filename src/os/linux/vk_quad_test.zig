const std = @import("std");
const Allocator = std.mem.Allocator;

const com = @import("com");

pub const TestDraw = struct {
    pub fn vkDemo(arena_alloc: std.mem.Allocator) !com.mdata.Init {
        const left_quad_model = com.mdata.Model{
            .id = "LeftQuadModel",
            .meshes = &[_]com.mdata.Mesh{
                .{
                    .id = "LeftQuadMesh",
                    .vertices = &[_]f32{
                        -0.99, // '0' Vertex Triplet
                        0.99,
                        0.0,
                        -0.2, // '1' Vertex
                        0.5,
                        0.0,
                        -0.2, // '2' Vertex
                        -0.5,
                        0.0,
                        -0.8, // '3' Vertex
                        -0.5,
                        0.0,
                    },
                    .indices = &[_]u32{
                        0, // Tri 0
                        1,
                        2,
                        0, // Tri 1
                        2,
                        3,
                    },
                },
            },
        };

        const right_quad_model = com.mdata.Model{
            .id = "RightQuadModel",
            .meshes = &[_]com.mdata.Mesh{
                .{
                    .id = "RightQuadMesh",
                    .vertices = &[_]f32{
                        0.8, // '0' Vertex Triplet
                        0.5,
                        0.0,
                        0.2, // '1' Vertex
                        0.5,
                        0.0,
                        0.2, // '2' Vertex
                        -0.5,
                        0.0,
                        0.8, // '3' Vertex
                        -0.5,
                        0.0,
                    },
                    .indices = &[_]u32{
                        0, // Tri 0
                        1,
                        2,
                        0, // Tri 1
                        2,
                        3,
                    },
                },
            },
        };

        const models = try arena_alloc.alloc(com.mdata.Model, 2);
        models[0] = left_quad_model;
        models[1] = right_quad_model;

        return .{ .models = models };
    }
};
