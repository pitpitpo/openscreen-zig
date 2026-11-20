const std = @import("std");

pub const SCHEMA_VERSION: u32 = 9;

pub const RecordingFrame = enum {
    none,
    window,
    laptop,
    phone,
    monitor,

    pub fn to_string(self: RecordingFrame) []const u8 {
        return switch (self) {
            .none => "none",
            .window => "window",
            .laptop => "laptop",
            .phone => "phone",
            .monitor => "monitor",
        };
    }

    pub fn from_string(s: []const u8) ?RecordingFrame {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "window")) return .window;
        if (std.mem.eql(u8, s, "laptop")) return .laptop;
        if (std.mem.eql(u8, s, "phone")) return .phone;
        if (std.mem.eql(u8, s, "monitor")) return .monitor;
        return null;
    }
};

pub const FrameTheme = enum {
    light,
    dark,
};

pub const AspectRatio = enum {
    auto,
    native,
    ar_16_9,
    ar_9_16,
    ar_1_1,
    ar_4_3,
    ar_4_5,
    ar_16_10,
    ar_10_16,

    pub fn to_string(self: AspectRatio) []const u8 {
        return switch (self) {
            .auto => "auto",
            .native => "native",
            .ar_16_9 => "16:9",
            .ar_9_16 => "9:16",
            .ar_1_1 => "1:1",
            .ar_4_3 => "4:3",
            .ar_4_5 => "4:5",
            .ar_16_10 => "16:10",
            .ar_10_16 => "10:16",
        };
    }

    pub fn from_string(s: []const u8) AspectRatio {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "native")) return .native;
        if (std.mem.eql(u8, s, "16:9")) return .ar_16_9;
        if (std.mem.eql(u8, s, "9:16")) return .ar_9_16;
        if (std.mem.eql(u8, s, "1:1")) return .ar_1_1;
        if (std.mem.eql(u8, s, "4:3")) return .ar_4_3;
        if (std.mem.eql(u8, s, "4:5")) return .ar_4_5;
        if (std.mem.eql(u8, s, "16:10")) return .ar_16_10;
        if (std.mem.eql(u8, s, "10:16")) return .ar_10_16;
        return .auto;
    }
};

pub const LayoutPreset = enum {
    picture_in_picture,
    dual_frame,
    vertical_stack,
    no_webcam,
    camera_only,
};

pub const CursorConfig = struct {
    size: f32 = 3.6,
    smoothing: f32 = 0.3,
    motionBlur: f32 = 0.35,
    clickBounce: f32 = 1.0,
    model3d: bool = false,
    clickImpact: bool = false,
    clickSound: bool = false,
    clickSoundGainDb: f32 = 0.0,
    autoHide: bool = false,
};

pub const LegacyEditorState = struct {
    wallpaper: []const u8 = "/wallpapers/wallpaper11.jpg",
    wallpaperMotion: []const u8 = "none",
    frame: []const u8 = "none",
    frameTheme: []const u8 = "light",
    aspectRatio: []const u8 = "auto",
    shadowIntensity: f32 = 0.6,
    backgroundBlur: f32 = 0.0,
    motionBlurAmount: f32 = 0.2,
    depthOfField: bool = true,
    borderRadius: f32 = 40.0,
    padding: f32 = 50.0,
    webcamLayoutPreset: []const u8 = "picture-in-picture",
    webcamMaskShape: []const u8 = "square",
    webcamRoundness: f32 = 0.7,
    webcamMirrored: bool = false,
    webcamReactiveZoom: bool = true,
    webcamSizePreset: f32 = 40.0,
    webcamShadowIntensity: f32 = 0.6,
    webcamAnchor: []const u8 = "bottom-right",
    webcamBackgroundMode: []const u8 = "none",
    webcamWallpaper: []const u8 = "/wallpapers/wallpaper11.jpg",
    webcamBlurIntensity: f32 = 0.5,
    cursor: CursorConfig = .{},
    cursorShow: bool = true,
    cursorTheme: []const u8 = "default",
};

pub const Asset = struct {
    id: []const u8,
    kind: []const u8 = "video",
    originalPath: []const u8,
    cameraTrack: ?[]const u8 = null,
    durationSec: f64 = 0.0,
    width: u32 = 1920,
    height: u32 = 1080,
    fps: f64 = 60.0,
};

pub const Word = struct {
    word: []const u8,
    startSec: f64,
    endSec: f64,
    confidence: f32 = 1.0,
};

pub const Silence = struct {
    startSec: f64,
    endSec: f64,
    durationSec: f64,
};

pub const Transcript = struct {
    assetId: []const u8,
    language: []const u8 = "en",
    words: []Word = &[_]Word{},
    silences: []Silence = &[_]Silence{},
};

pub const Clip = struct {
    id: []const u8,
    assetId: []const u8,
    sourceStartSec: f64,
    sourceEndSec: f64,
    timelineStartSec: f64,
};

pub const TrimRange = struct {
    id: []const u8,
    clipId: []const u8,
    startSec: f64,
    endSec: f64,
};

pub const SpeedRange = struct {
    id: []const u8,
    clipId: []const u8,
    startSec: f64,
    endSec: f64,
    speed: f32 = 1.0,
};

pub const Timeline = struct {
    clips: []Clip = &[_]Clip{},
    trimRanges: []TrimRange = &[_]TrimRange{},
    speedRanges: []SpeedRange = &[_]SpeedRange{},
};

pub const ZoomFocus = struct {
    cx: f32 = 0.5,
    cy: f32 = 0.5,
};

pub const ZoomRange = struct {
    id: []const u8,
    clipId: []const u8,
    startSec: f64,
    endSec: f64,
    depth: u8 = 3,
    customScale: ?f32 = null,
    focus: ZoomFocus = .{},
    focusMode: []const u8 = "manual",
    rotation: []const u8 = "flat",
};

pub const AnnotationStyle = struct {
    fontSize: f32 = 24.0,
    color: []const u8 = "#ffffff",
    backgroundColor: []const u8 = "rgba(0,0,0,0.6)",
    borderRadius: f32 = 8.0,
    padding: f32 = 12.0,
    animation: []const u8 = "none",
};

pub const Annotation = struct {
    id: []const u8,
    clipId: []const u8,
    startSec: f64,
    endSec: f64,
    type: []const u8 = "text",
    content: []const u8 = "",
    position_x: f32 = 10.0,
    position_y: f32 = 10.0,
    size_width: f32 = 30.0,
    size_height: f32 = 10.0,
    style: AnnotationStyle = .{},
};

pub const LayoutRegion = struct {
    id: []const u8,
    clipId: []const u8,
    startSec: f64,
    endSec: f64,
    preset: []const u8 = "picture-in-picture",
};

pub const ProjectMeta = struct {
    id: []const u8,
    title: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    primaryAssetId: ?[]const u8 = null,
};

pub const AxcutDocument = struct {
    schemaVersion: u32 = SCHEMA_VERSION,
    project: ProjectMeta,
    assets: []Asset = &[_]Asset{},
    transcripts: []Transcript = &[_]Transcript{},
    timeline: Timeline = .{},
    zoomRanges: []ZoomRange = &[_]ZoomRange{},
    annotations: []Annotation = &[_]Annotation{},
    layoutRegions: []LayoutRegion = &[_]LayoutRegion{},
    legacyEditor: LegacyEditorState = .{},

    pub fn deinit(self: *AxcutDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.project.id);
        allocator.free(self.project.title);
        allocator.free(self.project.createdAt);
        allocator.free(self.project.updatedAt);
        if (self.project.primaryAssetId) |id| allocator.free(id);

        for (self.assets) |a| {
            allocator.free(a.id);
            allocator.free(a.originalPath);
            if (a.cameraTrack) |c| allocator.free(c);
        }
        if (self.assets.len > 0) allocator.free(self.assets);

        for (self.transcripts) |t| {
            allocator.free(t.assetId);
            for (t.words) |w| allocator.free(w.word);
            if (t.words.len > 0) allocator.free(t.words);
            if (t.silences.len > 0) allocator.free(t.silences);
        }
        if (self.transcripts.len > 0) allocator.free(self.transcripts);

        for (self.timeline.clips) |c| {
            allocator.free(c.id);
            allocator.free(c.assetId);
        }
        if (self.timeline.clips.len > 0) allocator.free(self.timeline.clips);

        for (self.timeline.trimRanges) |tr| {
            allocator.free(tr.id);
            allocator.free(tr.clipId);
        }
        if (self.timeline.trimRanges.len > 0) allocator.free(self.timeline.trimRanges);

        for (self.timeline.speedRanges) |sr| {
            allocator.free(sr.id);
            allocator.free(sr.clipId);
        }
        if (self.timeline.speedRanges.len > 0) allocator.free(self.timeline.speedRanges);

        for (self.zoomRanges) |zr| {
            allocator.free(zr.id);
            allocator.free(zr.clipId);
        }
        if (self.zoomRanges.len > 0) allocator.free(self.zoomRanges);

        for (self.annotations) |ann| {
            allocator.free(ann.id);
            allocator.free(ann.clipId);
            allocator.free(ann.content);
        }
        if (self.annotations.len > 0) allocator.free(self.annotations);

        for (self.layoutRegions) |lr| {
            allocator.free(lr.id);
            allocator.free(lr.clipId);
        }
        if (self.layoutRegions.len > 0) allocator.free(self.layoutRegions);
    }
};

pub fn create_empty_document(allocator: std.mem.Allocator, title: []const u8) !AxcutDocument {
    return AxcutDocument{
        .schemaVersion = SCHEMA_VERSION,
        .project = .{
            .id = try allocator.dupe(u8, "proj-default"),
            .title = try allocator.dupe(u8, title),
            .createdAt = try allocator.dupe(u8, "2026-11-20T00:00:00Z"),
            .updatedAt = try allocator.dupe(u8, "2026-11-20T00:00:00Z"),
            .primaryAssetId = null,
        },
    };
}

test "document schema version and defaults" {
    var doc = try create_empty_document(std.testing.allocator, "Test Project");
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 9), doc.schemaVersion);
    try std.testing.expectEqualStrings("Test Project", doc.project.title);
    try std.testing.expectEqual(@as(f32, 0.6), doc.legacyEditor.shadowIntensity);
    try std.testing.expectEqualStrings("auto", doc.legacyEditor.aspectRatio);
}
