const std = @import("std");
const ui = @import("ui");
const core = @import("core");
const ffi = @import("ffi");

fn writeFile(path: []const u8, data: []const u8) !void {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_z), "wb") orelse return error.CannotCreateFile;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Create screenshots directory
    var dir_z: [64]u8 = undefined;
    @memcpy(dir_z[0..11], "screenshots");
    dir_z[11] = 0;
    const posix_c = struct {
        extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    };
    _ = posix_c.mkdir(@ptrCast(&dir_z), 0o755);

    var ctx = try ui.dvui.Context.init(allocator, 1280, 800);
    defer ctx.deinit();

    // 1. Floating Recording HUD (+ Notes window)
    var hud_app = ui.hud.Hud.init();
    hud_app.notes_open = true;
    hud_app.state = .recording;
    hud_app.duration_sec = 42.5;

    ctx.beginFrame(false);
    try hud_app.render(&ctx);
    ctx.endFrame(16_000_000);

    const hud_png = try ctx.fb.encodeToPng(allocator);
    defer allocator.free(hud_png);
    try writeFile("screenshots/hud.png", hud_png);
    std.debug.print("Rendered visual proof artifact: screenshots/hud.png ({d} bytes)\n", .{hud_png.len});

    // 2. Main Editor (English LTR populated)
    var doc = try core.project.create_empty_document(allocator, "OpenScreen Demo Gate 7");

    const sample_words = try allocator.alloc(core.project.Word, 3);
    sample_words[0] = .{ .word = try allocator.dupe(u8, "Welcome"), .startSec = 0.5, .endSec = 1.0 };
    sample_words[1] = .{ .word = try allocator.dupe(u8, "to"), .startSec = 1.0, .endSec = 1.3 };
    sample_words[2] = .{ .word = try allocator.dupe(u8, "OpenScreen"), .startSec = 1.3, .endSec = 2.0 };

    const sample_silences = try allocator.alloc(core.project.Silence, 1);
    sample_silences[0] = .{ .startSec = 2.0, .endSec = 3.5, .durationSec = 1.5 };

    const tr_slice = try allocator.alloc(core.project.Transcript, 1);
    tr_slice[0] = .{
        .assetId = try allocator.dupe(u8, "asset-1"),
        .language = "en",
        .words = sample_words,
        .silences = sample_silences,
    };
    doc.transcripts = tr_slice;

    const zr_slice = try allocator.alloc(core.project.ZoomRange, 1);
    zr_slice[0] = .{
        .id = try allocator.dupe(u8, "zoom-1"),
        .clipId = try allocator.dupe(u8, "clip-1"),
        .startSec = 1.0,
        .endSec = 3.0,
        .depth = 3,
        .focus = .{ .cx = 0.5, .cy = 0.5 },
    };
    doc.zoomRanges = zr_slice;

    var editor_app = ui.editor.Editor.init(allocator, doc);
    defer editor_app.deinit();

    // Warmup
    ctx.beginFrame(false);
    try editor_app.render(&ctx);
    ctx.endFrame(0);

    ctx.beginFrame(false);
    try editor_app.render(&ctx);
    ctx.endFrame(16_000_000);

    const ltr_png = try ctx.fb.encodeToPng(allocator);
    defer allocator.free(ltr_png);
    try writeFile("screenshots/editor_ltr.png", ltr_png);
    std.debug.print("Rendered visual proof artifact: screenshots/editor_ltr.png ({d} bytes)\n", .{ltr_png.len});

    // 3. Main Editor (Arabic RTL populated)
    editor_app.modal_settings.current_locale = "ar";
    ctx.beginFrame(true);
    try editor_app.render(&ctx);
    ctx.endFrame(16_000_000);

    const rtl_png = try ctx.fb.encodeToPng(allocator);
    defer allocator.free(rtl_png);
    try writeFile("screenshots/editor_rtl.png", rtl_png);
    std.debug.print("Rendered visual proof artifact: screenshots/editor_rtl.png ({d} bytes)\n", .{rtl_png.len});
}
