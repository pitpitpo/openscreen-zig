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

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

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

        return 0;
    }
};
