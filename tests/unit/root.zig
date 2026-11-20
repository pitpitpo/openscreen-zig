const std = @import("std");
const core = @import("core");
const compositor = @import("compositor");
const media = @import("media");
const capture = @import("capture");
const ffi = @import("ffi");
const cursor_diag = @import("cursor_diag");
const ai = @import("ai");
const cli = @import("cli");

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

test "ai: client 7 providers url and payload formatting, and token parsing" {
    const allocator = std.testing.allocator;

    const providers = [_]struct {
        provider: ai.client.Provider,
        name: []const u8,
        expected_url_substr: []const u8,
        model: []const u8,
    }{
        .{ .provider = .anthropic, .name = "anthropic", .expected_url_substr = "api.anthropic.com/v1/messages", .model = "claude-3-5-sonnet" },
        .{ .provider = .openai, .name = "openai", .expected_url_substr = "api.openai.com/v1/chat/completions", .model = "gpt-4o" },
        .{ .provider = .gemini, .name = "gemini", .expected_url_substr = "generativelanguage.googleapis.com", .model = "gemini-2.0-flash" },
        .{ .provider = .mistral, .name = "mistral", .expected_url_substr = "api.mistral.ai/v1/chat/completions", .model = "mistral-large" },
        .{ .provider = .openrouter, .name = "openrouter", .expected_url_substr = "openrouter.ai/api/v1/chat/completions", .model = "anthropic/claude-3.5-sonnet" },
        .{ .provider = .minimax, .name = "minimax", .expected_url_substr = "api.minimax.chat/v1/text/chatcompletion_v2", .model = "minimax-text-01" },
        .{ .provider = .custom, .name = "custom", .expected_url_substr = "127.0.0.1:8080/v1/chat/completions", .model = "local-llama" },
    };

    for (providers) |p| {
        try std.testing.expectEqual(p.provider, ai.client.Provider.fromString(p.name).?);

        const config = ai.client.Config{
            .provider = p.provider,
            .api_key = "test_secret_key_12345",
            .model = p.model,
        };
        var client_inst = ai.client.AiClient.init(allocator, config);
        defer client_inst.deinit();

        const url = try client_inst.buildRequestUrl(allocator);
        defer allocator.free(url);

        try std.testing.expect(std.mem.indexOf(u8, url, p.expected_url_substr) != null);

        const msgs = [_]ai.client.Message{
            .{ .role = "user", .content = "Hello, OpenScreen!" },
        };
        const payload = try client_inst.buildPayload(allocator, &msgs, &.{});
        defer allocator.free(payload);

        try std.testing.expect(payload.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, payload, "Hello, OpenScreen!") != null);
    }

    // Test parseResponse tool call and tokens extraction
    var default_client = ai.client.AiClient.init(allocator, .{});
    defer default_client.deinit();

    const mock_response_json =
        \\{
        \\  "choices": [{
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": "Added a zoom and cut",
        \\      "tool_calls": [{
        \\        "id": "call_abc",
        \\        "type": "function",
        \\        "function": {
        \\          "name": "add_zoom",
        \\          "arguments": "{\"startSec\":1.0,\"endSec\":3.0}"
        \\        }
        \\      }]
        \\    }
        \\  }],
        \\  "usage": {
        \\    "prompt_tokens": 120,
        \\    "completion_tokens": 45,
        \\    "total_tokens": 165
        \\  }
        \\}
    ;

    var resp = try default_client.parseResponse(mock_response_json);
    defer resp.deinit();

    try std.testing.expect(std.mem.indexOf(u8, resp.text, "Added a zoom and cut") != null);
    try std.testing.expectEqual(@as(usize, 1), resp.tool_calls.len);
    try std.testing.expectEqualStrings("add_zoom", resp.tool_calls[0].name);
}

test "ai: agent tools compact transcript with silences and undo/redo invariance" {
    const allocator = std.testing.allocator;

    var doc = try core.project.create_empty_document(allocator, "Transcript AI Test");
    defer doc.deinit(allocator);

    // Build sample transcript with words and silence interval
    const words = try allocator.alloc(core.project.Word, 4);
    words[0] = .{ .word = try allocator.dupe(u8, "Welcome"), .startSec = 0.5, .endSec = 0.9, .confidence = 0.98 };
    words[1] = .{ .word = try allocator.dupe(u8, "to"), .startSec = 0.95, .endSec = 1.1, .confidence = 0.99 };
    words[2] = .{ .word = try allocator.dupe(u8, "the"), .startSec = 3.6, .endSec = 3.8, .confidence = 0.95 };
    words[3] = .{ .word = try allocator.dupe(u8, "demo"), .startSec = 3.85, .endSec = 4.2, .confidence = 0.97 };

    const silences = try allocator.alloc(core.project.Silence, 1);
    silences[0] = .{ .startSec = 1.1, .endSec = 3.5, .durationSec = 2.4 };

    const t_slice = try allocator.alloc(core.project.Transcript, 1);
    t_slice[0] = .{
        .assetId = try allocator.dupe(u8, "asset-1"),
        .language = "en",
        .words = words,
        .silences = silences,
    };
    doc.transcripts = t_slice;

    // Verify compact transcript format includes [silence 2.4s]
    const compact = try ai.agent_tools.buildCompactTranscript(allocator, &doc);
    defer allocator.free(compact.text);

    try std.testing.expectEqual(@as(usize, 4), compact.word_count);
    try std.testing.expectEqual(@as(usize, 1), compact.silence_count);
    try std.testing.expect(std.mem.indexOf(u8, compact.text, "[silence 2.4s]") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact.text, "Welcome to") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact.text, "the demo") != null);

    // Context summary
    const ctx = try ai.agent_tools.buildTimelineContext(allocator, &doc);
    defer allocator.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "Transcript AI Test") != null);

    // Verify 100% undoable execution via CommandStack
    var stack = core.commands.CommandStack.init(allocator);
    defer stack.deinit();

    const initial_hash = core.commands.compute_document_hash(&doc);

    // 1. Add zoom via executeToolCall
    const zoom_res = try ai.agent_tools.executeToolCall(allocator, &stack, &doc, "add_zoom", "{\"startSec\":0.5,\"endSec\":2.5,\"focusX\":0.6,\"focusY\":0.4,\"depth\":3}");
    defer allocator.free(zoom_res);
    try std.testing.expect(doc.zoomRanges.len == 1);
    const hash_after_zoom = core.commands.compute_document_hash(&doc);
    try std.testing.expect(hash_after_zoom != initial_hash);

    // 2. Add cut via executeToolCall
    const cut_res = try ai.agent_tools.executeToolCall(allocator, &stack, &doc, "add_cut", "{\"startSec\":1.1,\"endSec\":3.5}");
    defer allocator.free(cut_res);
    try std.testing.expect(doc.timeline.trimRanges.len == 1);
    const hash_after_cut = core.commands.compute_document_hash(&doc);
    try std.testing.expect(hash_after_cut != hash_after_zoom);

    // 3. Set style
    const style_res = try ai.agent_tools.executeToolCall(allocator, &stack, &doc, "set_style", "{\"aspectRatio\":\"9:16\",\"shadow\":0.8,\"padding\":32.0}");
    defer allocator.free(style_res);
    const hash_after_style = core.commands.compute_document_hash(&doc);
    try std.testing.expect(hash_after_style != hash_after_cut);

    // Undo all 3 operations -> must return exactly to initial state hash
    while (try stack.undo(&doc)) {}
    try std.testing.expectEqual(initial_hash, core.commands.compute_document_hash(&doc));
    try std.testing.expectEqual(@as(usize, 0), doc.zoomRanges.len);
    try std.testing.expectEqual(@as(usize, 0), doc.timeline.trimRanges.len);

    // Redo all 3 operations -> must match hash_after_style
    while (try stack.redo(&doc)) {}
    try std.testing.expectEqual(hash_after_style, core.commands.compute_document_hash(&doc));
    try std.testing.expectEqual(@as(usize, 1), doc.zoomRanges.len);
    try std.testing.expectEqual(@as(usize, 1), doc.timeline.trimRanges.len);

    // Final undo to clean up doc back to initial
    while (try stack.undo(&doc)) {}
    try std.testing.expectEqual(initial_hash, core.commands.compute_document_hash(&doc));
}

fn dummyStdoutSink(_: []const u8) void {}

test "cli: NDJSON protocol formatting and exit codes" {
    cli.cli.stdout_writer_override = dummyStdoutSink;
    cli.cli.stderr_writer_override = dummyStdoutSink;
    defer {
        cli.cli.stdout_writer_override = null;
        cli.cli.stderr_writer_override = null;
    }

    const allocator = std.testing.allocator;
    var cli_app = cli.cli.Cli.init(allocator);

    // 1. Version (exit 0)
    const args_ver = [_][]const u8{ "openscreen", "--version" };
    const code_ver = try cli_app.run(&args_ver);
    try std.testing.expectEqual(@as(u8, 0), code_ver);

    // 2. Help (exit 0)
    const args_help = [_][]const u8{ "openscreen", "help" };
    const code_help = try cli_app.run(&args_help);
    try std.testing.expectEqual(@as(u8, 0), code_help);

    // 3. Sources --json (exit 0)
    const args_src = [_][]const u8{ "openscreen", "sources", "--json" };
    const code_src = try cli_app.run(&args_src);
    try std.testing.expectEqual(@as(u8, 0), code_src);

    // 4. Invalid subcommand (exit 2: invalid args)
    const args_bad = [_][]const u8{ "openscreen", "nonexistent_subcmd" };
    const code_bad = try cli_app.run(&args_bad);
    try std.testing.expectEqual(@as(u8, 2), code_bad);

    // 5. Record without required --project (exit 2: invalid args)
    const args_rec_bad = [_][]const u8{ "openscreen", "record", "--duration", "1.0" };
    const code_rec_bad = try cli_app.run(&args_rec_bad);
    try std.testing.expectEqual(@as(u8, 2), code_rec_bad);

    // 6. Record valid project with --json (exit 0)
    const p_path = if (@import("builtin").os.tag == .windows) "test_cli_rec.openscreen" else "/tmp/test_cli_rec.openscreen";
    defer {
        var p_z: [1024]u8 = undefined;
        @memcpy(p_z[0..p_path.len], p_path);
        p_z[p_path.len] = 0;
        _ = remove(@ptrCast(&p_z));
    }
    const args_rec = [_][]const u8{ "openscreen", "record", "--duration", "0.05", "--project", p_path, "--json" };
    const code_rec = try cli_app.run(&args_rec);
    try std.testing.expectEqual(@as(u8, 0), code_rec);

    // 7. Edit non-existent file (exit 1: operational error)
    const args_edit_missing = [_][]const u8{ "openscreen", "edit", "/nonexistent/path/never_existed.openscreen", "--json" };
    const code_edit_missing = try cli_app.run(&args_edit_missing);
    try std.testing.expectEqual(@as(u8, 1), code_edit_missing);

    // 8. Edit existing file (exit 0)
    const args_edit = [_][]const u8{ "openscreen", "edit", p_path, "--add-zoom", "--aspect", "16:9", "--json" };
    const code_edit = try cli_app.run(&args_edit);
    try std.testing.expectEqual(@as(u8, 0), code_edit);

    // 9. Captions on project (exit 0)
    const args_cap = [_][]const u8{ "openscreen", "captions", p_path, "--json" };
    const code_cap = try cli_app.run(&args_cap);
    try std.testing.expectEqual(@as(u8, 0), code_cap);

    // 10. Export to MP4 with --json (exit 0)
    const out_mp4 = if (@import("builtin").os.tag == .windows) "test_cli_out.mp4" else "/tmp/test_cli_out.mp4";
    defer {
        var out_z: [1024]u8 = undefined;
        @memcpy(out_z[0..out_mp4.len], out_mp4);
        out_z[out_mp4.len] = 0;
        _ = remove(@ptrCast(&out_z));
    }
    const args_exp = [_][]const u8{ "openscreen", "export", p_path, "-o", out_mp4, "--json" };
    const code_exp = try cli_app.run(&args_exp);
    try std.testing.expectEqual(@as(u8, 0), code_exp);
}

test "mcp: server lifecycle, tools/list, tool execution, extract_frame base64" {
    cli.mcp_server.stdout_writer_override = dummyStdoutSink;
    defer cli.mcp_server.stdout_writer_override = null;

    const allocator = std.testing.allocator;

    var server = cli.mcp_server.McpServer.init(allocator);
    defer server.deinit();

    // 1. initialize
    const init_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    const init_resp = (try server.handleMessage(init_req)).?;
    defer allocator.free(init_resp);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"name\":\"openscreen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"protocolVersion\":\"2024-11-05\"") != null);

    // 2. ping
    const ping_req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\",\"params\":{}}";
    const ping_resp = (try server.handleMessage(ping_req)).?;
    defer allocator.free(ping_resp);
    try std.testing.expect(std.mem.indexOf(u8, ping_resp, "\"result\":{}") != null);

    // 3. tools/list
    const list_req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{}}";
    const list_resp = (try server.handleMessage(list_req)).?;
    defer allocator.free(list_resp);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"list_sources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"record_screen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"inspect_project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"get_transcript\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"generate_captions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"add_zoom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"remove_zoom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"add_cut\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"remove_cut\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"export_video\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_resp, "\"name\":\"extract_frame\"") != null);

    // 4. tools/call: list_sources
    const call_src = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"list_sources\",\"arguments\":{}}}";
    const call_src_resp = (try server.handleMessage(call_src)).?;
    defer allocator.free(call_src_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_src_resp, "\"content\":") != null);

    // 5. tools/call: add_zoom
    const call_zoom = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"add_zoom\",\"arguments\":{\"startTimeSec\":1.0,\"durationSec\":2.0,\"scale\":1.5}}}";
    const call_zoom_resp = (try server.handleMessage(call_zoom)).?;
    defer allocator.free(call_zoom_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_zoom_resp, "Zoom added") != null);

    // 6. tools/call: add_cut
    const call_cut = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"add_cut\",\"arguments\":{\"startSec\":0.5,\"endSec\":1.5}}}";
    const call_cut_resp = (try server.handleMessage(call_cut)).?;
    defer allocator.free(call_cut_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_cut_resp, "Cut added") != null);

    // 7. tools/call: export_video
    const mcp_out = if (@import("builtin").os.tag == .windows) "test_mcp_out.mp4" else "/tmp/test_mcp_out.mp4";
    defer {
        var m_z: [1024]u8 = undefined;
        @memcpy(m_z[0..mcp_out.len], mcp_out);
        m_z[mcp_out.len] = 0;
        _ = remove(@ptrCast(&m_z));
    }
    const call_exp = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{{\"name\":\"export_video\",\"arguments\":{{\"outputPath\":\"{s}\",\"fps\":30.0}}}}}}", .{mcp_out});
    defer allocator.free(call_exp);
    const call_exp_resp = (try server.handleMessage(call_exp)).?;
    defer allocator.free(call_exp_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_exp_resp, "Exported successfully") != null);

    // 8. tools/call: extract_frame base64 PPM
    const call_frame = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"extract_frame\",\"arguments\":{\"timeSec\":1.0}}}";
    const call_frame_resp = (try server.handleMessage(call_frame)).?;
    defer allocator.free(call_frame_resp);
    try std.testing.expect(std.mem.indexOf(u8, call_frame_resp, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_frame_resp, "\"mimeType\":\"image/ppm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_frame_resp, "\"data\":") != null);
}

test {
    _ = core;
    _ = compositor;
    _ = media;
    _ = capture;
    _ = ai;
    _ = cli;
}
