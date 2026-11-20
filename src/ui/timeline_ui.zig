const std = @import("std");
const dvui = @import("dvui/root.zig");
const core = @import("core");

// Multi-Track Timeline Component

pub const TimelineTrack = enum {
    video,
    audio,
    zooms,
    layouts,
    speed,
    cuts,
    annotations,
    captions,
};

pub const TimelineView = struct {
    pixels_per_sec: f32 = 100.0,
    scroll_offset_x: f32 = 0.0,
    selected_clip_id: ?[]const u8 = null,
    selected_zoom_id: ?[]const u8 = null,
    selected_cut_id: ?[]const u8 = null,

    pub fn init() TimelineView {
        return .{};
    }

    pub fn render(
        self: *TimelineView,
        ctx: *dvui.Context,
        doc: *const core.project.AxcutDocument,
        current_time_sec: *f64,
        rect: dvui.Rect,
    ) !void {
        // Container
        try ctx.card("timeline_container", rect, ctx.theme.bg_secondary);

        const total_duration = if (doc.assets.len > 0) doc.assets[0].durationSec else 10.0;
        const ruler_h: f32 = 24.0;
        const track_h: f32 = 22.0;
        const track_gap: f32 = 4.0;

        // 1. Ruler
        const ruler_rect = dvui.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = ruler_h };
        try ctx.card("timeline_ruler", ruler_rect, ctx.theme.bg_card);

        // Click on ruler to seek
        if (ruler_rect.contains(ctx.mouse_pos) and ctx.mouse_down) {
            const click_x = ctx.mouse_pos.x - (rect.x + 80.0);
            if (click_x >= 0.0) {
                const target_time = @as(f64, @floatCast(click_x / self.pixels_per_sec));
                current_time_sec.* = @max(0.0, @min(total_duration, target_time));
            }
        }

        // Draw ruler tick labels
        var sec: f32 = 0.0;
        while (sec <= @as(f32, @floatCast(total_duration))) : (sec += 1.0) {
            const tick_x = rect.x + 80.0 + sec * self.pixels_per_sec;
            if (tick_x > rect.x + rect.w - 10.0) break;
            var sec_buf: [16]u8 = undefined;
            const sec_str = try std.fmt.bufPrint(&sec_buf, "{d:.0}s", .{sec});
            var tick_id_buf: [32]u8 = undefined;
            const tick_id = try std.fmt.bufPrint(&tick_id_buf, "ruler_sec_{d:.0}", .{sec});
            try ctx.label(tick_id, sec_str, .{ .x = tick_x, .y = rect.y + 4.0, .w = 40.0, .h = 16.0 }, ctx.theme.text_secondary);
        }

        var cur_y = rect.y + ruler_h + track_gap;

        // Track Labels Column (Left 76px)
        const track_names = [_][]const u8{
            "VIDEO", "AUDIO", "ZOOMS", "LAYOUT", "SPEED", "CUTS", "ANNOT", "CAPTIONS",
        };
        const track_ids = [_][]const u8{
            "trk_lbl_vid", "trk_lbl_aud", "trk_lbl_zoom", "trk_lbl_lay", "trk_lbl_spd", "trk_lbl_cut", "trk_lbl_ann", "trk_lbl_cap",
        };

        for (track_names, 0..) |tname, i| {
            if (cur_y + track_h > rect.y + rect.h) break;
            const lbl_rect = dvui.Rect{ .x = rect.x + 4.0, .y = cur_y, .w = 72.0, .h = track_h };
            try ctx.card(track_ids[i], lbl_rect, ctx.theme.bg_card);
            var text_id_buf: [32]u8 = undefined;
            const text_id = try std.fmt.bufPrint(&text_id_buf, "trk_txt_{d}", .{i});
            try ctx.label(text_id, tname, .{ .x = rect.x + 8.0, .y = cur_y + 4.0, .w = 64.0, .h = 14.0 }, ctx.theme.text_primary);

            // Track lane background
            const lane_rect = dvui.Rect{ .x = rect.x + 80.0, .y = cur_y, .w = rect.w - 84.0, .h = track_h };
            var lane_id_buf: [32]u8 = undefined;
            const lane_id = try std.fmt.bufPrint(&lane_id_buf, "trk_lane_{d}", .{i});
            try ctx.card(lane_id, lane_rect, ctx.theme.bg_primary);

            // Render Track Content Pills
            switch (i) {
                0 => { // Video
                    for (doc.timeline.clips, 0..) |clip, c_idx| {
                        const px_start = rect.x + 80.0 + @as(f32, @floatCast(clip.timelineStartSec)) * self.pixels_per_sec;
                        const px_w = @as(f32, @floatCast(clip.sourceEndSec - clip.sourceStartSec)) * self.pixels_per_sec;
                        var pill_id_buf: [32]u8 = undefined;
                        const pill_id = try std.fmt.bufPrint(&pill_id_buf, "clip_pill_{d}", .{c_idx});
                        try ctx.card(pill_id, .{ .x = px_start, .y = cur_y + 1.0, .w = px_w, .h = track_h - 2.0 }, ctx.theme.accent_blue);
                    }
                },
                2 => { // Zooms
                    for (doc.zoomRanges, 0..) |zr, z_idx| {
                        const px_start = rect.x + 80.0 + @as(f32, @floatCast(zr.startSec)) * self.pixels_per_sec;
                        const px_w = @as(f32, @floatCast(zr.endSec - zr.startSec)) * self.pixels_per_sec;
                        var pill_id_buf: [32]u8 = undefined;
                        const pill_id = try std.fmt.bufPrint(&pill_id_buf, "zoom_pill_{d}", .{z_idx});
                        try ctx.card(pill_id, .{ .x = px_start, .y = cur_y + 1.0, .w = px_w, .h = track_h - 2.0 }, ctx.theme.accent_purple);
                    }
                },
                4 => { // Speed
                    for (doc.timeline.speedRanges, 0..) |sr, s_idx| {
                        const px_start = rect.x + 80.0 + @as(f32, @floatCast(sr.startSec)) * self.pixels_per_sec;
                        const px_w = @as(f32, @floatCast(sr.endSec - sr.startSec)) * self.pixels_per_sec;
                        var pill_id_buf: [32]u8 = undefined;
                        const pill_id = try std.fmt.bufPrint(&pill_id_buf, "speed_pill_{d}", .{s_idx});
                        try ctx.card(pill_id, .{ .x = px_start, .y = cur_y + 1.0, .w = px_w, .h = track_h - 2.0 }, ctx.theme.accent_green);
                    }
                },
                5 => { // Cuts
                    for (doc.timeline.trimRanges, 0..) |tr, t_idx| {
                        const px_start = rect.x + 80.0 + @as(f32, @floatCast(tr.startSec)) * self.pixels_per_sec;
                        const px_w = @as(f32, @floatCast(tr.endSec - tr.startSec)) * self.pixels_per_sec;
                        var pill_id_buf: [32]u8 = undefined;
                        const pill_id = try std.fmt.bufPrint(&pill_id_buf, "cut_pill_{d}", .{t_idx});
                        try ctx.card(pill_id, .{ .x = px_start, .y = cur_y + 1.0, .w = px_w, .h = track_h - 2.0 }, ctx.theme.accent_red);
                    }
                },
                7 => { // Captions
                    if (doc.transcripts.len > 0) {
                        for (doc.transcripts[0].words, 0..) |w, w_idx| {
                            const px_start = rect.x + 80.0 + @as(f32, @floatCast(w.startSec)) * self.pixels_per_sec;
                            const px_w = @max(12.0, @as(f32, @floatCast(w.endSec - w.startSec)) * self.pixels_per_sec);
                            var pill_id_buf: [32]u8 = undefined;
                            const pill_id = try std.fmt.bufPrint(&pill_id_buf, "cap_pill_{d}", .{w_idx});
                            try ctx.card(pill_id, .{ .x = px_start, .y = cur_y + 1.0, .w = px_w, .h = track_h - 2.0 }, ctx.theme.accent_amber);
                        }
                    }
                },
                else => {},
            }

            cur_y += track_h + track_gap;
        }

        // 3. Playhead Line (drawn over timeline)
        const playhead_x = rect.x + 80.0 + @as(f32, @floatCast(current_time_sec.*)) * self.pixels_per_sec;
        if (playhead_x >= rect.x + 80.0 and playhead_x <= rect.x + rect.w) {
            ctx.fb.fillRect(.{ .x = playhead_x - 1.0, .y = rect.y, .w = 2.0, .h = rect.h }, ctx.theme.accent_red);
        }
    }
};
