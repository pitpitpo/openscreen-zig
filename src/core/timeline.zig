const std = @import("std");
const project = @import("project.zig");

pub const TimeMap = struct {
    source_sec: f64,
    timeline_sec: f64,
    playback_rate: f32,
    is_cut: bool,
};

pub fn is_time_trimmed(trims: []const project.TrimRange, clip_id: []const u8, source_sec: f64) bool {
    for (trims) |t| {
        if (std.mem.eql(u8, t.clipId, clip_id)) {
            if (source_sec >= t.startSec and source_sec < t.endSec) {
                return true;
            }
        }
    }
    return false;
}

pub fn get_playback_speed(speeds: []const project.SpeedRange, clip_id: []const u8, source_sec: f64) f32 {
    for (speeds) |s| {
        if (std.mem.eql(u8, s.clipId, clip_id)) {
            if (source_sec >= s.startSec and source_sec <= s.endSec) {
                return s.speed;
            }
        }
    }
    return 1.0;
}

pub fn calculate_timeline_duration(timeline: project.Timeline) f64 {
    var total_duration: f64 = 0.0;

    for (timeline.clips) |c| {
        var t = c.sourceStartSec;
        const dt: f64 = 0.01; // 10ms sampling interval
        while (t < c.sourceEndSec) : (t += dt) {
            if (!is_time_trimmed(timeline.trimRanges, c.id, t)) {
                const speed = get_playback_speed(timeline.speedRanges, c.id, t);
                total_duration += dt / @as(f64, speed);
            }
        }
    }

    return total_duration;
}

pub fn map_source_to_timeline(timeline: project.Timeline, clip_id: []const u8, source_sec: f64) ?f64 {
    var current_out_sec: f64 = 0.0;

    for (timeline.clips) |c| {
        const is_target_clip = std.mem.eql(u8, c.id, clip_id);
        var t = c.sourceStartSec;
        const dt: f64 = 0.01;

        while (t < c.sourceEndSec) : (t += dt) {
            if (is_target_clip and t >= source_sec) {
                if (is_time_trimmed(timeline.trimRanges, c.id, source_sec)) {
                    return null; // trimmed out
                }
                return current_out_sec;
            }

            if (!is_time_trimmed(timeline.trimRanges, c.id, t)) {
                const speed = get_playback_speed(timeline.speedRanges, c.id, t);
                current_out_sec += dt / @as(f64, speed);
            }
        }
    }

    return null;
}

pub fn map_timeline_to_source(timeline: project.Timeline, timeline_sec: f64) ?struct { clip_id: []const u8, source_sec: f64 } {
    var current_out_sec: f64 = 0.0;

    for (timeline.clips) |c| {
        var t = c.sourceStartSec;
        const dt: f64 = 0.01;

        while (t < c.sourceEndSec) : (t += dt) {
            if (!is_time_trimmed(timeline.trimRanges, c.id, t)) {
                const speed = get_playback_speed(timeline.speedRanges, c.id, t);
                const step_out = dt / @as(f64, speed);

                if (current_out_sec + step_out >= timeline_sec) {
                    return .{
                        .clip_id = c.id,
                        .source_sec = t,
                    };
                }
                current_out_sec += step_out;
            }
        }
    }

    return null;
}

test "timeline non-destructive trim and mapping" {
    const clip = project.Clip{
        .id = "clip-1",
        .assetId = "asset-1",
        .sourceStartSec = 0.0,
        .sourceEndSec = 10.0,
        .timelineStartSec = 0.0,
    };

    const trim = project.TrimRange{
        .id = "trim-1",
        .clipId = "clip-1",
        .startSec = 2.0,
        .endSec = 4.0, // 2 seconds cut out
    };

    const timeline = project.Timeline{
        .clips = @constCast(&[_]project.Clip{clip}),
        .trimRanges = @constCast(&[_]project.TrimRange{trim}),
        .speedRanges = &[_]project.SpeedRange{},
    };

    const duration = calculate_timeline_duration(timeline);
    try std.testing.expect(duration >= 7.9 and duration <= 8.1); // ~8 seconds

    // 1.0s source maps to ~1.0s timeline
    const out1 = map_source_to_timeline(timeline, "clip-1", 1.0);
    try std.testing.expect(out1 != null and out1.? >= 0.95 and out1.? <= 1.05);

    // 3.0s source is trimmed out
    const out3 = map_source_to_timeline(timeline, "clip-1", 3.0);
    try std.testing.expect(out3 == null);

    // 5.0s source maps to ~3.0s timeline (due to 2s cut)
    const out5 = map_source_to_timeline(timeline, "clip-1", 5.0);
    try std.testing.expect(out5 != null and out5.? >= 2.95 and out5.? <= 3.05);
}
