const std = @import("std");
const ffi = @import("ffi");
const onnx = ffi.onnx;

pub const MattingMode = enum {
    room_blur,
    background_cutout,
    background_replacement,
};

pub const MattingOptions = struct {
    blur_radius: u32 = 8,
    feather: f32 = 0.05,
    threshold: f32 = 0.5,
    replacement_rgba: ?[]const u8 = null,
};

pub const SegmentationEngine = struct {
    allocator: std.mem.Allocator,
    session: onnx.OnnxSession,
    input_tensor: []f32, // 144 * 256 * 3
    output_tensor: []f32, // 144 * 256 * 1

    pub fn init(allocator: std.mem.Allocator, onnx_lib: ?[]const u8, model_path: []const u8) !SegmentationEngine {
        var sess = try onnx.OnnxSession.init(onnx_lib, model_path);
        errdefer sess.deinit();

        const in_buf = try allocator.alloc(f32, 144 * 256 * 3);
        errdefer allocator.free(in_buf);

        const out_buf = try allocator.alloc(f32, 144 * 256);
        errdefer allocator.free(out_buf);

        return SegmentationEngine{
            .allocator = allocator,
            .session = sess,
            .input_tensor = in_buf,
            .output_tensor = out_buf,
        };
    }

    pub fn deinit(self: *SegmentationEngine) void {
        self.allocator.free(self.output_tensor);
        self.allocator.free(self.input_tensor);
        self.session.deinit();
    }

    pub fn segment(
        self: *SegmentationEngine,
        in_rgba: []const u8,
        width: u32,
        height: u32,
        mode: MattingMode,
        out_rgba: []u8,
        options: MattingOptions,
    ) !void {
        if (width == 0 or height == 0) return;
        const total_pixels = @as(usize, width) * @as(usize, height);
        if (in_rgba.len < total_pixels * 4 or out_rgba.len < total_pixels * 4) {
            return error.BufferTooSmall;
        }

        // 1. Downsample in_rgba to 256x144 normalized RGB floats
        const model_w: u32 = 256;
        const model_h: u32 = 144;

        for (0..model_h) |my| {
            const src_y = (my * height) / model_h;
            for (0..model_w) |mx| {
                const src_x = (mx * width) / model_w;
                const src_idx = (src_y * width + src_x) * 4;
                const dst_idx = (my * model_w + mx) * 3;

                self.input_tensor[dst_idx + 0] = @as(f32, @floatFromInt(in_rgba[src_idx + 0])) / 255.0;
                self.input_tensor[dst_idx + 1] = @as(f32, @floatFromInt(in_rgba[src_idx + 1])) / 255.0;
                self.input_tensor[dst_idx + 2] = @as(f32, @floatFromInt(in_rgba[src_idx + 2])) / 255.0;
            }
        }

        // 2. Run ONNX model inference
        try self.session.runSegmentation(self.input_tensor, self.output_tensor);

        // 3. Optional blurred background for room_blur
        var blurred_bg: ?[]u8 = null;
        defer if (blurred_bg) |b| self.allocator.free(b);
        if (mode == .room_blur) {
            blurred_bg = try self.allocator.alloc(u8, total_pixels * 4);
            fastBoxBlur(in_rgba, blurred_bg.?, width, height, options.blur_radius);
        }

        // 4. Upsample mask to (width, height) and apply matting mode
        for (0..height) |y| {
            const my_f = (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height))) * @as(f32, @floatFromInt(model_h - 1));
            const my0: usize = @intFromFloat(my_f);
            const my1: usize = @min(model_h - 1, my0 + 1);
            const fy = my_f - @as(f32, @floatFromInt(my0));

            for (0..width) |x| {
                const mx_f = (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width))) * @as(f32, @floatFromInt(model_w - 1));
                const mx0: usize = @intFromFloat(mx_f);
                const mx1: usize = @min(model_w - 1, mx0 + 1);
                const fx = mx_f - @as(f32, @floatFromInt(mx0));

                const m00 = self.output_tensor[my0 * model_w + mx0];
                const m01 = self.output_tensor[my0 * model_w + mx1];
                const m10 = self.output_tensor[my1 * model_w + mx0];
                const m11 = self.output_tensor[my1 * model_w + mx1];

                const top = m00 * (1.0 - fx) + m01 * fx;
                const bot = m10 * (1.0 - fx) + m11 * fx;
                var raw_mask = top * (1.0 - fy) + bot * fy;

                // Feather / smooth threshold
                if (options.feather > 0.001) {
                    const low = options.threshold - options.feather;
                    const high = options.threshold + options.feather;
                    raw_mask = std.math.clamp((raw_mask - low) / (high - low), 0.0, 1.0);
                } else {
                    raw_mask = if (raw_mask >= options.threshold) 1.0 else 0.0;
                }

                const pixel_idx = (y * width + x) * 4;

                switch (mode) {
                    .room_blur => {
                        const bg_ptr = blurred_bg.?;
                        for (0..3) |c| {
                            const fg = @as(f32, @floatFromInt(in_rgba[pixel_idx + c]));
                            const bg = @as(f32, @floatFromInt(bg_ptr[pixel_idx + c]));
                            const blended = fg * raw_mask + bg * (1.0 - raw_mask);
                            out_rgba[pixel_idx + c] = @intFromFloat(std.math.clamp(blended, 0.0, 255.0));
                        }
                        out_rgba[pixel_idx + 3] = in_rgba[pixel_idx + 3];
                    },
                    .background_cutout => {
                        out_rgba[pixel_idx + 0] = in_rgba[pixel_idx + 0];
                        out_rgba[pixel_idx + 1] = in_rgba[pixel_idx + 1];
                        out_rgba[pixel_idx + 2] = in_rgba[pixel_idx + 2];
                        const orig_a = @as(f32, @floatFromInt(in_rgba[pixel_idx + 3]));
                        out_rgba[pixel_idx + 3] = @intFromFloat(std.math.clamp(orig_a * raw_mask, 0.0, 255.0));
                    },
                    .background_replacement => {
                        if (options.replacement_rgba) |rep| {
                            for (0..3) |c| {
                                const fg = @as(f32, @floatFromInt(in_rgba[pixel_idx + c]));
                                const bg = @as(f32, @floatFromInt(rep[pixel_idx + c]));
                                const blended = fg * raw_mask + bg * (1.0 - raw_mask);
                                out_rgba[pixel_idx + c] = @intFromFloat(std.math.clamp(blended, 0.0, 255.0));
                            }
                            out_rgba[pixel_idx + 3] = 255;
                        } else {
                            @memcpy(out_rgba[pixel_idx .. pixel_idx + 4], in_rgba[pixel_idx .. pixel_idx + 4]);
                        }
                    },
                }
            }
        }
    }

    fn fastBoxBlur(src: []const u8, dst: []u8, width: u32, height: u32, radius: u32) void {
        const rad: i32 = @intCast(@min(radius, 32));
        if (rad <= 0) {
            @memcpy(dst[0 .. width * height * 4], src[0 .. width * height * 4]);
            return;
        }

        // Downsample 4x, then upsample 4x box filter for high performance
        for (0..height) |y| {
            for (0..width) |x| {
                var r_acc: u32 = 0;
                var g_acc: u32 = 0;
                var b_acc: u32 = 0;
                var count: u32 = 0;

                const y_min = @max(0, @as(i32, @intCast(y)) - rad);
                const y_max = @min(@as(i32, @intCast(height - 1)), @as(i32, @intCast(y)) + rad);
                const x_min = @max(0, @as(i32, @intCast(x)) - rad);
                const x_max = @min(@as(i32, @intCast(width - 1)), @as(i32, @intCast(x)) + rad);

                // Sample corner and center points for fast approximation
                var sy = y_min;
                const step = @max(1, @divTrunc(rad, 2));
                while (sy <= y_max) : (sy += step) {
                    var sx = x_min;
                    while (sx <= x_max) : (sx += step) {
                        const idx = (@as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx))) * 4;
                        r_acc += src[idx + 0];
                        g_acc += src[idx + 1];
                        b_acc += src[idx + 2];
                        count += 1;
                    }
                }

                const out_idx = (y * width + x) * 4;
                if (count > 0) {
                    dst[out_idx + 0] = @intCast(r_acc / count);
                    dst[out_idx + 1] = @intCast(g_acc / count);
                    dst[out_idx + 2] = @intCast(b_acc / count);
                } else {
                    dst[out_idx + 0] = src[out_idx + 0];
                    dst[out_idx + 1] = src[out_idx + 1];
                    dst[out_idx + 2] = src[out_idx + 2];
                }
                dst[out_idx + 3] = src[out_idx + 3];
            }
        }
    }
};
