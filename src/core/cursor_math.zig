const std = @import("std");
const easing = @import("easing.zig");

pub const STEP_MS: f32 = 1000.0 / 240.0;
pub const STEP_S: f32 = STEP_MS / 1000.0;

pub const OPENING_WIDE_MS: f64 = 2500.0;
pub const CLOSING_WIDE_MS: f64 = 1000.0;
pub const STOP_CLICK_GUARD_MS: f64 = 1000.0;
pub const SHOT_MERGE_GAP_MS: f64 = 3000.0;
pub const SHOT_LEAD_MS: f64 = 500.0;
pub const SHOT_TAIL_MS: f64 = 1500.0;
pub const MIN_SHOT_HOLD_MS: f64 = 1800.0;
pub const MIN_WIDE_BETWEEN_MS: f64 = 1500.0;
pub const SHOT_FIT_MARGIN: f32 = 0.12;

pub const SpringConfig = struct {
    stiffness: f32,
    damping: f32,
    mass: f32,
    rest_delta: f32 = 0.0005,
    rest_speed: f32 = 0.02,
};

pub fn get_cursor_spring_config(smoothing_factor: f32) SpringConfig {
    const clamped = std.math.clamp(smoothing_factor, 0.0, 2.0);
    if (clamped <= 0.0) {
        return .{
            .stiffness = 1000.0,
            .damping = 100.0,
            .mass = 1.0,
            .rest_delta = 0.0001,
            .rest_speed = 0.001,
        };
    }

    if (clamped <= 0.5) {
        const norm = clamped / 0.5;
        return .{
            .stiffness = 760.0 - norm * 420.0,
            .damping = 34.0 + norm * 24.0,
            .mass = 0.55 + norm * 0.45,
            .rest_delta = 0.0002,
            .rest_speed = 0.01,
        };
    }

    const norm = (clamped - 0.5) / 1.5;
    return .{
        .stiffness = 340.0 - norm * 180.0,
        .damping = 58.0 + norm * 22.0,
        .mass = 1.0 + norm * 0.35,
        .rest_delta = 0.0002,
        .rest_speed = 0.01,
    };
}

pub const CursorSpring = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    vx: f32 = 0.0,
    vy: f32 = 0.0,
    initialized: bool = false,

    pub fn reset(self: *CursorSpring, initial_x: f32, initial_y: f32) void {
        self.x = initial_x;
        self.y = initial_y;
        self.vx = 0.0;
        self.vy = 0.0;
        self.initialized = true;
    }

    pub fn step(self: *CursorSpring, target_x: f32, target_y: f32, dt_s: f32, config: SpringConfig) void {
        if (!self.initialized) {
            self.reset(target_x, target_y);
            return;
        }

        const safe_dt = std.math.clamp(dt_s, 0.001, 0.08);

        // Symplectic Euler step for x
        const ax = (-config.stiffness * (self.x - target_x) - config.damping * self.vx) / config.mass;
        self.vx += ax * safe_dt;
        self.x += self.vx * safe_dt;

        // Symplectic Euler step for y
        const ay = (-config.stiffness * (self.y - target_y) - config.damping * self.vy) / config.mass;
        self.vy += ay * safe_dt;
        self.y += self.vy * safe_dt;

        if (@abs(self.x - target_x) <= config.rest_delta and @abs(self.vx) <= config.rest_speed) {
            self.x = target_x;
            self.vx = 0.0;
        }
        if (@abs(self.y - target_y) <= config.rest_delta and @abs(self.vy) <= config.rest_speed) {
            self.y = target_y;
            self.vy = 0.0;
        }
    }
};

pub fn click_bounce_scale(time_since_click_s: f32, bounce_intensity: f32) f32 {
    if (time_since_click_s < 0.0 or time_since_click_s > 0.35) {
        return 1.0;
    }
    const t = time_since_click_s;
    const osc = @cos(std.math.tau * 6.0 * t);
    const decay = @exp(-12.0 * t);
    return 1.0 - bounce_intensity * 0.35 * osc * decay;
}

pub const TelemetrySample = struct {
    time_ms: f64,
    cx: f32,
    cy: f32,
    visible: bool = true,
    interaction: InteractionType = .move,
};

pub const InteractionType = enum {
    move,
    click,
    double_click,
    right_click,
    middle_click,
    mouseup,

    pub fn is_click(self: InteractionType) bool {
        return switch (self) {
            .click, .double_click, .right_click, .middle_click => true,
            else => false,
        };
    }
};

pub const AutoZoomShot = struct {
    start_ms: f64,
    end_ms: f64,
    focus_x: f32,
    focus_y: f32,
    depth: u8, // 1..6
};

pub fn compute_auto_zooms(
    allocator: std.mem.Allocator,
    samples: []const TelemetrySample,
    total_duration_ms: f64,
) ![]AutoZoomShot {
    if (samples.len == 0 or total_duration_ms <= OPENING_WIDE_MS + CLOSING_WIDE_MS) {
        return try allocator.alloc(AutoZoomShot, 0);
    }

    var clicks: std.ArrayList(TelemetrySample) = .empty;
    defer clicks.deinit(allocator);

    const max_click_time = total_duration_ms - STOP_CLICK_GUARD_MS;

    for (samples) |s| {
        if (s.time_ms >= OPENING_WIDE_MS and s.time_ms <= max_click_time and s.interaction.is_click() and s.visible) {
            try clicks.append(allocator, s);
        }
    }

    if (clicks.items.len == 0) {
        return try allocator.alloc(AutoZoomShot, 0);
    }

    var shots: std.ArrayList(AutoZoomShot) = .empty;
    defer shots.deinit(allocator);

    var cluster_start_idx: usize = 0;
    while (cluster_start_idx < clicks.items.len) {
        var cluster_end_idx = cluster_start_idx;
        while (cluster_end_idx + 1 < clicks.items.len) {
            const gap = clicks.items[cluster_end_idx + 1].time_ms - clicks.items[cluster_end_idx].time_ms;
            if (gap <= SHOT_MERGE_GAP_MS) {
                cluster_end_idx += 1;
            } else {
                break;
            }
        }

        const first_click = clicks.items[cluster_start_idx];
        const last_click = clicks.items[cluster_end_idx];

        var min_x = first_click.cx;
        var max_x = first_click.cx;
        var min_y = first_click.cy;
        var max_y = first_click.cy;

        var k = cluster_start_idx + 1;
        while (k <= cluster_end_idx) : (k += 1) {
            min_x = @min(min_x, clicks.items[k].cx);
            max_x = @max(max_x, clicks.items[k].cx);
            min_y = @min(min_y, clicks.items[k].cy);
            max_y = @max(max_y, clicks.items[k].cy);
        }

        const span_x = max_x - min_x + SHOT_FIT_MARGIN * 2.0;
        const span_y = max_y - min_y + SHOT_FIT_MARGIN * 2.0;
        const max_span = @max(span_x, span_y);

        var depth: u8 = 3; // Default 1.8x
        if (max_span > 0.6) {
            depth = 1; // 1.25x
        } else if (max_span > 0.45) {
            depth = 2; // 1.5x
        } else if (max_span < 0.25) {
            depth = 4; // 2.2x
        }

        const center_x = std.math.clamp((min_x + max_x) * 0.5, 0.1, 0.9);
        const center_y = std.math.clamp((min_y + max_y) * 0.5, 0.1, 0.9);

        var start_t = @max(OPENING_WIDE_MS, first_click.time_ms - SHOT_LEAD_MS);
        var end_t = @min(total_duration_ms - CLOSING_WIDE_MS, last_click.time_ms + SHOT_TAIL_MS);

        if (end_t - start_t < MIN_SHOT_HOLD_MS) {
            end_t = @min(total_duration_ms - CLOSING_WIDE_MS, start_t + MIN_SHOT_HOLD_MS);
        }

        // Avoid overlap with previous shot
        if (shots.items.len > 0) {
            const prev = shots.items[shots.items.len - 1];
            if (start_t < prev.end_ms + MIN_WIDE_BETWEEN_MS) {
                start_t = prev.end_ms + MIN_WIDE_BETWEEN_MS;
            }
        }

        if (start_t < end_t and (end_t - start_t >= MIN_SHOT_HOLD_MS)) {
            try shots.append(allocator, .{
                .start_ms = start_t,
                .end_ms = end_t,
                .focus_x = center_x,
                .focus_y = center_y,
                .depth = depth,
            });
        }

        cluster_start_idx = cluster_end_idx + 1;
    }

    return try shots.toOwnedSlice(allocator);
}

test "spring configuration derivation" {
    const zero = get_cursor_spring_config(0.0);
    try std.testing.expectEqual(@as(f32, 1000.0), zero.stiffness);
    try std.testing.expectEqual(@as(f32, 100.0), zero.damping);
    try std.testing.expectEqual(@as(f32, 1.0), zero.mass);

    const half = get_cursor_spring_config(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 340.0), half.stiffness, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 58.0), half.damping, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), half.mass, 1e-3);
}

test "cursor spring step convergence" {
    var spring = CursorSpring{};
    spring.reset(0.0, 0.0);

    const config = get_cursor_spring_config(0.3);
    var step_i: usize = 0;
    while (step_i < 120) : (step_i += 1) {
        spring.step(1.0, 1.0, STEP_S, config);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), spring.x, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), spring.y, 1e-2);
}

test "click bounce scale at rest and impact" {
    const scale_rest = click_bounce_scale(1.0, 1.0);
    try std.testing.expectEqual(@as(f32, 1.0), scale_rest);

    const scale_impact = click_bounce_scale(0.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), scale_impact, 1e-3);
}

test "compute auto zooms deterministic plan" {
    const samples = [_]TelemetrySample{
        .{ .time_ms = 500.0, .cx = 0.5, .cy = 0.5, .interaction = .click }, // ignored by OPENING_WIDE_MS
        .{ .time_ms = 3000.0, .cx = 0.3, .cy = 0.4, .interaction = .click },
        .{ .time_ms = 4500.0, .cx = 0.32, .cy = 0.42, .interaction = .click },
        .{ .time_ms = 19500.0, .cx = 0.8, .cy = 0.8, .interaction = .click }, // ignored by STOP_CLICK_GUARD_MS
    };

    const shots = try compute_auto_zooms(std.testing.allocator, &samples, 20000.0);
    defer std.testing.allocator.free(shots);

    try std.testing.expectEqual(@as(usize, 1), shots.len);
    try std.testing.expectEqual(@as(f64, 2500.0), shots[0].start_ms);
    try std.testing.expect(shots[0].end_ms >= 6000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.31), shots[0].focus_x, 0.05);
}
