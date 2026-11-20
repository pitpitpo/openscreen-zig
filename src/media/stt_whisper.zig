const std = @import("std");
const ffi = @import("ffi");
const whisper = ffi.whisper;

pub const ModelInfo = struct {
    name: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const KNOWN_MODELS = [_]ModelInfo{
    .{
        .name = "tiny.en",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
        .sha256 = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
    },
    .{
        .name = "base.en",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
        .sha256 = "60ed5bc3dd14eea856493d334349b405782ddcaf00eec290733a6f41f50459e8",
    },
};

pub const WordTimestamp = struct {
    word: []const u8,
    start_ms: i64,
    end_ms: i64,
    confidence: f32,
};

pub const SttSegment = struct {
    start_ms: i64,
    end_ms: i64,
    text: []const u8,
    is_silence: bool = false,
    words: []WordTimestamp = &.{},

    pub fn deinit(self: SttSegment, allocator: std.mem.Allocator) void {
        for (self.words) |w| allocator.free(w.word);
        if (self.words.len > 0) allocator.free(self.words);
        allocator.free(self.text);
    }
};

pub const SpeechToText = struct {
    allocator: std.mem.Allocator,
    whisper_engine: whisper.Whisper,

    pub fn init(allocator: std.mem.Allocator, model_path: []const u8) !SpeechToText {
        const engine = try whisper.Whisper.init(model_path);
        return SpeechToText{
            .allocator = allocator,
            .whisper_engine = engine,
        };
    }

    pub fn deinit(self: *SpeechToText) void {
        self.whisper_engine.deinit();
    }

    pub fn resampleTo16kMono(
        allocator: std.mem.Allocator,
        input_pcm: []const f32,
        src_sample_rate: u32,
        src_channels: u32,
    ) ![]f32 {
        if (input_pcm.len == 0 or src_sample_rate == 0 or src_channels == 0) {
            return try allocator.alloc(f32, 0);
        }

        const total_frames = input_pcm.len / src_channels;
        const target_rate: f32 = 16000.0;
        const ratio = target_rate / @as(f32, @floatFromInt(src_sample_rate));
        const out_frames: usize = @intFromFloat(@as(f32, @floatFromInt(total_frames)) * ratio);

        const out = try allocator.alloc(f32, out_frames);
        errdefer allocator.free(out);

        for (0..out_frames) |i| {
            const src_frame_f = @as(f32, @floatFromInt(i)) / ratio;
            const src_idx0 = @min(total_frames - 1, @as(usize, @intFromFloat(src_frame_f)));
            const src_idx1 = @min(total_frames - 1, src_idx0 + 1);
            const frac = src_frame_f - @as(f32, @floatFromInt(src_idx0));

            // Downmix to mono
            var val0: f32 = 0.0;
            var val1: f32 = 0.0;
            for (0..src_channels) |ch| {
                val0 += input_pcm[src_idx0 * src_channels + ch];
                val1 += input_pcm[src_idx1 * src_channels + ch];
            }
            val0 /= @as(f32, @floatFromInt(src_channels));
            val1 /= @as(f32, @floatFromInt(src_channels));

            // Linear interpolation
            out[i] = val0 * (1.0 - frac) + val1 * frac;
        }

        return out;
    }

    pub fn transcribe(
        self: *SpeechToText,
        allocator: std.mem.Allocator,
        pcm_16k_mono: []const f32,
        silence_threshold_ms: i64,
    ) ![]SttSegment {
        try self.whisper_engine.process(pcm_16k_mono, .{
            .n_threads = 4,
            .enable_token_timestamps = true,
            .language = "en",
        });

        const raw_segments = try self.whisper_engine.getAllSegments(allocator);
        defer {
            for (raw_segments) |seg| seg.deinit(allocator);
            allocator.free(raw_segments);
        }

        var result: std.ArrayListUnmanaged(SttSegment) = .empty;
        errdefer {
            for (result.items) |seg| seg.deinit(allocator);
            result.deinit(allocator);
        }

        var last_end_ms: i64 = 0;

        for (raw_segments) |raw| {
            // Check for silence gap before this segment
            const gap_ms = raw.t0_ms - last_end_ms;
            if (gap_ms >= silence_threshold_ms and silence_threshold_ms > 0) {
                const silence_sec = @as(f32, @floatFromInt(gap_ms)) / 1000.0;
                var buf: [64]u8 = undefined;
                const sil_text = try std.fmt.bufPrint(&buf, "[silence {d:.1}s]", .{silence_sec});

                try result.append(allocator, .{
                    .start_ms = last_end_ms,
                    .end_ms = raw.t0_ms,
                    .text = try allocator.dupe(u8, sil_text),
                    .is_silence = true,
                    .words = &.{},
                });
            }

            // Extract word timestamps from tokens
            var words: std.ArrayListUnmanaged(WordTimestamp) = .empty;
            errdefer {
                for (words.items) |w| allocator.free(w.word);
                words.deinit(allocator);
            }

            for (raw.tokens) |tok| {
                const trimmed = std.mem.trim(u8, tok.text, " \t\r\n");
                if (trimmed.len > 0) {
                    try words.append(allocator, .{
                        .word = try allocator.dupe(u8, trimmed),
                        .start_ms = tok.t0_ms,
                        .end_ms = tok.t1_ms,
                        .confidence = tok.prob,
                    });
                }
            }

            try result.append(allocator, .{
                .start_ms = raw.t0_ms,
                .end_ms = raw.t1_ms,
                .text = try allocator.dupe(u8, std.mem.trim(u8, raw.text, " \t\r\n")),
                .is_silence = false,
                .words = try words.toOwnedSlice(allocator),
            });

            last_end_ms = @max(last_end_ms, raw.t1_ms);
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn exportSrt(
        allocator: std.mem.Allocator,
        segments: []const SttSegment,
    ) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);

        var sub_idx: usize = 1;
        for (segments) |seg| {
            if (seg.text.len == 0) continue;

            const t0_h: u32 = @intCast(@max(0, @divTrunc(seg.start_ms, 3600_000)));
            const t0_m: u32 = @intCast(@max(0, @divTrunc(@rem(seg.start_ms, 3600_000), 60_000)));
            const t0_s: u32 = @intCast(@max(0, @divTrunc(@rem(seg.start_ms, 60_000), 1000)));
            const t0_ms: u32 = @intCast(@max(0, @rem(seg.start_ms, 1000)));

            const t1_h: u32 = @intCast(@max(0, @divTrunc(seg.end_ms, 3600_000)));
            const t1_m: u32 = @intCast(@max(0, @divTrunc(@rem(seg.end_ms, 3600_000), 60_000)));
            const t1_s: u32 = @intCast(@max(0, @divTrunc(@rem(seg.end_ms, 60_000), 1000)));
            const t1_ms: u32 = @intCast(@max(0, @rem(seg.end_ms, 1000)));

            var line_buf: [256]u8 = undefined;
            const entry = try std.fmt.bufPrint(
                &line_buf,
                "{d}\n{d:0>2}:{d:0>2}:{d:0>2},{d:0>3} --> {d:0>2}:{d:0>2}:{d:0>2},{d:0>3}\n{s}\n\n",
                .{ sub_idx, t0_h, t0_m, t0_s, t0_ms, t1_h, t1_m, t1_s, t1_ms, seg.text },
            );
            try out.appendSlice(allocator, entry);
            sub_idx += 1;
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn importSrt(
        allocator: std.mem.Allocator,
        srt_content: []const u8,
    ) ![]SttSegment {
        var list: std.ArrayListUnmanaged(SttSegment) = .empty;
        errdefer {
            for (list.items) |s| s.deinit(allocator);
            list.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, srt_content, '\n');
        var state: enum { index, timestamp, text } = .index;
        var start_ms: i64 = 0;
        var end_ms: i64 = 0;
        var text_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer text_buf.deinit(allocator);

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r \t");

            if (line.len == 0) {
                if (text_buf.items.len > 0) {
                    try list.append(allocator, .{
                        .start_ms = start_ms,
                        .end_ms = end_ms,
                        .text = try allocator.dupe(u8, text_buf.items),
                        .is_silence = false,
                        .words = &.{},
                    });
                    text_buf.clearRetainingCapacity();
                }
                state = .index;
                continue;
            }

            switch (state) {
                .index => {
                    _ = std.fmt.parseInt(u32, line, 10) catch continue;
                    state = .timestamp;
                },
                .timestamp => {
                    if (std.mem.indexOf(u8, line, "-->")) |_| {
                        var parts = std.mem.splitSequence(u8, line, "-->");
                        const p0 = std.mem.trim(u8, parts.next() orelse "", " ");
                        const p1 = std.mem.trim(u8, parts.next() orelse "", " ");

                        start_ms = parseSrtTimestamp(p0);
                        end_ms = parseSrtTimestamp(p1);
                        state = .text;
                    }
                },
                .text => {
                    if (text_buf.items.len > 0) {
                        try text_buf.append(allocator, ' ');
                    }
                    try text_buf.appendSlice(allocator, line);
                },
            }
        }

        if (text_buf.items.len > 0) {
            try list.append(allocator, .{
                .start_ms = start_ms,
                .end_ms = end_ms,
                .text = try allocator.dupe(u8, text_buf.items),
                .is_silence = false,
                .words = &.{},
            });
        }

        return list.toOwnedSlice(allocator);
    }

    fn parseSrtTimestamp(ts: []const u8) i64 {
        // format: 00:00:01,000 or 00:00:01.000
        var h: i64 = 0;
        var m: i64 = 0;
        var s: i64 = 0;
        var ms: i64 = 0;

        var colon_parts = std.mem.splitScalar(u8, ts, ':');
        if (colon_parts.next()) |h_str| h = std.fmt.parseInt(i64, h_str, 10) catch 0;
        if (colon_parts.next()) |m_str| m = std.fmt.parseInt(i64, m_str, 10) catch 0;
        if (colon_parts.next()) |rest| {
            var delim: u8 = ',';
            if (std.mem.indexOfScalar(u8, rest, '.')) |_| delim = '.';
            var s_parts = std.mem.splitScalar(u8, rest, delim);
            if (s_parts.next()) |s_str| s = std.fmt.parseInt(i64, s_str, 10) catch 0;
            if (s_parts.next()) |ms_str| ms = std.fmt.parseInt(i64, ms_str, 10) catch 0;
        }

        return h * 3600_000 + m * 60_000 + s * 1000 + ms;
    }

    pub fn downloadModelWithVerify(
        dest_path: []const u8,
        expected_sha256_hex: []const u8,
    ) !void {
        // If file already exists and hash matches, return success
        var path_buf: [1024]u8 = undefined;
        if (dest_path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..dest_path.len], dest_path);
        path_buf[dest_path.len] = 0;

        const maybe_file = std.c.fopen(@ptrCast(&path_buf), "rb");
        if (maybe_file) |f| {
            defer _ = std.c.fclose(f);
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = std.c.fread(&buf, 1, buf.len, f);
                if (n == 0) break;
                hasher.update(buf[0..n]);
            }
            var digest: [32]u8 = undefined;
            hasher.final(&digest);

            var hex_buf: [64]u8 = undefined;
            _ = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch {};
            if (std.mem.eql(u8, &hex_buf, expected_sha256_hex)) {
                return;
            }
        }

        return error.ModelNotFoundOrInvalid;
    }
};
