const std = @import("std");

pub const SourceType = enum(c_int) {
    display = 0,
    window = 1,
    microphone = 2,
    webcam = 3,
};

pub const PermissionType = enum(c_int) {
    screen = 0,
    audio = 1,
    camera = 2,
};

pub const PermissionStatus = enum(c_int) {
    not_determined = 0,
    restricted = 1,
    denied = 2,
    granted = 3,
};

pub const PixelFormat = enum(c_int) {
    rgba = 0,
    nv12 = 1,
    bgra = 2,
    yuyv = 3,
};

pub const CursorShape = enum(c_int) {
    default = 0,
    pointer = 1,
    ibeam = 2,
    crosshair = 3,
    hand = 4,
    resize = 5,
};

pub const MouseButton = enum(c_int) {
    none = 0,
    left = 1,
    right = 2,
    middle = 3,
};

pub const MouseEventType = enum(c_int) {
    move = 0,
    down = 1,
    up = 2,
    scroll = 3,
};

pub const SourceInfo = extern struct {
    id: [256]u8,
    name: [256]u8,
    source_type: c_int,
    width: u32,
    height: u32,
    is_primary: c_int,

    pub fn getId(self: *const SourceInfo) []const u8 {
        return std.mem.sliceTo(&self.id, 0);
    }

    pub fn getName(self: *const SourceInfo) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub const CursorEvent = extern struct {
    timestamp_ns: i64,
    x: f32,
    y: f32,
    raw_x: i32,
    raw_y: i32,
    shape: c_int,
    event_type: c_int,
    button: c_int,
    scroll_dx: f32,
    scroll_dy: f32,
};

pub const ScreenFrameCallback = *const fn (
    data: ?[*]const u8,
    width: u32,
    height: u32,
    stride: u32,
    format: c_int,
    pts_ns: i64,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const WebcamFrameCallback = *const fn (
    data: ?[*]const u8,
    width: u32,
    height: u32,
    stride: u32,
    format: c_int,
    pts_ns: i64,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const AudioFrameCallback = *const fn (
    is_system: c_int,
    pcm_samples: ?[*]const f32,
    num_samples: u32,
    sample_rate: u32,
    channels: u32,
    pts_ns: i64,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const CursorEventCallback = *const fn (
    event: ?*const CursorEvent,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const CaptureConfig = extern struct {
    display_id: [256]u8 = @splat(0),
    window_id: [256]u8 = @splat(0),
    mic_id: [256]u8 = @splat(0),
    webcam_id: [256]u8 = @splat(0),
    target_fps: u32 = 60,
    capture_cursor: c_int = 1,
    capture_webcam: c_int = 0,
    capture_system_audio: c_int = 1,
    capture_mic_audio: c_int = 1,

    on_screen_frame: ?ScreenFrameCallback = null,
    on_webcam_frame: ?WebcamFrameCallback = null,
    on_audio_frame: ?AudioFrameCallback = null,
    on_cursor_event: ?CursorEventCallback = null,
    user_data: ?*anyopaque = null,
};

pub const OscCaptureHandle = opaque {};

pub extern "c" fn osc_capture_enumerate_sources(
    source_type: c_int,
    out_sources: [*]SourceInfo,
    max_sources: c_int,
) c_int;

pub extern "c" fn osc_capture_check_permission(permission_type: c_int) c_int;
pub extern "c" fn osc_capture_request_permission(permission_type: c_int) c_int;

pub extern "c" fn osc_capture_create(config: *const CaptureConfig) ?*OscCaptureHandle;
pub extern "c" fn osc_capture_start(handle: *OscCaptureHandle) c_int;
pub extern "c" fn osc_capture_pause(handle: *OscCaptureHandle) c_int;
pub extern "c" fn osc_capture_resume(handle: *OscCaptureHandle) c_int;
pub extern "c" fn osc_capture_stop(handle: *OscCaptureHandle) c_int;
pub extern "c" fn osc_capture_destroy(handle: *OscCaptureHandle) void;

pub extern "c" fn osc_capture_set_excluded_windows(
    handle: *OscCaptureHandle,
    window_ids: [*]const [*:0]const u8,
    count: c_int,
) c_int;

pub extern "c" fn osc_capture_get_normalized_cursor(
    handle: *OscCaptureHandle,
    raw_x: c_int,
    raw_y: c_int,
    out_nx: *f32,
    out_ny: *f32,
) c_int;
