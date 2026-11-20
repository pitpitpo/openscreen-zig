const std = @import("std");
const ffi = @import("ffi");
const ffmpeg = ffi.ffmpeg;

pub const ExportFormat = enum {
    mp4,
    gif,
};

pub const ExportConfig = struct {
    width: u32,
    height: u32,
    fps: u32 = 30,
    video_bitrate: u32 = 4_000_000,
    audio_sample_rate: u32 = 44100,
    audio_channels: u32 = 2,
    audio_bitrate: u32 = 128_000,
    codec_override: ?[]const u8 = null,
};

pub const ProgressCallback = *const fn (progress: f32, current_frame: u64, total_frames: u64) void;

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.seq_cst);
    }
};

pub const FrameProvider = struct {
    ctx: *anyopaque,
    renderFrameFn: *const fn (ctx: *anyopaque, frame_idx: u64, out_rgba: []u8) anyerror!void,

    pub fn renderFrame(self: FrameProvider, frame_idx: u64, out_rgba: []u8) !void {
        try self.renderFrameFn(self.ctx, frame_idx, out_rgba);
    }
};

pub const MediaEncoder = struct {
    pub fn encodeMp4(
        output_path: []const u8,
        config: ExportConfig,
        total_frames: u64,
        provider: FrameProvider,
        audio_pcm: ?[]const f32,
        progress_cb: ?ProgressCallback,
        cancel_token: ?*const CancellationToken,
        allocator: std.mem.Allocator,
    ) !void {
        if (total_frames == 0) return;

        var muxer = try ffmpeg.Muxer.open(output_path, .{
            .width = config.width,
            .height = config.height,
            .fps_num = config.fps,
            .fps_den = 1,
            .video_bitrate = config.video_bitrate,
            .audio_sample_rate = config.audio_sample_rate,
            .audio_channels = if (audio_pcm != null) config.audio_channels else 0,
            .audio_bitrate = config.audio_bitrate,
            .codec_override = config.codec_override,
        });
        defer muxer.close();

        // Write audio in chunks if provided
        if (audio_pcm) |pcm| {
            if (pcm.len > 0) {
                var offset: usize = 0;
                const ch = if (config.audio_channels > 0) config.audio_channels else 1;
                const chunk_frames: usize = 1024;
                const chunk_size: usize = chunk_frames * ch;
                while (offset < pcm.len) {
                    if (cancel_token) |tok| {
                        if (tok.isCancelled()) return error.Cancelled;
                    }
                    const remaining = pcm.len - offset;
                    const this_chunk = @min(remaining, chunk_size);
                    try muxer.writeAudioSamples(pcm[offset .. offset + this_chunk], ch, 0);
                    offset += this_chunk;
                }
            }
        }

        const frame_bytes = @as(usize, config.width) * @as(usize, config.height) * 4;
        const frame_buf = try allocator.alloc(u8, frame_bytes);
        defer allocator.free(frame_buf);

        for (0..total_frames) |i| {
            if (cancel_token) |tok| {
                if (tok.isCancelled()) return error.Cancelled;
            }

            try provider.renderFrame(i, frame_buf);
            try muxer.writeVideoFrame(frame_buf, @intCast(i));

            if (progress_cb) |cb| {
                const prog = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(total_frames));
                cb(prog, i + 1, total_frames);
            }
        }

        try muxer.flush();
    }

    pub fn encodeGif(
        output_path: []const u8,
        width: u32,
        height: u32,
        fps: u32,
        total_frames: u64,
        provider: FrameProvider,
        progress_cb: ?ProgressCallback,
        cancel_token: ?*const CancellationToken,
        allocator: std.mem.Allocator,
    ) !void {
        if (total_frames == 0) return;

        var gif = try ffmpeg.GifMuxer.open(output_path, width, height, fps, 1);
        defer gif.close();

        const frame_bytes = @as(usize, width) * @as(usize, height) * 4;
        const frame_buf = try allocator.alloc(u8, frame_bytes);
        defer allocator.free(frame_buf);

        for (0..total_frames) |i| {
            if (cancel_token) |tok| {
                if (tok.isCancelled()) return error.Cancelled;
            }

            try provider.renderFrame(i, frame_buf);
            try gif.writeFrame(frame_buf, @intCast(i));

            if (progress_cb) |cb| {
                const prog = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(total_frames));
                cb(prog, i + 1, total_frames);
            }
        }
    }
};
