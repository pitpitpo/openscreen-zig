const std = @import("std");
pub const compositor = @import("compositor.zig");
pub const FrameGraph = compositor.FrameGraph;
pub const LayerCB = compositor.LayerCB;
pub const Modes = compositor.Modes;
pub const PrivacyBlurRegion = compositor.PrivacyBlurRegion;

/// Deterministic CPU reference rasterizer that evaluates the identical FrameGraph.
/// Produces 1080p (or custom resolution) 32-bit RGBA pixels in premultiplied alpha.
pub const CpuCompositor = struct {
    width: u32,
    height: u32,
    buffer: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !CpuCompositor {
        const size = @as(usize, width) * @as(usize, height) * 4;
        const buf = try allocator.alloc(u8, size);
        @memset(buf, 0);
        return .{
            .width = width,
            .height = height,
            .buffer = buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CpuCompositor) void {
        self.allocator.free(self.buffer);
    }

    pub fn render(self: *CpuCompositor, fg: *const FrameGraph) ![]const u8 {
        @memset(self.buffer, 0);

        for (fg.layers.items) |*layer| {
            self.rasterizeLayer(layer);
        }

        // Apply privacy blur regions if any
        for (fg.privacy_regions.items) |*region| {
            self.applyPrivacyBlur(region);
        }

        return self.buffer;
    }

    fn rasterizeLayer(self: *CpuCompositor, layer: *const LayerCB) void {
        const rw: f32 = @floatFromInt(self.width);
        const rh: f32 = @floatFromInt(self.height);

        const x0 = layer.dst[0] * rw;
        const y0 = layer.dst[1] * rh;
        const w = layer.dst[2] * rw;
        const h = layer.dst[3] * rh;

        const min_x = @max(0, @as(i32, @intFromFloat(@floor(x0))));
        const max_x = @min(@as(i32, @intCast(self.width)), @as(i32, @intFromFloat(@ceil(x0 + w))));
        const min_y = @max(0, @as(i32, @intFromFloat(@floor(y0))));
        const max_y = @min(@as(i32, @intCast(self.height)), @as(i32, @intFromFloat(@ceil(y0 + h))));

        if (min_x >= max_x or min_y >= max_y) return;

        const cx = x0 + w * 0.5;
        const cy = y0 + h * 0.5;
        const hw = w * 0.5;
        const hh = h * 0.5;
        const radius = layer.radius_px;

        if (layer.mode == Modes.SolidColorRect) {
            var y = min_y;
            while (y < max_y) : (y += 1) {
                const py: f32 = @as(f32, @floatFromInt(y)) + 0.5;
                var x = min_x;
                while (x < max_x) : (x += 1) {
                    const px: f32 = @as(f32, @floatFromInt(x)) + 0.5;

                    // Rounded rectangle SDF
                    const alpha = evalRoundedRectAlpha(px, py, cx, cy, hw, hh, radius);
                    if (alpha > 0) {
                        self.blendPixel(@intCast(x), @intCast(y), layer.color, alpha);
                    }
                }
            }
        } else if (layer.mode == Modes.DropShadow) {
            const spread = layer.fx[0];
            const blur = layer.fx[1];
            var y = min_y;
            while (y < max_y) : (y += 1) {
                const py: f32 = @as(f32, @floatFromInt(y)) + 0.5;
                var x = min_x;
                while (x < max_x) : (x += 1) {
                    const px: f32 = @as(f32, @floatFromInt(x)) + 0.5;
                    const alpha = evalDropShadowAlpha(px, py, cx, cy, hw - spread, hh - spread, radius, blur);
                    if (alpha > 0) {
                        self.blendPixel(@intCast(x), @intCast(y), layer.color, alpha);
                    }
                }
            }
        } else if (layer.mode == Modes.TiltedScreen3D or layer.mode == Modes.ProjectedShadow3D) {
            // 3D perspective quad defined by 4 corners in fx (TL, TR) and src_prev (BR, BL)
            const pTL = [2]f32{ layer.fx[0] * rw, layer.fx[1] * rh };
            const pTR = [2]f32{ layer.fx[2] * rw, layer.fx[3] * rh };
            const pBR = [2]f32{ layer.src_prev[0] * rw, layer.src_prev[1] * rh };
            const pBL = [2]f32{ layer.src_prev[2] * rw, layer.src_prev[3] * rh };

            const quad = [4][2]f32{ pTL, pTR, pBR, pBL };
            const q_min_x = @max(0, @as(i32, @intFromFloat(@floor(@min(@min(pTL[0], pTR[0]), @min(pBR[0], pBL[0]))))));
            const q_max_x = @min(@as(i32, @intCast(self.width)), @as(i32, @intFromFloat(@ceil(@max(@max(pTL[0], pTR[0]), @max(pBR[0], pBL[0]))))));
            const q_min_y = @max(0, @as(i32, @intFromFloat(@floor(@min(@min(pTL[1], pTR[1]), @min(pBR[1], pBL[1]))))));
            const q_max_y = @min(@as(i32, @intCast(self.height)), @as(i32, @intFromFloat(@ceil(@max(@max(pTL[1], pTR[1]), @max(pBR[1], pBL[1]))))));

            var y = q_min_y;
            while (y < q_max_y) : (y += 1) {
                const py: f32 = @as(f32, @floatFromInt(y)) + 0.5;
                var x = q_min_x;
                while (x < q_max_x) : (x += 1) {
                    const px: f32 = @as(f32, @floatFromInt(x)) + 0.5;
                    const alpha = evalConvexQuadAlpha(px, py, quad);
                    if (alpha > 0) {
                        self.blendPixel(@intCast(x), @intCast(y), layer.color, alpha);
                    }
                }
            }
        } else if (layer.mode == Modes.ClickRipple) {
            const cur_r = layer.radius_px;
            const ring_thick: f32 = 4.0;
            var y = min_y;
            while (y < max_y) : (y += 1) {
                const py: f32 = @as(f32, @floatFromInt(y)) + 0.5;
                var x = min_x;
                while (x < max_x) : (x += 1) {
                    const px: f32 = @as(f32, @floatFromInt(x)) + 0.5;
                    const d = std.math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
                    const diff = @abs(d - cur_r);
                    if (diff < ring_thick) {
                        const alpha = (1.0 - diff / ring_thick) * layer.color[3];
                        self.blendPixel(@intCast(x), @intCast(y), layer.color, alpha);
                    }
                }
            }
        }
    }

    fn applyPrivacyBlur(self: *CpuCompositor, region: *const PrivacyBlurRegion) void {
        const rw: f32 = @floatFromInt(self.width);
        const rh: f32 = @floatFromInt(self.height);

        const rx = region.rect[0] * rw;
        const ry = region.rect[1] * rh;
        const rw_box = region.rect[2] * rw;
        const rh_box = region.rect[3] * rh;

        const min_x = @max(0, @as(i32, @intFromFloat(@floor(rx))));
        const max_x = @min(@as(i32, @intCast(self.width)), @as(i32, @intFromFloat(@ceil(rx + rw_box))));
        const min_y = @max(0, @as(i32, @intFromFloat(@floor(ry))));
        const max_y = @min(@as(i32, @intCast(self.height)), @as(i32, @intFromFloat(@ceil(ry + rh_box))));

        if (min_x >= max_x or min_y >= max_y) return;

        const cx = rx + rw_box * 0.5;
        const cy = ry + rh_box * 0.5;
        const a_rad = rw_box * 0.5;
        const b_rad = rh_box * 0.5;

        if (region.style == .mosaic) {
            const block_size = @as(usize, @intFromFloat(@max(4.0, region.blur_radius_px)));
            const u_min_x: usize = @intCast(min_x);
            const u_max_x: usize = @intCast(max_x);
            const u_min_y: usize = @intCast(min_y);
            const u_max_y: usize = @intCast(max_y);
            var by = u_min_y;
            while (by < u_max_y) : (by += block_size) {
                var bx = u_min_x;
                while (bx < u_max_x) : (bx += block_size) {
                    const b_end_x = @min(bx + block_size, u_max_x);
                    const b_end_y = @min(by + block_size, u_max_y);

                    // Average color in block
                    var sum_r: u32 = 0;
                    var sum_g: u32 = 0;
                    var sum_b: u32 = 0;
                    var count: u32 = 0;

                    var py = by;
                    while (py < b_end_y) : (py += 1) {
                        var px = bx;
                        while (px < b_end_x) : (px += 1) {
                            if (self.pointInsideMask(@floatFromInt(px), @floatFromInt(py), region, cx, cy, a_rad, b_rad, rw, rh)) {
                                const idx = (py * self.width + px) * 4;
                                sum_r += self.buffer[idx + 0];
                                sum_g += self.buffer[idx + 1];
                                sum_b += self.buffer[idx + 2];
                                count += 1;
                            }
                        }
                    }

                    if (count > 0) {
                        const avg_r = @as(u8, @intCast(sum_r / count));
                        const avg_g = @as(u8, @intCast(sum_g / count));
                        const avg_b = @as(u8, @intCast(sum_b / count));

                        py = by;
                        while (py < b_end_y) : (py += 1) {
                            var px = bx;
                            while (px < b_end_x) : (px += 1) {
                                if (self.pointInsideMask(@floatFromInt(px), @floatFromInt(py), region, cx, cy, a_rad, b_rad, rw, rh)) {
                                    const idx = (py * self.width + px) * 4;
                                    self.buffer[idx + 0] = avg_r;
                                    self.buffer[idx + 1] = avg_g;
                                    self.buffer[idx + 2] = avg_b;
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // Gaussian / box blur
            const rad = @as(i32, @intFromFloat(@max(2.0, region.blur_radius_px)));
            var y = min_y;
            while (y < max_y) : (y += 1) {
                var x = min_x;
                while (x < max_x) : (x += 1) {
                    if (self.pointInsideMask(@floatFromInt(x), @floatFromInt(y), region, cx, cy, a_rad, b_rad, rw, rh)) {
                        var sum_r: u32 = 0;
                        var sum_g: u32 = 0;
                        var sum_b: u32 = 0;
                        var count: u32 = 0;

                        var dy = -rad;
                        while (dy <= rad) : (dy += 2) {
                            const sy = @as(i32, @intCast(y)) + dy;
                            if (sy < 0 or sy >= self.height) continue;
                            var dx = -rad;
                            while (dx <= rad) : (dx += 2) {
                                const sx = @as(i32, @intCast(x)) + dx;
                                if (sx < 0 or sx >= self.width) continue;
                                const idx = (@as(usize, @intCast(sy)) * self.width + @as(usize, @intCast(sx))) * 4;
                                sum_r += self.buffer[idx + 0];
                                sum_g += self.buffer[idx + 1];
                                sum_b += self.buffer[idx + 2];
                                count += 1;
                            }
                        }

                        if (count > 0) {
                            const idx = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
                            self.buffer[idx + 0] = @as(u8, @intCast(sum_r / count));
                            self.buffer[idx + 1] = @as(u8, @intCast(sum_g / count));
                            self.buffer[idx + 2] = @as(u8, @intCast(sum_b / count));
                        }
                    }
                }
            }
        }
    }

    fn pointInsideMask(
        self: *const CpuCompositor,
        px: f32,
        py: f32,
        region: *const PrivacyBlurRegion,
        cx: f32,
        cy: f32,
        a_rad: f32,
        b_rad: f32,
        rw: f32,
        rh: f32,
    ) bool {
        _ = self;
        switch (region.kind) {
            .rect => return true,
            .oval => {
                const nx = (px - cx) / a_rad;
                const ny = (py - cy) / b_rad;
                return (nx * nx + ny * ny) <= 1.0;
            },
            .polygon => {
                if (region.points) |pts| {
                    if (pts.len < 3) return true;
                    var inside = false;
                    var i: usize = 0;
                    var j: usize = pts.len - 1;
                    while (i < pts.len) : ({
                        j = i;
                        i += 1;
                    }) {
                        const xi = pts[i][0] * rw;
                        const yi = pts[i][1] * rh;
                        const xj = pts[j][0] * rw;
                        const yj = pts[j][1] * rh;
                        const intersect = ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi);
                        if (intersect) inside = !inside;
                    }
                    return inside;
                }
                return true;
            },
        }
    }

    fn blendPixel(self: *CpuCompositor, x: u32, y: u32, color: [4]f32, alpha: f32) void {
        const idx = (@as(usize, y) * self.width + @as(usize, x)) * 4;

        const src_a = color[3] * alpha;
        const src_r = color[0] * src_a;
        const src_g = color[1] * src_a;
        const src_b = color[2] * src_a;

        const dst_r = @as(f32, @floatFromInt(self.buffer[idx + 0])) / 255.0;
        const dst_g = @as(f32, @floatFromInt(self.buffer[idx + 1])) / 255.0;
        const dst_b = @as(f32, @floatFromInt(self.buffer[idx + 2])) / 255.0;
        const dst_a = @as(f32, @floatFromInt(self.buffer[idx + 3])) / 255.0;

        // Premultiplied alpha composite
        const out_r = src_r + dst_r * (1.0 - src_a);
        const out_g = src_g + dst_g * (1.0 - src_a);
        const out_b = src_b + dst_b * (1.0 - src_a);
        const out_a = src_a + dst_a * (1.0 - src_a);

        self.buffer[idx + 0] = @as(u8, @intFromFloat(@min(255.0, @max(0.0, out_r * 255.0 + 0.5))));
        self.buffer[idx + 1] = @as(u8, @intFromFloat(@min(255.0, @max(0.0, out_g * 255.0 + 0.5))));
        self.buffer[idx + 2] = @as(u8, @intFromFloat(@min(255.0, @max(0.0, out_b * 255.0 + 0.5))));
        self.buffer[idx + 3] = @as(u8, @intFromFloat(@min(255.0, @max(0.0, out_a * 255.0 + 0.5))));
    }
};

fn evalRoundedRectAlpha(px: f32, py: f32, cx: f32, cy: f32, hw: f32, hh: f32, r: f32) f32 {
    const qx = @abs(px - cx) - (hw - r);
    const qy = @abs(py - cy) - (hh - r);

    const ax = @max(qx, 0.0);
    const ay = @max(qy, 0.0);
    const dist = std.math.sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0.0) - r;

    return std.math.clamp(0.5 - dist, 0.0, 1.0);
}

fn evalDropShadowAlpha(px: f32, py: f32, cx: f32, cy: f32, hw: f32, hh: f32, r: f32, blur: f32) f32 {
    const qx = @abs(px - cx) - (hw - r);
    const qy = @abs(py - cy) - (hh - r);
    const ax = @max(qx, 0.0);
    const ay = @max(qy, 0.0);
    const dist = std.math.sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0.0) - r;

    if (dist <= 0) return 1.0;
    if (dist >= blur) return 0.0;
    const sigma = blur * 0.45;
    return @exp(-0.5 * (dist / sigma) * (dist / sigma));
}

fn evalConvexQuadAlpha(px: f32, py: f32, quad: [4][2]f32) f32 {
    var min_dist: f32 = 1e9;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const next = (i + 1) % 4;
        const p1 = quad[i];
        const p2 = quad[next];
        const ex = p2[0] - p1[0];
        const ey = p2[1] - p1[1];
        const cross = (px - p1[0]) * ey - (py - p1[1]) * ex;
        if (cross < -0.5) return 0.0; // Outside convex hull
        const len = std.math.sqrt(ex * ex + ey * ey);
        if (len > 0.001) {
            min_dist = @min(min_dist, cross / len);
        }
    }
    return std.math.clamp(min_dist + 0.5, 0.0, 1.0);
}

/// Helper function to save RGBA buffer to P6 PPM format
pub fn writeP6Ppm(path: []const u8, width: u32, height: u32, rgba: []const u8) !void {
    var path_buf: [1024:0]u8 = undefined;
    if (path.len >= 1024) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const file = std.c.fopen(&path_buf, "wb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height }) catch return error.HeaderFormatFailed;
    _ = std.c.fwrite(header.ptr, 1, header.len, file);

    var row_buf: [3840 * 3]u8 = undefined;
    const row_bytes = @as(usize, width) * 3;
    if (row_bytes <= row_buf.len) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const src_idx = (@as(usize, y) * width + @as(usize, x)) * 4;
                const dst_idx = @as(usize, x) * 3;
                row_buf[dst_idx + 0] = rgba[src_idx + 0];
                row_buf[dst_idx + 1] = rgba[src_idx + 1];
                row_buf[dst_idx + 2] = rgba[src_idx + 2];
            }
            _ = std.c.fwrite(&row_buf, 1, row_bytes, file);
        }
    } else {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const idx = (@as(usize, y) * width + @as(usize, x)) * 4;
                const rgb = [3]u8{ rgba[idx + 0], rgba[idx + 1], rgba[idx + 2] };
                _ = std.c.fwrite(&rgb, 1, 3, file);
            }
        }
    }
}
