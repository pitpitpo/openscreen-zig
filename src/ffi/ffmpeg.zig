const std = @import("std");

pub const OscDemuxer = opaque {};
pub const OscMuxer = opaque {};
pub const OscGifMuxer = opaque {};

pub extern "c" fn av_log_set_level(level: c_int) void;
pub const AV_LOG_QUIET: c_int = -8;
pub const AV_LOG_PANIC: c_int = 0;
pub const AV_LOG_FATAL: c_int = 8;
pub const AV_LOG_ERROR: c_int = 16;
pub const AV_LOG_WARNING: c_int = 24;
pub const AV_LOG_INFO: c_int = 32;

pub extern "c" fn osc_averror_eagain() c_int;
pub extern "c" fn osc_probe_best_h264_encoder(out_name: [*:0]u8, max_len: usize) c_int;

pub extern "c" fn osc_demuxer_open(filename: [*:0]const u8, out_demuxer: *?*OscDemuxer) c_int;
pub extern "c" fn osc_demuxer_close(d: ?*OscDemuxer) void;

pub extern "c" fn osc_demuxer_has_video(d: ?*const OscDemuxer) c_int;
pub extern "c" fn osc_demuxer_get_video_info(
    d: ?*const OscDemuxer,
    width: *c_int,
    height: *c_int,
    fps_num: *c_int,
    fps_den: *c_int,
    duration_ms: *i64,
    nb_frames: *i64,
) c_int;

pub extern "c" fn osc_demuxer_has_audio(d: ?*const OscDemuxer) c_int;
pub extern "c" fn osc_demuxer_get_audio_info(
    d: ?*const OscDemuxer,
    sample_rate: *c_int,
    channels: *c_int,
    duration_ms: *i64,
) c_int;

pub extern "c" fn osc_demuxer_seek_frame(d: ?*OscDemuxer, target_pts_ms: i64) c_int;
pub extern "c" fn osc_demuxer_read_video_frame(
    d: ?*OscDemuxer,
    out_rgba: [*]u8,
    out_pts_ms: *i64,
    is_eof: *c_int,
) c_int;

pub extern "c" fn osc_demuxer_seek_audio(d: ?*OscDemuxer, target_pts_ms: i64) c_int;
pub extern "c" fn osc_demuxer_read_audio_samples(
    d: ?*OscDemuxer,
    out_pcm: [*]f32,
    max_samples: c_int,
    out_samples: *c_int,
    out_pts_ms: *i64,
    is_eof: *c_int,
) c_int;

pub extern "c" fn osc_muxer_open(
    filename: [*:0]const u8,
    width: c_int,
    height: c_int,
    fps_num: c_int,
    fps_den: c_int,
    video_bitrate: c_int,
    audio_sample_rate: c_int,
    audio_channels: c_int,
    audio_bitrate: c_int,
    codec_override: ?[*:0]const u8,
    out_muxer: *?*OscMuxer,
) c_int;

pub extern "c" fn osc_muxer_write_video_frame(m: ?*OscMuxer, rgba: [*]const u8, pts_frame: i64) c_int;
pub extern "c" fn osc_muxer_write_audio_samples(m: ?*OscMuxer, pcm_interleaved: [*]const f32, num_samples: c_int, pts_sample: i64) c_int;
pub extern "c" fn osc_muxer_flush(m: ?*OscMuxer) c_int;
pub extern "c" fn osc_muxer_close(m: ?*OscMuxer) c_int;

pub extern "c" fn osc_gif_muxer_open(
    filename: [*:0]const u8,
    width: c_int,
    height: c_int,
    fps_num: c_int,
    fps_den: c_int,
    out_gif: *?*OscGifMuxer,
) c_int;
pub extern "c" fn osc_gif_muxer_write_frame(g: ?*OscGifMuxer, rgba: [*]const u8, pts_frame: i64) c_int;
pub extern "c" fn osc_gif_muxer_close(g: ?*OscGifMuxer) c_int;

pub const VideoInfo = struct {
    width: u32,
    height: u32,
    fps_num: u32,
    fps_den: u32,
    duration_ms: i64,
    nb_frames: i64,
};

pub const AudioInfo = struct {
    sample_rate: u32,
    channels: u32,
    duration_ms: i64,
};

pub const MuxerOptions = struct {
    width: u32,
    height: u32,
    fps_num: u32 = 30,
    fps_den: u32 = 1,
    video_bitrate: u32 = 4_000_000,
    audio_sample_rate: u32 = 44100,
    audio_channels: u32 = 2,
    audio_bitrate: u32 = 128_000,
    codec_override: ?[]const u8 = null,
};

pub fn probeBestH264Encoder(buf: *[64]u8) []const u8 {
    @memset(buf, 0);
    const ret = osc_probe_best_h264_encoder(@ptrCast(buf), buf.len);
    if (ret != 0) return "h264";
    return std.mem.sliceTo(buf, 0);
}

pub const Demuxer = struct {
    handle: *OscDemuxer,

    pub fn open(path: []const u8) !Demuxer {
        var path_z: [1024]u8 = undefined;
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var handle: ?*OscDemuxer = null;
        if (osc_demuxer_open(@ptrCast(&path_z), &handle) < 0 or handle == null) {
            return error.DemuxerOpenFailed;
        }
        return Demuxer{ .handle = handle.? };
    }

    pub fn close(self: *Demuxer) void {
        osc_demuxer_close(self.handle);
    }

    pub fn hasVideo(self: *const Demuxer) bool {
        return osc_demuxer_has_video(self.handle) != 0;
    }

    pub fn getVideoInfo(self: *const Demuxer) !VideoInfo {
        var w: c_int = 0;
        var h: c_int = 0;
        var num: c_int = 0;
        var den: c_int = 0;
        var dur: i64 = 0;
        var frames: i64 = 0;

        if (osc_demuxer_get_video_info(self.handle, &w, &h, &num, &den, &dur, &frames) != 0) {
            return error.NoVideoStream;
        }
        return VideoInfo{
            .width = @intCast(w),
            .height = @intCast(h),
            .fps_num = @intCast(num),
            .fps_den = @intCast(den),
            .duration_ms = dur,
            .nb_frames = frames,
        };
    }

    pub fn hasAudio(self: *const Demuxer) bool {
        return osc_demuxer_has_audio(self.handle) != 0;
    }

    pub fn getAudioInfo(self: *const Demuxer) !AudioInfo {
        var rate: c_int = 0;
        var ch: c_int = 0;
        var dur: i64 = 0;

        if (osc_demuxer_get_audio_info(self.handle, &rate, &ch, &dur) != 0) {
            return error.NoAudioStream;
        }
        return AudioInfo{
            .sample_rate = @intCast(rate),
            .channels = @intCast(ch),
            .duration_ms = dur,
        };
    }

    pub fn seekVideo(self: *Demuxer, target_pts_ms: i64) !void {
        if (osc_demuxer_seek_frame(self.handle, target_pts_ms) != 0) {
            return error.SeekFailed;
        }
    }

    pub fn seekAudio(self: *Demuxer, target_pts_ms: i64) !void {
        if (osc_demuxer_seek_audio(self.handle, target_pts_ms) != 0) {
            return error.SeekFailed;
        }
    }

    pub fn readVideoFrame(self: *Demuxer, out_rgba: []u8) !?i64 {
        var pts: i64 = 0;
        var is_eof: c_int = 0;
        const ret = osc_demuxer_read_video_frame(self.handle, out_rgba.ptr, &pts, &is_eof);
        if (ret < 0) return error.DecodeFailed;
        if (is_eof != 0) return null;
        return pts;
    }

    pub fn readAudioSamples(self: *Demuxer, out_pcm: []f32) !?struct { samples: usize, pts_ms: i64 } {
        var pts: i64 = 0;
        var is_eof: c_int = 0;
        var samples_read: c_int = 0;
        const max_samples: c_int = @intCast(out_pcm.len);
        const ret = osc_demuxer_read_audio_samples(self.handle, out_pcm.ptr, max_samples, &samples_read, &pts, &is_eof);
        if (ret < 0) return error.DecodeFailed;
        if (is_eof != 0 and samples_read == 0) return null;
        return .{
            .samples = @intCast(samples_read),
            .pts_ms = pts,
        };
    }
};

pub const Muxer = struct {
    handle: *OscMuxer,

    pub fn open(path: []const u8, opts: MuxerOptions) !Muxer {
        var path_z: [1024]u8 = undefined;
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var codec_z: [64]u8 = undefined;
        var codec_ptr: ?[*:0]const u8 = null;
        if (opts.codec_override) |c| {
            if (c.len >= codec_z.len) return error.CodecNameTooLong;
            @memcpy(codec_z[0..c.len], c);
            codec_z[c.len] = 0;
            codec_ptr = @ptrCast(&codec_z);
        }

        var handle: ?*OscMuxer = null;
        const ret = osc_muxer_open(
            @ptrCast(&path_z),
            @intCast(opts.width),
            @intCast(opts.height),
            @intCast(opts.fps_num),
            @intCast(opts.fps_den),
            @intCast(opts.video_bitrate),
            @intCast(opts.audio_sample_rate),
            @intCast(opts.audio_channels),
            @intCast(opts.audio_bitrate),
            codec_ptr,
            &handle,
        );
        if (ret < 0 or handle == null) {
            return error.MuxerOpenFailed;
        }
        return Muxer{ .handle = handle.? };
    }

    pub fn writeVideoFrame(self: *Muxer, rgba: []const u8, pts_frame: i64) !void {
        if (osc_muxer_write_video_frame(self.handle, rgba.ptr, pts_frame) != 0) {
            return error.WriteVideoFrameFailed;
        }
    }

    pub fn writeAudioSamples(self: *Muxer, pcm_interleaved: []const f32, channels: u32, pts_sample: i64) !void {
        const ch = if (channels > 0) channels else 1;
        const num_frames: c_int = @intCast(@divTrunc(pcm_interleaved.len, ch));
        if (osc_muxer_write_audio_samples(self.handle, pcm_interleaved.ptr, num_frames, pts_sample) != 0) {
            return error.WriteAudioSamplesFailed;
        }
    }

    pub fn flush(self: *Muxer) !void {
        if (osc_muxer_flush(self.handle) != 0) {
            return error.MuxerFlushFailed;
        }
    }

    pub fn close(self: *Muxer) void {
        _ = osc_muxer_close(self.handle);
    }
};

pub const GifMuxer = struct {
    handle: *OscGifMuxer,

    pub fn open(path: []const u8, width: u32, height: u32, fps_num: u32, fps_den: u32) !GifMuxer {
        var path_z: [1024]u8 = undefined;
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var handle: ?*OscGifMuxer = null;
        const ret = osc_gif_muxer_open(
            @ptrCast(&path_z),
            @intCast(width),
            @intCast(height),
            @intCast(fps_num),
            @intCast(fps_den),
            &handle,
        );
        if (ret < 0 or handle == null) {
            return error.GifMuxerOpenFailed;
        }
        return GifMuxer{ .handle = handle.? };
    }

    pub fn writeFrame(self: *GifMuxer, rgba: []const u8, pts_frame: i64) !void {
        if (osc_gif_muxer_write_frame(self.handle, rgba.ptr, pts_frame) != 0) {
            return error.WriteGifFrameFailed;
        }
    }

    pub fn close(self: *GifMuxer) void {
        _ = osc_gif_muxer_close(self.handle);
    }
};
