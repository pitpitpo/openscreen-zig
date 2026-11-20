const std = @import("std");

pub const FontHandle = anyopaque;

pub extern "c" fn osc_font_create(ttf_bytes: [*]const u8, size: usize) ?*FontHandle;
pub extern "c" fn osc_font_destroy(font: ?*FontHandle) void;
pub extern "c" fn osc_font_render_glyph(
    font: ?*FontHandle,
    codepoint: u32,
    font_size_px: f32,
    out_width: *c_int,
    out_height: *c_int,
    out_xoff: *c_int,
    out_yoff: *c_int,
    out_advance: *c_int,
) ?[*]u8;
pub extern "c" fn osc_font_free_bitmap(bitmap: ?[*]u8) void;

pub const GlyphBitmap = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    xoff: i32,
    yoff: i32,
    advance: i32,
    raw_ptr: ?[*]u8,

    pub fn deinit(self: *GlyphBitmap) void {
        if (self.raw_ptr) |p| {
            osc_font_free_bitmap(p);
            self.raw_ptr = null;
        }
    }
};

pub const TrueTypeFont = struct {
    handle: ?*FontHandle,

    pub fn init(ttf_bytes: []const u8) ?TrueTypeFont {
        const h = osc_font_create(ttf_bytes.ptr, ttf_bytes.len) orelse return null;
        return TrueTypeFont{ .handle = h };
    }

    pub fn deinit(self: *TrueTypeFont) void {
        if (self.handle) |h| {
            osc_font_destroy(h);
            self.handle = null;
        }
    }

    pub fn renderGlyph(self: *const TrueTypeFont, codepoint: u32, font_size_px: f32) ?GlyphBitmap {
        var w: c_int = 0;
        var h: c_int = 0;
        var xo: c_int = 0;
        var yo: c_int = 0;
        var adv: c_int = 0;

        const ptr = osc_font_render_glyph(self.handle, codepoint, font_size_px, &w, &h, &xo, &yo, &adv) orelse return null;
        if (w <= 0 or h <= 0) {
            osc_font_free_bitmap(ptr);
            return null;
        }

        const len: usize = @intCast(w * h);
        return GlyphBitmap{
            .pixels = ptr[0..len],
            .width = @intCast(w),
            .height = @intCast(h),
            .xoff = xo,
            .yoff = yo,
            .advance = adv,
            .raw_ptr = ptr,
        };
    }
};
