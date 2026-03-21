pub const Mesh = struct {
    id: []const u8,
    vertices: []const f32,
    indices: []const u32,
};

pub const Model = struct {
    id: []const u8,
    meshes: []const Mesh,
};

pub const Init = struct {
    models: []const Model,
};
