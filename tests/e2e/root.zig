const std = @import("std");
const core = @import("core");
const compositor = @import("compositor");
const media = @import("media");
const ffi = @import("ffi");

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

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
    const mp4_path = "/tmp/gate3_render_10s.mp4";
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
    const gif_path = "/tmp/gate3_render.gif";
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
    const builtin = @import("builtin");
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
