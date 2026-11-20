const std = @import("std");
const project = @import("project.zig");

pub const CommandType = enum {
    add_trim,
    remove_trim,
    add_zoom,
    remove_zoom,
    add_speed_range,
    remove_speed_range,
    add_annotation,
    remove_annotation,
    set_aspect_ratio,
    set_shadow_intensity,
    set_padding,
    set_wallpaper,
    set_cursor_theme,
    set_webcam_layout,
};

pub const Command = union(CommandType) {
    add_trim: struct {
        range: project.TrimRange,
    },
    remove_trim: struct {
        range: project.TrimRange,
    },
    add_zoom: struct {
        zoom: project.ZoomRange,
    },
    remove_zoom: struct {
        zoom: project.ZoomRange,
    },
    add_speed_range: struct {
        range: project.SpeedRange,
    },
    remove_speed_range: struct {
        range: project.SpeedRange,
    },
    add_annotation: struct {
        annotation: project.Annotation,
    },
    remove_annotation: struct {
        annotation: project.Annotation,
    },
    set_aspect_ratio: struct {
        old_val: []const u8,
        new_val: []const u8,
    },
    set_shadow_intensity: struct {
        old_val: f32,
        new_val: f32,
    },
    set_padding: struct {
        old_val: f32,
        new_val: f32,
    },
    set_wallpaper: struct {
        old_val: []const u8,
        new_val: []const u8,
    },
    set_cursor_theme: struct {
        old_val: []const u8,
        new_val: []const u8,
    },
    set_webcam_layout: struct {
        old_val: []const u8,
        new_val: []const u8,
    },
};

pub const CommandStack = struct {
    allocator: std.mem.Allocator,
    undo_list: std.ArrayList(Command),
    redo_list: std.ArrayList(Command),

    pub fn init(allocator: std.mem.Allocator) CommandStack {
        return .{
            .allocator = allocator,
            .undo_list = .empty,
            .redo_list = .empty,
        };
    }

    pub fn deinit(self: *CommandStack) void {
        self.undo_list.deinit(self.allocator);
        self.redo_list.deinit(self.allocator);
    }

    pub fn can_undo(self: *const CommandStack) bool {
        return self.undo_list.items.len > 0;
    }

    pub fn can_redo(self: *const CommandStack) bool {
        return self.redo_list.items.len > 0;
    }

    pub fn execute(self: *CommandStack, doc: *project.AxcutDocument, cmd: Command) !void {
        try apply_command(self.allocator, doc, cmd, false);
        try self.undo_list.append(self.allocator, cmd);
        self.redo_list.clearRetainingCapacity();
    }

    pub fn undo(self: *CommandStack, doc: *project.AxcutDocument) !bool {
        if (!self.can_undo()) return false;
        const cmd = self.undo_list.pop() orelse return false;
        try apply_command(self.allocator, doc, cmd, true);
        try self.redo_list.append(self.allocator, cmd);
        return true;
    }

    pub fn redo(self: *CommandStack, doc: *project.AxcutDocument) !bool {
        if (!self.can_redo()) return false;
        const cmd = self.redo_list.pop() orelse return false;
        try apply_command(self.allocator, doc, cmd, false);
        try self.undo_list.append(self.allocator, cmd);
        return true;
    }
};

fn appendZoom(allocator: std.mem.Allocator, doc: *project.AxcutDocument, z: project.ZoomRange) !void {
    const old_slice = doc.zoomRanges;
    const new_slice = try allocator.alloc(project.ZoomRange, old_slice.len + 1);
    if (old_slice.len > 0) {
        @memcpy(new_slice[0..old_slice.len], old_slice);
        allocator.free(old_slice);
    }
    new_slice[old_slice.len] = z;
    doc.zoomRanges = new_slice;
}

fn removeZoom(allocator: std.mem.Allocator, doc: *project.AxcutDocument, id: []const u8) !void {
    var found_idx: ?usize = null;
    for (doc.zoomRanges, 0..) |item, i| {
        if (std.mem.eql(u8, item.id, id)) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse return;
    const old_slice = doc.zoomRanges;
    const new_slice = try allocator.alloc(project.ZoomRange, old_slice.len - 1);
    var target: usize = 0;
    for (old_slice, 0..) |item, i| {
        if (i == idx) continue;
        new_slice[target] = item;
        target += 1;
    }
    allocator.free(old_slice);
    doc.zoomRanges = new_slice;
}

fn appendTrim(allocator: std.mem.Allocator, doc: *project.AxcutDocument, t: project.TrimRange) !void {
    const old_slice = doc.timeline.trimRanges;
    const new_slice = try allocator.alloc(project.TrimRange, old_slice.len + 1);
    if (old_slice.len > 0) {
        @memcpy(new_slice[0..old_slice.len], old_slice);
        allocator.free(old_slice);
    }
    new_slice[old_slice.len] = t;
    doc.timeline.trimRanges = new_slice;
}

fn removeTrim(allocator: std.mem.Allocator, doc: *project.AxcutDocument, id: []const u8) !void {
    var found_idx: ?usize = null;
    for (doc.timeline.trimRanges, 0..) |item, i| {
        if (std.mem.eql(u8, item.id, id)) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse return;
    const old_slice = doc.timeline.trimRanges;
    const new_slice = try allocator.alloc(project.TrimRange, old_slice.len - 1);
    var target: usize = 0;
    for (old_slice, 0..) |item, i| {
        if (i == idx) continue;
        new_slice[target] = item;
        target += 1;
    }
    allocator.free(old_slice);
    doc.timeline.trimRanges = new_slice;
}

fn appendSpeed(allocator: std.mem.Allocator, doc: *project.AxcutDocument, s: project.SpeedRange) !void {
    const old_slice = doc.timeline.speedRanges;
    const new_slice = try allocator.alloc(project.SpeedRange, old_slice.len + 1);
    if (old_slice.len > 0) {
        @memcpy(new_slice[0..old_slice.len], old_slice);
        allocator.free(old_slice);
    }
    new_slice[old_slice.len] = s;
    doc.timeline.speedRanges = new_slice;
}

fn removeSpeed(allocator: std.mem.Allocator, doc: *project.AxcutDocument, id: []const u8) !void {
    var found_idx: ?usize = null;
    for (doc.timeline.speedRanges, 0..) |item, i| {
        if (std.mem.eql(u8, item.id, id)) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse return;
    const old_slice = doc.timeline.speedRanges;
    const new_slice = try allocator.alloc(project.SpeedRange, old_slice.len - 1);
    var target: usize = 0;
    for (old_slice, 0..) |item, i| {
        if (i == idx) continue;
        new_slice[target] = item;
        target += 1;
    }
    allocator.free(old_slice);
    doc.timeline.speedRanges = new_slice;
}

fn appendAnnotation(allocator: std.mem.Allocator, doc: *project.AxcutDocument, a: project.Annotation) !void {
    const old_slice = doc.annotations;
    const new_slice = try allocator.alloc(project.Annotation, old_slice.len + 1);
    if (old_slice.len > 0) {
        @memcpy(new_slice[0..old_slice.len], old_slice);
        allocator.free(old_slice);
    }
    new_slice[old_slice.len] = a;
    doc.annotations = new_slice;
}

fn removeAnnotation(allocator: std.mem.Allocator, doc: *project.AxcutDocument, id: []const u8) !void {
    var found_idx: ?usize = null;
    for (doc.annotations, 0..) |item, i| {
        if (std.mem.eql(u8, item.id, id)) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse return;
    const old_slice = doc.annotations;
    const new_slice = try allocator.alloc(project.Annotation, old_slice.len - 1);
    var target: usize = 0;
    for (old_slice, 0..) |item, i| {
        if (i == idx) continue;
        new_slice[target] = item;
        target += 1;
    }
    allocator.free(old_slice);
    doc.annotations = new_slice;
}

fn apply_command(allocator: std.mem.Allocator, doc: *project.AxcutDocument, cmd: Command, is_undo: bool) !void {
    switch (cmd) {
        .set_aspect_ratio => |val| {
            doc.legacyEditor.aspectRatio = if (is_undo) val.old_val else val.new_val;
        },
        .set_shadow_intensity => |val| {
            doc.legacyEditor.shadowIntensity = if (is_undo) val.old_val else val.new_val;
        },
        .set_padding => |val| {
            doc.legacyEditor.padding = if (is_undo) val.old_val else val.new_val;
        },
        .set_wallpaper => |val| {
            doc.legacyEditor.wallpaper = if (is_undo) val.old_val else val.new_val;
        },
        .set_cursor_theme => |val| {
            doc.legacyEditor.cursorTheme = if (is_undo) val.old_val else val.new_val;
        },
        .set_webcam_layout => |val| {
            doc.legacyEditor.webcamLayoutPreset = if (is_undo) val.old_val else val.new_val;
        },
        .add_zoom => |val| {
            if (is_undo) {
                try removeZoom(allocator, doc, val.zoom.id);
            } else {
                try appendZoom(allocator, doc, val.zoom);
            }
        },
        .remove_zoom => |val| {
            if (is_undo) {
                try appendZoom(allocator, doc, val.zoom);
            } else {
                try removeZoom(allocator, doc, val.zoom.id);
            }
        },
        .add_trim => |val| {
            if (is_undo) {
                try removeTrim(allocator, doc, val.range.id);
            } else {
                try appendTrim(allocator, doc, val.range);
            }
        },
        .remove_trim => |val| {
            if (is_undo) {
                try appendTrim(allocator, doc, val.range);
            } else {
                try removeTrim(allocator, doc, val.range.id);
            }
        },
        .add_speed_range => |val| {
            if (is_undo) {
                try removeSpeed(allocator, doc, val.range.id);
            } else {
                try appendSpeed(allocator, doc, val.range);
            }
        },
        .remove_speed_range => |val| {
            if (is_undo) {
                try appendSpeed(allocator, doc, val.range);
            } else {
                try removeSpeed(allocator, doc, val.range.id);
            }
        },
        .add_annotation => |val| {
            if (is_undo) {
                try removeAnnotation(allocator, doc, val.annotation.id);
            } else {
                try appendAnnotation(allocator, doc, val.annotation);
            }
        },
        .remove_annotation => |val| {
            if (is_undo) {
                try appendAnnotation(allocator, doc, val.annotation);
            } else {
                try removeAnnotation(allocator, doc, val.annotation.id);
            }
        },
    }
}

pub fn compute_document_hash(doc: *const project.AxcutDocument) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(doc.legacyEditor.aspectRatio);
    hasher.update(std.mem.asBytes(&doc.legacyEditor.shadowIntensity));
    hasher.update(std.mem.asBytes(&doc.legacyEditor.padding));
    hasher.update(doc.legacyEditor.wallpaper);
    hasher.update(doc.legacyEditor.cursorTheme);
    hasher.update(doc.legacyEditor.webcamLayoutPreset);

    hasher.update(std.mem.asBytes(&doc.zoomRanges.len));
    for (doc.zoomRanges) |z| {
        hasher.update(z.id);
        hasher.update(std.mem.asBytes(&z.startSec));
        hasher.update(std.mem.asBytes(&z.endSec));
        hasher.update(std.mem.asBytes(&z.focus.cx));
        hasher.update(std.mem.asBytes(&z.focus.cy));
    }

    hasher.update(std.mem.asBytes(&doc.timeline.trimRanges.len));
    for (doc.timeline.trimRanges) |t| {
        hasher.update(t.id);
        hasher.update(std.mem.asBytes(&t.startSec));
        hasher.update(std.mem.asBytes(&t.endSec));
    }

    hasher.update(std.mem.asBytes(&doc.timeline.speedRanges.len));
    for (doc.timeline.speedRanges) |s| {
        hasher.update(s.id);
        hasher.update(std.mem.asBytes(&s.startSec));
        hasher.update(std.mem.asBytes(&s.endSec));
        hasher.update(std.mem.asBytes(&s.speed));
    }

    hasher.update(std.mem.asBytes(&doc.annotations.len));
    for (doc.annotations) |a| {
        hasher.update(a.id);
        hasher.update(a.content);
        hasher.update(std.mem.asBytes(&a.startSec));
        hasher.update(std.mem.asBytes(&a.endSec));
    }

    return hasher.final();
}

test "command stack undo redo state-hash invariance" {
    var doc = try project.create_empty_document(std.testing.allocator, "Invariance Project");
    defer doc.deinit(std.testing.allocator);

    var stack = CommandStack.init(std.testing.allocator);
    defer stack.deinit();

    const initial_hash = compute_document_hash(&doc);

    // Run 200 operations
    var prng = std.Random.DefaultPrng.init(12345);
    const rand = prng.random();

    var op: usize = 0;
    while (op < 200) : (op += 1) {
        const choice = rand.uintLessThan(u8, 7);
        switch (choice) {
            0 => {
                const old_ar = doc.legacyEditor.aspectRatio;
                const new_ar = if (rand.boolean()) "16:9" else "9:16";
                try stack.execute(&doc, .{ .set_aspect_ratio = .{ .old_val = old_ar, .new_val = new_ar } });
            },
            1 => {
                const old_val = doc.legacyEditor.shadowIntensity;
                const new_val = rand.float(f32);
                try stack.execute(&doc, .{ .set_shadow_intensity = .{ .old_val = old_val, .new_val = new_val } });
            },
            2 => {
                const old_val = doc.legacyEditor.padding;
                const new_val = rand.float(f32) * 100.0;
                try stack.execute(&doc, .{ .set_padding = .{ .old_val = old_val, .new_val = new_val } });
            },
            3 => {
                const z = project.ZoomRange{
                    .id = "z-test-1",
                    .clipId = "clip-1",
                    .startSec = 1.0,
                    .endSec = 3.0,
                    .depth = 2,
                    .focus = .{ .cx = 0.5, .cy = 0.5 },
                };
                if (doc.zoomRanges.len == 0) {
                    try stack.execute(&doc, .{ .add_zoom = .{ .zoom = z } });
                } else {
                    try stack.execute(&doc, .{ .remove_zoom = .{ .zoom = doc.zoomRanges[0] } });
                }
            },
            4 => {
                const t = project.TrimRange{
                    .id = "t-test-1",
                    .clipId = "clip-1",
                    .startSec = 4.0,
                    .endSec = 5.0,
                };
                if (doc.timeline.trimRanges.len == 0) {
                    try stack.execute(&doc, .{ .add_trim = .{ .range = t } });
                } else {
                    try stack.execute(&doc, .{ .remove_trim = .{ .range = doc.timeline.trimRanges[0] } });
                }
            },
            5 => {
                const s = project.SpeedRange{
                    .id = "s-test-1",
                    .clipId = "clip-1",
                    .startSec = 6.0,
                    .endSec = 8.0,
                    .speed = 2.0,
                };
                if (doc.timeline.speedRanges.len == 0) {
                    try stack.execute(&doc, .{ .add_speed_range = .{ .range = s } });
                } else {
                    try stack.execute(&doc, .{ .remove_speed_range = .{ .range = doc.timeline.speedRanges[0] } });
                }
            },
            6 => {
                const a = project.Annotation{
                    .id = "a-test-1",
                    .clipId = "clip-1",
                    .startSec = 0.5,
                    .endSec = 2.5,
                    .content = "Annotation text",
                };
                if (doc.annotations.len == 0) {
                    try stack.execute(&doc, .{ .add_annotation = .{ .annotation = a } });
                } else {
                    try stack.execute(&doc, .{ .remove_annotation = .{ .annotation = doc.annotations[0] } });
                }
            },
            else => unreachable,
        }
    }

    try std.testing.expect(compute_document_hash(&doc) != initial_hash);

    // Undo all 200 operations
    while (try stack.undo(&doc)) {}

    // Hash must match initial state exactly
    const undone_hash = compute_document_hash(&doc);
    try std.testing.expectEqual(initial_hash, undone_hash);

    // Redo all operations
    while (try stack.redo(&doc)) {}

    // Undo all operations once more
    while (try stack.undo(&doc)) {}
    try std.testing.expectEqual(initial_hash, compute_document_hash(&doc));
}
