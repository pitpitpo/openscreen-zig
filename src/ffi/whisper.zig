const std = @import("std");

pub const OscWhisperContext = opaque {};

pub extern "c" fn osc_whisper_init(path_model: [*:0]const u8) ?*OscWhisperContext;
pub extern "c" fn osc_whisper_free(ctx: ?*OscWhisperContext) void;

pub extern "c" fn osc_whisper_process(
    ctx: ?*OscWhisperContext,
    samples: [*]const f32,
    n_samples: c_int,
    n_threads: c_int,
    enable_token_timestamps: c_int,
    language: ?[*:0]const u8,
) c_int;

pub extern "c" fn osc_whisper_n_segments(ctx: ?*OscWhisperContext) c_int;
pub extern "c" fn osc_whisper_segment_t0(ctx: ?*OscWhisperContext, i_segment: c_int) i64;
pub extern "c" fn osc_whisper_segment_t1(ctx: ?*OscWhisperContext, i_segment: c_int) i64;
pub extern "c" fn osc_whisper_segment_text(ctx: ?*OscWhisperContext, i_segment: c_int) [*:0]const u8;

pub extern "c" fn osc_whisper_n_tokens(ctx: ?*OscWhisperContext, i_segment: c_int) c_int;
pub extern "c" fn osc_whisper_token_text(ctx: ?*OscWhisperContext, i_segment: c_int, i_token: c_int) [*:0]const u8;
pub extern "c" fn osc_whisper_token_t0(ctx: ?*OscWhisperContext, i_segment: c_int, i_token: c_int) i64;
pub extern "c" fn osc_whisper_token_t1(ctx: ?*OscWhisperContext, i_segment: c_int, i_token: c_int) i64;
pub extern "c" fn osc_whisper_token_p(ctx: ?*OscWhisperContext, i_segment: c_int, i_token: c_int) f32;

pub const Token = struct {
    text: []const u8,
    t0_ms: i64,
    t1_ms: i64,
    prob: f32,
};

pub const Segment = struct {
    t0_ms: i64,
    t1_ms: i64,
    text: []const u8,
    tokens: []Token,

    pub fn deinit(self: Segment, allocator: std.mem.Allocator) void {
        for (self.tokens) |tok| {
            allocator.free(tok.text);
        }
        allocator.free(self.tokens);
        allocator.free(self.text);
    }
};

pub const ProcessOptions = struct {
    n_threads: u32 = 4,
    enable_token_timestamps: bool = true,
    language: ?[]const u8 = "en",
};

pub const Whisper = struct {
    handle: *OscWhisperContext,

    pub fn init(model_path: []const u8) !Whisper {
        var path_z: [1024]u8 = undefined;
        if (model_path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..model_path.len], model_path);
        path_z[model_path.len] = 0;

        const handle = osc_whisper_init(@ptrCast(&path_z)) orelse return error.ModelLoadFailed;
        return Whisper{ .handle = handle };
    }

    pub fn deinit(self: *Whisper) void {
        osc_whisper_free(self.handle);
    }

    pub fn process(self: *Whisper, samples_16k_mono: []const f32, opts: ProcessOptions) !void {
        var lang_z: [16]u8 = undefined;
        var lang_ptr: ?[*:0]const u8 = null;
        if (opts.language) |lang| {
            if (lang.len >= lang_z.len) return error.LanguageCodeTooLong;
            @memcpy(lang_z[0..lang.len], lang);
            lang_z[lang.len] = 0;
            lang_ptr = @ptrCast(&lang_z);
        }

        const ret = osc_whisper_process(
            self.handle,
            samples_16k_mono.ptr,
            @intCast(samples_16k_mono.len),
            @intCast(opts.n_threads),
            if (opts.enable_token_timestamps) 1 else 0,
            lang_ptr,
        );

        if (ret != 0) return error.WhisperProcessFailed;
    }

    pub fn segmentCount(self: *const Whisper) usize {
        const count = osc_whisper_n_segments(self.handle);
        return if (count < 0) 0 else @intCast(count);
    }

    pub fn getSegment(self: *const Whisper, index: usize, allocator: std.mem.Allocator) !Segment {
        const i: c_int = @intCast(index);
        const t0 = osc_whisper_segment_t0(self.handle, i);
        const t1 = osc_whisper_segment_t1(self.handle, i);
        const text_raw = osc_whisper_segment_text(self.handle, i);
        const text_slice = std.mem.sliceTo(text_raw, 0);
        const text_copy = try allocator.dupe(u8, text_slice);
        errdefer allocator.free(text_copy);

        const n_tokens_c = osc_whisper_n_tokens(self.handle, i);
        const n_tokens: usize = if (n_tokens_c < 0) 0 else @intCast(n_tokens_c);
        const tokens = try allocator.alloc(Token, n_tokens);
        errdefer allocator.free(tokens);

        var filled: usize = 0;
        errdefer {
            for (tokens[0..filled]) |tok| allocator.free(tok.text);
        }

        for (0..n_tokens) |tok_idx| {
            const t_i: c_int = @intCast(tok_idx);
            const tok_raw = osc_whisper_token_text(self.handle, i, t_i);
            const tok_slice = std.mem.sliceTo(tok_raw, 0);
            tokens[tok_idx] = .{
                .text = try allocator.dupe(u8, tok_slice),
                .t0_ms = osc_whisper_token_t0(self.handle, i, t_i),
                .t1_ms = osc_whisper_token_t1(self.handle, i, t_i),
                .prob = osc_whisper_token_p(self.handle, i, t_i),
            };
            filled += 1;
        }

        return Segment{
            .t0_ms = t0,
            .t1_ms = t1,
            .text = text_copy,
            .tokens = tokens,
        };
    }

    pub fn getAllSegments(self: *const Whisper, allocator: std.mem.Allocator) ![]Segment {
        const count = self.segmentCount();
        const segments = try allocator.alloc(Segment, count);
        errdefer allocator.free(segments);

        var filled: usize = 0;
        errdefer {
            for (segments[0..filled]) |seg| seg.deinit(allocator);
        }

        for (0..count) |idx| {
            segments[idx] = try self.getSegment(idx, allocator);
            filled += 1;
        }

        return segments;
    }
};
