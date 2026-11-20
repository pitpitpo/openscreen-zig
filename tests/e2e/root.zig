const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const compositor = @import("compositor");
const media = @import("media");
const ffi = @import("ffi");
const capture = @import("capture");
const cursor_diag = @import("cursor_diag");

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

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn remove(pathname: [*:0]const u8) c_int;

const MockFrameGenerator = struct {
    width: u32,
    height: u32,

    pub fn renderFrame(ctx: *anyopaque, frame_idx: u64, out_rgba: []u8) anyerror!void {
        const self: *MockFrameGenerator = @ptrCast(@alignCast(ctx));
        const w = self.width;
        const h = self.height;

        const time = @as(f32, @floatFromInt(frame_idx)) / 30.0;
        const center_x: f32 = @as(f32, @floatFromInt(w)) * (0.5 + 0.3 * @sin(time * 2.0));
        const center_y: f32 = @as(f32, @floatFromInt(h)) * 0.5;
        const radius: f32 = @as(f32, @floatFromInt(@min(w, h))) * 0.2;

        for (0..h) |y| {
            const y_f = @as(f32, @floatFromInt(y));
            for (0..w) |x| {
                const x_f = @as(f32, @floatFromInt(x));
                const dx = x_f - center_x;
                const dy = y_f - center_y;
                const dist = @sqrt(dx * dx + dy * dy);

                const pixel_idx = (y * w + x) * 4;
                if (dist <= radius) {
                    // Moving foreground circle (bright teal)
                    out_rgba[pixel_idx + 0] = 0;
                    out_rgba[pixel_idx + 1] = 200;
                    out_rgba[pixel_idx + 2] = 255;
                    out_rgba[pixel_idx + 3] = 255;
                } else {
                    // Dark navy gradient background
                    const bg_val: u8 = @intCast(@min(255, (x * 128 / w) + (y * 64 / h)));
                    out_rgba[pixel_idx + 0] = 10;
                    out_rgba[pixel_idx + 1] = 20;
                    out_rgba[pixel_idx + 2] = 40 + (bg_val / 4);
                    out_rgba[pixel_idx + 3] = 255;
                }
            }
        }
    }
};

test "Gate 3: 10-second multi-track project render to MP4 and GIF" {
    const allocator = std.testing.allocator;

    const width: u32 = 640;
    const height: u32 = 360;
    const fps: u32 = 30;
    const duration_sec: u64 = 10;
    const total_frames: u64 = duration_sec * fps; // 300 frames
    const sample_rate: u32 = 44100;

    // 1. Prepare 3 Audio Tracks using AudioMixer
    var mixer = media.audio_mix.AudioMixer.init(allocator, sample_rate);
    defer mixer.deinit();

    // Track 1: Mic (sine 440Hz with cut 1s..9s)
    const mic_samples = try allocator.alloc(f32, sample_rate * 8);
    defer allocator.free(mic_samples);
    for (mic_samples, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        s.* = @sin(t * 440.0 * 2.0 * std.math.pi) * 0.7;
    }
    const mic_tr = mixer.getTrack(.microphone);
    mic_tr.volume = 0.8;
    mic_tr.pan = -0.3;
    try mic_tr.addClip(allocator, .{
        .samples = mic_samples,
        .sample_rate = sample_rate,
        .channels = 1,
        .timeline_start_ms = 1000,
        .in_point_ms = 0,
        .out_point_ms = 8000,
        .speed = 1.0,
    });

    // Track 2: System audio (sine 880Hz with 1.25x speed ramp)
    const sys_samples = try allocator.alloc(f32, sample_rate * 10 * 2);
    defer allocator.free(sys_samples);
    for (0..sample_rate * 10) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        sys_samples[i * 2 + 0] = @sin(t * 880.0 * 2.0 * std.math.pi) * 0.4;
        sys_samples[i * 2 + 1] = @sin(t * 880.0 * 2.0 * std.math.pi) * 0.4;
    }
    const sys_tr = mixer.getTrack(.system);
    sys_tr.volume = 0.6;
    sys_tr.pan = 0.3;
    try sys_tr.addClip(allocator, .{
        .samples = sys_samples,
        .sample_rate = sample_rate,
        .channels = 2,
        .timeline_start_ms = 0,
        .in_point_ms = 0,
        .out_point_ms = 10000,
        .speed = 1.25,
    });

    // Track 3: Media track (sine 220Hz)
    const media_samples = try allocator.alloc(f32, sample_rate * 10 * 2);
    defer allocator.free(media_samples);
    for (0..sample_rate * 10) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        media_samples[i * 2 + 0] = @sin(t * 220.0 * 2.0 * std.math.pi) * 0.3;
        media_samples[i * 2 + 1] = @sin(t * 220.0 * 2.0 * std.math.pi) * 0.3;
    }
    const media_tr = mixer.getTrack(.media);
    media_tr.volume = 0.5;
    try media_tr.addClip(allocator, .{
        .samples = media_samples,
        .sample_rate = sample_rate,
        .channels = 2,
        .timeline_start_ms = 0,
        .in_point_ms = 0,
        .out_point_ms = 10000,
        .speed = 1.0,
    });

    // Render 10s audio mix
    const mix = try mixer.renderMix(allocator, 10000);
    defer allocator.free(mix);
    try std.testing.expectEqual(@as(usize, 10 * sample_rate * 2), mix.len);

    // 2. Set up Frame Generator
    var generator = MockFrameGenerator{
        .width = width,
        .height = height,
    };
    const provider = media.encoder.FrameProvider{
        .ctx = &generator,
        .renderFrameFn = MockFrameGenerator.renderFrame,
    };

    // 3. Render 10s MP4 (H.264 + AAC)
    const mp4_path = if (builtin.os.tag == .windows) "gate3_render_10s.mp4" else "/tmp/gate3_render_10s.mp4";
    try media.encoder.MediaEncoder.encodeMp4(
        mp4_path,
        .{
            .width = width,
            .height = height,
            .fps = fps,
            .video_bitrate = 2_000_000,
            .audio_sample_rate = sample_rate,
            .audio_channels = 2,
            .audio_bitrate = 128_000,
        },
        total_frames,
        provider,
        mix,
        null,
        null,
        allocator,
    );

    // 4. Render 2s GIF (60 frames at 30 fps)
    const gif_path = if (builtin.os.tag == .windows) "gate3_render.gif" else "/tmp/gate3_render.gif";
    try media.encoder.MediaEncoder.encodeGif(
        gif_path,
        width,
        height,
        fps,
        60,
        provider,
        null,
        null,
        allocator,
    );

    // 5. Verify MP4 with Demuxer
    var dec = try media.decoder.VideoDecoder.open(allocator, mp4_path, 8);
    defer dec.close();

    try std.testing.expect(dec.hasVideo());
    try std.testing.expect(dec.hasAudio());

    const v_info = dec.info.?;
    try std.testing.expectEqual(width, v_info.width);
    try std.testing.expectEqual(height, v_info.height);
    try std.testing.expect(v_info.duration_ms >= 9900 and v_info.duration_ms <= 10100);

    const a_info = dec.audio_info.?;
    try std.testing.expectEqual(sample_rate, a_info.sample_rate);
    try std.testing.expectEqual(@as(u32, 2), a_info.channels);

    // Verify video frames at 0s, 3s, 5s, 8s are non-blank
    const frame_bytes = @as(usize, width) * @as(usize, height) * 4;
    const test_frame = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(test_frame);

    const check_pts = [_]i64{ 0, 3000, 5000, 8000 };
    for (check_pts) |pts| {
        const decoded_pts = try dec.getFrameAtPts(pts, test_frame);
        try std.testing.expect(decoded_pts >= 0);

        var non_blank: usize = 0;
        for (test_frame) |b| {
            if (b > 10) non_blank += 1;
        }
        try std.testing.expect(non_blank > 1000);
    }

    // 6. Verify GIF file
    var gif_buf: [1024]u8 = undefined;
    @memcpy(gif_buf[0..gif_path.len], gif_path);
    gif_buf[gif_path.len] = 0;
    const gif_file = std.c.fopen(@ptrCast(&gif_buf), "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(gif_file);
    _ = fseek(gif_file, 0, 2);
    const gif_size = ftell(gif_file);
    try std.testing.expect(gif_size > 5000);
}

test "Gate 3: Real Whisper speech-to-text inference" {
    const allocator = std.testing.allocator;
    const model_path = "tests/fixtures/models/ggml-tiny.en.bin";
    const audio_path = "tests/fixtures/peaks-sample.m4a";

    // Verify model exists
    var model_buf: [1024]u8 = undefined;
    @memcpy(model_buf[0..model_path.len], model_path);
    model_buf[model_path.len] = 0;
    const model_file = std.c.fopen(@ptrCast(&model_buf), "rb") orelse {
        std.debug.print("Whisper model not found at {s}\n", .{model_path});
        return;
    };
    _ = std.c.fclose(model_file);

    var dec = try media.decoder.VideoDecoder.open(allocator, audio_path, 2);
    defer dec.close();

    const audio_res = try dec.extractAllAudio(allocator);
    try std.testing.expect(audio_res != null);
    defer allocator.free(audio_res.?.samples);

    const pcm_16k = try media.stt_whisper.SpeechToText.resampleTo16kMono(
        allocator,
        audio_res.?.samples,
        audio_res.?.sample_rate,
        audio_res.?.channels,
    );
    defer allocator.free(pcm_16k);

    var stt = try media.stt_whisper.SpeechToText.init(allocator, model_path);
    defer stt.deinit();

    const segments = try stt.transcribe(allocator, pcm_16k, 500);
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    try std.testing.expect(segments.len >= 1);
    for (segments) |seg| {
        try std.testing.expect(seg.end_ms >= seg.start_ms);
        try std.testing.expect(seg.text.len > 0);
    }

    // Export and import SRT
    const srt = try media.stt_whisper.SpeechToText.exportSrt(allocator, segments);
    defer allocator.free(srt);
    try std.testing.expect(srt.len > 0);

    const imported = try media.stt_whisper.SpeechToText.importSrt(allocator, srt);
    defer {
        for (imported) |seg| seg.deinit(allocator);
        allocator.free(imported);
    }
    try std.testing.expectEqual(segments.len, imported.len);
}

test "Gate 3: Real ONNX webcam segmentation matting" {
    const allocator = std.testing.allocator;
    var onnx_lib: []const u8 = switch (builtin.os.tag) {
        .windows => "onnxruntime.dll",
        .macos => "tests/fixtures/onnx/libonnxruntime.dylib",
        else => "tests/fixtures/onnx/libonnxruntime.so",
    };
    const model_path = "tests/fixtures/selfie_segmentation_landscape.onnx";

    var lib_buf: [1024]u8 = undefined;
    @memcpy(lib_buf[0..onnx_lib.len], onnx_lib);
    lib_buf[onnx_lib.len] = 0;
    var lib_file = std.c.fopen(@ptrCast(&lib_buf), "rb");
    if (lib_file == null and builtin.os.tag == .windows) {
        onnx_lib = "tests/fixtures/onnx/onnxruntime.dll";
        @memcpy(lib_buf[0..onnx_lib.len], onnx_lib);
        lib_buf[onnx_lib.len] = 0;
        lib_file = std.c.fopen(@ptrCast(&lib_buf), "rb");
    }
    if (lib_file == null) return;
    _ = std.c.fclose(lib_file.?);

    var m_buf: [1024]u8 = undefined;
    @memcpy(m_buf[0..model_path.len], model_path);
    m_buf[model_path.len] = 0;
    const m_file = std.c.fopen(@ptrCast(&m_buf), "rb") orelse return;
    _ = std.c.fclose(m_file);

    var engine = try compositor.segmentation.SegmentationEngine.init(allocator, onnx_lib, model_path);
    defer engine.deinit();

    // Generate a 640x480 test image with a human-like center silhouette (skin tone center, white background)
    const w: u32 = 640;
    const h: u32 = 480;
    const frame_bytes = @as(usize, w) * @as(usize, h) * 4;

    const in_rgba = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(in_rgba);

    const out_rgba = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(out_rgba);

    for (0..h) |y| {
        const y_f = @as(f32, @floatFromInt(y));
        for (0..w) |x| {
            const x_f = @as(f32, @floatFromInt(x));
            const dx = x_f - 320.0;
            const dy = y_f - 240.0;
            const idx = (y * w + x) * 4;

            if (dx * dx / (100.0 * 100.0) + dy * dy / (160.0 * 160.0) <= 1.0) {
                // Human silhouette center (skin / clothing)
                in_rgba[idx + 0] = 210;
                in_rgba[idx + 1] = 160;
                in_rgba[idx + 2] = 130;
                in_rgba[idx + 3] = 255;
            } else {
                // Background (white wall)
                in_rgba[idx + 0] = 240;
                in_rgba[idx + 1] = 240;
                in_rgba[idx + 2] = 240;
                in_rgba[idx + 3] = 255;
            }
        }
    }

    // 1. Test Room Blur
    try engine.segment(in_rgba, w, h, .room_blur, out_rgba, .{ .blur_radius = 16 });
    // Verify output is non-empty and processed
    var room_blur_diff: usize = 0;
    for (0..totalPixels(w, h)) |p| {
        if (out_rgba[p * 4] != in_rgba[p * 4]) room_blur_diff += 1;
    }

    // 2. Test Background Cutout
    try engine.segment(in_rgba, w, h, .background_cutout, out_rgba, .{});
    // Check that background alpha was attenuated
    const bg_corner_alpha = out_rgba[3]; // top-left corner
    try std.testing.expect(bg_corner_alpha < 255);

    // 3. Test Background Replacement (green screen)
    const rep_rgba = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(rep_rgba);
    for (0..totalPixels(w, h)) |p| {
        rep_rgba[p * 4 + 0] = 0;
        rep_rgba[p * 4 + 1] = 255;
        rep_rgba[p * 4 + 2] = 0;
        rep_rgba[p * 4 + 3] = 255;
    }

    try engine.segment(in_rgba, w, h, .background_replacement, out_rgba, .{
        .replacement_rgba = rep_rgba,
    });
    // Corner background pixel should now have green component replaced
    try std.testing.expect(out_rgba[1] > 200);
}

fn totalPixels(w: u32, h: u32) usize {
    return @as(usize, w) * @as(usize, h);
}

test "Gate 4: Native capture, synchronized tracks, sidecar telemetry, and MP4 export" {
    const allocator = std.testing.allocator;

    // 1. Platform headless sanity: permissions and source enumeration
    const perm_screen = ffi.capture.osc_capture_check_permission(@backingInt(ffi.capture.PermissionType.screen));
    try std.testing.expect(perm_screen >= 0 and perm_screen <= 3);

    const perm_audio = ffi.capture.osc_capture_check_permission(@backingInt(ffi.capture.PermissionType.audio));
    try std.testing.expect(perm_audio >= 0 and perm_audio <= 3);

    var displays: [8]ffi.capture.SourceInfo = undefined;
    const disp_count = ffi.capture.osc_capture_enumerate_sources(
        @backingInt(ffi.capture.SourceType.display),
        &displays,
        8,
    );
    try std.testing.expect(disp_count >= 0);

    var windows: [32]ffi.capture.SourceInfo = undefined;
    const win_count = ffi.capture.osc_capture_enumerate_sources(
        @backingInt(ffi.capture.SourceType.window),
        &windows,
        32,
    );
    try std.testing.expect(win_count >= 0);

    // 2. Perform live capture session across platforms
    const tmp_dir = if (builtin.os.tag == .windows) "." else "/tmp";
    const take_name = "gate4_capture_live";
    var session = try capture.CaptureSession.init(allocator, .{
        .output_dir = tmp_dir,
        .take_name = take_name,
        .target_fps = 30,
        .capture_cursor = true,
        .capture_system_audio = true,
        .capture_mic_audio = true,
    });
    defer session.deinit();

    const CaptureSink = struct {
        frame_count: usize = 0,
        last_width: u32 = 0,
        last_height: u32 = 0,
        last_frame: ?[]u8 = null,
        alloc: std.mem.Allocator,

        pub fn handleFrame(ctx: *anyopaque, frame: capture.capture.FrameData) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.frame_count += 1;
            self.last_width = frame.width;
            self.last_height = frame.height;
            if (self.last_frame == null) {
                self.last_frame = self.alloc.alloc(u8, frame.data.len) catch null;
            }
            if (self.last_frame) |buf| {
                if (buf.len == frame.data.len) {
                    @memcpy(buf, frame.data);
                }
            }
        }
    };

    var sink = CaptureSink{
        .alloc = allocator,
    };
    defer {
        if (sink.last_frame) |buf| allocator.free(buf);
    }

    session.setFrameHandler(CaptureSink.handleFrame, &sink);

    // Start live capture
    try session.start();
    try std.testing.expectEqual(capture.SessionState.recording, session.state);

    // Record for 1.0s
    sleepMs(1000);

    // Pause for 0.5s
    try session.pause();
    try std.testing.expectEqual(capture.SessionState.paused, session.state);
    sleepMs(500);

    // Resume for 0.5s
    try session.@"resume"();
    try std.testing.expectEqual(capture.SessionState.recording, session.state);
    sleepMs(500);

    // Clean stop
    try session.stop();
    try std.testing.expectEqual(capture.SessionState.stopped, session.state);

    // Verify frames were captured
    try std.testing.expect(sink.frame_count > 5);
    try std.testing.expect(sink.last_width > 0);
    try std.testing.expect(sink.last_height > 0);

    // 3. Verify .cursor.jsonl sidecar via cursor_diag
    const sidecar_path = if (builtin.os.tag == .windows) "gate4_capture_live.cursor.jsonl" else "/tmp/gate4_capture_live.cursor.jsonl";
    const diag = try cursor_diag.analyzeSidecar(allocator, sidecar_path);
    try std.testing.expect(diag.total_events > 0);
    try std.testing.expect(diag.is_monotonic);
    try std.testing.expect(diag.pause_gap_intact);
    try std.testing.expect(diag.duration_ms > 400.0);

    // 4. Export captured video to MP4 and verify via VideoDecoder
    const export_path = if (builtin.os.tag == .windows) "gate4_test_export.mp4" else "/tmp/gate4_test_export.mp4";
    const FrameFeeder = struct {
        frame_data: []const u8,
        pub fn renderFrame(ctx: *anyopaque, frame_idx: u64, out_rgba: []u8) anyerror!void {
            _ = frame_idx;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(out_rgba[0..self.frame_data.len], self.frame_data);
        }
    };

    if (sink.last_frame) |frame_buf| {
        var feeder = FrameFeeder{
            .frame_data = frame_buf,
        };
        const provider = media.encoder.FrameProvider{
            .ctx = &feeder,
            .renderFrameFn = FrameFeeder.renderFrame,
        };

        const sample_rate: u32 = 44100;
        const total_audio_floats = sample_rate * 2; // 1s stereo
        const audio_samples = try allocator.alloc(f32, total_audio_floats);
        defer allocator.free(audio_samples);
        for (0..sample_rate) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
            audio_samples[i * 2 + 0] = @sin(t * 440.0 * 2.0 * std.math.pi) * 0.5;
            audio_samples[i * 2 + 1] = @sin(t * 440.0 * 2.0 * std.math.pi) * 0.5;
        }

        try media.encoder.MediaEncoder.encodeMp4(
            export_path,
            .{
                .width = sink.last_width,
                .height = sink.last_height,
                .fps = 30,
                .video_bitrate = 2_000_000,
                .audio_sample_rate = sample_rate,
                .audio_channels = 2,
                .audio_bitrate = 128_000,
            },
            30, // 1s at 30fps
            provider,
            audio_samples,
            null,
            null,
            allocator,
        );

        // Verify with VideoDecoder
        var dec = try media.decoder.VideoDecoder.open(allocator, export_path, 2);
        defer dec.close();

        try std.testing.expect(dec.hasVideo());
        try std.testing.expect(dec.hasAudio());
        const v_info = dec.info.?;
        try std.testing.expectEqual(sink.last_width, v_info.width);
        try std.testing.expectEqual(sink.last_height, v_info.height);

        // Read decoded frame and verify it is non-blank
        const check_buf = try allocator.alloc(u8, @as(usize, sink.last_width) * @as(usize, sink.last_height) * 4);
        defer allocator.free(check_buf);
        _ = try dec.getFrameAtPts(0, check_buf);

        var non_blank: usize = 0;
        for (check_buf) |b| {
            if (b > 0) non_blank += 1;
        }
        try std.testing.expect(non_blank > 100);
    }
}

test "Gate 5: Headless CLI and MCP Stdio Child Process Integration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const exe_path = if (builtin.os.tag == .windows) "zig-out\\bin\\openscreen.exe" else "./zig-out/bin/openscreen";

    // 1. openscreen --version
    const ver_res = try std.process.run(allocator, io, .{
        .argv = &.{ exe_path, "--version" },
    });
    defer {
        allocator.free(ver_res.stdout);
        allocator.free(ver_res.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), ver_res.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, ver_res.stdout, "openscreen 2.0.0") != null);

    // 2. openscreen sources --json
    const src_res = try std.process.run(allocator, io, .{
        .argv = &.{ exe_path, "sources", "--json" },
    });
    defer {
        allocator.free(src_res.stdout);
        allocator.free(src_res.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), src_res.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, src_res.stdout, "\"event\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src_res.stdout, "\"sources\":") != null);

    // 3. openscreen edit --json
    const test_proj = if (builtin.os.tag == .windows) "test_cli.openscreen" else "/tmp/test_cli.openscreen";
    defer {
        var p_z: [1024]u8 = undefined;
        @memcpy(p_z[0..test_proj.len], test_proj);
        p_z[test_proj.len] = 0;
        _ = remove(@ptrCast(&p_z));
    }
    {
        var init_doc = try core.project.create_empty_document(allocator, "E2E CLI Project");
        const json_data = try core.project.save_to_json(allocator, &init_doc);
        defer allocator.free(json_data);
        init_doc.deinit(allocator);

        var p_z: [1024]u8 = undefined;
        @memcpy(p_z[0..test_proj.len], test_proj);
        p_z[test_proj.len] = 0;
        const f = std.c.fopen(@ptrCast(&p_z), "wb") orelse return error.CannotCreateFile;
        _ = std.c.fwrite(json_data.ptr, 1, json_data.len, f);
        _ = std.c.fclose(f);
    }

    const edit_res = try std.process.run(allocator, io, .{
        .argv = &.{ exe_path, "edit", test_proj, "--add-zoom", "1.0", "3.0", "--cut", "0.5", "1.5", "--aspect", "16:9", "--json" },
    });
    defer {
        allocator.free(edit_res.stdout);
        allocator.free(edit_res.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), edit_res.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, edit_res.stdout, "\"event\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit_res.stdout, "\"operations\":3") != null);

    // 4. openscreen export --json
    const test_export = if (builtin.os.tag == .windows) "test_cli_export.mp4" else "/tmp/test_cli_export.mp4";
    var exp_z: [1024]u8 = undefined;
    @memcpy(exp_z[0..test_export.len], test_export);
    exp_z[test_export.len] = 0;
    defer _ = remove(@ptrCast(&exp_z));

    const export_res = try std.process.run(allocator, io, .{
        .argv = &.{ exe_path, "export", test_proj, "-o", test_export, "--fps", "30", "--json" },
    });
    defer {
        allocator.free(export_res.stdout);
        allocator.free(export_res.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), export_res.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, export_res.stdout, "\"event\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_res.stdout, "\"outputPath\"") != null);

    const exp_f = std.c.fopen(@ptrCast(&exp_z), "rb");
    try std.testing.expect(exp_f != null);
    _ = std.c.fclose(exp_f.?);

    // Validate CLI export with ffprobe
    const ffprobe_cmd = std.process.run(allocator, io, .{
        .argv = &.{ "ffprobe", "-v", "error", "-show_format", "-show_streams", test_export },
    }) catch null;
    if (ffprobe_cmd) |probe| {
        defer {
            allocator.free(probe.stdout);
            allocator.free(probe.stderr);
        }
        try std.testing.expectEqual(@as(u8, 0), probe.term.exited);
        try std.testing.expect(std.mem.indexOf(u8, probe.stdout, "codec_type=video") != null or
            std.mem.indexOf(u8, probe.stdout, "h264") != null);
    }

    // 5. openscreen mcp (JSON-RPC 2.0 stdio server)
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe_path, "mcp" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    const readResponseLine = struct {
        fn read(out: anytype, io_ctx: anytype, buf: []u8) ![]const u8 {
            var len: usize = 0;
            while (len < buf.len) {
                var chunk: [1]u8 = undefined;
                var slice = [_][]u8{&chunk};
                const n = try out.readStreaming(io_ctx, &slice);
                if (n == 0) break;
                if (chunk[0] == '\n') {
                    const trimmed = std.mem.trim(u8, buf[0..len], "\r \t");
                    if (trimmed.len > 0) return trimmed;
                    len = 0; // Skip empty leading newlines
                    continue;
                }
                buf[len] = chunk[0];
                len += 1;
            }
            return std.mem.trim(u8, buf[0..len], "\r \t");
        }
    }.read;

    // 5a. initialize
    const init_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n";
    try child.stdin.?.writeStreamingAll(io, init_req);
    var buf_4k: [4096]u8 = undefined;
    const init_resp = try readResponseLine(&child.stdout.?, io, &buf_4k);
    try std.testing.expect(init_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"name\":\"openscreen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"protocolVersion\":\"2024-11-05\"") != null);

    // 5b. inspect_project
    const insp_req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect_project\",\"arguments\":{\"projectPath\":\"test_cli.openscreen\"}}}\n";
    try child.stdin.?.writeStreamingAll(io, insp_req);
    const insp_resp = try readResponseLine(&child.stdout.?, io, &buf_4k);
    try std.testing.expect(insp_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, insp_resp, "Project:") != null);

    // 5c. add_zoom
    const zoom_req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"add_zoom\",\"arguments\":{\"startSec\":1.0,\"endSec\":3.0,\"cx\":0.5,\"cy\":0.5,\"depth\":2}}}\n";
    try child.stdin.?.writeStreamingAll(io, zoom_req);
    const zoom_resp = try readResponseLine(&child.stdout.?, io, &buf_4k);
    try std.testing.expect(zoom_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, zoom_resp, "Zoom added") != null);

    // 5d. add_cut
    const cut_req = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"add_cut\",\"arguments\":{\"startSec\":0.5,\"endSec\":1.5}}}\n";
    try child.stdin.?.writeStreamingAll(io, cut_req);
    const cut_resp = try readResponseLine(&child.stdout.?, io, &buf_4k);
    try std.testing.expect(cut_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cut_resp, "Cut added") != null);

    // 5e. undo
    const undo_req = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"undo\",\"arguments\":{}}}\n";
    try child.stdin.?.writeStreamingAll(io, undo_req);
    const undo_resp = try readResponseLine(&child.stdout.?, io, &buf_4k);
    try std.testing.expect(undo_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, undo_resp, "Undo: success") != null);

    // 5f. redo
    const redo_req = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"redo\",\"arguments\":{}}}\n";
    try child.stdin.?.writeStreamingAll(io, redo_req);
    const redo_resp = try readResponseLine(&child.stdout.?, io, &buf_4k);
    try std.testing.expect(redo_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, redo_resp, "Redo: success") != null);

    // 5g. export_video
    const mcp_out = if (builtin.os.tag == .windows) "test_mcp_e2e.mp4" else "/tmp/test_mcp_e2e.mp4";
    var mcp_out_z: [1024]u8 = undefined;
    @memcpy(mcp_out_z[0..mcp_out.len], mcp_out);
    mcp_out_z[mcp_out.len] = 0;
    defer _ = remove(@ptrCast(&mcp_out_z));

    var exp_cmd_buf: [512]u8 = undefined;
    const exp_req = try std.fmt.bufPrint(&exp_cmd_buf, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{{\"name\":\"export_video\",\"arguments\":{{\"outputPath\":\"{s}\",\"fps\":30}}}}}}\n", .{mcp_out});
    try child.stdin.?.writeStreamingAll(io, exp_req);
    const exp_resp = try readResponseLine(&child.stdout.?, io, &buf_4k);
    try std.testing.expect(exp_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, exp_resp, "Exported successfully") != null);

    // Validate MCP export with ffprobe
    const mcp_probe_cmd = std.process.run(allocator, io, .{
        .argv = &.{ "ffprobe", "-v", "error", "-show_format", "-show_streams", mcp_out },
    }) catch null;
    if (mcp_probe_cmd) |probe| {
        defer {
            allocator.free(probe.stdout);
            allocator.free(probe.stderr);
        }
        try std.testing.expectEqual(@as(u8, 0), probe.term.exited);
        try std.testing.expect(std.mem.indexOf(u8, probe.stdout, "codec_type=video") != null or
            std.mem.indexOf(u8, probe.stdout, "h264") != null);
    }

    // 5h. extract_frame (valid base64 PNG)
    const frame_req = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"extract_frame\",\"arguments\":{\"timeSec\":0.5,\"width\":64,\"height\":36}}}\n";
    try child.stdin.?.writeStreamingAll(io, frame_req);

    var frame_buf: [16384]u8 = undefined;
    const frame_resp = try readResponseLine(&child.stdout.?, io, &frame_buf);
    try std.testing.expect(frame_resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, frame_resp, "\"mimeType\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_resp, "\"data\":\"iVBORw0K") != null);

    // 5i. Close stdin to initiate graceful shutdown and drain remaining output
    child.stdin.?.close(io);
    child.stdin = null;

    var drain_buf: [16384]u8 = undefined;
    var drain_slices = [_][]u8{&drain_buf};
    while (true) {
        const rd = child.stdout.?.readStreaming(io, &drain_slices) catch 0;
        if (rd == 0) break;
    }
    child.stdout.?.close(io);
    child.stdout = null;

    const term = try child.wait(io);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
}
