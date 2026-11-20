const std = @import("std");
const ffi = @import("ffi");
const ffmpeg = ffi.ffmpeg;

pub const CachedFrame = struct {
    pts_ms: i64,
    rgba: []u8,
    last_access: u64,
};

pub const VideoDecoder = struct {
    allocator: std.mem.Allocator,
    demuxer: ffmpeg.Demuxer,
    info: ?ffmpeg.VideoInfo,
    audio_info: ?ffmpeg.AudioInfo,
    cache: []CachedFrame,
    cache_capacity: usize,
    access_counter: u64 = 0,
    current_pts_ms: i64 = -1,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, cache_capacity: usize) !VideoDecoder {
        var demuxer = try ffmpeg.Demuxer.open(path);
        errdefer demuxer.close();

        const v_info = if (demuxer.hasVideo()) try demuxer.getVideoInfo() else null;
        const a_info = if (demuxer.hasAudio()) try demuxer.getAudioInfo() else null;

        if (v_info == null and a_info == null) {
            return error.NoPlayableStream;
        }

        const cap = if (cache_capacity == 0) 16 else cache_capacity;
        var cache: []CachedFrame = &.{};

        if (v_info) |v| {
            cache = try allocator.alloc(CachedFrame, cap);
            errdefer allocator.free(cache);

            const frame_size = @as(usize, v.width) * @as(usize, v.height) * 4;
            var allocated: usize = 0;
            errdefer {
                for (cache[0..allocated]) |c| allocator.free(c.rgba);
            }

            for (0..cap) |i| {
                cache[i] = .{
                    .pts_ms = -1,
                    .rgba = try allocator.alloc(u8, frame_size),
                    .last_access = 0,
                };
                allocated += 1;
            }
        }

        return VideoDecoder{
            .allocator = allocator,
            .demuxer = demuxer,
            .info = v_info,
            .audio_info = a_info,
            .cache = cache,
            .cache_capacity = cap,
        };
    }

    pub fn close(self: *VideoDecoder) void {
        for (self.cache) |c| {
            self.allocator.free(c.rgba);
        }
        if (self.cache.len > 0) {
            self.allocator.free(self.cache);
        }
        self.demuxer.close();
    }

    pub fn hasVideo(self: *const VideoDecoder) bool {
        return self.info != null;
    }

    pub fn hasAudio(self: *const VideoDecoder) bool {
        return self.audio_info != null;
    }

    pub fn getEffectiveDurationMs(self: *const VideoDecoder) i64 {
        if (self.info) |v| {
            if (v.duration_ms > 0) return v.duration_ms;
        }
        if (self.audio_info) |a| {
            if (a.duration_ms > 0) return a.duration_ms;
        }
        return 0;
    }

    pub fn getFrameAtPts(self: *VideoDecoder, target_pts_ms: i64, out_rgba: []u8) !i64 {
        const v = self.info orelse return error.NoVideoStream;
        const frame_size = @as(usize, v.width) * @as(usize, v.height) * 4;
        if (out_rgba.len < frame_size) return error.BufferTooSmall;

        self.access_counter += 1;

        // 1. Check cache for closest frame
        for (self.cache) |*c| {
            if (c.pts_ms >= 0 and @abs(c.pts_ms - target_pts_ms) <= 16) {
                c.last_access = self.access_counter;
                @memcpy(out_rgba[0..frame_size], c.rgba[0..frame_size]);
                return c.pts_ms;
            }
        }

        // 2. Need to seek if target is before current position or jump forward is large (> 500ms)
        const frame_dur_ms = if (v.fps_num > 0)
            @divTrunc(@as(i64, @intCast(v.fps_den)) * 1000, @as(i64, @intCast(v.fps_num)))
        else
            33;

        if (self.current_pts_ms < 0 or target_pts_ms < self.current_pts_ms or (target_pts_ms - self.current_pts_ms) > 500) {
            try self.demuxer.seekVideo(target_pts_ms);
            self.current_pts_ms = -1;
        }

        // 3. Decode forward until frame >= target_pts_ms
        var last_decoded_pts: i64 = -1;
        while (true) {
            const maybe_pts = try self.demuxer.readVideoFrame(out_rgba);
            if (maybe_pts) |pts| {
                last_decoded_pts = pts;
                self.current_pts_ms = pts;

                // Store in LRU cache
                var lru_idx: usize = 0;
                var min_access: u64 = self.cache[0].last_access;
                for (self.cache, 0..) |c, idx| {
                    if (c.last_access < min_access) {
                        min_access = c.last_access;
                        lru_idx = idx;
                    }
                }
                self.cache[lru_idx].pts_ms = pts;
                self.cache[lru_idx].last_access = self.access_counter;
                @memcpy(self.cache[lru_idx].rgba[0..frame_size], out_rgba[0..frame_size]);

                if (pts >= target_pts_ms - @divTrunc(frame_dur_ms, 2)) {
                    return pts;
                }
            } else {
                if (last_decoded_pts >= 0) return last_decoded_pts;
                return error.EndOfStream;
            }
        }
    }

    pub fn extractAllAudio(self: *VideoDecoder, allocator: std.mem.Allocator) !?struct {
        samples: []f32,
        sample_rate: u32,
        channels: u32,
    } {
        if (!self.demuxer.hasAudio()) return null;
        const a_info = self.audio_info orelse try self.demuxer.getAudioInfo();

        try self.demuxer.seekAudio(0);

        var list: std.ArrayListUnmanaged(f32) = .empty;
        defer list.deinit(allocator);

        var chunk: [4096]f32 = undefined;
        while (true) {
            const res = try self.demuxer.readAudioSamples(&chunk);
            if (res) |r| {
                if (r.samples > 0) {
                    const count = r.samples * a_info.channels;
                    try list.appendSlice(allocator, chunk[0..count]);
                }
            } else {
                break;
            }
        }

        const owned = try list.toOwnedSlice(allocator);
        return .{
            .samples = owned,
            .sample_rate = a_info.sample_rate,
            .channels = a_info.channels,
        };
    }
};
