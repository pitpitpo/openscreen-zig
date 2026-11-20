const std = @import("std");
const ffi = @import("ffi");

// DVUI - Direct Value User Interface for OpenScreen (Zig 0.17 strictly NO @cImport)

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Size = struct {
    w: f32,
    h: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, pt: Point) bool {
        return pt.x >= (self.x - 0.01) and pt.x <= (self.x + self.w + 0.01) and
            pt.y >= (self.y - 0.01) and pt.y <= (self.y + self.h + 0.01);
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return !(self.x + self.w <= other.x or other.x + other.w <= self.x or
            self.y + self.h <= other.y or other.y + other.h <= self.y);
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
};

pub const Theme = struct {
    bg_primary: Color = .{ .r = 17, .g = 24, .b = 39, .a = 255 },
    bg_secondary: Color = .{ .r = 31, .g = 41, .b = 55, .a = 255 },
    bg_card: Color = .{ .r = 55, .g = 65, .b = 81, .a = 255 },
    border: Color = .{ .r = 75, .g = 85, .b = 99, .a = 255 },
    text_primary: Color = .{ .r = 243, .g = 244, .b = 246, .a = 255 },
    text_secondary: Color = .{ .r = 156, .g = 163, .b = 175, .a = 255 },
    accent_red: Color = .{ .r = 239, .g = 68, .b = 68, .a = 255 },
    accent_blue: Color = .{ .r = 59, .g = 130, .b = 246, .a = 255 },
    accent_purple: Color = .{ .r = 139, .g = 92, .b = 246, .a = 255 },
    accent_green: Color = .{ .r = 16, .g = 185, .b = 129, .a = 255 },
    accent_amber: Color = .{ .r = 245, .g = 158, .b = 11, .a = 255 },
};

pub const Event = union(enum) {
    mouse_move: Point,
    mouse_down: struct { pt: Point, button: u8 },
    mouse_up: struct { pt: Point, button: u8 },
    scroll: struct { dx: f32, dy: f32 },
    key_down: struct { key: u32, ctrl: bool, shift: bool },
};

pub const TrackedWidget = struct {
    id: []const u8,
    rect: Rect,
};

pub const FrameBuffer = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,
    ttf_bytes: ?[]u8 = null,
    ttf_font: ?ffi.font.TrueTypeFont = null,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !FrameBuffer {
        const size = @as(usize, w) * h * 4;
        const pixels = try allocator.alloc(u8, size);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = w,
            .height = h,
            .pixels = pixels,
            .ttf_bytes = null,
            .ttf_font = null,
        };
    }

    pub fn setFont(self: *FrameBuffer, bytes: []u8) void {
        if (self.ttf_font) |*f| {
            f.deinit();
            self.ttf_font = null;
        }
        if (self.ttf_bytes) |b| {
            self.allocator.free(b);
            self.ttf_bytes = null;
        }
        self.ttf_bytes = bytes;
        self.ttf_font = ffi.font.TrueTypeFont.init(bytes);
    }

    pub fn deinit(self: *FrameBuffer) void {
        if (self.ttf_font) |*f| {
            f.deinit();
            self.ttf_font = null;
        }
        if (self.ttf_bytes) |b| {
            self.allocator.free(b);
            self.ttf_bytes = null;
        }
        self.allocator.free(self.pixels);
    }

    pub fn blendPixel(self: *FrameBuffer, px: i32, py: i32, c: Color, alpha: u8) void {
        if (px < 0 or py < 0 or px >= @as(i32, @intCast(self.width)) or py >= @as(i32, @intCast(self.height))) return;
        if (alpha == 0) return;
        const idx = (@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))) * 4;
        if (alpha == 255) {
            self.pixels[idx + 0] = c.r;
            self.pixels[idx + 1] = c.g;
            self.pixels[idx + 2] = c.b;
            self.pixels[idx + 3] = c.a;
            return;
        }
        const a_f = @as(u32, alpha);
        const inv_a = 255 - a_f;
        self.pixels[idx + 0] = @intCast((@as(u32, c.r) * a_f + @as(u32, self.pixels[idx + 0]) * inv_a) / 255);
        self.pixels[idx + 1] = @intCast((@as(u32, c.g) * a_f + @as(u32, self.pixels[idx + 1]) * inv_a) / 255);
        self.pixels[idx + 2] = @intCast((@as(u32, c.b) * a_f + @as(u32, self.pixels[idx + 2]) * inv_a) / 255);
        self.pixels[idx + 3] = @max(self.pixels[idx + 3], alpha);
    }

    pub fn resize(self: *FrameBuffer, new_w: u32, new_h: u32) !void {
        if (self.width == new_w and self.height == new_h) return;
        const new_size = @as(usize, new_w) * new_h * 4;
        const new_pixels = try self.allocator.alloc(u8, new_size);
        @memset(new_pixels, 0);
        self.allocator.free(self.pixels);
        self.pixels = new_pixels;
        self.width = new_w;
        self.height = new_h;
    }

    pub fn clear(self: *FrameBuffer, c: Color) void {
        const total = @as(usize, self.width) * self.height;
        const slice_colors: [][4]u8 = @as([*][4]u8, @ptrCast(self.pixels.ptr))[0..total];
        @memset(slice_colors, [4]u8{ c.r, c.g, c.b, c.a });
    }

    pub fn fillRect(self: *FrameBuffer, rect: Rect, c: Color) void {
        const x0 = @max(0, @min(@as(i32, @intFromFloat(rect.x)), @as(i32, @intCast(self.width))));
        const y0 = @max(0, @min(@as(i32, @intFromFloat(rect.y)), @as(i32, @intCast(self.height))));
        const x1 = @max(0, @min(@as(i32, @intFromFloat(rect.x + rect.w)), @as(i32, @intCast(self.width))));
        const y1 = @max(0, @min(@as(i32, @intFromFloat(rect.y + rect.h)), @as(i32, @intCast(self.height))));

        if (x1 <= x0 or y1 <= y0) return;

        var y: usize = @intCast(y0);
        const y_end: usize = @intCast(y1);
        const x_start: usize = @intCast(x0);
        const x_end: usize = @intCast(x1);
        const scanline_w = x_end - x_start;

        while (y < y_end) : (y += 1) {
            const off = (y * self.width + x_start) * 4;
            if (c.a == 255) {
                const scan_slice: [][4]u8 = @as([*][4]u8, @ptrCast(&self.pixels[off]))[0..scanline_w];
                @memset(scan_slice, [4]u8{ c.r, c.g, c.b, 255 });
            } else {
                var x: usize = x_start;
                while (x < x_end) : (x += 1) {
                    const px_off = (y * self.width + x) * 4;
                    const alpha = @as(u32, c.a);
                    const inv_alpha = 255 - alpha;
                    self.pixels[px_off + 0] = @intCast((@as(u32, c.r) * alpha + @as(u32, self.pixels[px_off + 0]) * inv_alpha) / 255);
                    self.pixels[px_off + 1] = @intCast((@as(u32, c.g) * alpha + @as(u32, self.pixels[px_off + 1]) * inv_alpha) / 255);
                    self.pixels[px_off + 2] = @intCast((@as(u32, c.b) * alpha + @as(u32, self.pixels[px_off + 2]) * inv_alpha) / 255);
                    self.pixels[px_off + 3] = 255;
                }
            }
        }
    }

    pub fn drawBorder(self: *FrameBuffer, rect: Rect, c: Color, thickness: f32) void {
        const t = thickness;
        // Top
        self.fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t }, c);
        // Bottom
        self.fillRect(.{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t }, c);
        // Left
        self.fillRect(.{ .x = rect.x, .y = rect.y, .w = t, .h = rect.h }, c);
        // Right
        self.fillRect(.{ .x = rect.x + rect.w - t, .y = rect.y, .w = t, .h = rect.h }, c);
    }

    pub fn drawChar(self: *FrameBuffer, char: u8, x: i32, y: i32, scale: i32, c: Color) void {
        self.drawGlyph(@as(u21, char), x, y, scale, c);
    }

    pub fn drawBitmapGlyph(self: *FrameBuffer, cp: u21, x: i32, y: i32, scale: i32, c: Color) void {
        const glyph_data = getGlyphPattern(cp);
        var row: usize = 0;
        while (row < 8) : (row += 1) {
            var col: usize = 0;
            while (col < 8) : (col += 1) {
                const shift: u3 = @intCast(7 - col);
                const bit = (glyph_data[row] >> shift) & 1;
                if (bit == 1) {
                    const rx: f32 = @floatFromInt(x + @as(i32, @intCast(col)) * scale);
                    const ry: f32 = @floatFromInt(y + @as(i32, @intCast(row)) * scale);
                    const rw: f32 = @floatFromInt(scale);
                    self.fillRect(.{ .x = rx, .y = ry, .w = rw, .h = rw }, c);
                }
            }
        }
    }

    pub fn drawGlyph(self: *FrameBuffer, cp: u21, x: i32, y: i32, scale: i32, c: Color) void {
        if (self.ttf_font) |*font| {
            var glyph_bmp = font.renderGlyph(@as(u32, cp), @as(f32, @floatFromInt(scale * 10)));
            if (glyph_bmp) |*bmp| {
                defer bmp.deinit();
                var r: usize = 0;
                while (r < bmp.height) : (r += 1) {
                    var col: usize = 0;
                    while (col < bmp.width) : (col += 1) {
                        const alpha = bmp.pixels[r * bmp.width + col];
                        if (alpha > 0) {
                            self.blendPixel(x + bmp.xoff + @as(i32, @intCast(col)), y + 8 * scale + bmp.yoff + @as(i32, @intCast(r)), c, alpha);
                        }
                    }
                }
                return;
            }
        }

        self.drawBitmapGlyph(cp, x, y, scale, c);
    }

    pub fn drawText(self: *FrameBuffer, text: []const u8, x: f32, y: f32, scale: i32, c: Color, is_rtl: bool) void {
        const char_w = 7 * scale;
        var start_x = @as(i32, @intFromFloat(x));
        const py = @as(i32, @intFromFloat(y));

        var has_non_ascii = false;
        for (text) |b| {
            if (b >= 0x80) {
                has_non_ascii = true;
                break;
            }
        }

        if (!has_non_ascii) {
            // Fast zero-allocation path for ASCII
            if (is_rtl) {
                start_x += @intCast(text.len * @as(usize, @intCast(char_w)));
                for (text) |ch| {
                    start_x -= char_w;
                    self.drawBitmapGlyph(@as(u21, ch), start_x, py, scale, c);
                }
            } else {
                for (text) |ch| {
                    self.drawBitmapGlyph(@as(u21, ch), start_x, py, scale, c);
                    start_x += char_w;
                }
            }
            return;
        }

        // Fast stack buffer for Unicode / Arabic text
        var stack_buf: [256]u21 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(stack_buf[0..]));
        const shaped = shapeArabicText(fba.allocator(), text) catch return;

        if (is_rtl) {
            start_x += @intCast(shaped.len * @as(usize, @intCast(char_w)));
            for (shaped) |cp| {
                start_x -= char_w;
                self.drawGlyph(cp, start_x, py, scale, c);
            }
        } else {
            for (shaped) |cp| {
                self.drawGlyph(cp, start_x, py, scale, c);
                start_x += char_w;
            }
        }
    }

    pub fn encodeToPng(self: *const FrameBuffer, allocator: std.mem.Allocator) ![]u8 {
        return try ffi.ffmpeg.encodePng(allocator, self.pixels, self.width, self.height);
    }
};

pub const ArabicJoinKind = enum {
    none,
    right,
    dual,
};

pub fn getArabicJoinKind(cp: u21) ArabicJoinKind {
    return switch (cp) {
        // Dual-joining
        0x0628, // Baa
        0x062A, // Taa
        0x062B, // Thaa
        0x062C, // Jeem
        0x062D, // Haa
        0x062E, // Khaa
        0x0633, // Seen
        0x0634, // Sheen
        0x0635, // Saad
        0x0636, // Daad
        0x0637, // Taa
        0x0638, // Zaa
        0x0639, // Ain
        0x063A, // Ghain
        0x0641, // Faa
        0x0642, // Qaaf
        0x0643, // Kaaf
        0x0644, // Laam
        0x0645, // Meem
        0x0646, // Noon
        0x0647, // Haa
        0x064A, // Yaa
        => .dual,

        // Right-joining
        0x0622, // Alef Madda
        0x0623, // Alef Hamza Above
        0x0625, // Alef Hamza Below
        0x0627, // Alef
        0x0629, // Taa Marbuta
        0x062F, // Daal
        0x0630, // Dhaal
        0x0631, // Raa
        0x0632, // Zaay
        0x0648, // Waaw
        0x0649, // Alef Maksura
        => .right,

        else => .none,
    };
}

pub fn mapArabicForm(cp: u21, form_idx: usize) u21 {
    // form_idx: 0 = isolated, 1 = initial, 2 = medial, 3 = final
    return switch (cp) {
        0x0628 => ([4]u21{ 0xFE8F, 0xFE91, 0xFE92, 0xFE90 })[form_idx], // Baa
        0x062A => ([4]u21{ 0xFE95, 0xFE97, 0xFE98, 0xFE96 })[form_idx], // Taa
        0x062B => ([4]u21{ 0xFE99, 0xFE9B, 0xFE9C, 0xFE9A })[form_idx], // Thaa
        0x062C => ([4]u21{ 0xFE9D, 0xFE9F, 0xFEA0, 0xFE9E })[form_idx], // Jeem
        0x062D => ([4]u21{ 0xFEA1, 0xFEA3, 0xFEA4, 0xFEA2 })[form_idx], // Haa
        0x062E => ([4]u21{ 0xFEA5, 0xFEA7, 0xFEA8, 0xFEA6 })[form_idx], // Khaa
        0x0633 => ([4]u21{ 0xFEB1, 0xFEB3, 0xFEB4, 0xFEB2 })[form_idx], // Seen
        0x0634 => ([4]u21{ 0xFEB5, 0xFEB7, 0xFEB8, 0xFEB6 })[form_idx], // Sheen
        0x0635 => ([4]u21{ 0xFEB9, 0xFEBB, 0xFEBC, 0xFEBA })[form_idx], // Saad
        0x0636 => ([4]u21{ 0xFEBD, 0xFEBF, 0xFEC0, 0xFEBE })[form_idx], // Daad
        0x0637 => ([4]u21{ 0xFEC1, 0xFEC3, 0xFEC4, 0xFEC2 })[form_idx], // Taa
        0x0638 => ([4]u21{ 0xFEC5, 0xFEC7, 0xFEC8, 0xFEC6 })[form_idx], // Zaa
        0x0639 => ([4]u21{ 0xFEC9, 0xFECB, 0xFECC, 0xFECA })[form_idx], // Ain
        0x063A => ([4]u21{ 0xFECD, 0xFECF, 0xFED0, 0xFECE })[form_idx], // Ghain
        0x0641 => ([4]u21{ 0xFED1, 0xFED3, 0xFED4, 0xFED2 })[form_idx], // Faa
        0x0642 => ([4]u21{ 0xFED5, 0xFED7, 0xFED8, 0xFED6 })[form_idx], // Qaaf
        0x0643 => ([4]u21{ 0xFED9, 0xFEDB, 0xFEDC, 0xFEDA })[form_idx], // Kaaf
        0x0644 => ([4]u21{ 0xFEDD, 0xFEDF, 0xFEE0, 0xFEDE })[form_idx], // Laam
        0x0645 => ([4]u21{ 0xFEE1, 0xFEE3, 0xFEE4, 0xFEE2 })[form_idx], // Meem
        0x0646 => ([4]u21{ 0xFEE5, 0xFEE7, 0xFEE8, 0xFEE6 })[form_idx], // Noon
        0x0647 => ([4]u21{ 0xFEE9, 0xFEEB, 0xFEEC, 0xFEEA })[form_idx], // Haa
        0x064A => ([4]u21{ 0xFEF1, 0xFEF3, 0xFEF4, 0xFEF2 })[form_idx], // Yaa

        // Right-joining
        0x0622 => if (form_idx == 3 or form_idx == 2) 0xFE82 else 0xFE81,
        0x0623 => if (form_idx == 3 or form_idx == 2) 0xFE84 else 0xFE83,
        0x0625 => if (form_idx == 3 or form_idx == 2) 0xFE88 else 0xFE87,
        0x0627 => if (form_idx == 3 or form_idx == 2) 0xFE8E else 0xFE8D,
        0x0629 => if (form_idx == 3 or form_idx == 2) 0xFE94 else 0xFE93,
        0x062F => if (form_idx == 3 or form_idx == 2) 0xFEAA else 0xFEA9,
        0x0630 => if (form_idx == 3 or form_idx == 2) 0xFEAC else 0xFEAB,
        0x0631 => if (form_idx == 3 or form_idx == 2) 0xFEAE else 0xFEAD,
        0x0632 => if (form_idx == 3 or form_idx == 2) 0xFEB0 else 0xFEAF,
        0x0648 => if (form_idx == 3 or form_idx == 2) 0xFEEE else 0xFEED,
        0x0649 => 0xFEF0,

        else => cp,
    };
}

pub fn shapeArabicText(allocator: std.mem.Allocator, text: []const u8) ![]u21 {
    var raw_codepoints: std.ArrayListUnmanaged(u21) = .empty;
    defer raw_codepoints.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + cp_len > text.len) {
            try raw_codepoints.append(allocator, @as(u21, text[i]));
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch @as(u21, text[i]);
        try raw_codepoints.append(allocator, cp);
        i += cp_len;
    }

    var shaped: std.ArrayListUnmanaged(u21) = .empty;
    errdefer shaped.deinit(allocator);

    var idx: usize = 0;
    const cps = raw_codepoints.items;
    while (idx < cps.len) {
        const cp = cps[idx];
        const kind = getArabicJoinKind(cp);
        if (kind == .none) {
            try shaped.append(allocator, cp);
            idx += 1;
            continue;
        }

        // Check for Lam-Alef ligature (0x0644 followed by 0x0627, 0x0622, 0x0623, 0x0625)
        if (cp == 0x0644 and idx + 1 < cps.len and (cps[idx + 1] == 0x0627 or cps[idx + 1] == 0x0622 or cps[idx + 1] == 0x0623 or cps[idx + 1] == 0x0625)) {
            const prev_connects = (idx > 0 and getArabicJoinKind(cps[idx - 1]) == .dual);
            try shaped.append(allocator, if (prev_connects) 0xFEFC else 0xFEFB);
            idx += 2;
            continue;
        }

        const prev_connects = (idx > 0 and getArabicJoinKind(cps[idx - 1]) == .dual);
        const next_connects = (idx + 1 < cps.len and getArabicJoinKind(cps[idx + 1]) != .none);

        const form_idx: usize = if (prev_connects and next_connects and kind == .dual)
            2 // Medial
        else if (prev_connects)
            3 // Final
        else if (next_connects and kind == .dual)
            1 // Initial
        else
            0; // Isolated

        const shaped_cp = mapArabicForm(cp, form_idx);
        try shaped.append(allocator, shaped_cp);
        idx += 1;
    }

    return shaped.toOwnedSlice(allocator);
}

pub fn getGlyphPattern(cp: u21) [8]u8 {
    // 1. Arabic Presentation Forms-B (0xFE70..0xFEFC) with continuous cursive baseline at row 6
    if (cp >= 0xFE70 and cp <= 0xFEFC) {
        return switch (cp) {
            0xFEE3 => [8]u8{ 0x00, 0x00, 0x1C, 0x22, 0x22, 0x1C, 0xFE, 0x00 }, // Meem Initial (joins left)
            0xFEAE => [8]u8{ 0x00, 0x00, 0x00, 0x08, 0x18, 0x30, 0x7E, 0x80 }, // Raa Final (joins right)
            0xFEA3 => [8]u8{ 0x00, 0x1E, 0x24, 0x08, 0x10, 0x20, 0xFE, 0x00 }, // Haa Initial (joins left)
            0xFE92 => [8]u8{ 0x00, 0x00, 0x00, 0x08, 0x08, 0x08, 0xFF, 0x08 }, // Baa Medial (joins left & right, dot below)
            0xFE8E => [8]u8{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x3E, 0x00 }, // Alef Final (joins right)
            0xFE91 => [8]u8{ 0x00, 0x00, 0x00, 0x08, 0x08, 0x08, 0xFE, 0x08 }, // Baa Initial (joins left, dot below)
            0xFEDA => [8]u8{ 0x04, 0x04, 0x04, 0x24, 0x14, 0x0C, 0x7E, 0x00 }, // Kaaf Final (joins right)
            0xFED3 => [8]u8{ 0x08, 0x00, 0x1C, 0x22, 0x22, 0x1C, 0xFE, 0x00 }, // Faa Initial (dot above, joins left)
            0xFEF2 => [8]u8{ 0x00, 0x00, 0x00, 0x1C, 0x20, 0x1C, 0x7E, 0x24 }, // Yaa Final (joins right, 2 dots below)
            0xFEFB, 0xFEFC => [8]u8{ 0x24, 0x24, 0x18, 0x18, 0x24, 0x42, 0xFF, 0x00 }, // Lam-Alef Ligature
            else => [8]u8{ 0x00, 0x00, 0x18, 0x24, 0x24, 0x18, 0xFF, 0x00 }, // Generic connected Arabic glyph
        };
    }

    // 2. CJK Unified Ideographs & Kana/Hangul (0x3000..0xD7AF)
    if ((cp >= 0x3000 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7AF)) {
        return [8]u8{ 0x7E, 0x18, 0x3C, 0x5A, 0x18, 0x3C, 0x66, 0x42 }; // Clear CJK ideographic character
    }

    // 3. ASCII & Latin (32..127)
    const ch: u8 = if (cp < 128) @intCast(cp) else '?';
    return switch (ch) {
        'A' => [8]u8{ 0x18, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x00 },
        'B' => [8]u8{ 0x78, 0x44, 0x44, 0x78, 0x44, 0x44, 0x78, 0x00 },
        'C' => [8]u8{ 0x3C, 0x42, 0x40, 0x40, 0x40, 0x42, 0x3C, 0x00 },
        'D' => [8]u8{ 0x78, 0x44, 0x42, 0x42, 0x42, 0x44, 0x78, 0x00 },
        'E' => [8]u8{ 0x7E, 0x40, 0x40, 0x78, 0x40, 0x40, 0x7E, 0x00 },
        'F' => [8]u8{ 0x7E, 0x40, 0x40, 0x78, 0x40, 0x40, 0x40, 0x00 },
        'G' => [8]u8{ 0x3C, 0x42, 0x40, 0x4E, 0x42, 0x42, 0x3C, 0x00 },
        'H' => [8]u8{ 0x42, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x00 },
        'I' => [8]u8{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        'J' => [8]u8{ 0x1E, 0x06, 0x06, 0x06, 0x06, 0x46, 0x3C, 0x00 },
        'K' => [8]u8{ 0x44, 0x48, 0x50, 0x60, 0x50, 0x48, 0x44, 0x00 },
        'L' => [8]u8{ 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7E, 0x00 },
        'M' => [8]u8{ 0x42, 0x66, 0x5A, 0x42, 0x42, 0x42, 0x42, 0x00 },
        'N' => [8]u8{ 0x42, 0x62, 0x52, 0x4A, 0x46, 0x42, 0x42, 0x00 },
        'O' => [8]u8{ 0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00 },
        'P' => [8]u8{ 0x7C, 0x42, 0x42, 0x7C, 0x40, 0x40, 0x40, 0x00 },
        'Q' => [8]u8{ 0x3C, 0x42, 0x42, 0x42, 0x4A, 0x44, 0x3A, 0x00 },
        'R' => [8]u8{ 0x7C, 0x42, 0x42, 0x7C, 0x50, 0x48, 0x44, 0x00 },
        'S' => [8]u8{ 0x3C, 0x42, 0x40, 0x3C, 0x02, 0x42, 0x3C, 0x00 },
        'T' => [8]u8{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 },
        'U' => [8]u8{ 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00 },
        'V' => [8]u8{ 0x42, 0x42, 0x42, 0x42, 0x42, 0x24, 0x18, 0x00 },
        'W' => [8]u8{ 0x42, 0x42, 0x42, 0x42, 0x5A, 0x66, 0x42, 0x00 },
        'X' => [8]u8{ 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x42, 0x00 },
        'Y' => [8]u8{ 0x42, 0x42, 0x24, 0x18, 0x18, 0x18, 0x18, 0x00 },
        'Z' => [8]u8{ 0x7E, 0x04, 0x08, 0x10, 0x20, 0x40, 0x7E, 0x00 },
        'a'...'z' => [8]u8{ 0x00, 0x00, 0x3C, 0x02, 0x3E, 0x42, 0x3E, 0x00 },
        '0' => [8]u8{ 0x3C, 0x46, 0x4A, 0x52, 0x62, 0x42, 0x3C, 0x00 },
        '1' => [8]u8{ 0x18, 0x28, 0x08, 0x08, 0x08, 0x08, 0x3E, 0x00 },
        '2' => [8]u8{ 0x3C, 0x42, 0x02, 0x0C, 0x30, 0x40, 0x7E, 0x00 },
        '3' => [8]u8{ 0x3C, 0x42, 0x02, 0x1C, 0x02, 0x42, 0x3C, 0x00 },
        '4' => [8]u8{ 0x08, 0x18, 0x28, 0x48, 0x7E, 0x08, 0x08, 0x00 },
        '5' => [8]u8{ 0x7E, 0x40, 0x7C, 0x02, 0x02, 0x42, 0x3C, 0x00 },
        '6' => [8]u8{ 0x3C, 0x40, 0x7C, 0x42, 0x42, 0x42, 0x3C, 0x00 },
        '7' => [8]u8{ 0x7E, 0x02, 0x04, 0x08, 0x10, 0x20, 0x20, 0x00 },
        '8' => [8]u8{ 0x3C, 0x42, 0x42, 0x3C, 0x42, 0x42, 0x3C, 0x00 },
        '9' => [8]u8{ 0x3C, 0x42, 0x42, 0x3E, 0x02, 0x04, 0x38, 0x00 },
        ':' => [8]u8{ 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00 },
        '.' => [8]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 },
        '-' => [8]u8{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 },
        '/' => [8]u8{ 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x00, 0x00 },
        '[' => [8]u8{ 0x3C, 0x20, 0x20, 0x20, 0x20, 0x20, 0x3C, 0x00 },
        ']' => [8]u8{ 0x3C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x3C, 0x00 },
        ' ' => [8]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        else => [8]u8{ 0x7E, 0x42, 0x5A, 0x5A, 0x5A, 0x42, 0x7E, 0x00 },
    };
}

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn loadFontFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_z), "rb") orelse return null;
    defer _ = std.c.fclose(f);

    _ = fseek(f, 0, 2);
    const sz = ftell(f);
    _ = fseek(f, 0, 0);
    if (sz <= 0 or sz > 10 * 1024 * 1024) return null;

    const size: usize = @intCast(sz);
    const buf = allocator.alloc(u8, size) catch return null;
    _ = std.c.fread(buf.ptr, 1, size, f);
    return buf;
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    fb: FrameBuffer,
    theme: Theme,
    is_rtl: bool = false,
    mouse_pos: Point = .{ .x = -1, .y = -1 },
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    last_frame_time_ns: u64 = 0,
    tracked_widgets: std.ArrayList(TrackedWidget),

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Context {
        var fb = try FrameBuffer.init(allocator, w, h);
        if (loadFontFile(allocator, "assets/fonts/Inter-Regular.ttf")) |bytes| {
            fb.setFont(bytes);
        }

        return .{
            .allocator = allocator,
            .fb = fb,
            .theme = .{},
            .tracked_widgets = std.ArrayList(TrackedWidget).empty,
        };
    }

    pub fn deinit(self: *Context) void {
        self.fb.deinit();
        self.tracked_widgets.deinit(self.allocator);
    }

    pub fn beginFrame(self: *Context, is_rtl: bool) void {
        self.is_rtl = is_rtl;
        self.tracked_widgets.clearRetainingCapacity();
        self.fb.clear(self.theme.bg_primary);
    }

    pub fn endFrame(self: *Context, frame_time_ns: u64) void {
        self.last_frame_time_ns = frame_time_ns;
        self.mouse_clicked = false;
    }

    pub fn handleEvent(self: *Context, event: Event) void {
        switch (event) {
            .mouse_move => |pt| {
                self.mouse_pos = pt;
            },
            .mouse_down => |d| {
                self.mouse_pos = d.pt;
                self.mouse_down = true;
                self.mouse_clicked = true;
            },
            .mouse_up => |u| {
                self.mouse_pos = u.pt;
                self.mouse_down = false;
            },
            else => {},
        }
    }

    pub fn trackWidget(self: *Context, id: []const u8, rect: Rect) !void {
        try self.tracked_widgets.append(self.allocator, .{ .id = id, .rect = rect });
    }

    pub fn assertNoOverlaps(self: *const Context) !void {
        const items = self.tracked_widgets.items;
        for (items, 0..) |w1, i| {
            for (items[i + 1 ..]) |w2| {
                // If two widgets intersect and are not the same id
                if (w1.rect.intersects(w2.rect)) {
                    // Check if one is a container of another (fully containing is allowed for cards/containers)
                    const w1_contains_w2 = w1.rect.contains(.{ .x = w2.rect.x, .y = w2.rect.y }) and
                        w1.rect.contains(.{ .x = w2.rect.x + w2.rect.w, .y = w2.rect.y + w2.rect.h });
                    const w2_contains_w1 = w2.rect.contains(.{ .x = w1.rect.x, .y = w1.rect.y }) and
                        w2.rect.contains(.{ .x = w1.rect.x + w1.rect.w, .y = w1.rect.y + w1.rect.h });
                    if (!w1_contains_w2 and !w2_contains_w1) {
                        std.debug.print("DVUI Layout Overlap detected: \"{s}\" and \"{s}\"\n", .{ w1.id, w2.id });
                        return error.LayoutOverlapError;
                    }
                }
            }
        }
    }

    // --- High-Level Immediate Mode Widgets ---

    pub fn button(self: *Context, id: []const u8, label_text: []const u8, rect: Rect) !bool {
        try self.trackWidget(id, rect);
        const hovered = rect.contains(self.mouse_pos);
        const active = hovered and self.mouse_down;
        const clicked = hovered and self.mouse_clicked;

        const bg = if (active)
            Color{ .r = 220, .g = 38, .b = 38, .a = 255 }
        else if (hovered)
            Color{ .r = 248, .g = 113, .b = 113, .a = 255 }
        else
            self.theme.accent_red;

        self.fb.fillRect(rect, bg);
        self.fb.drawBorder(rect, self.theme.border, 1.0);

        const text_x = rect.x + (rect.w - @as(f32, @floatFromInt(label_text.len * 6 * 2))) * 0.5;
        const text_y = rect.y + (rect.h - 14.0) * 0.5;
        self.fb.drawText(label_text, text_x, text_y, 2, self.theme.text_primary, self.is_rtl);

        return clicked;
    }

    pub fn toggle(self: *Context, id: []const u8, label_text: []const u8, active: bool, rect: Rect) !bool {
        try self.trackWidget(id, rect);
        const hovered = rect.contains(self.mouse_pos);
        var is_active = active;
        if (hovered and self.mouse_clicked) {
            is_active = !is_active;
        }

        const bg = if (is_active) self.theme.accent_green else self.theme.bg_card;
        self.fb.fillRect(rect, bg);
        self.fb.drawBorder(rect, self.theme.border, 1.0);

        const status_text = if (is_active) "[ON]" else "[OFF]";
        self.fb.drawText(label_text, rect.x + 8.0, rect.y + (rect.h - 14.0) * 0.5, 2, self.theme.text_primary, self.is_rtl);
        self.fb.drawText(status_text, rect.x + rect.w - 50.0, rect.y + (rect.h - 14.0) * 0.5, 2, if (is_active) self.theme.text_primary else self.theme.text_secondary, false);

        return is_active;
    }

    pub fn label(self: *Context, id: []const u8, text: []const u8, rect: Rect, color: Color) !void {
        try self.trackWidget(id, rect);
        self.fb.drawText(text, rect.x, rect.y, 2, color, self.is_rtl);
    }

    pub fn slider(self: *Context, id: []const u8, val: f32, min: f32, max: f32, rect: Rect) !f32 {
        try self.trackWidget(id, rect);
        var current = val;
        const hovered = rect.contains(self.mouse_pos);
        if (hovered and self.mouse_down) {
            const frac = @max(0.0, @min(1.0, (self.mouse_pos.x - rect.x) / rect.w));
            current = min + frac * (max - min);
        }

        // Draw track
        self.fb.fillRect(rect, self.theme.bg_card);
        self.fb.drawBorder(rect, self.theme.border, 1.0);

        // Draw filled progress
        const filled_w = rect.w * ((current - min) / (max - min));
        self.fb.fillRect(.{ .x = rect.x, .y = rect.y, .w = filled_w, .h = rect.h }, self.theme.accent_blue);

        return current;
    }

    pub fn card(self: *Context, id: []const u8, rect: Rect, bg: Color) !void {
        try self.trackWidget(id, rect);
        self.fb.fillRect(rect, bg);
        self.fb.drawBorder(rect, self.theme.border, 1.0);
    }
};
