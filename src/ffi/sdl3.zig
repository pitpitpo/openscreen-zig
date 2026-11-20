const std = @import("std");
const builtin = @import("builtin");

// Clean Zig 0.17 SDL3 C-ABI FFI (strictly NO @cImport)

pub const Window = anyopaque;
pub const Renderer = anyopaque;
pub const Texture = anyopaque;

pub const WindowFlags = packed struct(u64) {
    fullscreen: bool = false,
    opengl: bool = false,
    occluded: bool = false,
    hidden: bool = false,
    borderless: bool = false,
    resizable: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    mouse_grabbed: bool = false,
    input_focus: bool = false,
    mouse_focus: bool = false,
    external: bool = false,
    modal: bool = false,
    high_pixel_density: bool = false,
    mouse_capture: bool = false,
    mouse_relative_mode: bool = false,
    always_on_top: bool = false,
    utility: bool = false,
    tooltip: bool = false,
    popup_menu: bool = false,
    keyboard_grabbed: bool = false,
    vulkan: bool = false,
    metal: bool = false,
    transparent: bool = false,
    not_focusable: bool = false,
    _pad: u39 = 0,
};

pub const SDL_WINDOW_HIDDEN: u64 = 0x00000008;
pub const SDL_WINDOW_BORDERLESS: u64 = 0x00000010;
pub const SDL_WINDOW_RESIZABLE: u64 = 0x00000020;
pub const SDL_WINDOW_ALWAYS_ON_TOP: u64 = 0x00010000;
pub const SDL_WINDOW_HIGH_PIXEL_DENSITY: u64 = 0x00002000;

pub const PixelFormat = enum(u32) {
    unknown = 0,
    rgba32 = 0x16462004,
    bgra32 = 0x16662004,
};

pub const TextureAccess = enum(c_int) {
    static = 0,
    streaming = 1,
    target = 2,
};

pub const EventType = enum(u32) {
    first = 0,
    quit = 0x100,
    window_shown = 0x202,
    window_hidden = 0x203,
    window_exposed = 0x204,
    window_moved = 0x205,
    window_resized = 0x206,
    window_close_requested = 0x20A,
    key_down = 0x300,
    key_up = 0x301,
    mouse_motion = 0x400,
    mouse_button_down = 0x401,
    mouse_button_up = 0x402,
    mouse_wheel = 0x403,
    _,
};

pub const CommonEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
};

pub const MouseMotionEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    windowID: u32,
    which: u32,
    state: u32,
    x: f32,
    y: f32,
    xrel: f32,
    yrel: f32,
};

pub const MouseButtonEvent = extern struct {
    type: u32,
    reserved: u32,
    timestamp: u64,
    windowID: u32,
    which: u32,
    button: u8,
    down: bool,
    clicks: u8,
    padding: u8,
    x: f32,
    y: f32,
};

pub const Event = extern union {
    type: u32,
    common: CommonEvent,
    motion: MouseMotionEvent,
    button: MouseButtonEvent,
    padding: [128]u8,
};

pub const FRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Rect = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Dynamic / linked SDL3 bindings with headless fallback
pub const Sdl3Api = struct {
    lib: ?std.DynLib = null,
    is_headless: bool = true,

    init_fn: ?*const fn (flags: u32) callconv(.c) bool = null,
    quit_fn: ?*const fn () callconv(.c) void = null,
    create_window_fn: ?*const fn (title: [*:0]const u8, w: c_int, h: c_int, flags: u64) callconv(.c) ?*Window = null,
    destroy_window_fn: ?*const fn (window: *Window) callconv(.c) void = null,
    show_window_fn: ?*const fn (window: *Window) callconv(.c) bool = null,
    hide_window_fn: ?*const fn (window: *Window) callconv(.c) bool = null,
    set_window_position_fn: ?*const fn (window: *Window, x: c_int, y: c_int) callconv(.c) bool = null,
    set_window_size_fn: ?*const fn (window: *Window, w: c_int, h: c_int) callconv(.c) bool = null,
    create_renderer_fn: ?*const fn (window: *Window, name: ?[*:0]const u8) callconv(.c) ?*Renderer = null,
    destroy_renderer_fn: ?*const fn (renderer: *Renderer) callconv(.c) void = null,
    create_texture_fn: ?*const fn (renderer: *Renderer, format: u32, access: c_int, w: c_int, h: c_int) callconv(.c) ?*Texture = null,
    update_texture_fn: ?*const fn (texture: *Texture, rect: ?*const Rect, pixels: ?*const anyopaque, pitch: c_int) callconv(.c) bool = null,
    destroy_texture_fn: ?*const fn (texture: *Texture) callconv(.c) void = null,
    render_clear_fn: ?*const fn (renderer: *Renderer) callconv(.c) bool = null,
    render_texture_fn: ?*const fn (renderer: *Renderer, texture: *Texture, srcrect: ?*const FRect, dstrect: ?*const FRect) callconv(.c) bool = null,
    render_present_fn: ?*const fn (renderer: *Renderer) callconv(.c) bool = null,
    poll_event_fn: ?*const fn (event: *Event) callconv(.c) bool = null,

    pub fn init() Sdl3Api {
        if (getenv("OPENSCREEN_TEST_HEADLESS")) |h| {
            if (std.mem.span(h).len > 0 and h[0] == '1') {
                return .{ .is_headless = true };
            }
        }

        const lib_names = switch (builtin.os.tag) {
            .windows => &[_][]const u8{"SDL3.dll"},
            .macos => &[_][]const u8{ "libSDL3.dylib", "/opt/homebrew/lib/libSDL3.dylib", "/usr/local/lib/libSDL3.dylib" },
            else => &[_][]const u8{ "libSDL3.so.0", "libSDL3.so", "/usr/lib/x86_64-linux-gnu/libSDL3.so" },
        };

        var maybe_lib: ?std.DynLib = null;
        for (lib_names) |name| {
            if (std.DynLib.open(name)) |lib| {
                maybe_lib = lib;
                break;
            } else |_| {}
        }

        if (maybe_lib == null) {
            return .{ .is_headless = true };
        }

        var lib = maybe_lib.?;
        var api = Sdl3Api{
            .lib = lib,
            .is_headless = false,
            .init_fn = lib.lookup(*const fn (u32) callconv(.c) bool, "SDL_Init"),
            .quit_fn = lib.lookup(*const fn () callconv(.c) void, "SDL_Quit"),
            .create_window_fn = lib.lookup(*const fn ([*:0]const u8, c_int, c_int, u64) callconv(.c) ?*Window, "SDL_CreateWindow"),
            .destroy_window_fn = lib.lookup(*const fn (*Window) callconv(.c) void, "SDL_DestroyWindow"),
            .show_window_fn = lib.lookup(*const fn (*Window) callconv(.c) bool, "SDL_ShowWindow"),
            .hide_window_fn = lib.lookup(*const fn (*Window) callconv(.c) bool, "SDL_HideWindow"),
            .set_window_position_fn = lib.lookup(*const fn (*Window, c_int, c_int) callconv(.c) bool, "SDL_SetWindowPosition"),
            .set_window_size_fn = lib.lookup(*const fn (*Window, c_int, c_int) callconv(.c) bool, "SDL_SetWindowSize"),
            .create_renderer_fn = lib.lookup(*const fn (*Window, ?[*:0]const u8) callconv(.c) ?*Renderer, "SDL_CreateRenderer"),
            .destroy_renderer_fn = lib.lookup(*const fn (*Renderer) callconv(.c) void, "SDL_DestroyRenderer"),
            .create_texture_fn = lib.lookup(*const fn (*Renderer, u32, c_int, c_int, c_int) callconv(.c) ?*Texture, "SDL_CreateTexture"),
            .update_texture_fn = lib.lookup(*const fn (*Texture, ?*const Rect, ?*const anyopaque, c_int) callconv(.c) bool, "SDL_UpdateTexture"),
            .destroy_texture_fn = lib.lookup(*const fn (*Texture) callconv(.c) void, "SDL_DestroyTexture"),
            .render_clear_fn = lib.lookup(*const fn (*Renderer) callconv(.c) bool, "SDL_RenderClear"),
            .render_texture_fn = lib.lookup(*const fn (*Renderer, *Texture, ?*const FRect, ?*const FRect) callconv(.c) bool, "SDL_RenderTexture"),
            .render_present_fn = lib.lookup(*const fn (*Renderer) callconv(.c) bool, "SDL_RenderPresent"),
            .poll_event_fn = lib.lookup(*const fn (*Event) callconv(.c) bool, "SDL_PollEvent"),
        };

        if (api.init_fn == null or api.create_window_fn == null) {
            lib.close();
            api.lib = null;
            api.is_headless = true;
        }

        return api;
    }

    pub fn deinit(self: *Sdl3Api) void {
        if (self.lib) |*l| {
            l.close();
            self.lib = null;
        }
    }
};

pub var global_api: ?Sdl3Api = null;

pub fn getApi() *Sdl3Api {
    if (global_api == null) {
        global_api = Sdl3Api.init();
    }
    return &global_api.?;
}
