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
                insp_y += 24.0;
                try ctx.label("insp_lbl_pad", "Frame Padding:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 120.0, .h = 16.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.padding = try ctx.slider("insp_sld_pad", self.doc.legacyEditor.padding, 0.0, 100.0, .{ .x = insp_x + 12.0, .y = insp_y + 18.0, .w = right_col_w - 24.0, .h = 14.0 });
                insp_y += 38.0;

                try ctx.label("insp_lbl_rnd", "Corner Roundness:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 16.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.borderRadius = try ctx.slider("insp_sld_rnd", self.doc.legacyEditor.borderRadius, 0.0, 60.0, .{ .x = insp_x + 12.0, .y = insp_y + 18.0, .w = right_col_w - 24.0, .h = 14.0 });
                insp_y += 38.0;

                try ctx.label("insp_lbl_shd", "Shadow Intensity:", .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 16.0 }, ctx.theme.text_secondary);
                self.doc.legacyEditor.shadowIntensity = try ctx.slider("insp_sld_shd", self.doc.legacyEditor.shadowIntensity, 0.0, 1.0, .{ .x = insp_x + 12.0, .y = insp_y + 18.0, .w = right_col_w - 24.0, .h = 14.0 });
            },
            .camera_3d => {
                try ctx.label("insp_body_title_cam", "3D CAMERA ORIENTATION", .{ .x = insp_x + 12.0, .y = insp_y, .w = 220.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;
                if (try ctx.button("insp_cam_flat", "Flat 2D", .{ .x = insp_x + 12.0, .y = insp_y, .w = 80.0, .h = 24.0 })) {}
                if (try ctx.button("insp_cam_left", "Left Tilt", .{ .x = insp_x + 96.0, .y = insp_y, .w = 80.0, .h = 24.0 })) {}
                if (try ctx.button("insp_cam_right", "Right Tilt", .{ .x = insp_x + 180.0, .y = insp_y, .w = 80.0, .h = 24.0 })) {}
            },
            .cursor => {
                try ctx.label("insp_body_title_cur", "CURSOR TELEMETRY", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;
                self.doc.legacyEditor.cursorShow = try ctx.toggle("insp_tog_cur_show", "Show Cursor", self.doc.legacyEditor.cursorShow, .{ .x = insp_x + 12.0, .y = insp_y, .w = 140.0, .h = 26.0 });
            },
            .layouts => {
                try ctx.label("insp_body_title_lay", "WEBCAM & LAYOUTS", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;
                if (try ctx.button("insp_lay_pip", "Picture in Picture", .{ .x = insp_x + 12.0, .y = insp_y, .w = 160.0, .h = 24.0 })) {
                    self.doc.legacyEditor.webcamLayoutPreset = "picture-in-picture";
                }
            },
            .annotations_blur => {
                try ctx.label("insp_body_title_ann", "ANNOTATIONS & BLUR", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;
                if (try ctx.button("insp_add_text_btn", "+ Add Text Annotation", .{ .x = insp_x + 12.0, .y = insp_y, .w = 180.0, .h = 26.0 })) {
                    const ann = core.project.Annotation{
                        .id = try self.allocator.dupe(u8, "ann_ui"),
                        .clipId = try self.allocator.dupe(u8, "clip-1"),
                        .startSec = self.current_time_sec,
                        .endSec = self.current_time_sec + 2.0,
                        .content = try self.allocator.dupe(u8, "Note"),
                    };
                    try self.stack.execute(&self.doc, .{ .add_annotation = .{ .annotation = ann } });
                }
            },
            .ai_assistant => {
                try ctx.label("insp_body_title_ai", "AI CONFIGURATION", .{ .x = insp_x + 12.0, .y = insp_y, .w = 200.0, .h = 18.0 }, ctx.theme.text_primary);
                insp_y += 24.0;
                try ctx.label("insp_ai_key_lbl", "Provider: Anthropic / OpenAI", .{ .x = insp_x + 12.0, .y = insp_y, .w = 220.0, .h = 16.0 }, ctx.theme.text_secondary);
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
