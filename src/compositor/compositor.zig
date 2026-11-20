const std = @import("std");
pub const layer = @import("layer.zig");
pub const LayerCB = layer.LayerCB;
pub const Modes = layer.Modes;

pub const PipPosition = enum {
    top_left,
    top_center,
    top_right,
    bottom_left,
    bottom_center,
    bottom_right,
    left_center,
    right_center,

    pub fn computeRect(self: PipPosition, render_w: f32, render_h: f32, pip_w: f32, pip_h: f32, margin: f32) [4]f32 {
        var x: f32 = 0;
        var y: f32 = 0;
        switch (self) {
            .top_left => {
                x = margin;
                y = margin;
            },
            .top_center => {
                x = (render_w - pip_w) * 0.5;
                y = margin;
            },
            .top_right => {
                x = render_w - margin - pip_w;
                y = margin;
            },
            .bottom_left => {
                x = margin;
                y = render_h - margin - pip_h;
            },
            .bottom_center => {
                x = (render_w - pip_w) * 0.5;
                y = render_h - margin - pip_h;
            },
            .bottom_right => {
                x = render_w - margin - pip_w;
                y = render_h - margin - pip_h;
            },
            .left_center => {
                x = margin;
                y = (render_h - pip_h) * 0.5;
            },
            .right_center => {
                x = render_w - margin - pip_w;
                y = (render_h - pip_h) * 0.5;
            },
        }
        return .{ x, y, pip_w, pip_h };
    }
};

pub const BlurMaskKind = enum {
    rect,
    oval,
    polygon,
};

pub const BlurStyle = enum {
    gaussian,
    mosaic,
};

pub const PrivacyBlurRegion = struct {
    kind: BlurMaskKind = .rect,
    style: BlurStyle = .gaussian,
    rect: [4]f32, // [x, y, w, h] in normalized 0..1 coordinates
    blur_radius_px: f32 = 16.0,
    points: ?[]const [2]f32 = null, // Polygon points (normalized 0..1)
};

pub const SceneConfig = struct {
    output_width: u32 = 1920,
    output_height: u32 = 1080,
    padding_px: f32 = 60.0,
    corner_radius_px: f32 = 24.0,
    shadow_spread_px: f32 = 16.0,
    shadow_blur_px: f32 = 36.0,
    shadow_opacity: f32 = 0.40,
    bg_color: [4]f32 = .{ 0.08, 0.09, 0.12, 1.0 },
    screen_color: [4]f32 = .{ 0.94, 0.95, 0.96, 1.0 },
    has_camera: bool = false,
    camera_pip: PipPosition = .bottom_right,
    camera_size: [2]f32 = .{ 320.0, 180.0 },
    camera_radius_px: f32 = 16.0,
    camera_margin_px: f32 = 32.0,
    camera_color: [4]f32 = .{ 0.22, 0.55, 0.95, 1.0 },
    camera_angles_deg: [3]f32 = .{ 0, 0, 0 }, // [Rx, Ry, Rz]
    zoom_scale: f32 = 1.0,
    zoom_center: [2]f32 = .{ 0.5, 0.5 },
    cursor_pos: ?[2]f32 = null, // [cx, cy] in normalized 0..1
    cursor_click_time: ?f32 = null,
    cursor_shape: []const u8 = "arrow",
    privacy_regions: []const PrivacyBlurRegion = &.{},
};

pub const FrameGraph = struct {
    width: u32,
    height: u32,
    layers: std.ArrayListUnmanaged(LayerCB) = .empty,
    privacy_regions: std.ArrayListUnmanaged(PrivacyBlurRegion) = .empty,

    pub fn deinit(self: *FrameGraph, allocator: std.mem.Allocator) void {
        self.layers.deinit(allocator);
        self.privacy_regions.deinit(allocator);
    }
};

/// 3D perspective quad projection helper
pub fn compute3DTiltedCorners(
    rx_deg: f32,
    ry_deg: f32,
    rz_deg: f32,
    base_rect: [4]f32, // [x, y, w, h] normalized
) struct { tl: [2]f32, tr: [2]f32, br: [2]f32, bl: [2]f32 } {
    const rx = rx_deg * (std.math.pi / 180.0);
    const ry = ry_deg * (std.math.pi / 180.0);
    const rz = rz_deg * (std.math.pi / 180.0);

    const cos_x = @cos(rx);
    const sin_x = @sin(rx);
    const cos_y = @cos(ry);
    const sin_y = @sin(ry);
    const cos_z = @cos(rz);
    const sin_z = @sin(rz);

    const cx = base_rect[0] + base_rect[2] * 0.5;
    const cy = base_rect[1] + base_rect[3] * 0.5;
    const hw = base_rect[2] * 0.5;
    const hh = base_rect[3] * 0.5;

    const corners_local = [4][2]f32{
        .{ -hw, -hh }, // TL
        .{ hw, -hh }, // TR
        .{ hw, hh }, // BR
        .{ -hw, hh }, // BL
    };

    var projected: [4][2]f32 = undefined;
    const fov_dist: f32 = 2.0;

    for (corners_local, 0..) |pt, i| {
        // Rotate Z
        const x1 = pt[0] * cos_z - pt[1] * sin_z;
        const y1 = pt[0] * sin_z + pt[1] * cos_z;
        const z1: f32 = 0;

        // Rotate Y
        const x2 = x1 * cos_y + z1 * sin_y;
        const y2 = y1;
        const z2 = -x1 * sin_y + z1 * cos_y;

        // Rotate X
        const x3 = x2;
        const y3 = y2 * cos_x - z2 * sin_x;
        const z3 = y2 * sin_x + z2 * cos_x;

        // Perspective projection
        const persp = fov_dist / (fov_dist + z3);
        projected[i] = .{
            cx + x3 * persp,
            cy + y3 * persp,
        };
    }

    return .{
        .tl = projected[0],
        .tr = projected[1],
        .br = projected[2],
        .bl = projected[3],
    };
}

/// Produces the pure FrameGraph representation for a single frame.
/// Both gpu_wgpu.zig and cpu_fallback.zig evaluate this exact graph.
pub fn planFrame(allocator: std.mem.Allocator, scene: SceneConfig, time_sec: f32) !FrameGraph {
    var fg = FrameGraph{
        .width = scene.output_width,
        .height = scene.output_height,
        .layers = .empty,
        .privacy_regions = .empty,
    };
    errdefer fg.deinit(allocator);

    const rw: f32 = @floatFromInt(scene.output_width);
    const rh: f32 = @floatFromInt(scene.output_height);

    // 1. Background layer (solid color / UI background)
    try fg.layers.append(allocator, LayerCB{
        .dst = .{ 0, 0, 1, 1 },
        .src = .{ 0, 0, 1, 1 },
        .quad_px = .{ rw, rh },
        .radius_px = 0,
        .mode = Modes.SolidColorRect,
        .color = scene.bg_color,
    });

    // Compute screen quad in normalized coordinates
    const sx = scene.padding_px / rw;
    const sy = scene.padding_px / rh;
    const sw = (rw - 2.0 * scene.padding_px) / rw;
    const sh = (rh - 2.0 * scene.padding_px) / rh;
    const screen_rect = [4]f32{ sx, sy, sw, sh };

    const is_3d = (scene.camera_angles_deg[0] != 0 or scene.camera_angles_deg[1] != 0 or scene.camera_angles_deg[2] != 0);

    if (is_3d) {
        const corners = compute3DTiltedCorners(
            scene.camera_angles_deg[0],
            scene.camera_angles_deg[1],
            scene.camera_angles_deg[2],
            screen_rect,
        );

        // 2a. Projected 3D drop shadow (Mode 12)
        try fg.layers.append(allocator, LayerCB{
            .dst = .{ sx, sy + 0.02, sw, sh },
            .quad_px = .{ sw * rw, sh * rh },
            .radius_px = scene.corner_radius_px + scene.shadow_spread_px,
            .mode = Modes.ProjectedShadow3D,
            .color = .{ 0, 0, 0, scene.shadow_opacity },
            .fx = .{ corners.tl[0], corners.tl[1], corners.tr[0], corners.tr[1] },
            .src_prev = .{ corners.br[0], corners.br[1], corners.bl[0], corners.bl[1] },
            .mb = .{ 0, scene.shadow_spread_px, 0, 0 },
        });

        // 3a. 3D perspective-tilted screen (Mode 8)
        try fg.layers.append(allocator, LayerCB{
            .dst = screen_rect,
            .src = .{ 0, 0, 1, 1 },
            .quad_px = .{ sw * rw, sh * rh },
            .radius_px = scene.corner_radius_px,
            .mode = Modes.TiltedScreen3D,
            .color = scene.screen_color,
            .fx = .{ corners.tl[0], corners.tl[1], corners.tr[0], corners.tr[1] },
            .src_prev = .{ corners.br[0], corners.br[1], corners.bl[0], corners.bl[1] },
            .dst_prev = .{ sw * rw, sh * rh, 0, 1 },
        });
    } else {
        // 2b. 2D Drop shadow with Gaussian feathering (Mode 2)
        const shadow_pad_x = (scene.shadow_spread_px + scene.shadow_blur_px) / rw;
        const shadow_pad_y = (scene.shadow_spread_px + scene.shadow_blur_px) / rh;
        try fg.layers.append(allocator, LayerCB{
            .dst = .{
                sx - shadow_pad_x,
                sy - shadow_pad_y + (scene.shadow_spread_px * 0.5) / rh,
                sw + 2.0 * shadow_pad_x,
                sh + 2.0 * shadow_pad_y,
            },
            .quad_px = .{
                (sw + 2.0 * shadow_pad_x) * rw,
                (sh + 2.0 * shadow_pad_y) * rh,
            },
            .radius_px = scene.corner_radius_px + scene.shadow_spread_px,
            .mode = Modes.DropShadow,
            .color = .{ 0, 0, 0, scene.shadow_opacity },
            .fx = .{ scene.shadow_spread_px, scene.shadow_blur_px, 0, 0 },
        });

        // 3b. 2D Screen quad (Mode 1 Solid color / Video surface)
        try fg.layers.append(allocator, LayerCB{
            .dst = screen_rect,
            .src = .{ 0, 0, 1, 1 },
            .quad_px = .{ sw * rw, sh * rh },
            .radius_px = scene.corner_radius_px,
            .mode = Modes.SolidColorRect,
            .color = scene.screen_color,
        });
    }

    // 4. Privacy blur regions (Mode 10)
    for (scene.privacy_regions) |pr| {
        try fg.privacy_regions.append(allocator, pr);

        // Convert region from normalized screen space to output canvas space
        const pr_x = screen_rect[0] + pr.rect[0] * screen_rect[2];
        const pr_y = screen_rect[1] + pr.rect[1] * screen_rect[3];
        const pr_w = pr.rect[2] * screen_rect[2];
        const pr_h = pr.rect[3] * screen_rect[3];

        try fg.layers.append(allocator, LayerCB{
            .dst = .{ pr_x, pr_y, pr_w, pr_h },
            .quad_px = .{ pr_w * rw, pr_h * rh },
            .radius_px = if (pr.kind == .oval) @min(pr_w * rw, pr_h * rh) * 0.5 else 0,
            .mode = Modes.PrivacyBlur,
            .fx = .{
                if (pr.style == .gaussian) 1.0 else 0.0,
                pr.blur_radius_px,
                if (pr.kind == .oval) 1.0 else 0.0,
                0,
            },
        });
    }

    // 5. PiP Camera overlay if enabled
    if (scene.has_camera) {
        const pip_px = scene.camera_pip.computeRect(
            rw,
            rh,
            scene.camera_size[0],
            scene.camera_size[1],
            scene.camera_margin_px,
        );
        const pip_norm = [4]f32{
            pip_px[0] / rw,
            pip_px[1] / rh,
            pip_px[2] / rw,
            pip_px[3] / rh,
        };

        // PiP shadow
        try fg.layers.append(allocator, LayerCB{
            .dst = .{
                pip_norm[0] - 8.0 / rw,
                pip_norm[1] - 4.0 / rh,
                pip_norm[2] + 16.0 / rw,
                pip_norm[3] + 16.0 / rh,
            },
            .quad_px = .{ pip_px[2] + 16.0, pip_px[3] + 16.0 },
            .radius_px = scene.camera_radius_px + 8.0,
            .mode = Modes.DropShadow,
            .color = .{ 0, 0, 0, 0.35 },
            .fx = .{ 8.0, 16.0, 0, 0 },
        });

        // PiP camera frame
        try fg.layers.append(allocator, LayerCB{
            .dst = pip_norm,
            .quad_px = .{ pip_px[2], pip_px[3] },
            .radius_px = scene.camera_radius_px,
            .mode = Modes.SolidColorRect,
            .color = scene.camera_color,
        });
    }

    // 6. Click impact ripple (Mode 16)
    if (scene.cursor_click_time) |tc| {
        const dt = time_sec - tc;
        if (dt >= 0 and dt < 0.5) {
            const progress = dt / 0.5;
            const radius = progress * 60.0;
            const alpha = (1.0 - progress) * 0.6;
            if (scene.cursor_pos) |cp| {
                const cx_norm = screen_rect[0] + cp[0] * screen_rect[2];
                const cy_norm = screen_rect[1] + cp[1] * screen_rect[3];
                const rw_box = (radius * 2.0) / rw;
                const rh_box = (radius * 2.0) / rh;
                try fg.layers.append(allocator, LayerCB{
                    .dst = .{ cx_norm - rw_box * 0.5, cy_norm - rh_box * 0.5, rw_box, rh_box },
                    .quad_px = .{ radius * 2.0, radius * 2.0 },
                    .radius_px = radius,
                    .mode = Modes.ClickRipple,
                    .color = .{ 0.3, 0.7, 1.0, alpha },
                    .fx = .{ progress, radius, alpha, 0 },
                });
            }
        }
    }

    // 7. Cursor rendering (Mode 13 / 15)
    if (scene.cursor_pos) |cp| {
        var bounce_offset_y: f32 = 0;
        if (scene.cursor_click_time) |tc| {
            const dt = time_sec - tc;
            if (dt >= 0 and dt < 0.35) {
                // Click bounce physics: dy = -A * e^(-gamma*t) * sin(omega*t)
                const amp: f32 = 8.0;
                const gamma: f32 = 12.0;
                const omega: f32 = 28.0;
                bounce_offset_y = -amp * @exp(-gamma * dt) * @sin(omega * dt);
            }
        }

        const cursor_w_px: f32 = 32.0;
        const cursor_h_px: f32 = 32.0;
        const cur_x_px = (screen_rect[0] + cp[0] * screen_rect[2]) * rw;
        const cur_y_px = (screen_rect[1] + cp[1] * screen_rect[3]) * rh + bounce_offset_y;

        try fg.layers.append(allocator, LayerCB{
            .dst = .{
                cur_x_px / rw,
                cur_y_px / rh,
                cursor_w_px / rw,
                cursor_h_px / rh,
            },
            .quad_px = .{ cursor_w_px, cursor_h_px },
            .radius_px = 0,
            .mode = if (is_3d) Modes.TiltedCursor3D else Modes.SolidColorRect,
            .color = .{ 0.1, 0.1, 0.1, 1.0 }, // Cursor fill
            .fx = .{ bounce_offset_y, 0, 0, 0 },
        });
    }

    return fg;
}
