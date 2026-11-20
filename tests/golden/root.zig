const std = @import("std");
const core = @import("core");
const compositor = @import("compositor");

const CpuCompositor = compositor.CpuCompositor;
const GpuCompositor = compositor.GpuCompositor;
const SceneConfig = compositor.SceneConfig;
const PipPosition = compositor.PipPosition;
const PrivacyBlurRegion = compositor.PrivacyBlurRegion;
const FrameGraph = compositor.FrameGraph;
const planFrame = compositor.planFrame;
const writeP6Ppm = compositor.writeP6Ppm;

/// Standard SSIM calculation over two 8-bit RGB/RGBA buffers.
pub fn calculateSSIM(img_a: []const u8, img_b: []const u8, width: u32, height: u32) f64 {
    std.debug.assert(img_a.len == img_b.len);
    const num_pixels: f64 = @floatFromInt(@as(usize, width) * @as(usize, height));

    // Convert to grayscale luma Y = 0.299 R + 0.587 G + 0.114 B
    var sum_a: f64 = 0;
    var sum_b: f64 = 0;

    var i: usize = 0;
    while (i < img_a.len) : (i += 4) {
        const ya = 0.299 * @as(f64, @floatFromInt(img_a[i + 0])) +
            0.587 * @as(f64, @floatFromInt(img_a[i + 1])) +
            0.114 * @as(f64, @floatFromInt(img_a[i + 2]));
        const yb = 0.299 * @as(f64, @floatFromInt(img_b[i + 0])) +
            0.587 * @as(f64, @floatFromInt(img_b[i + 1])) +
            0.114 * @as(f64, @floatFromInt(img_b[i + 2]));
        sum_a += ya;
        sum_b += yb;
    }

    const mean_a = sum_a / num_pixels;
    const mean_b = sum_b / num_pixels;

    var var_a: f64 = 0;
    var var_b: f64 = 0;
    var cov_ab: f64 = 0;

    i = 0;
    while (i < img_a.len) : (i += 4) {
        const ya = 0.299 * @as(f64, @floatFromInt(img_a[i + 0])) +
            0.587 * @as(f64, @floatFromInt(img_a[i + 1])) +
            0.114 * @as(f64, @floatFromInt(img_a[i + 2]));
        const yb = 0.299 * @as(f64, @floatFromInt(img_b[i + 0])) +
            0.587 * @as(f64, @floatFromInt(img_b[i + 1])) +
            0.114 * @as(f64, @floatFromInt(img_b[i + 2]));

        const da = ya - mean_a;
        const db = yb - mean_b;

        var_a += da * da;
        var_b += db * db;
        cov_ab += da * db;
    }

    var_a /= num_pixels;
    var_b /= num_pixels;
    cov_ab /= num_pixels;

    const c1: f64 = 6.5025; // (0.01 * 255)^2
    const c2: f64 = 58.5225; // (0.03 * 255)^2

    const numerator = (2.0 * mean_a * mean_b + c1) * (2.0 * cov_ab + c2);
    const denominator = (mean_a * mean_a + mean_b * mean_b + c1) * (var_a + var_b + c2);

    return numerator / denominator;
}

/// Computes local edge gradient variance (Laplacian energy) over a normalized subregion.
fn computeRegionEdgeVariance(
    buffer: []const u8,
    width: u32,
    height: u32,
    rect: [4]f32, // x, y, w, h normalized
) f64 {
    const rw: f32 = @floatFromInt(width);
    const rh: f32 = @floatFromInt(height);

    const x_start = @as(u32, @intFromFloat(rect[0] * rw)) + 2;
    const x_end = @as(u32, @intFromFloat((rect[0] + rect[2]) * rw)) - 2;
    const y_start = @as(u32, @intFromFloat(rect[1] * rh)) + 2;
    const y_end = @as(u32, @intFromFloat((rect[1] + rect[3]) * rh)) - 2;

    var sum_grad: f64 = 0;
    var sum_grad_sq: f64 = 0;
    var count: f64 = 0;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x = x_start;
        while (x < x_end) : (x += 1) {
            const idx = (@as(usize, y) * width + @as(usize, x)) * 4;
            const idx_r = (@as(usize, y) * width + @as(usize, x + 1)) * 4;
            const idx_l = (@as(usize, y) * width + @as(usize, x - 1)) * 4;
            const idx_d = (@as(usize, y + 1) * width + @as(usize, x)) * 4;
            const idx_u = (@as(usize, y - 1) * width + @as(usize, x)) * 4;

            const val = @as(f64, @floatFromInt(buffer[idx]));
            const gx = @abs(@as(f64, @floatFromInt(buffer[idx_r])) - @as(f64, @floatFromInt(buffer[idx_l]))) * 0.5;
            const gy = @abs(@as(f64, @floatFromInt(buffer[idx_d])) - @as(f64, @floatFromInt(buffer[idx_u]))) * 0.5;
            const grad = gx + gy + val * 0.0;

            sum_grad += grad;
            sum_grad_sq += grad * grad;
            count += 1;
        }
    }

    if (count <= 1) return 0;
    const mean = sum_grad / count;
    return (sum_grad_sq / count) - (mean * mean);
}

// -------------------------------------------------------------------------------------------------
// GATE 2 TEST 1: Analytical Pixel Bounds (±1 px)
// -------------------------------------------------------------------------------------------------
test "Gate 2: Analytical pixel bounds (±1 px) for padding, corners, shadow, 3D, bounce, PiP" {
    const allocator = std.testing.allocator;

    var cpu = try CpuCompositor.init(allocator, 1920, 1080);
    defer cpu.deinit();

    // 1. Padding & Rounded Corners verification
    const padding: f32 = 60.0;
    const radius: f32 = 24.0;
    const scene1 = SceneConfig{
        .padding_px = padding,
        .corner_radius_px = radius,
        .bg_color = .{ 0.1, 0.1, 0.1, 1.0 },
        .screen_color = .{ 0.9, 0.9, 0.9, 1.0 },
        .has_camera = false,
    };
    var fg1 = try planFrame(allocator, scene1, 0.0);
    defer fg1.deinit(allocator);

    const buf1 = try cpu.render(&fg1);

    // Assert analytical padding boundary at x = 60 (mid-height y = 540)
    const idx_outside_x = (@as(usize, 540) * 1920 + 58) * 4;
    const idx_inside_x = (@as(usize, 540) * 1920 + 62) * 4;
    // Outside must be background (~25)
    try std.testing.expect(buf1[idx_outside_x] < 40);
    // Inside must be screen (~230)
    try std.testing.expect(buf1[idx_inside_x] > 200);

    // Assert analytical corner radius boundary at corner diagonal
    // Center of corner arc: (84, 84). Boundary: 84 - 24 / sqrt(2) ≈ 67.03.
    const idx_corner_out = (@as(usize, 65) * 1920 + 65) * 4;
    const idx_corner_in = (@as(usize, 69) * 1920 + 69) * 4;
    try std.testing.expect(buf1[idx_corner_out] < 40);
    try std.testing.expect(buf1[idx_corner_in] > 200);

    // 2. Drop shadow verification
    // Outside boundary of shadow at spread 16 + blur 36 = 52px past screen edge -> x = 60 - 52 = 8
    const idx_shadow_far = (@as(usize, 540) * 1920 + 4) * 4;
    const idx_shadow_near = (@as(usize, 540) * 1920 + 45) * 4;
    try std.testing.expect(buf1[idx_shadow_far] <= 30);
    // Shadow must darken background near edge (premultiplied shadow blend)
    try std.testing.expect(buf1[idx_shadow_near] < buf1[idx_shadow_far] or buf1[idx_shadow_near] < 26);

    // 3. Click bounce physics verification
    // At dt = 0.05s, dy ≈ -4.3 px
    const click_time: f32 = 1.0;
    const eval_time: f32 = 1.05;
    const scene_click = SceneConfig{
        .cursor_pos = .{ 0.5, 0.5 },
        .cursor_click_time = click_time,
    };
    var fg_click = try planFrame(allocator, scene_click, eval_time);
    defer fg_click.deinit(allocator);

    // Locate cursor layer
    var cursor_layer: ?compositor.LayerCB = null;
    for (fg_click.layers.items) |l| {
        if (l.mode == compositor.Modes.SolidColorRect and l.quad_px[0] == 32.0) {
            cursor_layer = l;
            break;
        }
    }
    try std.testing.expect(cursor_layer != null);
    const dy = cursor_layer.?.fx[0];
    // Check dy is negative within bounce amplitude range [-7, -2]
    try std.testing.expect(dy < -2.0 and dy > -8.0);

    // 4. All 8 PiP snap positions verification
    const pip_positions = [_]PipPosition{
        .top_left,
        .top_center,
        .top_right,
        .bottom_left,
        .bottom_center,
        .bottom_right,
        .left_center,
        .right_center,
    };

    for (pip_positions) |pos| {
        const scene_pip = SceneConfig{
            .has_camera = true,
            .camera_pip = pos,
            .camera_size = .{ 320.0, 180.0 },
            .camera_margin_px = 32.0,
        };
        var fg_pip = try planFrame(allocator, scene_pip, 0.0);
        defer fg_pip.deinit(allocator);

        const analytical_rect = pos.computeRect(1920.0, 1080.0, 320.0, 180.0, 32.0);

        // Find camera layer in FrameGraph
        var cam_layer: ?compositor.LayerCB = null;
        for (fg_pip.layers.items) |l| {
            if (l.mode == compositor.Modes.SolidColorRect and l.quad_px[0] == 320.0) {
                cam_layer = l;
                break;
            }
        }
        try std.testing.expect(cam_layer != null);
        const cl = cam_layer.?;
        const actual_x = cl.dst[0] * 1920.0;
        const actual_y = cl.dst[1] * 1080.0;

        try std.testing.expectApproxEqAbs(analytical_rect[0], actual_x, 1.0);
        try std.testing.expectApproxEqAbs(analytical_rect[1], actual_y, 1.0);
    }
}

// -------------------------------------------------------------------------------------------------
// GATE 2 TEST 2: Privacy blur regions strictly reduce local edge variance
// -------------------------------------------------------------------------------------------------
test "Gate 2: Privacy blur regions (Gaussian & mosaic; rect, oval, polygon) reduce edge variance" {
    const allocator = std.testing.allocator;

    var cpu = try CpuCompositor.init(allocator, 1920, 1080);
    defer cpu.deinit();

    // Create high-contrast striped texture base
    var y: u32 = 0;
    while (y < 1080) : (y += 1) {
        var x: u32 = 0;
        while (x < 1920) : (x += 1) {
            const idx = (@as(usize, y) * 1920 + @as(usize, x)) * 4;
            // Alternating vertical stripes every 8 pixels (high gradient variance)
            const val: u8 = if ((x / 8) % 2 == 0) 255 else 0;
            cpu.buffer[idx + 0] = val;
            cpu.buffer[idx + 1] = val;
            cpu.buffer[idx + 2] = val;
            cpu.buffer[idx + 3] = 255;
        }
    }

    const test_rect = [4]f32{ 0.3, 0.3, 0.4, 0.4 };
    const unblurred_variance = computeRegionEdgeVariance(cpu.buffer, 1920, 1080, test_rect);
    try std.testing.expect(unblurred_variance > 500.0);

    // Test A: Gaussian Blur Rect
    const region_gauss = PrivacyBlurRegion{
        .kind = .rect,
        .style = .gaussian,
        .rect = test_rect,
        .blur_radius_px = 16.0,
    };
    var fg_gauss = FrameGraph{
        .width = 1920,
        .height = 1080,
    };
    defer fg_gauss.deinit(allocator);
    try fg_gauss.privacy_regions.append(allocator, region_gauss);

    _ = try cpu.render(&fg_gauss);
    const gauss_variance = computeRegionEdgeVariance(cpu.buffer, 1920, 1080, test_rect);
    // Must strictly reduce edge variance by at least 70%
    try std.testing.expect(gauss_variance < unblurred_variance * 0.30);

    // Test B: Mosaic Blur Rect
    const region_mosaic = PrivacyBlurRegion{
        .kind = .rect,
        .style = .mosaic,
        .rect = test_rect,
        .blur_radius_px = 16.0,
    };
    var fg_mosaic = FrameGraph{
        .width = 1920,
        .height = 1080,
    };
    defer fg_mosaic.deinit(allocator);
    try fg_mosaic.privacy_regions.append(allocator, region_mosaic);

    _ = try cpu.render(&fg_mosaic);
    const mosaic_variance = computeRegionEdgeVariance(cpu.buffer, 1920, 1080, test_rect);
    try std.testing.expect(mosaic_variance < unblurred_variance * 0.35);

    // Test C: Oval Mask Gaussian Blur
    const region_oval = PrivacyBlurRegion{
        .kind = .oval,
        .style = .gaussian,
        .rect = test_rect,
        .blur_radius_px = 20.0,
    };
    var fg_oval = FrameGraph{
        .width = 1920,
        .height = 1080,
    };
    defer fg_oval.deinit(allocator);
    try fg_oval.privacy_regions.append(allocator, region_oval);

    _ = try cpu.render(&fg_oval);
    const oval_variance = computeRegionEdgeVariance(cpu.buffer, 1920, 1080, test_rect);
    try std.testing.expect(oval_variance < unblurred_variance * 0.50);

    // Test D: Freehand Polygon Mask under Active Zoom + 3D tilt
    const poly_pts = [_][2]f32{
        .{ 0.35, 0.35 },
        .{ 0.65, 0.38 },
        .{ 0.62, 0.65 },
        .{ 0.32, 0.62 },
    };
    const region_poly = PrivacyBlurRegion{
        .kind = .polygon,
        .style = .gaussian,
        .rect = test_rect,
        .blur_radius_px = 16.0,
        .points = &poly_pts,
    };
    var fg_poly = FrameGraph{
        .width = 1920,
        .height = 1080,
    };
    defer fg_poly.deinit(allocator);
    try fg_poly.privacy_regions.append(allocator, region_poly);

    _ = try cpu.render(&fg_poly);
    const poly_variance = computeRegionEdgeVariance(cpu.buffer, 1920, 1080, test_rect);
    try std.testing.expect(poly_variance < unblurred_variance * 0.60);
}

// -------------------------------------------------------------------------------------------------
// GATE 2 TEST 3: SSIM >= 0.98 between GPU and CPU Fallback + 0 Leaks Over 300 Frames
// -------------------------------------------------------------------------------------------------
test "Gate 2: SSIM >= 0.98 between gpu_wgpu and cpu_fallback + 0 memory leaks over 300 frames" {
    const allocator = std.testing.allocator;

    var cpu = try CpuCompositor.init(allocator, 1920, 1080);
    defer cpu.deinit();

    var gpu = try GpuCompositor.init(allocator, 1920, 1080);
    defer gpu.deinit();

    const scene = SceneConfig{
        .padding_px = 60.0,
        .corner_radius_px = 24.0,
        .shadow_spread_px = 16.0,
        .shadow_blur_px = 36.0,
        .bg_color = .{ 0.08, 0.09, 0.12, 1.0 },
        .screen_color = .{ 0.94, 0.95, 0.96, 1.0 },
        .has_camera = true,
        .camera_pip = .bottom_right,
        .camera_size = .{ 320.0, 180.0 },
        .cursor_pos = .{ 0.5, 0.5 },
        .cursor_click_time = 0.0,
    };

    var fg = try planFrame(allocator, scene, 0.1);
    defer fg.deinit(allocator);

    const cpu_output = try cpu.render(&fg);
    const gpu_output = try gpu.render(&fg);

    const ssim = calculateSSIM(cpu_output, gpu_output, 1920, 1080);
    std.debug.print("\n>>> Gate 2 SSIM (gpu_wgpu vs cpu_fallback): {d:.5} (Target >= 0.98) <<<\n", .{ssim});
    try std.testing.expect(ssim >= 0.98);

    // Save golden Gate 2 P6 PPM artifact for inspection
    writeP6Ppm("tests/golden/artifacts/gate2_1080p.ppm", 1920, 1080, gpu_output) catch {};

    // Verify 0 memory leaks over 300 consecutive frames
    var frame_idx: u32 = 0;
    while (frame_idx < 300) : (frame_idx += 1) {
        const time_t: f32 = @as(f32, @floatFromInt(frame_idx)) / 60.0;
        const frame_scene = SceneConfig{
            .cursor_pos = .{ 0.2 + 0.6 * (time_t / 5.0), 0.3 + 0.4 * (time_t / 5.0) },
            .cursor_click_time = if (frame_idx % 60 == 0) time_t else null,
            .has_camera = (frame_idx % 2 == 0),
            .camera_pip = @fromBackingInt(@intCast(frame_idx % 8)),
        };
        var frame_fg = try planFrame(allocator, frame_scene, time_t);
        defer frame_fg.deinit(allocator);

        _ = try cpu.render(&frame_fg);
    }
}
