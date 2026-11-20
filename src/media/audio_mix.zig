const std = @import("std");

pub const TrackKind = enum {
    microphone,
    system,
    media,
};

pub const AudioClip = struct {
    samples: []const f32, // interleaved stereo float32
    sample_rate: u32,
    channels: u32,
    timeline_start_ms: i64,
    in_point_ms: i64,
    out_point_ms: i64,
    speed: f32 = 1.0,
};

pub const AudioTrack = struct {
    kind: TrackKind,
    volume: f32 = 1.0,
    pan: f32 = 0.0, // -1.0 (left) .. 0.0 (center) .. +1.0 (right)
    muted: bool = false,
    solo: bool = false,
    clips: std.ArrayListUnmanaged(AudioClip) = .empty,

    pub fn deinit(self: *AudioTrack, allocator: std.mem.Allocator) void {
        self.clips.deinit(allocator);
    }

    pub fn addClip(self: *AudioTrack, allocator: std.mem.Allocator, clip: AudioClip) !void {
        try self.clips.append(allocator, clip);
    }
};

pub const WaveformPeak = struct {
    min: f32,
    max: f32,
};

pub const MultiResPeaks = struct {
    peaks_100hz: []WaveformPeak, // ~10ms per peak
    peaks_10hz: []WaveformPeak, // ~100ms per peak
    peaks_1hz: []WaveformPeak, // ~1s per peak

    pub fn deinit(self: MultiResPeaks, allocator: std.mem.Allocator) void {
        allocator.free(self.peaks_100hz);
        allocator.free(self.peaks_10hz);
        allocator.free(self.peaks_1hz);
    }
};

pub const AudioMixer = struct {
    allocator: std.mem.Allocator,
    target_sample_rate: u32,
    tracks: [3]AudioTrack,

    pub fn init(allocator: std.mem.Allocator, target_sample_rate: u32) AudioMixer {
        return AudioMixer{
            .allocator = allocator,
            .target_sample_rate = if (target_sample_rate > 0) target_sample_rate else 44100,
            .tracks = .{
                .{ .kind = .microphone },
                .{ .kind = .system },
                .{ .kind = .media },
            },
        };
    }

    pub fn deinit(self: *AudioMixer) void {
        for (&self.tracks) |*tr| {
            tr.deinit(self.allocator);
        }
    }

    pub fn getTrack(self: *AudioMixer, kind: TrackKind) *AudioTrack {
        return switch (kind) {
            .microphone => &self.tracks[0],
            .system => &self.tracks[1],
            .media => &self.tracks[2],
        };
    }

    pub fn renderMix(
        self: *const AudioMixer,
        allocator: std.mem.Allocator,
        duration_ms: i64,
    ) ![]f32 {
        if (duration_ms <= 0) return try allocator.alloc(f32, 0);

        const total_samples: usize = @intCast(@divTrunc(duration_ms * @as(i64, self.target_sample_rate), 1000));
        const total_floats = total_samples * 2; // stereo
        const output = try allocator.alloc(f32, total_floats);
        @memset(output, 0.0);

        const any_solo = self.tracks[0].solo or self.tracks[1].solo or self.tracks[2].solo;

        for (&self.tracks) |tr| {
            if (tr.muted) continue;
            if (any_solo and !tr.solo) continue;
            if (tr.volume <= 0.0001) continue;

            // Pan gains (constant power or linear pan)
            const pan_clamped = std.math.clamp(tr.pan, -1.0, 1.0);
            const left_gain = tr.volume * @min(1.0, 1.0 - pan_clamped);
            const right_gain = tr.volume * @min(1.0, 1.0 + pan_clamped);

            for (tr.clips.items) |clip| {
                const clip_dur_ms = clip.out_point_ms - clip.in_point_ms;
                if (clip_dur_ms <= 0 or clip.speed <= 0.001) continue;

                const effective_dur_ms: i64 = @intFromFloat(@as(f32, @floatFromInt(clip_dur_ms)) / clip.speed);
                const clip_start_sample: i64 = @divTrunc(clip.timeline_start_ms * @as(i64, self.target_sample_rate), 1000);
                const clip_total_samples: i64 = @divTrunc(effective_dur_ms * @as(i64, self.target_sample_rate), 1000);

                var s_i: i64 = 0;
                while (s_i < clip_total_samples) : (s_i += 1) {
                    const timeline_sample = clip_start_sample + s_i;
                    if (timeline_sample < 0 or timeline_sample >= total_samples) continue;

                    // Compute source position in clip
                    const src_time_ms = @as(f32, @floatFromInt(clip.in_point_ms)) +
                        (@as(f32, @floatFromInt(s_i)) * 1000.0 / @as(f32, @floatFromInt(self.target_sample_rate))) * clip.speed;

                    const src_sample_float = (src_time_ms / 1000.0) * @as(f32, @floatFromInt(clip.sample_rate));
                    const src_sample_idx: usize = @intFromFloat(@max(0.0, src_sample_float));

                    var sample_l: f32 = 0.0;
                    var sample_r: f32 = 0.0;

                    if (clip.channels == 1) {
                        if (src_sample_idx < clip.samples.len) {
                            sample_l = clip.samples[src_sample_idx];
                            sample_r = sample_l;
                        }
                    } else if (clip.channels >= 2) {
                        const base_idx = src_sample_idx * clip.channels;
                        if (base_idx + 1 < clip.samples.len) {
                            sample_l = clip.samples[base_idx];
                            sample_r = clip.samples[base_idx + 1];
                        }
                    }

                    const out_idx = @as(usize, @intCast(timeline_sample)) * 2;
                    output[out_idx] += sample_l * left_gain;
                    output[out_idx + 1] += sample_r * right_gain;
                }
            }
        }

        // Soft clipper to prevent harsh distortion
        for (output) |*val| {
            if (val.* > 1.0) {
                val.* = 1.0;
            } else if (val.* < -1.0) {
                val.* = -1.0;
            }
        }

        return output;
    }

    pub fn computeMultiResPeaks(
        allocator: std.mem.Allocator,
        samples: []const f32,
        sample_rate: u32,
        channels: u32,
    ) !MultiResPeaks {
        if (samples.len == 0 or sample_rate == 0 or channels == 0) {
            return MultiResPeaks{
                .peaks_100hz = try allocator.alloc(WaveformPeak, 0),
                .peaks_10hz = try allocator.alloc(WaveformPeak, 0),
                .peaks_1hz = try allocator.alloc(WaveformPeak, 0),
            };
        }

        const total_frames = samples.len / channels;
        const frames_per_100hz = @max(1, sample_rate / 100);
        const frames_per_10hz = @max(1, sample_rate / 10);
        const frames_per_1hz = @max(1, sample_rate);

        const count_100hz = (total_frames + frames_per_100hz - 1) / frames_per_100hz;
        const count_10hz = (total_frames + frames_per_10hz - 1) / frames_per_10hz;
        const count_1hz = (total_frames + frames_per_1hz - 1) / frames_per_1hz;

        const p_100hz = try allocator.alloc(WaveformPeak, count_100hz);
        errdefer allocator.free(p_100hz);

        const p_10hz = try allocator.alloc(WaveformPeak, count_10hz);
        errdefer allocator.free(p_10hz);

        const p_1hz = try allocator.alloc(WaveformPeak, count_1hz);
        errdefer allocator.free(p_1hz);

        // Compute 100Hz peaks
        for (0..count_100hz) |b_idx| {
            const start = b_idx * frames_per_100hz;
            const end = @min(total_frames, start + frames_per_100hz);
            var min_v: f32 = 0.0;
            var max_v: f32 = 0.0;
            for (start..end) |f_idx| {
                const s = samples[f_idx * channels];
                if (s < min_v) min_v = s;
                if (s > max_v) max_v = s;
            }
            p_100hz[b_idx] = .{ .min = min_v, .max = max_v };
        }

        // Compute 10Hz peaks from 100Hz
        for (0..count_10hz) |b_idx| {
            const start = b_idx * 10;
            const end = @min(count_100hz, start + 10);
            var min_v: f32 = 0.0;
            var max_v: f32 = 0.0;
            for (start..end) |i| {
                if (p_100hz[i].min < min_v) min_v = p_100hz[i].min;
                if (p_100hz[i].max > max_v) max_v = p_100hz[i].max;
            }
            p_10hz[b_idx] = .{ .min = min_v, .max = max_v };
        }

        // Compute 1Hz peaks from 10Hz
        for (0..count_1hz) |b_idx| {
            const start = b_idx * 10;
            const end = @min(count_10hz, start + 10);
            var min_v: f32 = 0.0;
            var max_v: f32 = 0.0;
            for (start..end) |i| {
                if (p_10hz[i].min < min_v) min_v = p_10hz[i].min;
                if (p_10hz[i].max > max_v) max_v = p_10hz[i].max;
            }
            p_1hz[b_idx] = .{ .min = min_v, .max = max_v };
        }

        return MultiResPeaks{
            .peaks_100hz = p_100hz,
            .peaks_10hz = p_10hz,
            .peaks_1hz = p_1hz,
        };
    }
};
