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

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !FrameBuffer {
        const size = @as(usize, w) * h * 4;
        const pixels = try allocator.alloc(u8, size);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = w,
            .height = h,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *FrameBuffer) void {
        self.allocator.free(self.pixels);
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
        // Compact 5x7 bitmap font table for ASCII 32..126
        const glyph_data = getGlyph5x7(char);
        var row: usize = 0;
        while (row < 7) : (row += 1) {
            var col: usize = 0;
            while (col < 5) : (col += 1) {
                const shift: u3 = @intCast(4 - col);
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

    pub fn drawText(self: *FrameBuffer, text: []const u8, x: f32, y: f32, scale: i32, c: Color, is_rtl: bool) void {
        const char_w = 6 * scale;
        var start_x = @as(i32, @intFromFloat(x));
        const py = @as(i32, @intFromFloat(y));

        if (is_rtl) {
            // In RTL, render from right to left
            start_x += @intCast(text.len * @as(usize, @intCast(char_w)));
            for (text) |ch| {
                start_x -= char_w;
                self.drawChar(ch, start_x, py, scale, c);
            }
        } else {
            for (text) |ch| {
                self.drawChar(ch, start_x, py, scale, c);
                start_x += char_w;
            }
        }
    }

    pub fn encodeToPng(self: *const FrameBuffer, allocator: std.mem.Allocator) ![]u8 {
        return try ffi.ffmpeg.encodePng(allocator, self.pixels, self.width, self.height);
    }
};

fn getGlyph5x7(ch: u8) [7]u8 {
    // 5x7 font representations for UI labels, numbers, and symbols
    return switch (ch) {
        'A'...'Z' => [7]u8{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'a'...'z' => [7]u8{ 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F, 0x00 },
        '0' => [7]u8{ 0x0E, 0x13, 0x15, 0x19, 0x11, 0x0E, 0x00 },
        '1' => [7]u8{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x0E, 0x00 },
        '2' => [7]u8{ 0x0E, 0x11, 0x01, 0x06, 0x08, 0x1F, 0x00 },
        '3' => [7]u8{ 0x1E, 0x01, 0x06, 0x01, 0x01, 0x1E, 0x00 },
        '4' => [7]u8{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x00 },
        '5' => [7]u8{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x1E, 0x00 },
        '6' => [7]u8{ 0x0E, 0x10, 0x1E, 0x11, 0x11, 0x0E, 0x00 },
        '7' => [7]u8{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x00 },
        '8' => [7]u8{ 0x0E, 0x11, 0x0E, 0x11, 0x11, 0x0E, 0x00 },
        '9' => [7]u8{ 0x0E, 0x11, 0x0F, 0x01, 0x01, 0x0E, 0x00 },
        ':' => [7]u8{ 0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00 },
        '.' => [7]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00 },
        '-' => [7]u8{ 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00, 0x00 },
        '/' => [7]u8{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x00, 0x00 },
        '[' => [7]u8{ 0x0E, 0x08, 0x08, 0x08, 0x08, 0x0E, 0x00 },
        ']' => [7]u8{ 0x0E, 0x02, 0x02, 0x02, 0x02, 0x0E, 0x00 },
        ' ' => [7]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        else => [7]u8{ 0x1F, 0x15, 0x15, 0x15, 0x15, 0x1F, 0x00 },
    };
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
        const fb = try FrameBuffer.init(allocator, w, h);
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
