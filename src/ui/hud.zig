const std = @import("std");
const dvui = @import("dvui/root.zig");

// Floating Recording HUD & Notes Window

pub const RecordingState = enum {
    idle,
    countdown,
    recording,
    paused,
};

pub const Hud = struct {
    state: RecordingState = .idle,
    duration_sec: f64 = 0.0,
    countdown_val: i32 = 0,
    source_name: []const u8 = "Display 1 (1920x1080)",
    mic_enabled: bool = true,
    sys_audio_enabled: bool = true,
    webcam_enabled: bool = false,
    auto_zoom_enabled: bool = true,
    notes_open: bool = false,
    notes_content: []const u8 = "Demo Teleprompter Notes:\n1. Welcome to OpenScreen 2.0\n2. Show fast zoom and auto-cursor smoothing\n3. Export with zero memory leaks",

    // Actions emitted during render
    action_toggle_record: bool = false,
    action_toggle_pause: bool = false,
    action_restart_take: bool = false,
    action_cancel_take: bool = false,

    pub fn init() Hud {
        return .{};
    }

    pub fn update(self: *Hud, delta_sec: f64) void {
        if (self.state == .countdown) {
            if (self.countdown_val > 0) {
                // Countdown tick
            } else {
                self.state = .recording;
                self.duration_sec = 0.0;
            }
        } else if (self.state == .recording) {
            self.duration_sec += delta_sec;
        }
    }

    pub fn render(self: *Hud, ctx: *dvui.Context) !void {
        self.action_toggle_record = false;
        self.action_toggle_pause = false;
        self.action_restart_take = false;
        self.action_cancel_take = false;

        // HUD Bar: centered at top of screen, e.g. 800x48 px
        const bar_w: f32 = 780.0;
        const bar_h: f32 = 46.0;
        const bar_x: f32 = (@as(f32, @floatFromInt(ctx.fb.width)) - bar_w) * 0.5;
        const bar_y: f32 = 12.0;
        const bar_rect = dvui.Rect{ .x = bar_x, .y = bar_y, .w = bar_w, .h = bar_h };

        // Background pill
        try ctx.card("hud_bar_container", bar_rect, ctx.theme.bg_secondary);

        var cur_x = bar_x + 8.0;
        const btn_y = bar_y + 7.0;
        const btn_h: f32 = 32.0;

        // 1. Source selector
        const src_w: f32 = 120.0;
        if (try ctx.button("hud_btn_source", "Display 1", .{ .x = cur_x, .y = btn_y, .w = src_w, .h = btn_h })) {
            // Source picker toggle
        }
        cur_x += src_w + 6.0;

        // 2. Toggles: Mic, Sys Audio, Webcam, Auto-Zoom
        const toggle_w: f32 = 64.0;
        self.mic_enabled = try ctx.toggle("hud_tog_mic", "Mic", self.mic_enabled, .{ .x = cur_x, .y = btn_y, .w = toggle_w, .h = btn_h });
        cur_x += toggle_w + 6.0;

        self.sys_audio_enabled = try ctx.toggle("hud_tog_sys", "Sys", self.sys_audio_enabled, .{ .x = cur_x, .y = btn_y, .w = toggle_w, .h = btn_h });
        cur_x += toggle_w + 6.0;

        self.webcam_enabled = try ctx.toggle("hud_tog_cam", "Cam", self.webcam_enabled, .{ .x = cur_x, .y = btn_y, .w = toggle_w, .h = btn_h });
        cur_x += toggle_w + 6.0;

        self.auto_zoom_enabled = try ctx.toggle("hud_tog_zoom", "Zoom", self.auto_zoom_enabled, .{ .x = cur_x, .y = btn_y, .w = toggle_w, .h = btn_h });
        cur_x += toggle_w + 10.0;

        // 3. Duration / State counter
        var dur_buf: [32]u8 = undefined;
        const dur_text = switch (self.state) {
            .idle => "00:00:00",
            .countdown => try std.fmt.bufPrint(&dur_buf, "COUNTDOWN {d}", .{self.countdown_val}),
            .recording, .paused => s: {
                const total_sec = @as(u64, @intFromFloat(self.duration_sec));
                const hours = total_sec / 3600;
                const mins = (total_sec % 3600) / 60;
                const secs = total_sec % 60;
                break :s try std.fmt.bufPrint(&dur_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, mins, secs });
            },
        };
        const dur_w: f32 = 90.0;
        const dur_color = if (self.state == .recording) ctx.theme.accent_red else if (self.state == .paused) ctx.theme.accent_amber else ctx.theme.text_secondary;
        try ctx.label("hud_lbl_duration", dur_text, .{ .x = cur_x + 6.0, .y = btn_y + 6.0, .w = dur_w, .h = 20.0 }, dur_color);
        cur_x += dur_w + 6.0;

        // 4. Record / Stop button
        const rec_w: f32 = 72.0;
        const rec_label = if (self.state == .recording or self.state == .paused) "STOP" else "REC";
        if (try ctx.button("hud_btn_rec", rec_label, .{ .x = cur_x, .y = btn_y, .w = rec_w, .h = btn_h })) {
            self.action_toggle_record = true;
            if (self.state == .idle) {
                self.state = .recording;
                self.duration_sec = 0.0;
            } else {
                self.state = .idle;
            }
        }
        cur_x += rec_w + 6.0;

        // 5. Pause / Resume button
        if (self.state == .recording or self.state == .paused) {
            const pause_w: f32 = 64.0;
            const pause_label = if (self.state == .paused) "RESUME" else "PAUSE";
            if (try ctx.button("hud_btn_pause", pause_label, .{ .x = cur_x, .y = btn_y, .w = pause_w, .h = btn_h })) {
                self.action_toggle_pause = true;
                self.state = if (self.state == .paused) .recording else .paused;
            }
            cur_x += pause_w + 6.0;
        }

        // 6. Notes toggle button
        const notes_btn_w: f32 = 60.0;
        if (try ctx.button("hud_btn_notes", "NOTES", .{ .x = bar_x + bar_w - notes_btn_w - 8.0, .y = btn_y, .w = notes_btn_w, .h = btn_h })) {
            self.notes_open = !self.notes_open;
        }

        // Floating Notes Window
        if (self.notes_open) {
            const notes_x: f32 = bar_x + bar_w - 320.0;
            const notes_y: f32 = bar_y + bar_h + 12.0;
            const notes_w: f32 = 320.0;
            const notes_h: f32 = 220.0;
            const notes_rect = dvui.Rect{ .x = notes_x, .y = notes_y, .w = notes_w, .h = notes_h };

            try ctx.card("hud_notes_container", notes_rect, ctx.theme.bg_card);
            try ctx.label("hud_notes_title", "RECORDING NOTES", .{ .x = notes_x + 12.0, .y = notes_y + 10.0, .w = notes_w - 24.0, .h = 20.0 }, ctx.theme.text_primary);

            // Notes body
            var line_it = std.mem.splitScalar(u8, self.notes_content, '\n');
            var line_y = notes_y + 36.0;
            var line_idx: usize = 0;
            while (line_it.next()) |line| : (line_idx += 1) {
                if (line_y + 18.0 > notes_y + notes_h - 10.0) break;
                var line_id_buf: [32]u8 = undefined;
                const line_id = try std.fmt.bufPrint(&line_id_buf, "hud_note_ln_{d}", .{line_idx});
                try ctx.label(line_id, line, .{ .x = notes_x + 12.0, .y = line_y, .w = notes_w - 24.0, .h = 16.0 }, ctx.theme.text_secondary);
                line_y += 20.0;
            }
        }
    }
};
