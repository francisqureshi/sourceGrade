pub const Resolution = struct {
    width: usize,
    height: usize,
};

pub const Rational = struct {
    num: usize,
    den: usize,
};

pub const PTRZ = struct {
    offset_x: f32,
    offset_y: f32,

    rotation: f32,

    zoom_x: f32,
    zoom_y: f32,

    pub fn init() PTRZ {
        return .{
            .offset_x = 0.0,
            .offset_y = 0.0,

            .rotation = 0.0,

            .zoom_x = 1.0,
            .zoom_y = 1.0,
        };
    }
};
