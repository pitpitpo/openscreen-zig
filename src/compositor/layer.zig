const std = @import("std");

/// WGSL Layer Uniform Layout — exact 192-byte layout matching SPEC_PARITY.md §4.1
/// and assets/shaders/layer.wgsl (44 f32 fields + 4 f32 padding to 192 bytes).
pub const LayerCB = extern struct {
    dst: [4]f32 = .{ 0, 0, 1, 1 }, // [x, y, w, h] in output normalized coordinates (0..1)
    src: [4]f32 = .{ 0, 0, 1, 1 }, // [u0, v0, u1, v1] in source texture normalized coordinates
    quad_px: [2]f32 = .{ 1920, 1080 }, // Output quad size in physical pixels (for isotropic SDF)
    radius_px: f32 = 0, // Corner radius in pixels
    mode: f32 = 1, // Mode enum (0.0 to 18.0)
    color: [4]f32 = .{ 0, 0, 0, 1 }, // Primary color / tint [r, g, b, a]
    fx: [4]f32 = .{ 0, 0, 0, 0 }, // Mode-specific fx (shadow spread, 3D TL/TR, blur params)
    src_prev: [4]f32 = .{ 0, 0, 0, 0 }, // 3D BR/BL corners or motion trail
    dst_prev: [4]f32 = .{ 0, 0, 0, 0 }, // 3D plane dimensions or clip rect
    mb: [4]f32 = .{ 0, 0, 0, 0 }, // Motion blur taps / depth of field
    trail_a: [4]f32 = .{ 0, 0, 0, 0 }, // Motion trail TL, TR
    trail_b: [4]f32 = .{ 0, 0, 0, 0 }, // Motion trail BR, BL
    trail_mb: [4]f32 = .{ 0, 0, 0, 0 }, // Motion trail parameters

    pub fn needsModels(self: *const LayerCB) bool {
        return (self.mode > 14.5 and self.mode < 17.5) or self.mode > 18.5;
    }
};

pub const LayerUniform = extern struct {
    cb: LayerCB = .{},
    _padding: [4]f32 = .{ 0, 0, 0, 0 },
};

comptime {
    if (@sizeOf(LayerCB) != 176) {
        @compileError("LayerCB must be exactly 176 bytes (44 f32 fields)");
    }
    if (@sizeOf(LayerUniform) != 192) {
        @compileError("LayerUniform must be exactly 192 bytes");
    }
}

pub const Modes = struct {
    pub const NV12Video: f32 = 0.0;
    pub const SolidColorRect: f32 = 1.0;
    pub const DropShadow: f32 = 2.0;
    pub const BackgroundAnimated: f32 = 5.0;
    pub const TiltedScreen3D: f32 = 8.0;
    pub const VectorArrow: f32 = 9.0;
    pub const PrivacyBlur: f32 = 10.0;
    pub const ProjectedShadow3D: f32 = 12.0;
    pub const TiltedCursor3D: f32 = 13.0;
    pub const WindowChrome14: f32 = 14.0;
    pub const ModelledCursor3D: f32 = 15.0;
    pub const ClickRipple: f32 = 16.0;
    pub const DeviceFrame3D: f32 = 17.0;
    pub const MultiPassScreen: f32 = 18.0;
};
