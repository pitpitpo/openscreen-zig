const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("ffi");
const shim = ffi.capture;

extern "c" fn remove(filename: [*:0]const u8) c_int;
extern "c" fn fflush(stream: *std.c.FILE) c_int;

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

fn getNanoTimestamp() i64 {
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
        // 6 = CLOCK_MONOTONIC on Darwin
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
        _ = posix_c.clock_gettime(1, &ts); // 1 = CLOCK_MONOTONIC on Linux
        return @as(i64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec));
    }
}

pub const SessionState = enum {
    idle,
    counting_down,
    recording,
    paused,
    stopped,
};

pub const CursorSidecarEvent = struct {
    timestamp_ns: i64,
    x: f32,
    y: f32,
    raw_x: i32,
    raw_y: i32,
    shape: []const u8,
    event: []const u8,
    button: []const u8,
    scroll_dx: f32 = 0.0,
    scroll_dy: f32 = 0.0,
};

pub const CaptureOptions = struct {
    display_id: []const u8 = "",
    window_id: []const u8 = "",
    mic_id: []const u8 = "",
    webcam_id: []const u8 = "",
    target_fps: u32 = 60,
    capture_cursor: bool = true,
    capture_webcam: bool = false,
    capture_system_audio: bool = true,
    capture_mic_audio: bool = true,
    output_dir: []const u8,
    take_name: []const u8 = "take_001",
};

pub const FrameData = struct {
    data: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    format: shim.PixelFormat,
    pts_ns: i64,
};

pub const AudioData = struct {
    is_system: bool,
    samples: []const f32,
    sample_rate: u32,
    channels: u32,
    pts_ns: i64,
};

pub const FrameHandler = *const fn (ctx: *anyopaque, frame: FrameData) void;
pub const AudioHandler = *const fn (ctx: *anyopaque, audio: AudioData) void;

pub const CaptureSession = struct {
    allocator: std.mem.Allocator,
    options: CaptureOptions,
    state: SessionState = .idle,

    handle: ?*shim.OscCaptureHandle = null,

    session_start_ns: i64 = 0,
    pause_start_ns: i64 = 0,
    total_paused_ns: i64 = 0,

    cursor_file: ?*std.c.FILE = null,
    cursor_file_path: []u8 = &[_]u8{},
    event_count: u64 = 0,

    frame_handler: ?FrameHandler = null,
    frame_handler_ctx: ?*anyopaque = null,

    audio_handler: ?AudioHandler = null,
    audio_handler_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, options: CaptureOptions) !*CaptureSession {
        const self = try allocator.create(CaptureSession);
        self.* = .{
            .allocator = allocator,
            .options = options,
            .state = .idle,
        };

        const sidecar_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.cursor.jsonl",
            .{ options.output_dir, options.take_name },
        );
        self.cursor_file_path = sidecar_path;

        return self;
    }

    pub fn deinit(self: *CaptureSession) void {
        if (self.state == .recording or self.state == .paused) {
            _ = self.stop() catch {};
        }
        if (self.cursor_file) |f| {
            _ = std.c.fclose(f);
            self.cursor_file = null;
        }
        if (self.cursor_file_path.len > 0) {
            self.allocator.free(self.cursor_file_path);
        }
        if (self.handle) |h| {
            shim.osc_capture_destroy(h);
            self.handle = null;
        }
        self.allocator.destroy(self);
    }

    pub fn startCountdown(self: *CaptureSession, seconds: u32) !void {
        self.state = .counting_down;
        var s = seconds;
        while (s > 0) : (s -= 1) {
            sleepMs(100);
        }
    }

    pub fn start(self: *CaptureSession) !void {
        if (self.state == .recording) return;

        var path_z: [1024]u8 = undefined;
        @memcpy(path_z[0..self.cursor_file_path.len], self.cursor_file_path);
        path_z[self.cursor_file_path.len] = 0;

        const f = std.c.fopen(@ptrCast(&path_z), "wb") orelse return error.CannotCreateSidecarFile;
        self.cursor_file = f;
        self.event_count = 0;

        var cfg = shim.CaptureConfig{
            .target_fps = self.options.target_fps,
            .capture_cursor = if (self.options.capture_cursor) 1 else 0,
            .capture_webcam = if (self.options.capture_webcam) 1 else 0,
            .capture_system_audio = if (self.options.capture_system_audio) 1 else 0,
            .capture_mic_audio = if (self.options.capture_mic_audio) 1 else 0,
            .on_screen_frame = screenFrameCallback,
            .on_webcam_frame = null,
            .on_audio_frame = audioFrameCallback,
            .on_cursor_event = cursorEventCallback,
            .user_data = self,
        };

        if (self.options.display_id.len > 0 and self.options.display_id.len < cfg.display_id.len) {
            @memcpy(cfg.display_id[0..self.options.display_id.len], self.options.display_id);
            cfg.display_id[self.options.display_id.len] = 0;
        }

        const handle = shim.osc_capture_create(&cfg) orelse return error.CaptureCreateFailed;
        self.handle = handle;

        self.session_start_ns = getNanoTimestamp();
        self.pause_start_ns = 0;
        self.total_paused_ns = 0;

        if (shim.osc_capture_start(handle) != 0) {
            return error.CaptureStartFailed;
        }

        self.state = .recording;
    }

    pub fn pause(self: *CaptureSession) !void {
        if (self.state != .recording) return;
        self.pause_start_ns = getNanoTimestamp();
        self.state = .paused;
        if (self.handle) |h| {
            _ = shim.osc_capture_pause(h);
        }
    }

    pub fn resumeCapture(self: *CaptureSession) !void {
        if (self.state != .paused) return;
        const now = getNanoTimestamp();
        if (self.pause_start_ns > 0) {
            self.total_paused_ns += (now - self.pause_start_ns);
            self.pause_start_ns = 0;
        }
        self.state = .recording;
        if (self.handle) |h| {
            _ = shim.osc_capture_resume(h);
        }
    }

    pub const @"resume" = resumeCapture;

    pub fn stop(self: *CaptureSession) !void {
        if (self.state == .stopped or self.state == .idle) return;
        if (self.handle) |h| {
            _ = shim.osc_capture_stop(h);
            shim.osc_capture_destroy(h);
            self.handle = null;
        }
        if (self.cursor_file) |f| {
            _ = fflush(f);
            _ = std.c.fclose(f);
            self.cursor_file = null;
        }
        self.state = .stopped;
    }

    pub fn restartTake(self: *CaptureSession) !void {
        try self.stop();
        self.session_start_ns = 0;
        self.pause_start_ns = 0;
        self.total_paused_ns = 0;
        self.event_count = 0;
        try self.start();
    }

    pub fn cancelTake(self: *CaptureSession) !void {
        try self.stop();
        var buf: [1024]u8 = undefined;
        @memcpy(buf[0..self.cursor_file_path.len], self.cursor_file_path);
        buf[self.cursor_file_path.len] = 0;
        _ = remove(@ptrCast(&buf));
        self.state = .idle;
    }

    pub fn getRemappedPts(self: *const CaptureSession, raw_pts_ns: i64) ?i64 {
        if (self.state == .paused) return null;
        const pts = raw_pts_ns - self.session_start_ns - self.total_paused_ns;
        return if (pts < 0) 0 else pts;
    }

    pub fn setFrameHandler(self: *CaptureSession, handler: FrameHandler, ctx: *anyopaque) void {
        self.frame_handler = handler;
        self.frame_handler_ctx = ctx;
    }

    pub fn setAudioHandler(self: *CaptureSession, handler: AudioHandler, ctx: *anyopaque) void {
        self.audio_handler = handler;
        self.audio_handler_ctx = ctx;
    }

    fn writeCursorJsonl(self: *CaptureSession, ev: *const shim.CursorEvent, remapped_pts: i64) void {
        const f = self.cursor_file orelse return;

        const shape_str: []const u8 = switch (@as(shim.CursorShape, @fromBackingInt(@intCast(ev.shape)))) {
            .default => "default",
            .pointer => "pointer",
            .ibeam => "ibeam",
            .crosshair => "crosshair",
            .hand => "hand",
            .resize => "resize",
        };

        const event_str: []const u8 = switch (@as(shim.MouseEventType, @fromBackingInt(@intCast(ev.event_type)))) {
            .move => "move",
            .down => "down",
            .up => "up",
            .scroll => "scroll",
        };

        const button_str: []const u8 = switch (@as(shim.MouseButton, @fromBackingInt(@intCast(ev.button)))) {
            .none => "none",
            .left => "left",
            .right => "right",
            .middle => "middle",
        };

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "{{\"timestamp_ns\":{d},\"x\":{d:.4},\"y\":{d:.4},\"raw_x\":{d},\"raw_y\":{d},\"shape\":\"{s}\",\"event\":\"{s}\",\"button\":\"{s}\",\"scroll_dx\":{d:.2},\"scroll_dy\":{d:.2}}}\n",
            .{
                remapped_pts,
                ev.x,
                ev.y,
                ev.raw_x,
                ev.raw_y,
                shape_str,
                event_str,
                button_str,
                ev.scroll_dx,
                ev.scroll_dy,
            },
        ) catch return;

        _ = std.c.fwrite(line.ptr, 1, line.len, f);
        self.event_count += 1;
    }

    fn screenFrameCallback(
        data: ?[*]const u8,
        width: u32,
        height: u32,
        stride: u32,
        format: c_int,
        pts_ns: i64,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *CaptureSession = @ptrCast(@alignCast(user_data orelse return));
        const pts = self.getRemappedPts(pts_ns) orelse return;
        const d = data orelse return;

        if (self.frame_handler) |h| {
            const frame_bytes = @as(usize, stride) * @as(usize, height);
            h(self.frame_handler_ctx.?, .{
                .data = d[0..frame_bytes],
                .width = width,
                .height = height,
                .stride = stride,
                .format = @fromBackingInt(@intCast(format)),
                .pts_ns = pts,
            });
        }
    }

    fn audioFrameCallback(
        is_system: c_int,
        pcm_samples: ?[*]const f32,
        num_samples: u32,
        sample_rate: u32,
        channels: u32,
        pts_ns: i64,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *CaptureSession = @ptrCast(@alignCast(user_data orelse return));
        const pts = self.getRemappedPts(pts_ns) orelse return;
        const pcm = pcm_samples orelse return;

        if (self.audio_handler) |h| {
            const total_floats = @as(usize, num_samples) * @as(usize, channels);
            h(self.audio_handler_ctx.?, .{
                .is_system = (is_system != 0),
                .samples = pcm[0..total_floats],
                .sample_rate = sample_rate,
                .channels = channels,
                .pts_ns = pts,
            });
        }
    }

    fn cursorEventCallback(
        event: ?*const shim.CursorEvent,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *CaptureSession = @ptrCast(@alignCast(user_data orelse return));
        const ev = event orelse return;
        const pts = self.getRemappedPts(ev.timestamp_ns) orelse return;
        self.writeCursorJsonl(ev, pts);
    }
};
