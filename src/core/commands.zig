const std = @import("std");
const project = @import("project.zig");

pub const CommandType = enum {
    add_trim,
    remove_trim,
    add_zoom,
    remove_zoom,
    set_aspect_ratio,
    set_shadow_intensity,
    set_padding,
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
        try apply_command(doc, cmd, false);
        try self.undo_list.append(self.allocator, cmd);
        self.redo_list.clearRetainingCapacity();
    }

    pub fn undo(self: *CommandStack, doc: *project.AxcutDocument) !bool {
        if (!self.can_undo()) return false;
        const cmd = self.undo_list.pop() orelse return false;
        try apply_command(doc, cmd, true);
        try self.redo_list.append(self.allocator, cmd);
        return true;
    }

    pub fn redo(self: *CommandStack, doc: *project.AxcutDocument) !bool {
        if (!self.can_redo()) return false;
        const cmd = self.redo_list.pop() orelse return false;
        try apply_command(doc, cmd, false);
        try self.undo_list.append(self.allocator, cmd);
        return true;
    }
};

fn apply_command(doc: *project.AxcutDocument, cmd: Command, is_undo: bool) !void {
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
        .add_trim, .remove_trim => {
            // Trim manipulation
        },
        .add_zoom, .remove_zoom => {
            // Zoom manipulation
        },
    }
}

pub fn compute_document_hash(doc: *const project.AxcutDocument) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(doc.legacyEditor.aspectRatio);
    hasher.update(std.mem.asBytes(&doc.legacyEditor.shadowIntensity));
    hasher.update(std.mem.asBytes(&doc.legacyEditor.padding));
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
        const choice = rand.uintLessThan(u8, 3);
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
