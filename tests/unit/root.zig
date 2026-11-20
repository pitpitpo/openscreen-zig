const std = @import("std");
const core = @import("core");
const compositor = @import("compositor");
const media = @import("media");
const capture = @import("capture");
const ffi = @import("ffi");
const cursor_diag = @import("cursor_diag");

extern "c" fn remove(filename: [*:0]const u8) c_int;

test "unit tests root" {
    try std.testing.expect(true);
}

test "audio mixer: 3-track mixing, volume, pan, speed ramp, peaks" {
    const allocator = std.testing.allocator;
    var mixer = media.audio_mix.AudioMixer.init(allocator, 44100);
    defer mixer.deinit();

    // Track 1: Mic (mono sine 440Hz, 1 second = 44100 samples)
    const mic_samples = try allocator.alloc(f32, 44100);
    defer allocator.free(mic_samples);
    for (mic_samples, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        s.* = @sin(t * 440.0 * 2.0 * std.math.pi) * 0.8;
    }

    // Track 2: System (stereo sine 880Hz, 1 second = 88200 samples)
    const sys_samples = try allocator.alloc(f32, 88200);
    defer allocator.free(sys_samples);
    for (0..44100) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        sys_samples[i * 2 + 0] = @sin(t * 880.0 * 2.0 * std.math.pi) * 0.5;
        sys_samples[i * 2 + 1] = @sin(t * 880.0 * 2.0 * std.math.pi) * 0.5;
    }

    const mic_tr = mixer.getTrack(.microphone);
    mic_tr.volume = 0.9;
    mic_tr.pan = -0.5; // panned slightly left
    try mic_tr.addClip(allocator, .{
        .samples = mic_samples,
        .sample_rate = 44100,
        .channels = 1,
        .timeline_start_ms = 0,
        .in_point_ms = 0,
        .out_point_ms = 1000,
        .speed = 1.0,
    });

    const sys_tr = mixer.getTrack(.system);
    sys_tr.volume = 0.7;
    sys_tr.pan = 0.5; // panned slightly right
    try sys_tr.addClip(allocator, .{
        .samples = sys_samples,
        .sample_rate = 44100,
        .channels = 2,
        .timeline_start_ms = 500,
        .in_point_ms = 0,
        .out_point_ms = 1000,
        .speed = 2.0, // 2x speed ramp -> effective duration 500ms
    });

    // Render 2 seconds of mix
    const mix = try mixer.renderMix(allocator, 2000);
    defer allocator.free(mix);

    try std.testing.expectEqual(@as(usize, 2 * 44100 * 2), mix.len);

    // Verify non-silent samples
    var non_zero: usize = 0;
    for (mix) |val| {
        if (@abs(val) > 0.01) non_zero += 1;
    }
    try std.testing.expect(non_zero > 1000);

    // Compute multi-res peaks
    const peaks = try media.audio_mix.AudioMixer.computeMultiResPeaks(allocator, mix, 44100, 2);
    defer peaks.deinit(allocator);

    try std.testing.expect(peaks.peaks_100hz.len > 0);
    try std.testing.expect(peaks.peaks_10hz.len > 0);
    try std.testing.expect(peaks.peaks_1hz.len > 0);
}

test "media decoder: inspect sample.webm and extract frames" {
    const allocator = std.testing.allocator;
    var dec = try media.decoder.VideoDecoder.open(allocator, "tests/fixtures/sample.webm", 4);
    defer dec.close();

    try std.testing.expect(dec.hasVideo());
    const v_info = dec.info.?;
    try std.testing.expectEqual(@as(u32, 640), v_info.width);
    try std.testing.expectEqual(@as(u32, 480), v_info.height);

    const frame_bytes = @as(usize, v_info.width) * @as(usize, v_info.height) * 4;
    const buf = try allocator.alloc(u8, frame_bytes);
    defer allocator.free(buf);

    const pts = try dec.getFrameAtPts(0, buf);
    try std.testing.expect(pts >= 0);

    // Frame should have non-zero pixels
    var non_zero_pixels: usize = 0;
    for (buf) |b| {
        if (b > 0) non_zero_pixels += 1;
    }
    try std.testing.expect(non_zero_pixels > 100);

    // Test LRU cache hit
    const pts2 = try dec.getFrameAtPts(pts, buf);
    try std.testing.expectEqual(pts, pts2);
}

test "media decoder: handles audio-only peaks-sample.m4a" {
    const allocator = std.testing.allocator;
    var dec = try media.decoder.VideoDecoder.open(allocator, "tests/fixtures/peaks-sample.m4a", 2);
    defer dec.close();

    try std.testing.expect(!dec.hasVideo());
    try std.testing.expect(dec.hasAudio());
    try std.testing.expect(dec.getEffectiveDurationMs() > 0);

    const audio = try dec.extractAllAudio(allocator);
    try std.testing.expect(audio != null);
    defer allocator.free(audio.?.samples);

    try std.testing.expect(audio.?.samples.len > 0);
    try std.testing.expectEqual(@as(u32, 44100), audio.?.sample_rate);
}

test "stt whisper: SRT export and import roundtrip" {
    const allocator = std.testing.allocator;

    const segments = [_]media.stt_whisper.SttSegment{
        .{
            .start_ms = 0,
            .end_ms = 2500,
            .text = "Hello world from OpenScreen",
            .is_silence = false,
        },
        .{
            .start_ms = 2500,
            .end_ms = 4000,
            .text = "[silence 1.5s]",
            .is_silence = true,
        },
        .{
            .start_ms = 4000,
            .end_ms = 7200,
            .text = "High quality local speech recognition",
            .is_silence = false,
        },
    };

    const srt = try media.stt_whisper.SpeechToText.exportSrt(allocator, &segments);
    defer allocator.free(srt);

    try std.testing.expect(std.mem.indexOf(u8, srt, "00:00:00,000 --> 00:00:02,500") != null);
    try std.testing.expect(std.mem.indexOf(u8, srt, "Hello world from OpenScreen") != null);

    const imported = try media.stt_whisper.SpeechToText.importSrt(allocator, srt);
    defer {
        for (imported) |s| s.deinit(allocator);
        allocator.free(imported);
    }

    try std.testing.expectEqual(@as(usize, 3), imported.len);
    try std.testing.expectEqual(@as(i64, 0), imported[0].start_ms);
    try std.testing.expectEqual(@as(i64, 2500), imported[0].end_ms);
    try std.testing.expectEqualStrings("Hello world from OpenScreen", imported[0].text);
}

test "media encoder: test cancellation token" {
    var tok = media.encoder.CancellationToken{};
    try std.testing.expect(!tok.isCancelled());
    tok.cancel();
    try std.testing.expect(tok.isCancelled());
}

test "capture session: state transitions, countdown, and pause-resume gap excision" {
    const allocator = std.testing.allocator;

    const tmp_dir = if (@import("builtin").os.tag == .windows) "." else "/tmp";
    var session = try capture.CaptureSession.init(allocator, .{
        .output_dir = tmp_dir,
        .take_name = "test_unit_take",
        .target_fps = 60,
    });
    defer session.deinit();

    try std.testing.expectEqual(capture.SessionState.idle, session.state);

    // Test countdown
    try session.startCountdown(1);
    try std.testing.expectEqual(capture.SessionState.counting_down, session.state);

    // Mock session start
    session.session_start_ns = 1_000_000_000; // 1.0s
    session.state = .recording;

    // Normal pts at 2.0s -> remapped pts = 1.0s (1_000_000_000 ns)
    const pts1 = session.getRemappedPts(2_000_000_000);
    try std.testing.expect(pts1 != null);
    try std.testing.expectEqual(@as(i64, 1_000_000_000), pts1.?);

    // Simulate pause at 3.0s
    session.pause_start_ns = 3_000_000_000;
    session.state = .paused;

    // During pause, getRemappedPts returns null (discarded)
    const pts_paused = session.getRemappedPts(3_500_000_000);
    try std.testing.expect(pts_paused == null);

    // Simulate resume at 5.0s (paused for 2.0s = 2_000_000_000 ns)
    session.total_paused_ns += (5_000_000_000 - session.pause_start_ns);
    session.pause_start_ns = 0;
    session.state = .recording;

    // PTS at 5.5s -> remapped pts = 5.5s - 1.0s - 2.0s = 2.5s (2_500_000_000 ns)
    const pts2 = session.getRemappedPts(5_500_000_000);
    try std.testing.expect(pts2 != null);
    try std.testing.expectEqual(@as(i64, 2_500_000_000), pts2.?);

    // Clean stop
    session.state = .stopped;
}

test "capture audio: audio track buffer and capture router" {
    const allocator = std.testing.allocator;

    var track = capture.audio_capture.AudioTrackBuffer.init(allocator, 44100, 2);
    defer track.deinit();

    const test_samples = [_]f32{ 0.1, -0.2, 0.3, -0.4 };
    try track.append(&test_samples);
    try std.testing.expectEqual(@as(usize, 4), track.getSlice().len);
    try std.testing.expectEqual(@as(f32, 0.1), track.getSlice()[0]);

    track.reset();
    try std.testing.expectEqual(@as(usize, 0), track.getSlice().len);

    var ac = capture.AudioCapture.init(allocator, 48000);
    defer ac.deinit();

    const mic_data = [_]f32{ 0.5, 0.6 };
    const sys_data = [_]f32{ -0.5, -0.6, 0.7, 0.8 };

    try ac.handleAudioData(false, &mic_data);
    try ac.handleAudioData(true, &sys_data);

    try std.testing.expectEqual(@as(usize, 2), ac.mic_track.getSlice().len);
    try std.testing.expectEqual(@as(usize, 4), ac.system_track.getSlice().len);
}

test "capture webcam: frame buffer and thread-safe copy" {
    const allocator = std.testing.allocator;

    var wc = capture.WebcamCapture.init(allocator);
    defer wc.deinit();

    const dummy_rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    try wc.handleFrame(&dummy_rgba, 2, 1, 100_000);

    try std.testing.expectEqual(@as(u32, 2), wc.width);
    try std.testing.expectEqual(@as(u32, 1), wc.height);

    var copy_buf: [8]u8 = undefined;
    const copied = wc.copyLatestFrame(&copy_buf);
    try std.testing.expect(copied);
    try std.testing.expectEqualSlices(u8, &dummy_rgba, &copy_buf);
}

test "capture shims: source enumeration and permission query" {
    const perm = ffi.capture.osc_capture_check_permission(@backingInt(ffi.capture.PermissionType.screen));
    try std.testing.expect(perm >= 0 and perm <= 3);

    var sources: [16]ffi.capture.SourceInfo = undefined;
    const count = ffi.capture.osc_capture_enumerate_sources(
        @backingInt(ffi.capture.SourceType.display),
        &sources,
        16,
    );
    try std.testing.expect(count >= 0);
    if (count > 0) {
        try std.testing.expect(sources[0].width > 0);
        try std.testing.expect(sources[0].height > 0);
    }
}

test "cursor diag: sidecar analyzer validates monotonicity and clicks" {
    const allocator = std.testing.allocator;

    const sidecar_path = if (@import("builtin").os.tag == .windows) "test_diag.cursor.jsonl" else "/tmp/test_diag.cursor.jsonl";

    var path_z: [1024]u8 = undefined;
    @memcpy(path_z[0..sidecar_path.len], sidecar_path);
    path_z[sidecar_path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_z), "wb") orelse return error.CannotCreateFile;
    const lines =
        "{\"timestamp_ns\":0,\"x\":0.1000,\"y\":0.2000,\"raw_x\":100,\"raw_y\":200,\"shape\":\"default\",\"event\":\"move\",\"button\":\"none\",\"scroll_dx\":0.00,\"scroll_dy\":0.00}\n" ++
        "{\"timestamp_ns\":16666666,\"x\":0.1500,\"y\":0.2500,\"raw_x\":150,\"raw_y\":250,\"shape\":\"default\",\"event\":\"down\",\"button\":\"left\",\"scroll_dx\":0.00,\"scroll_dy\":0.00}\n" ++
        "{\"timestamp_ns\":33333333,\"x\":0.2000,\"y\":0.3000,\"raw_x\":200,\"raw_y\":300,\"shape\":\"pointer\",\"event\":\"up\",\"button\":\"left\",\"scroll_dx\":0.00,\"scroll_dy\":0.00}\n" ++
        "{\"timestamp_ns\":50000000,\"x\":0.3000,\"y\":0.4000,\"raw_x\":300,\"raw_y\":400,\"shape\":\"default\",\"event\":\"down\",\"button\":\"right\",\"scroll_dx\":0.00,\"scroll_dy\":0.00}\n" ++
        "{\"timestamp_ns\":66666666,\"x\":0.3500,\"y\":0.4500,\"raw_x\":350,\"raw_y\":450,\"shape\":\"default\",\"event\":\"up\",\"button\":\"right\",\"scroll_dx\":0.00,\"scroll_dy\":0.00}\n";
    _ = std.c.fwrite(lines.ptr, 1, lines.len, f);
    _ = std.c.fclose(f);
    defer _ = remove(@ptrCast(&path_z));

    const report = try cursor_diag.analyzeSidecar(allocator, sidecar_path);
    try std.testing.expectEqual(@as(u64, 5), report.total_events);
    try std.testing.expect(report.is_monotonic);
    try std.testing.expect(report.pause_gap_intact);
    try std.testing.expectEqual(@as(u32, 1), report.left_clicks);
    try std.testing.expectEqual(@as(u32, 1), report.right_clicks);
    try std.testing.expect(report.duration_ms > 60.0 and report.duration_ms < 70.0);
    try std.testing.expect(report.effective_hz > 50.0);
    try std.testing.expect(report.min_x >= 0.09 and report.max_x <= 0.36);
}

test {
    _ = core;
    _ = compositor;
    _ = media;
    _ = capture;
}
