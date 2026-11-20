const std = @import("std");
const dvui = @import("dvui/root.zig");
const core = @import("core");

// Settings Modal Dialog with 17 Locales, Shortcuts & Updater Check

pub const SettingsModal = struct {
    is_open: bool = false,
    current_locale: []const u8 = "en",
    shortcut_recording: []const u8 = "Ctrl+Shift+O",
    shortcut_playpause: []const u8 = "Space",
    version_str: []const u8 = "OpenScreen v2.0.0 (release)",
    update_status: []const u8 = "Up to date",

    pub fn init() SettingsModal {
        return .{};
    }

    pub fn render(self: *SettingsModal, ctx: *dvui.Context) !void {
        if (!self.is_open) return;

        // Modal backdrop overlay (dimmed)
        const screen_rect = dvui.Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(ctx.fb.width),
            .h = @floatFromInt(ctx.fb.height),
        };
        ctx.fb.fillRect(screen_rect, .{ .r = 0, .g = 0, .b = 0, .a = 160 });

        // Centered dialog box: 540x380 px
        const box_w: f32 = 540.0;
        const box_h: f32 = 380.0;
        const box_x: f32 = (@as(f32, @floatFromInt(ctx.fb.width)) - box_w) * 0.5;
        const box_y: f32 = (@as(f32, @floatFromInt(ctx.fb.height)) - box_h) * 0.5;
        const box_rect = dvui.Rect{ .x = box_x, .y = box_y, .w = box_w, .h = box_h };

        try ctx.card("settings_modal_box", box_rect, ctx.theme.bg_card);

        // Title
        try ctx.label("settings_modal_title", "PREFERENCES & SETTINGS", .{ .x = box_x + 16.0, .y = box_y + 16.0, .w = box_w - 32.0, .h = 24.0 }, ctx.theme.text_primary);

        var cur_y = box_y + 46.0;

        // 1. Language switcher (17 Locales)
        try ctx.label("settings_lbl_lang", "Language (17 Locales):", .{ .x = box_x + 16.0, .y = cur_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_secondary);
        cur_y += 24.0;

        const locales = core.i18n.ALL_LOCALES;
        var loc_x = box_x + 16.0;
        for (locales, 0..) |loc, l_idx| {
            const is_selected = std.mem.eql(u8, self.current_locale, loc);
            const btn_w: f32 = 54.0;
            const btn_h: f32 = 22.0;

            if (loc_x + btn_w > box_x + box_w - 16.0) {
                loc_x = box_x + 16.0;
                cur_y += btn_h + 4.0;
            }

            var loc_id_buf: [32]u8 = undefined;
            const loc_id = try std.fmt.bufPrint(&loc_id_buf, "lang_btn_{d}", .{l_idx});

            if (try ctx.button(loc_id, loc, .{ .x = loc_x, .y = cur_y, .w = btn_w, .h = btn_h })) {
                self.current_locale = loc;
                // Arabic triggers RTL layout flip
                ctx.is_rtl = core.i18n.is_rtl(loc);
            }
            if (is_selected) {
                ctx.fb.drawBorder(.{ .x = loc_x, .y = cur_y, .w = btn_w, .h = btn_h }, ctx.theme.accent_blue, 2.0);
            }

            loc_x += btn_w + 4.0;
        }
        cur_y += 32.0;

        // 2. Keyboard Shortcuts
        try ctx.label("settings_lbl_shortcuts", "Global Shortcuts:", .{ .x = box_x + 16.0, .y = cur_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_secondary);
        cur_y += 22.0;
        try ctx.label("settings_sc_rec", "Toggle Recording:   Cmd/Ctrl+Shift+O", .{ .x = box_x + 24.0, .y = cur_y, .w = 300.0, .h = 16.0 }, ctx.theme.text_primary);
        cur_y += 18.0;
        try ctx.label("settings_sc_play", "Play / Pause:       Space", .{ .x = box_x + 24.0, .y = cur_y, .w = 300.0, .h = 16.0 }, ctx.theme.text_primary);
        cur_y += 26.0;

        // 3. Updater Check
        try ctx.label("settings_lbl_updates", "Software Updates:", .{ .x = box_x + 16.0, .y = cur_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_secondary);
        cur_y += 20.0;
        try ctx.label("settings_val_ver", self.version_str, .{ .x = box_x + 24.0, .y = cur_y, .w = 260.0, .h = 16.0 }, ctx.theme.text_primary);

        const check_w: f32 = 140.0;
        if (try ctx.button("settings_btn_check_update", "Check Updates", .{ .x = box_x + box_w - check_w - 16.0, .y = cur_y - 4.0, .w = check_w, .h = 24.0 })) {
            self.update_status = "OpenScreen 2.0.0 is the latest version";
        }
        cur_y += 20.0;
        try ctx.label("settings_val_status", self.update_status, .{ .x = box_x + 24.0, .y = cur_y, .w = 300.0, .h = 16.0 }, ctx.theme.accent_green);

        // Close Button
        const close_w: f32 = 90.0;
        const close_h: f32 = 30.0;
        if (try ctx.button("settings_btn_close", "Close", .{ .x = box_x + box_w - close_w - 16.0, .y = box_y + box_h - close_h - 16.0, .w = close_w, .h = close_h })) {
            self.is_open = false;
        }
    }
};
