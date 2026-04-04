pub const Resolution = struct {
    width: usize,
    height: usize,
};

pub const Rational = struct {
    num: usize,
    den: usize,
};

pub const Position = struct {
    offset_x: usize,
    offset_y: usize,

    zoom_x: f32,
    zoom_y: f32,
};
