const std = @import("std");
const media = @import("media");
const stt = media.stt_whisper;
const decoder = media.decoder;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const argv = init.minimal.args.vector;

    if (argv.len < 3) {
        std.debug.print("Usage: stt-eval <model_path> <audio_path> [silence_threshold_ms]\n", .{});
        return;
    }

    const model_path = std.mem.sliceTo(argv[1], 0);
    const audio_path = std.mem.sliceTo(argv[2], 0);
    const silence_threshold_ms: i64 = if (argv.len >= 4)
        std.fmt.parseInt(i64, std.mem.sliceTo(argv[3], 0), 10) catch 1000
    else
        1000;

    std.debug.print("Loading audio: {s}\n", .{audio_path});
    var dec = try decoder.VideoDecoder.open(allocator, audio_path, 4);
    defer dec.close();

    const audio_res = try dec.extractAllAudio(allocator) orelse {
        std.debug.print("No audio track found in {s}\n", .{audio_path});
        return;
    };
    defer allocator.free(audio_res.samples);

    std.debug.print("Resampling audio to 16kHz mono...\n", .{});
    const pcm_16k = try stt.SpeechToText.resampleTo16kMono(
        allocator,
        audio_res.samples,
        audio_res.sample_rate,
        audio_res.channels,
    );
    defer allocator.free(pcm_16k);

    std.debug.print("Initializing Whisper from: {s}\n", .{model_path});
    var stt_engine = try stt.SpeechToText.init(allocator, model_path);
    defer stt_engine.deinit();

    std.debug.print("Transcribing {d} samples ({d:.2}s)...\n", .{
        pcm_16k.len,
        @as(f32, @floatFromInt(pcm_16k.len)) / 16000.0,
    });
    const segments = try stt_engine.transcribe(allocator, pcm_16k, silence_threshold_ms);
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    std.debug.print("\n=== Transcription Result ({d} segments) ===\n", .{segments.len});
    for (segments) |seg| {
        if (seg.is_silence) {
            std.debug.print("[{d}ms -> {d}ms] {s}\n", .{ seg.start_ms, seg.end_ms, seg.text });
        } else {
            std.debug.print("[{d}ms -> {d}ms] {s}\n", .{ seg.start_ms, seg.end_ms, seg.text });
            for (seg.words) |w| {
                std.debug.print("    word: \"{s}\" ({d}ms..{d}ms, p={d:.2})\n", .{
                    w.word,
                    w.start_ms,
                    w.end_ms,
                    w.confidence,
                });
            }
        }
    }

    const srt = try stt.SpeechToText.exportSrt(allocator, segments);
    defer allocator.free(srt);
    std.debug.print("\n=== SRT Output ===\n{s}\n", .{srt});
}
