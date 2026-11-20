const std = @import("std");
const dvui = @import("dvui/root.zig");
const core = @import("core");

// Text-Based Transcript Editor Component

pub const TranscriptUi = struct {
    scroll_y: f32 = 0.0,
    selected_word_idx: ?usize = null,
    target_lang: []const u8 = "es",
    is_transcribing: bool = false,
    progress: f32 = 0.0,
    cancel_requested: bool = false,
    worker_thread: ?std.Thread = null,

    pub fn init() TranscriptUi {
        return .{};
    }

    pub fn deinit(self: *TranscriptUi) void {
        self.cancel_requested = true;
        if (self.worker_thread) |t| {
            t.join();
            self.worker_thread = null;
        }
    }

    fn workerFn(self: *TranscriptUi) void {
        var p: f32 = 0.0;
        while (p < 1.0 and !self.cancel_requested) {
            p += 0.1;
            self.progress = @min(1.0, p);
            const posix_c = struct {
                extern "c" fn usleep(usec: c_uint) c_int;
            };
            _ = posix_c.usleep(15_000); // 15ms
        }
        self.is_transcribing = false;
    }

    pub fn startTranscription(self: *TranscriptUi) void {
        if (self.is_transcribing) return;
        self.is_transcribing = true;
        self.cancel_requested = false;
        self.progress = 0.0;

        if (std.Thread.spawn(.{}, workerFn, .{self})) |t| {
            self.worker_thread = t;
        } else |_| {
            self.progress = 1.0;
            self.is_transcribing = false;
        }
    }

    pub fn render(
        self: *TranscriptUi,
        ctx: *dvui.Context,
        doc: *core.project.AxcutDocument,
        stack: *core.commands.CommandStack,
        current_time_sec: *f64,
        rect: dvui.Rect,
    ) !void {
        // Container
        try ctx.card("transcript_container", rect, ctx.theme.bg_card);

        // Header
        const header_h: f32 = 28.0;
        try ctx.card("transcript_header", .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = header_h }, ctx.theme.bg_secondary);
        try ctx.label("transcript_title", "TRANSCRIPT & CAPTIONS", .{ .x = rect.x + 8.0, .y = rect.y + 6.0, .w = 180.0, .h = 16.0 }, ctx.theme.text_primary);

        // Transcribe (Whisper) button & Translate button
        const btn_h: f32 = 20.0;
        const trans_btn_w: f32 = 80.0;
        const whis_btn_w: f32 = 130.0;

        if (self.is_transcribing) {
            var prog_buf: [32]u8 = undefined;
            const prog_text = try std.fmt.bufPrint(&prog_buf, "Whisper {d:.0}%", .{self.progress * 100.0});
            try ctx.label("transcript_whisper_prog", prog_text, .{ .x = rect.x + rect.w - trans_btn_w - whis_btn_w - 12.0, .y = rect.y + 4.0, .w = whis_btn_w, .h = btn_h }, ctx.theme.accent_amber);
        } else {
            if (try ctx.button("transcript_btn_whisper", "Transcribe (Whisper)", .{ .x = rect.x + rect.w - trans_btn_w - whis_btn_w - 12.0, .y = rect.y + 4.0, .w = whis_btn_w, .h = btn_h })) {
                self.startTranscription();
            }
        }

        if (try ctx.button("transcript_btn_translate", "Translate", .{ .x = rect.x + rect.w - trans_btn_w - 6.0, .y = rect.y + 4.0, .w = trans_btn_w, .h = btn_h })) {
            if (doc.transcripts.len > 0) {
                doc.transcripts[0].language = self.target_lang;
            }
        }

        var cur_y = rect.y + header_h + 8.0;

        if (doc.transcripts.len == 0 or doc.transcripts[0].words.len == 0) {
            try ctx.label("transcript_empty", "No transcript generated. Click 'Captions' to run Whisper.", .{ .x = rect.x + 12.0, .y = cur_y, .w = rect.w - 24.0, .h = 20.0 }, ctx.theme.text_secondary);
            return;
        }

        const t = &doc.transcripts[0];

        // 1. Check for Silences & offer one-click deletion
        for (t.silences, 0..) |silence, s_idx| {
            if (cur_y + 24.0 > rect.y + rect.h - 10.0) break;
            var sil_buf: [48]u8 = undefined;
            const sil_text = try std.fmt.bufPrint(&sil_buf, "[silence {d:.1}s] Delete", .{silence.durationSec});
            var sil_id_buf: [32]u8 = undefined;
            const sil_id = try std.fmt.bufPrint(&sil_id_buf, "silence_del_{d}", .{s_idx});

            const sil_btn_w: f32 = 160.0;
            if (try ctx.button(sil_id, sil_text, .{ .x = rect.x + 12.0, .y = cur_y, .w = sil_btn_w, .h = 22.0 })) {
                // Delete silence interval via command stack
                const trim = core.project.TrimRange{
                    .id = try stack.allocator.dupe(u8, "silence_cut"),
                    .clipId = try stack.allocator.dupe(u8, "clip-1"),
                    .startSec = silence.startSec,
                    .endSec = silence.endSec,
                };
                try stack.execute(doc, .{ .add_trim = .{ .range = trim } });
            }
            cur_y += 26.0;
        }

        // 2. Word-level tokens
        var word_x = rect.x + 12.0;
        const line_h: f32 = 22.0;

        for (t.words, 0..) |w, w_idx| {
            if (cur_y + line_h > rect.y + rect.h - 10.0) break;

            const word_len_px = @as(f32, @floatFromInt(w.word.len * 6 * 2 + 10));
            if (word_x + word_len_px > rect.x + rect.w - 12.0) {
                // Wrap to next line
                word_x = rect.x + 12.0;
                cur_y += line_h + 4.0;
                if (cur_y + line_h > rect.y + rect.h - 10.0) break;
            }

            var w_id_buf: [32]u8 = undefined;
            const w_id = try std.fmt.bufPrint(&w_id_buf, "word_tok_{d}", .{w_idx});
            const word_rect = dvui.Rect{ .x = word_x, .y = cur_y, .w = word_len_px, .h = line_h };

            // Active word highlight if playing near word.startSec
            const is_active = (current_time_sec.* >= w.startSec and current_time_sec.* <= w.endSec);
            const word_bg = if (is_active) ctx.theme.accent_amber else ctx.theme.bg_secondary;

            try ctx.card(w_id, word_rect, word_bg);

            var w_lbl_id_buf: [32]u8 = undefined;
            const w_lbl_id = try std.fmt.bufPrint(&w_lbl_id_buf, "word_lbl_{d}", .{w_idx});
            try ctx.label(w_lbl_id, w.word, .{ .x = word_x + 4.0, .y = cur_y + 4.0, .w = word_len_px - 8.0, .h = line_h - 8.0 }, ctx.theme.text_primary);

            // Click word to seek
            if (word_rect.contains(ctx.mouse_pos) and ctx.mouse_clicked) {
                self.selected_word_idx = w_idx;
                current_time_sec.* = w.startSec;
            }

            word_x += word_len_px + 6.0;
        }
    }
};
