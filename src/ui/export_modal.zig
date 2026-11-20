const std = @import("std");
const dvui = @import("dvui/root.zig");

// Export Modal Dialog

pub const ExportFormat = enum {
    mp4,
    gif,
};

pub const ExportResolution = enum {
    res_1080p,
    res_4k,
    res_720p,
};

pub const ExportModal = struct {
    is_open: bool = false,
    format: ExportFormat = .mp4,
    resolution: ExportResolution = .res_1080p,
    fps: u32 = 60,
    is_exporting: bool = false,
    progress: f32 = 0.0,
    action_export: bool = false,

    pub fn init() ExportModal {
        return .{};
    }

    pub fn render(self: *ExportModal, ctx: *dvui.Context) !void {
        if (!self.is_open) return;

        self.action_export = false;

        // Modal backdrop overlay (dimmed)
        const screen_rect = dvui.Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(ctx.fb.width),
            .h = @floatFromInt(ctx.fb.height),
        };
        ctx.fb.fillRect(screen_rect, .{ .r = 0, .g = 0, .b = 0, .a = 160 });

        // Centered dialog box
        const box_w: f32 = 420.0;
        const box_h: f32 = 280.0;
        const box_x: f32 = (@as(f32, @floatFromInt(ctx.fb.width)) - box_w) * 0.5;
        const box_y: f32 = (@as(f32, @floatFromInt(ctx.fb.height)) - box_h) * 0.5;
        const box_rect = dvui.Rect{ .x = box_x, .y = box_y, .w = box_w, .h = box_h };

        try ctx.card("export_modal_box", box_rect, ctx.theme.bg_card);

        // Title
        try ctx.label("export_modal_title", "EXPORT VIDEO / GIF", .{ .x = box_x + 16.0, .y = box_y + 16.0, .w = box_w - 32.0, .h = 24.0 }, ctx.theme.text_primary);

        var cur_y = box_y + 48.0;

        // Format selector (MP4 vs GIF)
        try ctx.label("export_lbl_format", "Format:", .{ .x = box_x + 16.0, .y = cur_y + 4.0, .w = 80.0, .h = 20.0 }, ctx.theme.text_secondary);
        const is_mp4 = (self.format == .mp4);
        if (try ctx.button("export_btn_mp4", if (is_mp4) "[MP4 H.264]" else "MP4 H.264", .{ .x = box_x + 100.0, .y = cur_y, .w = 120.0, .h = 26.0 })) {
            self.format = .mp4;
        }
        if (try ctx.button("export_btn_gif", if (!is_mp4) "[GIF Anim]" else "GIF Anim", .{ .x = box_x + 230.0, .y = cur_y, .w = 110.0, .h = 26.0 })) {
            self.format = .gif;
        }
        cur_y += 36.0;

        // Resolution selector
        try ctx.label("export_lbl_res", "Resolution:", .{ .x = box_x + 16.0, .y = cur_y + 4.0, .w = 80.0, .h = 20.0 }, ctx.theme.text_secondary);
        if (try ctx.button("export_btn_1080p", "1080p", .{ .x = box_x + 100.0, .y = cur_y, .w = 70.0, .h = 26.0 })) {
            self.resolution = .res_1080p;
        }
        if (try ctx.button("export_btn_4k", "4K UHD", .{ .x = box_x + 180.0, .y = cur_y, .w = 70.0, .h = 26.0 })) {
            self.resolution = .res_4k;
        }
        if (try ctx.button("export_btn_720p", "720p", .{ .x = box_x + 260.0, .y = cur_y, .w = 70.0, .h = 26.0 })) {
            self.resolution = .res_720p;
        }
        cur_y += 36.0;

        // Framerate selector
        try ctx.label("export_lbl_fps", "Framerate:", .{ .x = box_x + 16.0, .y = cur_y + 4.0, .w = 80.0, .h = 20.0 }, ctx.theme.text_secondary);
        if (try ctx.button("export_btn_60fps", "60 FPS", .{ .x = box_x + 100.0, .y = cur_y, .w = 70.0, .h = 26.0 })) {
            self.fps = 60;
        }
        if (try ctx.button("export_btn_30fps", "30 FPS", .{ .x = box_x + 180.0, .y = cur_y, .w = 70.0, .h = 26.0 })) {
            self.fps = 30;
        }
        cur_y += 36.0;

        // Progress bar (if exporting)
        if (self.is_exporting) {
            _ = try ctx.slider("export_progress_bar", self.progress, 0.0, 1.0, .{ .x = box_x + 16.0, .y = cur_y, .w = box_w - 32.0, .h = 16.0 });
            var prog_buf: [32]u8 = undefined;
            const prog_str = try std.fmt.bufPrint(&prog_buf, "Encoding: {d:.0}%", .{self.progress * 100.0});
            try ctx.label("export_progress_lbl", prog_str, .{ .x = box_x + 16.0, .y = cur_y + 20.0, .w = box_w - 32.0, .h = 16.0 }, ctx.theme.accent_blue);
            cur_y += 40.0;
        } else {
            cur_y += 20.0;
        }

        // Action Buttons: Cancel vs Start Export
        const btn_w: f32 = 100.0;
        const btn_h: f32 = 32.0;
        if (try ctx.button("export_btn_cancel", "Cancel", .{ .x = box_x + box_w - btn_w * 2.0 - 24.0, .y = box_y + box_h - btn_h - 16.0, .w = btn_w, .h = btn_h })) {
            self.is_open = false;
        }

        if (try ctx.button("export_btn_start", "Export", .{ .x = box_x + box_w - btn_w - 16.0, .y = box_y + box_h - btn_h - 16.0, .w = btn_w, .h = btn_h })) {
            self.is_exporting = true;
            self.progress = 0.0;
            self.action_export = true;
        }
    }
};
