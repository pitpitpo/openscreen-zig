const std = @import("std");

extern "c" fn fgets(s: [*]u8, size: c_int, stream: *std.c.FILE) ?[*]u8;

pub const DiagReport = struct {
    total_events: u64,
    duration_ms: f64,
    effective_hz: f64,
    jitter_ms: f64,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    left_clicks: u32,
    right_clicks: u32,
    is_monotonic: bool,
    pause_gap_intact: bool,
};

pub fn analyzeSidecar(allocator: std.mem.Allocator, file_path: []const u8) !DiagReport {
    var path_z: [1024]u8 = undefined;
    if (file_path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..file_path.len], file_path);
    path_z[file_path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_z), "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    var total_events: u64 = 0;
    var first_ts: i64 = -1;
    var last_ts: i64 = -1;
    var prev_ts: i64 = -1;

    var min_x: f32 = 1.0;
    var max_x: f32 = 0.0;
    var min_y: f32 = 1.0;
    var max_y: f32 = 0.0;

    var left_clicks: u32 = 0;
    var right_clicks: u32 = 0;

    var intervals: std.ArrayListUnmanaged(f64) = .empty;
    defer intervals.deinit(allocator);

    var is_monotonic = true;
    var pause_gap_intact = true;

    var line_buf: [1024]u8 = undefined;
    while (fgets(&line_buf, @intCast(line_buf.len), f) != null) {
        const line = std.mem.sliceTo(&line_buf, 0);
        if (line.len < 10) continue;

        var ts_val: ?i64 = null;
        var x_val: ?f32 = null;
        var y_val: ?f32 = null;
        var is_left_down = false;
        var is_right_down = false;

        if (std.mem.indexOf(u8, line, "\"timestamp_ns\":")) |pos| {
            const start = pos + 15;
            var end = start;
            while (end < line.len and (line[end] >= '0' and line[end] <= '9')) : (end += 1) {}
            if (end > start) {
                ts_val = std.fmt.parseInt(i64, line[start..end], 10) catch null;
            }
        }

        if (std.mem.indexOf(u8, line, "\"x\":")) |pos| {
            const start = pos + 4;
            var end = start;
            while (end < line.len and ((line[end] >= '0' and line[end] <= '9') or line[end] == '.')) : (end += 1) {}
            if (end > start) {
                x_val = std.fmt.parseFloat(f32, line[start..end]) catch null;
            }
        }

        if (std.mem.indexOf(u8, line, "\"y\":")) |pos| {
            const start = pos + 4;
            var end = start;
            while (end < line.len and ((line[end] >= '0' and line[end] <= '9') or line[end] == '.')) : (end += 1) {}
            if (end > start) {
                y_val = std.fmt.parseFloat(f32, line[start..end]) catch null;
            }
        }

        if (std.mem.indexOf(u8, line, "\"event\":\"down\"") != null) {
            if (std.mem.indexOf(u8, line, "\"button\":\"left\"") != null) {
                is_left_down = true;
            } else if (std.mem.indexOf(u8, line, "\"button\":\"right\"") != null) {
                is_right_down = true;
            }
        }

        if (ts_val) |ts| {
            if (first_ts < 0) first_ts = ts;
            if (prev_ts >= 0) {
                if (ts < prev_ts) {
                    is_monotonic = false;
                }
                const dt_ms = @as(f64, @floatFromInt(ts - prev_ts)) / 1_000_000.0;
                try intervals.append(allocator, dt_ms);

                if (dt_ms > 2000.0) {
                    pause_gap_intact = false;
                }
            }
            prev_ts = ts;
            last_ts = ts;
            total_events += 1;
        }

        if (x_val) |x| {
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
        }
        if (y_val) |y| {
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;
        }

        if (is_left_down) left_clicks += 1;
        if (is_right_down) right_clicks += 1;
    }

    const duration_ms: f64 = if (last_ts >= first_ts and first_ts >= 0)
        @as(f64, @floatFromInt(last_ts - first_ts)) / 1_000_000.0
    else
        0.0;

    const effective_hz: f64 = if (duration_ms > 0.0 and total_events > 1)
        @as(f64, @floatFromInt(total_events - 1)) / (duration_ms / 1000.0)
    else
        0.0;

    var jitter_ms: f64 = 0.0;
    if (intervals.items.len > 1) {
        var mean: f64 = 0.0;
        for (intervals.items) |dt| mean += dt;
        mean /= @as(f64, @floatFromInt(intervals.items.len));

        var variance: f64 = 0.0;
        for (intervals.items) |dt| {
            const diff = dt - mean;
            variance += diff * diff;
        }
        variance /= @as(f64, @floatFromInt(intervals.items.len));
        jitter_ms = @sqrt(variance);
    }

    return DiagReport{
        .total_events = total_events,
        .duration_ms = duration_ms,
        .effective_hz = effective_hz,
        .jitter_ms = jitter_ms,
        .min_x = if (total_events > 0) min_x else 0.0,
        .max_x = if (total_events > 0) max_x else 0.0,
        .min_y = if (total_events > 0) min_y else 0.0,
        .max_y = if (total_events > 0) max_y else 0.0,
        .left_clicks = left_clicks,
        .right_clicks = right_clicks,
        .is_monotonic = is_monotonic,
        .pause_gap_intact = pause_gap_intact,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const argv = init.minimal.args.vector;

    if (argv.len < 2) {
        std.debug.print("Usage: cursor-diag <path-to-.cursor.jsonl>\n", .{});
        return;
    }

    const path = std.mem.sliceTo(argv[1], 0);
    const report = analyzeSidecar(allocator, path) catch |err| {
        std.debug.print("Error analyzing sidecar file: {t}\n", .{err});
        return err;
    };

    std.debug.print("=== OpenScreen Cursor Sidecar Diagnostic Report ===\n", .{});
    std.debug.print("File:                {s}\n", .{path});
    std.debug.print("Total Events:        {d}\n", .{report.total_events});
    std.debug.print("Total Duration:      {d:.2} ms ({d:.2} s)\n", .{ report.duration_ms, report.duration_ms / 1000.0 });
    std.debug.print("Effective Rate:      {d:.1} Hz\n", .{report.effective_hz});
    std.debug.print("Interval Jitter:     {d:.3} ms\n", .{report.jitter_ms});
    std.debug.print("Coordinate Bounds:   X: [{d:.4} .. {d:.4}], Y: [{d:.4} .. {d:.4}]\n", .{
        report.min_x,
        report.max_x,
        report.min_y,
        report.max_y,
    });
    std.debug.print("Clicks Recorded:     Left: {d}, Right: {d}\n", .{ report.left_clicks, report.right_clicks });
    std.debug.print("Monotonic Clock:     {s}\n", .{if (report.is_monotonic) "PASS (strictly monotonic)" else "FAIL (negative delta detected)"});
    std.debug.print("Pause-Gap Integrity: {s}\n", .{if (report.pause_gap_intact) "PASS (no gaps or drift)" else "FAIL (unexpected pause jump)"});

    if (!report.is_monotonic or !report.pause_gap_intact) {
        return error.SidecarValidationFailed;
    }
}
