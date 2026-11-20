const std = @import("std");
const core = @import("core");
const compositor = @import("compositor");
const media = @import("media");

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

test {
    _ = core;
    _ = compositor;
    _ = media;
}
