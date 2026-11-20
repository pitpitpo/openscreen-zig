const std = @import("std");
pub const dvui = @import("dvui/root.zig");
pub const hud = @import("hud.zig");
pub const editor = @import("editor.zig");
pub const timeline_ui = @import("timeline_ui.zig");
pub const transcript_ui = @import("transcript_ui.zig");
pub const export_modal = @import("export_modal.zig");
pub const settings_modal = @import("settings_modal.zig");

const ffi = @import("ffi");
const core = @import("core");
const builtin = @import("builtin");

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        const win = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        };
        win.Sleep(ms);
    } else {
        const posix_c = struct {
            extern "c" fn usleep(usec: c_uint) c_int;
        };
        _ = posix_c.usleep(@as(c_uint, ms) * 1000);
    }
}

fn getMonotonicNs() i64 {
    if (builtin.os.tag == .windows) {
        const win = struct {
            extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) c_int;
            extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) c_int;
        };
        var freq: i64 = 0;
        var counter: i64 = 0;
        _ = win.QueryPerformanceFrequency(&freq);
        _ = win.QueryPerformanceCounter(&counter);
        if (freq == 0) return 0;
        const product = @as(i128, counter) * 1_000_000_000;
        return @as(i64, @intCast(@divTrunc(product, freq)));
    } else if (builtin.os.tag == .macos) {
        const darwin = struct {
            extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
        };
        const ns = darwin.clock_gettime_nsec_np(6);
        return @as(i64, @intCast(ns & 0x7FFF_FFFF_FFFF_FFFF));
    } else {
        const posix_c = struct {
            const timespec = extern struct {
                tv_sec: isize,
                tv_nsec: isize,
            };
            extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;
        };
        var ts: posix_c.timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
        _ = posix_c.clock_gettime(1, &ts);
        return @as(i64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec));
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_z), "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    _ = fseek(f, 0, 2);
    const size_l = ftell(f);
    _ = fseek(f, 0, 0);
    if (size_l <= 0) return try allocator.alloc(u8, 0);

    const size: usize = @intCast(size_l);
    const buf = try allocator.alloc(u8, size);
    _ = std.c.fread(buf.ptr, 1, size, f);
    return buf;
}

pub const App = struct {
    allocator: std.mem.Allocator,
    hud_app: hud.Hud,
    editor_app: ?editor.Editor = null,
    parsed_doc: ?std.json.Parsed(core.project.AxcutDocument) = null,
    is_running: bool = true,
    show_hud: bool = true,
    show_editor: bool = false,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{
            .allocator = allocator,
            .hud_app = hud.Hud.init(),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.editor_app) |*ed| {
            ed.deinit();
            self.editor_app = null;
        }
        if (self.parsed_doc) |*p| {
            p.deinit();
            self.parsed_doc = null;
        }
        ffi.shell.singleInstanceUnlock();
        ffi.shell.trayDestroy();
        ffi.shell.unregisterGlobalShortcut();
    }

    pub fn openProject(self: *App, path: []const u8) !void {
        const contents = try readFileAlloc(self.allocator, path);
        defer self.allocator.free(contents);
        const parsed = try core.project.load_from_json(self.allocator, contents);

        if (self.editor_app) |*ed| {
            ed.deinit();
            self.editor_app = null;
        }
        if (self.parsed_doc) |*p| {
            p.deinit();
        }
        self.parsed_doc = parsed;
        self.editor_app = editor.Editor.init(self.allocator, parsed.value);
        self.show_editor = true;
    }

    pub fn run(self: *App, maybe_project_path: ?[]const u8) !u8 {
        // 1. Single Instance Lock
        if (!ffi.shell.singleInstanceLock(null)) {
            // Secondary instance focused primary and must exit 0 cleanly
            return 0;
        }

        // 2. Tray and Shortcut Registration
        const TrayHandler = struct {
            pub fn onTrayAction(action: ffi.shell.TrayAction, user_data: ?*anyopaque) callconv(.c) void {
                if (user_data == null) return;
                const app: *App = @ptrCast(@alignCast(user_data.?));
                switch (action) {
                    .start_stop_recording => {
                        app.hud_app.state = if (app.hud_app.state == .idle) .recording else .idle;
                    },
                    .open_editor => {
                        app.show_editor = true;
                    },
                    .settings => {
                        if (app.editor_app) |*ed| {
                            ed.modal_settings.is_open = true;
                        }
                    },
                    .quit => {
                        app.is_running = false;
                    },
                }
            }
        };

        const ShortcutHandler = struct {
            pub fn onGlobalShortcut(user_data: ?*anyopaque) callconv(.c) void {
                if (user_data == null) return;
                const app: *App = @ptrCast(@alignCast(user_data.?));
                app.hud_app.state = if (app.hud_app.state == .idle) .recording else .idle;
            }
        };

        _ = ffi.shell.trayInit("OpenScreen 2.0", TrayHandler.onTrayAction, self);
        _ = ffi.shell.registerGlobalShortcut("Cmd/Ctrl+Shift+O", ShortcutHandler.onGlobalShortcut, self);

        if (maybe_project_path) |path| {
            self.openProject(path) catch {};
        }

        // In headless mode (CI or no display), run a single frame verification cycle and exit 0
        if (getenv("OPENSCREEN_TEST_HEADLESS")) |h| {
            if (std.mem.span(h).len > 0 and h[0] == '1') {
                var ctx = try dvui.Context.init(self.allocator, 1280, 800);
                defer ctx.deinit();
                ctx.beginFrame(false);
                try self.hud_app.render(&ctx);
                if (self.editor_app) |*ed| {
                    try ed.render(&ctx);
                }
                ctx.endFrame(16_000_000);
                return 0;
            }
        }

        // Real Interactive OS Window Loop
        const win = ffi.shell.windowCreate("OpenScreen 2.0", 1280, 800, true) orelse return 0;
        defer ffi.shell.windowDestroy(win);

        var ctx = try dvui.Context.init(self.allocator, 1280, 800);
        defer ctx.deinit();

        var last_time_ns = getMonotonicNs();

        while (self.is_running and ffi.shell.windowIsOpen(win)) {
            var ev: ffi.shell.WindowEvent = undefined;
            ctx.mouse_clicked = false;
            while (ffi.shell.windowPollEvent(win, &ev)) {
                switch (ev.kind) {
                    .quit, .close => {
                        self.is_running = false;
                        break;
                    },
                    .resize => {
                        if (ev.width > 100 and ev.height > 100) {
                            ctx.fb.resize(@intCast(ev.width), @intCast(ev.height)) catch {};
                        }
                    },
                    .mouse_move => {
                        ctx.mouse_pos = .{ .x = @floatFromInt(ev.x), .y = @floatFromInt(ev.y) };
                    },
                    .mouse_down => {
                        ctx.mouse_down = true;
                    },
                    .mouse_up => {
                        ctx.mouse_down = false;
                        ctx.mouse_clicked = true;
                    },
                    .key_down => {
                        if (ev.is_ctrl != 0 and (ev.keycode == 'z' or ev.keycode == 'Z')) {
                            if (ev.is_shift != 0) {
                                if (self.editor_app) |*ed| {
                                    _ = ed.stack.redo(&ed.doc) catch {};
                                }
                            } else {
                                if (self.editor_app) |*ed| {
                                    _ = ed.stack.undo(&ed.doc) catch {};
                                }
                            }
                        } else if (ev.keycode == ' ') {
                            if (self.editor_app) |*ed| {
                                ed.is_playing = !ed.is_playing;
                            }
                        }
                    },
                    else => {},
                }
            }

            const now_ns = getMonotonicNs();
            const delta_ns = now_ns - last_time_ns;
            last_time_ns = now_ns;
            const delta_sec = @as(f64, @floatFromInt(delta_ns)) / 1_000_000_000.0;

            if (self.editor_app) |*ed| {
                ed.update(delta_sec);
            }

            ctx.beginFrame(false);
            if (self.show_editor and self.editor_app != null) {
                try self.editor_app.?.render(&ctx);
            } else {
                try self.hud_app.render(&ctx);
            }
            ctx.endFrame(@intCast(@max(0, delta_ns)));

            ffi.shell.windowPresent(win, ctx.fb.pixels, ctx.fb.width, ctx.fb.height);

            sleepMs(16);
        }

        return 0;
    }

    pub fn runSmokeTest(self: *App) !u8 {
        const win = ffi.shell.windowCreate("OpenScreen 2.0 (Smoke Test)", 1280, 800, true) orelse return error.WindowCreationFailed;
        defer ffi.shell.windowDestroy(win);

        var ctx = try dvui.Context.init(self.allocator, 1280, 800);
        defer ctx.deinit();

        // Run 5 real event loop iterations
        var frame: usize = 0;
        while (frame < 5) : (frame += 1) {
            var ev: ffi.shell.WindowEvent = undefined;
            while (ffi.shell.windowPollEvent(win, &ev)) {}

            ctx.beginFrame(false);
            try self.hud_app.render(&ctx);
            if (self.editor_app) |*ed| {
                try ed.render(&ctx);
            }
            ctx.endFrame(16_000_000);

            ffi.shell.windowPresent(win, ctx.fb.pixels, ctx.fb.width, ctx.fb.height);
        }
        return 0;
    }
};
