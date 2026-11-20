const std = @import("std");

pub const TrayAction = enum(c_int) {
    start_stop_recording = 1,
    open_editor = 2,
    settings = 3,
    quit = 4,
};

pub const TrayCallback = ?*const fn (action: TrayAction, user_data: ?*anyopaque) callconv(.c) void;
pub const ShortcutCallback = ?*const fn (user_data: ?*anyopaque) callconv(.c) void;

extern "c" fn osc_shell_single_instance_lock(user_data_path: ?[*:0]const u8) c_int;
extern "c" fn osc_shell_single_instance_unlock() void;
extern "c" fn osc_shell_tray_init(tooltip: ?[*:0]const u8, callback: TrayCallback, user_data: ?*anyopaque) c_int;
extern "c" fn osc_shell_tray_update_state(is_recording: c_int) void;
extern "c" fn osc_shell_tray_destroy() void;
extern "c" fn osc_shell_register_global_shortcut(shortcut_desc: ?[*:0]const u8, callback: ShortcutCallback, user_data: ?*anyopaque) c_int;
extern "c" fn osc_shell_unregister_global_shortcut() void;
extern "c" fn osc_shell_set_window_content_protection(native_window_handle: ?*anyopaque, exclude: c_int) c_int;

pub fn singleInstanceLock(user_data_path: ?[:0]const u8) bool {
    const p = if (user_data_path) |s| s.ptr else null;
    return osc_shell_single_instance_lock(p) != 0;
}

pub fn singleInstanceUnlock() void {
    osc_shell_single_instance_unlock();
}

pub fn trayInit(tooltip: ?[:0]const u8, callback: TrayCallback, user_data: ?*anyopaque) bool {
    const t = if (tooltip) |s| s.ptr else null;
    return osc_shell_tray_init(t, callback, user_data) != 0;
}

pub fn trayUpdateState(is_recording: bool) void {
    osc_shell_tray_update_state(if (is_recording) 1 else 0);
}

pub fn trayDestroy() void {
    osc_shell_tray_destroy();
}

pub fn registerGlobalShortcut(shortcut_desc: ?[:0]const u8, callback: ShortcutCallback, user_data: ?*anyopaque) bool {
    const s = if (shortcut_desc) |d| d.ptr else null;
    return osc_shell_register_global_shortcut(s, callback, user_data) != 0;
}

pub fn unregisterGlobalShortcut() void {
    osc_shell_unregister_global_shortcut();
}

pub fn setWindowContentProtection(native_window_handle: ?*anyopaque, exclude: bool) bool {
    return osc_shell_set_window_content_protection(native_window_handle, if (exclude) 1 else 0) != 0;
}

pub const WindowEventKind = enum(c_int) {
    none = 0,
    quit = 1,
    close = 2,
    resize = 3,
    mouse_move = 4,
    mouse_down = 5,
    mouse_up = 6,
    key_down = 7,
    key_up = 8,
    text_input = 9,
    mouse_wheel = 10,
};

pub const WindowEvent = extern struct {
    kind: WindowEventKind,
    x: c_int,
    y: c_int,
    button: c_int,
    keycode: c_int,
    width: c_int,
    height: c_int,
    is_ctrl: c_int,
    is_shift: c_int,
    wheel_dx: f32,
    wheel_dy: f32,
    text: [32]u8,
};

pub extern "c" fn osc_window_create(title: ?[*:0]const u8, width: c_int, height: c_int, resizable: c_int) ?*anyopaque;
pub extern "c" fn osc_window_create_hud(title: ?[*:0]const u8, width: c_int, height: c_int) ?*anyopaque;
pub extern "c" fn osc_window_destroy(win: ?*anyopaque) void;
pub extern "c" fn osc_window_poll_event(win: ?*anyopaque, out_event: *WindowEvent) c_int;
pub extern "c" fn osc_window_present(win: ?*anyopaque, rgba_pixels: [*]const u8, width: c_int, height: c_int) void;
pub extern "c" fn osc_window_is_open(win: ?*anyopaque) c_int;

pub fn windowCreate(title: [:0]const u8, width: u32, height: u32, resizable: bool) ?*anyopaque {
    return osc_window_create(title.ptr, @intCast(width), @intCast(height), if (resizable) 1 else 0);
}

pub fn windowCreateHud(title: [:0]const u8, width: u32, height: u32) ?*anyopaque {
    return osc_window_create_hud(title.ptr, @intCast(width), @intCast(height));
}

pub fn windowDestroy(win: ?*anyopaque) void {
    osc_window_destroy(win);
}

pub fn windowPollEvent(win: ?*anyopaque, out_event: *WindowEvent) bool {
    return osc_window_poll_event(win, out_event) != 0;
}

pub fn windowPresent(win: ?*anyopaque, rgba_pixels: []const u8, width: u32, height: u32) void {
    osc_window_present(win, rgba_pixels.ptr, @intCast(width), @intCast(height));
}

pub fn windowIsOpen(win: ?*anyopaque) bool {
    return osc_window_is_open(win) != 0;
}
