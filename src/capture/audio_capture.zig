const std = @import("std");

pub const AudioTrackBuffer = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayListUnmanaged(f32) = .empty,
    sample_rate: u32 = 44100,
    channels: u32 = 2,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u32) AudioTrackBuffer {
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn deinit(self: *AudioTrackBuffer) void {
        self.samples.deinit(self.allocator);
    }

    pub fn append(self: *AudioTrackBuffer, new_samples: []const f32) !void {
        try self.samples.appendSlice(self.allocator, new_samples);
    }

    pub fn getSlice(self: *const AudioTrackBuffer) []const f32 {
        return self.samples.items;
    }

    pub fn reset(self: *AudioTrackBuffer) void {
        self.samples.clearRetainingCapacity();
    }
};

pub const AudioCapture = struct {
    allocator: std.mem.Allocator,
    mic_track: AudioTrackBuffer,
    system_track: AudioTrackBuffer,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) AudioCapture {
        return .{
            .allocator = allocator,
            .mic_track = AudioTrackBuffer.init(allocator, sample_rate, 1),
            .system_track = AudioTrackBuffer.init(allocator, sample_rate, 2),
        };
    }

    pub fn deinit(self: *AudioCapture) void {
        self.mic_track.deinit();
        self.system_track.deinit();
    }

    pub fn handleAudioData(self: *AudioCapture, is_system: bool, samples: []const f32) !void {
        if (is_system) {
            try self.system_track.append(samples);
        } else {
            try self.mic_track.append(samples);
        }
    }

    pub fn reset(self: *AudioCapture) void {
        self.mic_track.reset();
        self.system_track.reset();
    }
};
