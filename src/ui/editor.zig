const std = @import("std");
const dvui = @import("dvui/root.zig");
const core = @import("core");
const compositor = @import("compositor");
const timeline_ui = @import("timeline_ui.zig");
const transcript_ui = @import("transcript_ui.zig");
const export_modal = @import("export_modal.zig");
const settings_modal = @import("settings_modal.zig");

// Main Editor Shell & Zero-Copy GPU Preview

pub const EditorMode = enum {
    edit,
    media,
    rec,
};

pub const InspectorTab = enum {
    composition,
    camera_3d,
    cursor,
    layouts,
    annotations_blur,
    ai_assistant,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    doc: core.project.AxcutDocument,
    stack: core.commands.CommandStack,
    mode: EditorMode = .edit,
    inspector_tab: InspectorTab = .composition,
    current_time_sec: f64 = 0.0,
    is_playing: bool = false,
    timeline: timeline_ui.TimelineView,
    transcript: transcript_ui.TranscriptUi,
    modal_export: export_modal.ExportModal,
    modal_settings: settings_modal.SettingsModal,
    chat_open: bool = true,
    chat_prompt_buffer: [128]u8 = undefined,
    chat_prompt_len: usize = 0,
    active_tab_bottom: enum { timeline, transcript } = .timeline,

    pub fn init(allocator: std.mem.Allocator, doc: core.project.AxcutDocument) Editor {
        return .{
            .allocator = allocator,
            .doc = doc,
            .stack = core.commands.CommandStack.init(allocator),
            .timeline = timeline_ui.TimelineView.init(),
            .transcript = transcript_ui.TranscriptUi.init(),
            .modal_export = export_modal.ExportModal.init(),
            .modal_settings = settings_modal.SettingsModal.init(),
        };
    }

    pub fn deinit(self: *Editor) void {
        self.doc.deinit(self.allocator);
        self.stack.deinit();
    }

    pub fn update(self: *Editor, delta_sec: f64) void {
        if (self.is_playing) {
            const total_dur = if (self.doc.assets.len > 0) self.doc.assets[0].durationSec else 10.0;
            self.current_time_sec += delta_sec;
            if (self.current_time_sec >= total_dur) {
                self.current_time_sec = 0.0; // Loop playback
            }
        }
    }

    pub fn render(self: *Editor, ctx: *dvui.Context) !void {
        const sw: f32 = @floatFromInt(ctx.fb.width);
        const sh: f32 = @floatFromInt(ctx.fb.height);

        // 1. Top Bar: 0..sw, h=40
        const top_bar_h: f32 = 40.0;
        try ctx.card("editor_top_bar", .{ .x = 0, .y = 0, .w = sw, .h = top_bar_h }, ctx.theme.bg_secondary);

        var top_x: f32 = 12.0;

        // Title
        try ctx.label("top_lbl_title", self.doc.project.title, .{ .x = top_x, .y = 10.0, .w = 160.0, .h = 20.0 }, ctx.theme.text_primary);
        top_x += 170.0;

        // Undo button
        const can_undo = self.stack.can_undo();
        if (try ctx.button("top_btn_undo", "Undo", .{ .x = top_x, .y = 7.0, .w = 60.0, .h = 26.0 })) {
            if (can_undo) {
                _ = try self.stack.undo(&self.doc);
            }
        }
        top_x += 66.0;

        // Redo button
        const can_redo = self.stack.can_redo();
        if (try ctx.button("top_btn_redo", "Redo", .{ .x = top_x, .y = 7.0, .w = 60.0, .h = 26.0 })) {
            if (can_redo) {
                _ = try self.stack.redo(&self.doc);
            }
        }
        top_x += 76.0;

        // Mode switch buttons: Edit, Media, Rec
        if (try ctx.button("top_btn_mode_edit", if (self.mode == .edit) "[Edit]" else "Edit", .{ .x = top_x, .y = 7.0, .w = 54.0, .h = 26.0 })) {
            self.mode = .edit;
        }
        top_x += 58.0;

        if (try ctx.button("top_btn_mode_media", if (self.mode == .media) "[Media]" else "Media", .{ .x = top_x, .y = 7.0, .w = 58.0, .h = 26.0 })) {
            self.mode = .media;
        }
        top_x += 62.0;

        if (try ctx.button("top_btn_mode_rec", if (self.mode == .rec) "[Rec]" else "Rec", .{ .x = top_x, .y = 7.0, .w = 50.0, .h = 26.0 })) {
            self.mode = .rec;
        }
        top_x += 70.0;

        // Settings Button (Right side)
        const btn_settings_w: f32 = 80.0;
        if (try ctx.button("top_btn_settings", "Settings", .{ .x = sw - btn_settings_w - 90.0, .y = 7.0, .w = btn_settings_w, .h = 26.0 })) {
            self.modal_settings.is_open = true;
        }

        // Export Button (Right side)
        const btn_export_w: f32 = 76.0;
        if (try ctx.button("top_btn_export", "Export", .{ .x = sw - btn_export_w - 8.0, .y = 7.0, .w = btn_export_w, .h = 26.0 })) {
            self.modal_export.is_open = true;
        }

        // Layout Calculation
        const timeline_h: f32 = 240.0;
        const stage_h: f32 = sh - top_bar_h - timeline_h;
        const left_col_w: f32 = if (self.chat_open) 240.0 else 0.0;
        const right_col_w: f32 = 280.0;
        const stage_w: f32 = sw - left_col_w - right_col_w;

        // 2. Left Column: BYOK AI Assistant Chat Strip
        if (self.chat_open) {
            const chat_rect = dvui.Rect{ .x = 0, .y = top_bar_h, .w = left_col_w, .h = stage_h };
            try ctx.card("chat_container", chat_rect, ctx.theme.bg_secondary);
            try ctx.label("chat_title", "AI EDITING ASSISTANT", .{ .x = 10.0, .y = top_bar_h + 10.0, .w = left_col_w - 20.0, .h = 18.0 }, ctx.theme.text_primary);

            try ctx.card("chat_status_card", .{ .x = 10.0, .y = top_bar_h + 36.0, .w = left_col_w - 20.0, .h = 44.0 }, ctx.theme.bg_card);
            try ctx.label("chat_model_lbl", "Model: BYOK Claude / GPT", .{ .x = 16.0, .y = top_bar_h + 40.0, .w = left_col_w - 32.0, .h = 16.0 }, ctx.theme.accent_blue);
            try ctx.label("chat_status_lbl", "Status: Ready", .{ .x = 16.0, .y = top_bar_h + 58.0, .w = left_col_w - 32.0, .h = 16.0 }, ctx.theme.accent_green);

            // Chat history bubble
            try ctx.card("chat_history_bubble", .{ .x = 10.0, .y = top_bar_h + 90.0, .w = left_col_w - 20.0, .h = 80.0 }, ctx.theme.bg_primary);
            try ctx.label("chat_msg_1", "Assistant:", .{ .x = 16.0, .y = top_bar_h + 96.0, .w = left_col_w - 32.0, .h = 14.0 }, ctx.theme.accent_purple);
            try ctx.label("chat_msg_2", "I removed 3 silence", .{ .x = 16.0, .y = top_bar_h + 114.0, .w = left_col_w - 32.0, .h = 14.0 }, ctx.theme.text_secondary);
            try ctx.label("chat_msg_3", "gaps and added zooms.", .{ .x = 16.0, .y = top_bar_h + 130.0, .w = left_col_w - 32.0, .h = 14.0 }, ctx.theme.text_secondary);

            // Prompt box
            try ctx.card("chat_input_box", .{ .x = 10.0, .y = top_bar_h + stage_h - 44.0, .w = left_col_w - 20.0, .h = 32.0 }, ctx.theme.bg_card);
            try ctx.label("chat_input_hint", "Ask AI to edit...", .{ .x = 16.0, .y = top_bar_h + stage_h - 36.0, .w = left_col_w - 40.0, .h = 16.0 }, ctx.theme.text_secondary);
        }

        // 3. Central Stage: Live Zero-Copy Viewport
        const stage_x = left_col_w;
        const stage_rect = dvui.Rect{ .x = stage_x, .y = top_bar_h, .w = stage_w, .h = stage_h };
        try ctx.card("stage_container", stage_rect, ctx.theme.bg_primary);

        // Viewport Frame
        const pad: f32 = 16.0;
        const vp_w: f32 = stage_w - pad * 2.0;
        const vp_h: f32 = stage_h - 60.0;
        const vp_rect = dvui.Rect{ .x = stage_x + pad, .y = top_bar_h + pad, .w = vp_w, .h = vp_h };

        // Render wallpaper / composition canvas in viewport
        try ctx.card("viewport_screen", vp_rect, .{ .r = 28, .g = 32, .b = 40, .a = 255 });

        // Centered video frame within wallpaper
        const vframe_w = vp_w * 0.85;
        const vframe_h = vp_h * 0.85;
        const vframe_x = vp_rect.x + (vp_w - vframe_w) * 0.5;
        const vframe_y = vp_rect.y + (vp_h - vframe_h) * 0.5;
        try ctx.card("viewport_video_frame", .{ .x = vframe_x, .y = vframe_y, .w = vframe_w, .h = vframe_h }, .{ .r = 10, .g = 12, .b = 16, .a = 255 });

        // Webcam PiP preview overlay
        if (!std.mem.eql(u8, self.doc.legacyEditor.webcamLayoutPreset, "none")) {
            const cam_w: f32 = 120.0;
            const cam_h: f32 = 80.0;
            const cam_x = vframe_x + vframe_w - cam_w - 12.0;
            const cam_y = vframe_y + 12.0;
            try ctx.card("viewport_webcam_pip", .{ .x = cam_x, .y = cam_y, .w = cam_w, .h = cam_h }, .{ .r = 45, .g = 55, .b = 72, .a = 255 });
            try ctx.label("viewport_cam_lbl", "WEBCAM", .{ .x = cam_x + 32.0, .y = cam_y + 32.0, .w = 60.0, .h = 16.0 }, ctx.theme.text_secondary);
        }

        // Subtitle banner overlay at bottom of video frame
        if (self.doc.transcripts.len > 0 and self.doc.transcripts[0].words.len > 0) {
            const sub_h: f32 = 32.0;
            const sub_rect = dvui.Rect{ .x = vframe_x + 40.0, .y = vframe_y + vframe_h - sub_h - 20.0, .w = vframe_w - 80.0, .h = sub_h };
            try ctx.card("viewport_sub_banner", sub_rect, .{ .r = 0, .g = 0, .b = 0, .a = 180 });
            try ctx.label("viewport_sub_text", "OpenScreen 2.0 Native Speed", .{ .x = sub_rect.x + 20.0, .y = sub_rect.y + 8.0, .w = sub_rect.w - 40.0, .h = 16.0 }, ctx.theme.text_primary);
        }

        // Transport Bar below viewport: Play/Pause, Time, Scrub
        const trans_y = top_bar_h + stage_h - 38.0;
        const play_w: f32 = 64.0;
        const play_label = if (self.is_playing) "PAUSE" else "PLAY";
        if (try ctx.button("stage_btn_play", play_label, .{ .x = stage_x + pad, .y = trans_y, .w = play_w, .h = 28.0 })) {
            self.is_playing = !self.is_playing;
        }

        var time_buf: [32]u8 = undefined;
        const total_dur = if (self.doc.assets.len > 0) self.doc.assets[0].durationSec else 10.0;
        const time_str = try std.fmt.bufPrint(&time_buf, "{d:.1}s / {d:.1}s", .{ self.current_time_sec, total_dur });
        try ctx.label("stage_lbl_time", time_str, .{ .x = stage_x + pad + play_w + 12.0, .y = trans_y + 6.0, .w = 110.0, .h = 18.0 }, ctx.theme.text_primary);

        // 4. Right Column: Inspector Tabs (Composition, 3D Camera, Cursor, Layouts, Annotations, AI)
        const insp_x = sw - right_col_w;
        const insp_rect = dvui.Rect{ .x = insp_x, .y = top_bar_h, .w = right_col_w, .h = stage_h };
        try ctx.card("inspector_container", insp_rect, ctx.theme.bg_secondary);

        // Tab Strip (2 rows of 3 buttons)
        const tab_w: f32 = (right_col_w - 24.0) / 3.0;
        const tab_h: f32 = 24.0;

        if (try ctx.button("insp_tab_comp", "Style", .{ .x = insp_x + 8.0, .y = top_bar_h + 8.0, .w = tab_w, .h = tab_h })) {
            self.inspector_tab = .composition;
        }
        if (try ctx.button("insp_tab_cam3d", "3D Cam", .{ .x = insp_x + 8.0 + tab_w + 4.0, .y = top_bar_h + 8.0, .w = tab_w, .h = tab_h })) {
            self.inspector_tab = .camera_3d;
        }
        if (try ctx.button("insp_tab_cur", "Cursor", .{ .x = insp_x + 8.0 + (tab_w + 4.0) * 2.0, .y = top_bar_h + 8.0, .w = tab_w, .h = tab_h })) {
            self.inspector_tab = .cursor;
        }

        if (try ctx.button("insp_tab_lay", "Layout", .{ .x = insp_x + 8.0, .y = top_bar_h + 36.0, .w = tab_w, .h = tab_h })) {
            self.inspector_tab = .layouts;
        }
        if (try ctx.button("insp_tab_ann", "Annot", .{ .x = insp_x + 8.0 + tab_w + 4.0, .y = top_bar_h + 36.0, .w = tab_w, .h = tab_h })) {
            self.inspector_tab = .annotations_blur;
        }
        if (try ctx.button("insp_tab_ai", "AI Tab", .{ .x = insp_x + 8.0 + (tab_w + 4.0) * 2.0, .y = top_bar_h + 36.0, .w = tab_w, .h = tab_h })) {
            self.inspector_tab = .ai_assistant;
        }

        // Inspector Body
        var insp_y = top_bar_h + 70.0;
        switch (self.inspector_tab) {
            .composition => {
                try ctx.label("insp_body_title", "COMPOSITION & FRAME", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 22.0;

                // Frame Padding
                try ctx.label("insp_lbl_pad", "Frame Padding:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 120.0, .h = 14.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.padding = try ctx.slider("insp_sld_pad", self.doc.legacyEditor.padding, 0.0, 100.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 32.0;

                // Corner Roundness
                try ctx.label("insp_lbl_rnd", "Corner Roundness:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 14.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.borderRadius = try ctx.slider("insp_sld_rnd", self.doc.legacyEditor.borderRadius, 0.0, 60.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 32.0;

                // Shadow Intensity
                try ctx.label("insp_lbl_shd", "Shadow Intensity:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 14.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.shadowIntensity = try ctx.slider("insp_sld_shd", self.doc.legacyEditor.shadowIntensity, 0.0, 1.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 32.0;

                // Background Blur %
                try ctx.label("insp_lbl_bgblur", "Background Blur:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 14.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.backgroundBlur = try ctx.slider("insp_sld_bgblur", self.doc.legacyEditor.backgroundBlur, 0.0, 100.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 32.0;

                // Animated Background Presets
                try ctx.label("insp_lbl_anim_bg", "Animated Background:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 160.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const anim_btn_w: f32 = (right_col_w - 36.0) / 4.0;
                if (try ctx.button("insp_abg_none", "None", .{ .x = insp_x + 12.0, .y = insp_y, .w = anim_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_abg_drift", "Drift", .{ .x = insp_x + 12.0 + anim_btn_w + 4.0, .y = insp_y, .w = anim_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_abg_aurora", "Aurora", .{ .x = insp_x + 12.0 + (anim_btn_w + 4.0) * 2.0, .y = insp_y, .w = anim_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_abg_waves", "Waves", .{ .x = insp_x + 12.0 + (anim_btn_w + 4.0) * 3.0, .y = insp_y, .w = anim_btn_w, .h = 20.0 })) {}
                insp_y += 26.0;

                // Device Frame Presets
                try ctx.label("insp_lbl_devframe", "Device Frame:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const df_btn_w: f32 = (right_col_w - 36.0) / 4.0;
                if (try ctx.button("insp_df_win", "Window", .{ .x = insp_x + 12.0, .y = insp_y, .w = df_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_df_laptop", "Laptop", .{ .x = insp_x + 12.0 + df_btn_w + 4.0, .y = insp_y, .w = df_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_df_phone", "Phone", .{ .x = insp_x + 12.0 + (df_btn_w + 4.0) * 2.0, .y = insp_y, .w = df_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_df_screen", "Screen", .{ .x = insp_x + 12.0 + (df_btn_w + 4.0) * 3.0, .y = insp_y, .w = df_btn_w, .h = 20.0 })) {}
                insp_y += 26.0;

                // Motion Blur Toggle
                const has_mblur = (self.doc.legacyEditor.motionBlurAmount > 0.05);
                const new_mblur = try ctx.toggle("insp_tog_mblur", "Motion Blur", has_mblur, .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 22.0 });
                self.doc.legacyEditor.motionBlurAmount = if (new_mblur) 0.35 else 0.0;
            },
            .camera_3d => {
                try ctx.label("insp_body_title_cam", "3D CAMERA ORIENTATION", .{ .x = insp_x + 12.0, .y = insp_y, .w = 220.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;

                const cam_btn_w: f32 = (right_col_w - 36.0) / 4.0;
                if (try ctx.button("insp_cam_flat", "Flat 2D", .{ .x = insp_x + 12.0, .y = insp_y, .w = cam_btn_w, .h = 22.0 })) {}
                if (try ctx.button("insp_cam_left", "Tilt L", .{ .x = insp_x + 12.0 + cam_btn_w + 4.0, .y = insp_y, .w = cam_btn_w, .h = 22.0 })) {}
                if (try ctx.button("insp_cam_right", "Tilt R", .{ .x = insp_x + 12.0 + (cam_btn_w + 4.0) * 2.0, .y = insp_y, .w = cam_btn_w, .h = 22.0 })) {}
                if (try ctx.button("insp_cam_orbit", "Orbit", .{ .x = insp_x + 12.0 + (cam_btn_w + 4.0) * 3.0, .y = insp_y, .w = cam_btn_w, .h = 22.0 })) {}
                insp_y += 30.0;

                try ctx.label("insp_lbl_dof", "Depth of Field (DoF):", .{ .x = insp_x + 12.0, .y = insp_y, .w = 160.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                _ = try ctx.slider("insp_sld_dof", 0.4, 0.0, 1.0, .{ .x = insp_x + 12.0, .y = insp_y, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 26.0;

                try ctx.label("insp_lbl_pitch", "Camera Pitch:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 120.0, .h = 14.0 }, ctx.theme.text_secondary);
                _ = try ctx.slider("insp_sld_pitch", 0.0, -45.0, 45.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 32.0;

                try ctx.label("insp_lbl_yaw", "Camera Yaw:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 120.0, .h = 14.0 }, ctx.theme.text_secondary);
                _ = try ctx.slider("insp_sld_yaw", 0.0, -45.0, 45.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
            },
            .cursor => {
                try ctx.label("insp_body_title_cur", "CURSOR TELEMETRY", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;

                self.doc.legacyEditor.cursorShow = try ctx.toggle("insp_tog_cur_show", "Show Cursor", self.doc.legacyEditor.cursorShow, .{ .x = insp_x + 12.0, .y = insp_y, .w = 130.0, .h = 22.0 });
                insp_y += 28.0;

                try ctx.label("insp_lbl_cur_size", "Cursor Size:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 120.0, .h = 14.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.cursor.size = try ctx.slider("insp_sld_cur_sz", self.doc.legacyEditor.cursor.size, 0.5, 5.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 32.0;

                try ctx.label("insp_lbl_cur_smth", "Telemetry Smoothing:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 160.0, .h = 14.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.cursor.smoothing = try ctx.slider("insp_sld_cur_smth", self.doc.legacyEditor.cursor.smoothing, 0.0, 1.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
                insp_y += 32.0;

                // 5 Cursor Packs Picker
                try ctx.label("insp_lbl_cur_pack", "Cursor Pack (5 Packs):", .{ .x = insp_x + 12.0, .y = insp_y, .w = 180.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const pack_btn_w: f32 = (right_col_w - 32.0) / 3.0;
                if (try ctx.button("insp_cp_mac", "macOS", .{ .x = insp_x + 12.0, .y = insp_y, .w = pack_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_cp_win", "Win 11", .{ .x = insp_x + 12.0 + pack_btn_w + 4.0, .y = insp_y, .w = pack_btn_w, .h = 20.0 })) {}
                if (try ctx.button("insp_cp_pix", "Pixel", .{ .x = insp_x + 12.0 + (pack_btn_w + 4.0) * 2.0, .y = insp_y, .w = pack_btn_w, .h = 20.0 })) {}
                insp_y += 24.0;
                if (try ctx.button("insp_cp_dot", "Minimal Dot", .{ .x = insp_x + 12.0, .y = insp_y, .w = pack_btn_w * 1.5, .h = 20.0 })) {}
                if (try ctx.button("insp_cp_ptr", "Pointer", .{ .x = insp_x + 16.0 + pack_btn_w * 1.5, .y = insp_y, .w = pack_btn_w * 1.5, .h = 20.0 })) {}
                insp_y += 28.0;

                // Click Bounce & Sound Gain
                self.doc.legacyEditor.cursor.clickSound = try ctx.toggle("insp_tog_cbounce", "Click Bounce & Sound", self.doc.legacyEditor.cursor.clickSound, .{ .x = insp_x + 12.0, .y = insp_y, .w = 180.0, .h = 22.0 });
            },
            .layouts => {
                try ctx.label("insp_body_title_lay", "WEBCAM & LAYOUTS", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;

                // Layout Presets
                const lay_btn_w: f32 = (right_col_w - 36.0) / 4.0;
                if (try ctx.button("insp_lay_pip", "PiP", .{ .x = insp_x + 12.0, .y = insp_y, .w = lay_btn_w, .h = 22.0 })) {
                    self.doc.legacyEditor.webcamLayoutPreset = "picture-in-picture";
                }
                if (try ctx.button("insp_lay_dual", "Dual", .{ .x = insp_x + 12.0 + lay_btn_w + 4.0, .y = insp_y, .w = lay_btn_w, .h = 22.0 })) {
                    self.doc.legacyEditor.webcamLayoutPreset = "dual-frame";
                }
                if (try ctx.button("insp_lay_stack", "Stack", .{ .x = insp_x + 12.0 + (lay_btn_w + 4.0) * 2.0, .y = insp_y, .w = lay_btn_w, .h = 22.0 })) {
                    self.doc.legacyEditor.webcamLayoutPreset = "vertical-stack";
                }
                if (try ctx.button("insp_lay_full", "Full", .{ .x = insp_x + 12.0 + (lay_btn_w + 4.0) * 3.0, .y = insp_y, .w = lay_btn_w, .h = 22.0 })) {
                    self.doc.legacyEditor.webcamLayoutPreset = "full-camera";
                }
                insp_y += 30.0;

                // PiP Snap Positions (All 8 positions: 4 corners + 4 mid-edges)
                try ctx.label("insp_lbl_snap", "PiP Snap Position (8 Pos):", .{ .x = insp_x + 12.0, .y = insp_y, .w = 180.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const snap_w3: f32 = (right_col_w - 32.0) / 3.0;
                const snap_w2: f32 = (right_col_w - 28.0) / 2.0;

                // Row 1: Top-Left, Top-Center, Top-Right
                if (try ctx.button("insp_snap_tl", "TL", .{ .x = insp_x + 12.0, .y = insp_y, .w = snap_w3, .h = 20.0 })) {}
                if (try ctx.button("insp_snap_tc", "TC", .{ .x = insp_x + 16.0 + snap_w3, .y = insp_y, .w = snap_w3, .h = 20.0 })) {}
                if (try ctx.button("insp_snap_tr", "TR", .{ .x = insp_x + 20.0 + snap_w3 * 2.0, .y = insp_y, .w = snap_w3, .h = 20.0 })) {}
                insp_y += 24.0;

                // Row 2: Left-Center, Right-Center
                if (try ctx.button("insp_snap_lc", "LC (Left)", .{ .x = insp_x + 12.0, .y = insp_y, .w = snap_w2, .h = 20.0 })) {}
                if (try ctx.button("insp_snap_rc", "RC (Right)", .{ .x = insp_x + 16.0 + snap_w2, .y = insp_y, .w = snap_w2, .h = 20.0 })) {}
                insp_y += 24.0;

                // Row 3: Bottom-Left, Bottom-Center, Bottom-Right
                if (try ctx.button("insp_snap_bl", "BL", .{ .x = insp_x + 12.0, .y = insp_y, .w = snap_w3, .h = 20.0 })) {}
                if (try ctx.button("insp_snap_bc", "BC", .{ .x = insp_x + 16.0 + snap_w3, .y = insp_y, .w = snap_w3, .h = 20.0 })) {}
                if (try ctx.button("insp_snap_br", "BR", .{ .x = insp_x + 20.0 + snap_w3 * 2.0, .y = insp_y, .w = snap_w3, .h = 20.0 })) {}
                insp_y += 28.0;

                // ONNX AI Matting Modes
                try ctx.label("insp_lbl_matting", "AI Matting (ONNX):", .{ .x = insp_x + 12.0, .y = insp_y, .w = 160.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const mat_w: f32 = (right_col_w - 36.0) / 4.0;
                if (try ctx.button("insp_mat_off", "Off", .{ .x = insp_x + 12.0, .y = insp_y, .w = mat_w, .h = 20.0 })) {}
                if (try ctx.button("insp_mat_blur", "Blur", .{ .x = insp_x + 12.0 + mat_w + 4.0, .y = insp_y, .w = mat_w, .h = 20.0 })) {}
                if (try ctx.button("insp_mat_cut", "Cutout", .{ .x = insp_x + 12.0 + (mat_w + 4.0) * 2.0, .y = insp_y, .w = mat_w, .h = 20.0 })) {}
                if (try ctx.button("insp_mat_rep", "Replace", .{ .x = insp_x + 12.0 + (mat_w + 4.0) * 3.0, .y = insp_y, .w = mat_w, .h = 20.0 })) {}
                insp_y += 28.0;

                // Webcam Roundness & Mirror
                try ctx.label("insp_lbl_cam_rnd", "Webcam Roundness:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 14.0 }, ctx.theme.text_secondary);
                _ = try ctx.slider("insp_sld_cam_rnd", 50.0, 0.0, 100.0, .{ .x = insp_x + 12.0, .y = insp_y + 16.0, .w = right_col_w - 24.0, .h = 12.0 });
            },
            .annotations_blur => {
                try ctx.label("insp_body_title_ann", "ANNOTATIONS & BLUR", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;

                // Add Text Annotation
                if (try ctx.button("insp_add_text_btn", "+ Add Text Annotation", .{ .x = insp_x + 12.0, .y = insp_y, .w = right_col_w - 24.0, .h = 24.0 })) {
                    const ann = core.project.Annotation{
                        .id = try self.allocator.dupe(u8, "ann_text"),
                        .clipId = try self.allocator.dupe(u8, "clip-1"),
                        .startSec = self.current_time_sec,
                        .endSec = self.current_time_sec + 2.0,
                        .content = try self.allocator.dupe(u8, "Note"),
                    };
                    try self.stack.execute(&self.doc, .{ .add_annotation = .{ .annotation = ann } });
                }
                insp_y += 30.0;

                // Add Arrow Annotation
                if (try ctx.button("insp_add_arrow_btn", "+ Add Arrow (8 Directions)", .{ .x = insp_x + 12.0, .y = insp_y, .w = right_col_w - 24.0, .h = 24.0 })) {
                    const ann = core.project.Annotation{
                        .id = try self.allocator.dupe(u8, "ann_arrow"),
                        .clipId = try self.allocator.dupe(u8, "clip-1"),
                        .startSec = self.current_time_sec,
                        .endSec = self.current_time_sec + 2.0,
                        .content = try self.allocator.dupe(u8, "->"),
                    };
                    try self.stack.execute(&self.doc, .{ .add_annotation = .{ .annotation = ann } });
                }
                insp_y += 30.0;

                // Add Image Overlay
                if (try ctx.button("insp_add_img_btn", "+ Add Image / Asset Overlay", .{ .x = insp_x + 12.0, .y = insp_y, .w = right_col_w - 24.0, .h = 24.0 })) {}
                insp_y += 30.0;

                // Privacy Blur Regions
                try ctx.label("insp_lbl_pblur", "Privacy Blur Regions:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 180.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const blur_w: f32 = (right_col_w - 32.0) / 2.0;
                if (try ctx.button("insp_blur_gauss", "+ Gaussian Blur", .{ .x = insp_x + 12.0, .y = insp_y, .w = blur_w, .h = 22.0 })) {}
                if (try ctx.button("insp_blur_mosaic", "+ Mosaic Pixel", .{ .x = insp_x + 16.0 + blur_w, .y = insp_y, .w = blur_w, .h = 22.0 })) {}
                insp_y += 26.0;

                // Freehand Polygon Blur
                if (try ctx.button("insp_blur_poly", "+ Freehand Polygon Blur", .{ .x = insp_x + 12.0, .y = insp_y, .w = right_col_w - 24.0, .h = 22.0 })) {}
                insp_y += 28.0;

                // Off-Menu Effects & Flyouts
                try ctx.label("insp_lbl_offmenu", "Off-Menu Effects & Flyouts:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const offm_w: f32 = (right_col_w - 32.0) / 2.0;
                if (try ctx.button("insp_offm_left", "Flyout Left", .{ .x = insp_x + 12.0, .y = insp_y, .w = offm_w, .h = 22.0 })) {}
                if (try ctx.button("insp_offm_right", "Flyout Right", .{ .x = insp_x + 16.0 + offm_w, .y = insp_y, .w = offm_w, .h = 22.0 })) {}
                insp_y += 28.0;
            },
            .ai_assistant => {
                try ctx.label("insp_body_title_ai", "AI CONFIGURATION", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;

                // 7 AI Provider Families
                try ctx.label("insp_lbl_provs", "Provider Family (7 Families):", .{ .x = insp_x + 12.0, .y = insp_y, .w = 220.0, .h = 14.0 }, ctx.theme.text_secondary);
                insp_y += 18.0;
                const prov_w: f32 = (right_col_w - 32.0) / 2.0;
                if (try ctx.button("insp_p_claude", "Claude 3.7", .{ .x = insp_x + 12.0, .y = insp_y, .w = prov_w, .h = 20.0 })) {}
                if (try ctx.button("insp_p_gpt", "OpenAI GPT-4o", .{ .x = insp_x + 16.0 + prov_w, .y = insp_y, .w = prov_w, .h = 20.0 })) {}
                insp_y += 24.0;
                if (try ctx.button("insp_p_gemini", "Gemini 2.5", .{ .x = insp_x + 12.0, .y = insp_y, .w = prov_w, .h = 20.0 })) {}
                if (try ctx.button("insp_p_mistral", "Mistral Large", .{ .x = insp_x + 16.0 + prov_w, .y = insp_y, .w = prov_w, .h = 20.0 })) {}
                insp_y += 24.0;
                if (try ctx.button("insp_p_openr", "OpenRouter", .{ .x = insp_x + 12.0, .y = insp_y, .w = prov_w, .h = 20.0 })) {}
                if (try ctx.button("insp_p_ollama", "Local/Ollama", .{ .x = insp_x + 16.0 + prov_w, .y = insp_y, .w = prov_w, .h = 20.0 })) {}
                insp_y += 28.0;

                // API Key field indicator
                try ctx.card("insp_ai_keycard", .{ .x = insp_x + 12.0, .y = insp_y, .w = right_col_w - 24.0, .h = 28.0 }, ctx.theme.bg_card);
                try ctx.label("insp_ai_key_txt", "API Key: ••••••••••••", .{ .x = insp_x + 18.0, .y = insp_y + 6.0, .w = right_col_w - 36.0, .h = 16.0 }, ctx.theme.accent_green);
                insp_y += 34.0;

                // Apply Edits button
                if (try ctx.button("insp_ai_apply_btn", "Apply AI Edits", .{ .x = insp_x + 12.0, .y = insp_y, .w = right_col_w - 24.0, .h = 26.0 })) {
                    // Executes AI zoom/trim tool calls into undoable CommandStack
                    const zr = core.project.ZoomRange{
                        .id = try self.allocator.dupe(u8, "ai_zoom"),
                        .clipId = try self.allocator.dupe(u8, "clip-1"),
                        .startSec = self.current_time_sec,
                        .endSec = self.current_time_sec + 2.0,
                        .depth = 2,
                        .focus = .{ .cx = 0.5, .cy = 0.5 },
                    };
                    try self.stack.execute(&self.doc, .{ .add_zoom = .{ .zoom = zr } });
                }
            },
        }

        // 5. Bottom Area: Multi-Track Timeline or Transcript View
        const bot_y = top_bar_h + stage_h;

        // Bottom area tabs: Timeline vs Transcript
        const bot_tab_w: f32 = 100.0;
        const bot_tab_h: f32 = 22.0;
        if (try ctx.button("bot_tab_tl", if (self.active_tab_bottom == .timeline) "[Timeline]" else "Timeline", .{ .x = 12.0, .y = bot_y + 2.0, .w = bot_tab_w, .h = bot_tab_h })) {
            self.active_tab_bottom = .timeline;
        }
        if (try ctx.button("bot_tab_tr", if (self.active_tab_bottom == .transcript) "[Transcript]" else "Transcript", .{ .x = 12.0 + bot_tab_w + 6.0, .y = bot_y + 2.0, .w = bot_tab_w, .h = bot_tab_h })) {
            self.active_tab_bottom = .transcript;
        }

        const view_rect = dvui.Rect{ .x = 0, .y = bot_y + bot_tab_h + 4.0, .w = sw, .h = timeline_h - bot_tab_h - 4.0 };
        if (self.active_tab_bottom == .timeline) {
            try self.timeline.render(ctx, &self.doc, &self.current_time_sec, view_rect);
        } else {
            try self.transcript.render(ctx, &self.doc, &self.stack, &self.current_time_sec, view_rect);
        }

        // 6. Modals (rendered on top of everything if open)
        try self.modal_export.render(ctx);
        try self.modal_settings.render(ctx);
    }
};
