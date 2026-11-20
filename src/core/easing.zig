const std = @import("std");

pub const SPRING_OMEGA_T: f32 = 7.0;
pub const ZOOM_TRANSITION_BASE_MS: f32 = 600.0;
pub const ZOOM_TRANSITION_PER_LN_MS: f32 = 550.0;
pub const CHAINED_ZOOM_PAN_GAP_MS: f32 = 1500.0;
pub const CONNECTED_ZOOM_PAN_DURATION_MS: f32 = 1000.0;

pub fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0.0, 1.0);
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn scale_lerp(a: f32, b: f32, t: f32) f32 {
    const safe_a = @max(1e-3, a);
    const safe_b = @max(1e-3, b);
    return safe_a * std.math.pow(f32, safe_b / safe_a, t);
}

pub fn zoom_transition_ms(scale: f32) f32 {
    return ZOOM_TRANSITION_BASE_MS + ZOOM_TRANSITION_PER_LN_MS * @log(@max(1.0, scale));
}

fn sample_cubic_bezier(a1: f32, a2: f32, t: f32) f32 {
    const o = 1.0 - t;
    return 3.0 * a1 * o * o * t + 3.0 * a2 * o * t * t + t * t * t;
}

fn sample_cubic_bezier_derivative(a1: f32, a2: f32, t: f32) f32 {
    const o = 1.0 - t;
    return 3.0 * a1 * o * o + 6.0 * (a2 - a1) * o * t + 3.0 * (1.0 - a2) * t * t;
}

pub fn cubic_bezier(x1: f32, y1: f32, x2: f32, y2: f32, t: f32) f32 {
    const target_x = clamp01(t);
    var solved_t = target_x;

    // Newton-Raphson iterations
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const cur_x = sample_cubic_bezier(x1, x2, solved_t) - target_x;
        const cur_d = sample_cubic_bezier_derivative(x1, x2, solved_t);
        if (@abs(cur_x) < 1e-6 or @abs(cur_d) < 1e-6) {
            break;
        }
        solved_t -= cur_x / cur_d;
    }

    // Bisection fallback
    var lower: f32 = 0.0;
    var upper: f32 = 1.0;
    solved_t = clamp01(solved_t);
    var j: usize = 0;
    while (j < 10) : (j += 1) {
        const cur_x = sample_cubic_bezier(x1, x2, solved_t);
        if (@abs(cur_x - target_x) < 1e-6) {
            break;
        }
        if (cur_x < target_x) {
            lower = solved_t;
        } else {
            upper = solved_t;
        }
        solved_t = (lower + upper) * 0.5;
    }

    return sample_cubic_bezier(y1, y2, solved_t);
}

pub fn ease_out_screen_studio(t: f32) f32 {
    return cubic_bezier(0.16, 1.0, 0.3, 1.0, t);
}

pub fn ease_connected_pan(t: f32) f32 {
    return cubic_bezier(0.1, 0.0, 0.2, 1.0, t);
}

pub fn ease_spring(t: f32) f32 {
    const x = SPRING_OMEGA_T * clamp01(t);
    const end = 1.0 - (1.0 + SPRING_OMEGA_T) * @exp(-SPRING_OMEGA_T);
    return (1.0 - (1.0 + x) * @exp(-x)) / end;
}

pub const Rotation3D = [3]f32;

pub fn rotation3d_for(preset_opt: ?[]const u8) Rotation3D {
    if (preset_opt) |p| {
        if (std.mem.eql(u8, p, "left") or std.mem.eql(u8, p, "iso")) {
            return .{ -12.0, -18.0, -2.0 };
        } else if (std.mem.eql(u8, p, "right")) {
            return .{ -12.0, 18.0, 2.0 };
        }
    }
    return .{ 0.0, 0.0, 0.0 };
}

pub fn lerp_rotation3d(a: Rotation3D, b: Rotation3D, t: f32) Rotation3D {
    return .{
        lerp(a[0], b[0], t),
        lerp(a[1], b[1], t),
        lerp(a[2], b[2], t),
    };
}

test "easing curves endpoints and monotonicity" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ease_spring(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease_spring(1.0), 1e-4);
    try std.testing.expect(ease_spring(0.5) > 0.4 and ease_spring(0.5) < 0.95);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ease_out_screen_studio(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease_out_screen_studio(1.0), 1e-4);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ease_connected_pan(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease_connected_pan(1.0), 1e-4);
}

test "zoom transition duration formula" {
    const dur1 = zoom_transition_ms(1.0);
    try std.testing.expectApproxEqAbs(600.0, dur1, 1e-3);
    const dur18 = zoom_transition_ms(1.8);
    try std.testing.expect(dur18 > 900.0 and dur18 < 950.0);
}

test "3d rotation presets" {
    const left = rotation3d_for("left");
    try std.testing.expectEqual(@as(f32, -12.0), left[0]);
    try std.testing.expectEqual(@as(f32, -18.0), left[1]);
    try std.testing.expectEqual(@as(f32, -2.0), left[2]);

    const iso = rotation3d_for("iso");
    try std.testing.expectEqual(left, iso);

    const right = rotation3d_for("right");
    try std.testing.expectEqual(@as(f32, -12.0), right[0]);
    try std.testing.expectEqual(@as(f32, 18.0), right[1]);
    try std.testing.expectEqual(@as(f32, 2.0), right[2]);

    const flat = rotation3d_for(null);
    try std.testing.expectEqual(@as(f32, 0.0), flat[0]);
    try std.testing.expectEqual(@as(f32, 0.0), flat[1]);
    try std.testing.expectEqual(@as(f32, 0.0), flat[2]);
}
