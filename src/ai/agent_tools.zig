const std = @import("std");
const core = @import("core");
const project = core.project;
const commands = core.commands;
const client = @import("client.zig");

var next_tool_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub const CompactTranscript = struct {
    text: []u8,
    word_count: usize,
    silence_count: usize,
};

pub fn buildCompactTranscript(allocator: std.mem.Allocator, doc: *const project.AxcutDocument) !CompactTranscript {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var total_words: usize = 0;
    var total_silences: usize = 0;

    for (doc.transcripts) |t| {
        var header_buf: [128]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "[language: {s}]\n", .{t.language});
        try out.appendSlice(allocator, header);

        var word_idx: usize = 0;
        var silence_idx: usize = 0;

        while (word_idx < t.words.len or silence_idx < t.silences.len) {
            const next_is_silence = if (silence_idx >= t.silences.len)
                false
            else if (word_idx >= t.words.len)
                true
            else
                t.silences[silence_idx].startSec < t.words[word_idx].startSec;

            if (next_is_silence) {
                const s = t.silences[silence_idx];
                var s_buf: [64]u8 = undefined;
                const s_str = try std.fmt.bufPrint(&s_buf, " [silence {d:.1}s] ", .{s.durationSec});
                try out.appendSlice(allocator, s_str);
                silence_idx += 1;
                total_silences += 1;
            } else {
                const w = t.words[word_idx];
                try out.appendSlice(allocator, w.word);
                try out.append(allocator, ' ');
                word_idx += 1;
                total_words += 1;
            }
        }
        try out.append(allocator, '\n');
    }

    return CompactTranscript{
        .text = try out.toOwnedSlice(allocator),
        .word_count = total_words,
        .silence_count = total_silences,
    };
}

pub fn buildTimelineContext(allocator: std.mem.Allocator, doc: *const project.AxcutDocument) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    const dur = if (doc.assets.len > 0) doc.assets[0].durationSec else 0.0;
    var buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "Project: \"{s}\"\nDuration: {d:.2}s\nAspect: {s}\n", .{
        doc.project.title,
        dur,
        doc.legacyEditor.aspectRatio,
    });
    try out.appendSlice(allocator, header);

    const z_hdr = try std.fmt.bufPrint(&buf, "Zooms ({d}):\n", .{doc.zoomRanges.len});
    try out.appendSlice(allocator, z_hdr);
    for (doc.zoomRanges) |z| {
        const line = try std.fmt.bufPrint(&buf, "  - [{d:.2}s - {d:.2}s] focus=({d:.2},{d:.2}) depth={d}\n", .{
            z.startSec,
            z.endSec,
            z.focus.cx,
            z.focus.cy,
            z.depth,
        });
        try out.appendSlice(allocator, line);
    }

    const t_hdr = try std.fmt.bufPrint(&buf, "Trims/Cuts ({d}):\n", .{doc.timeline.trimRanges.len});
    try out.appendSlice(allocator, t_hdr);
    for (doc.timeline.trimRanges) |tr| {
        const line = try std.fmt.bufPrint(&buf, "  - [{d:.2}s - {d:.2}s]\n", .{ tr.startSec, tr.endSec });
        try out.appendSlice(allocator, line);
    }

    const s_hdr = try std.fmt.bufPrint(&buf, "Speed Ramps ({d}):\n", .{doc.timeline.speedRanges.len});
    try out.appendSlice(allocator, s_hdr);
    for (doc.timeline.speedRanges) |sr| {
        const line = try std.fmt.bufPrint(&buf, "  - [{d:.2}s - {d:.2}s] {d:.1}x\n", .{ sr.startSec, sr.endSec, sr.speed });
        try out.appendSlice(allocator, line);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn getEditingTools() []const client.ToolDefinition {
    return &[_]client.ToolDefinition{
        .{
            .name = "add_zoom",
            .description = "Add a smooth camera zoom to focus on a screen region",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"startSec\":{\"type\":\"number\"},\"endSec\":{\"type\":\"number\"},\"focusX\":{\"type\":\"number\"},\"focusY\":{\"type\":\"number\"},\"depth\":{\"type\":\"integer\"}},\"required\":[\"startSec\",\"endSec\"]}",
        },
        .{
            .name = "remove_zoom",
            .description = "Remove a zoom by its id",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
        },
        .{
            .name = "add_cut",
            .description = "Cut or excise an unwanted segment (e.g. silence or mistake)",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"startSec\":{\"type\":\"number\"},\"endSec\":{\"type\":\"number\"}},\"required\":[\"startSec\",\"endSec\"]}",
        },
        .{
            .name = "add_speed_ramp",
            .description = "Speed up a timeline segment (e.g. 2.0x for typing)",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"startSec\":{\"type\":\"number\"},\"endSec\":{\"type\":\"number\"},\"speed\":{\"type\":\"number\"}},\"required\":[\"startSec\",\"endSec\",\"speed\"]}",
        },
        .{
            .name = "add_annotation",
            .description = "Add a text banner annotation overlay",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"startSec\":{\"type\":\"number\"},\"endSec\":{\"type\":\"number\"},\"text\":{\"type\":\"string\"}},\"required\":[\"startSec\",\"endSec\",\"text\"]}",
        },
        .{
            .name = "set_style",
            .description = "Set overall styling (aspect ratio, wallpaper, padding, shadow)",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"aspectRatio\":{\"type\":\"string\"},\"wallpaper\":{\"type\":\"string\"},\"padding\":{\"type\":\"number\"},\"shadow\":{\"type\":\"number\"}}}",
        },
    };
}

pub fn executeToolCall(
    allocator: std.mem.Allocator,
    stack: *commands.CommandStack,
    doc: *project.AxcutDocument,
    tool_name: []const u8,
    args_json: []const u8,
) ![]const u8 {
    const dur = if (doc.assets.len > 0) doc.assets[0].durationSec else 3600.0;

    if (std.mem.eql(u8, tool_name, "add_zoom")) {
        var start: f64 = 0.0;
        var end: f64 = 2.0;
        var cx: f32 = 0.5;
        var cy: f32 = 0.5;
        var depth: u8 = 2;

        if (std.mem.indexOf(u8, args_json, "\"startSec\":")) |p| {
            start = parseJsonFloat(args_json[p + 11 ..]) orelse 0.0;
        }
        if (std.mem.indexOf(u8, args_json, "\"endSec\":")) |p| {
            end = parseJsonFloat(args_json[p + 9 ..]) orelse 2.0;
        }
        if (std.mem.indexOf(u8, args_json, "\"focusX\":")) |p| {
            cx = @floatCast(parseJsonFloat(args_json[p + 9 ..]) orelse 0.5);
        }
        if (std.mem.indexOf(u8, args_json, "\"focusY\":")) |p| {
            cy = @floatCast(parseJsonFloat(args_json[p + 9 ..]) orelse 0.5);
        }
        if (std.mem.indexOf(u8, args_json, "\"depth\":")) |p| {
            const d = parseJsonFloat(args_json[p + 8 ..]) orelse 2.0;
            depth = @intCast(@min(5, @max(1, @as(u32, @intFromFloat(d)))));
        }

        if (start < 0.0) start = 0.0;
        if (end > dur and dur > 0.0) end = dur;
        if (end <= start) end = start + 1.0;

        const z = project.ZoomRange{
            .id = "ai_zoom",
            .clipId = if (doc.timeline.clips.len > 0) doc.timeline.clips[0].id else "clip-1",
            .startSec = start,
            .endSec = end,
            .depth = depth,
            .focus = .{ .cx = cx, .cy = cy },
        };
        try stack.execute(doc, .{ .add_zoom = .{ .zoom = z } });
        return try std.fmt.allocPrint(allocator, "Zoom added: {s} from {d:.2}s to {d:.2}s", .{ z.id, start, end });
    } else if (std.mem.eql(u8, tool_name, "add_cut")) {
        var start: f64 = 0.0;
        var end: f64 = 1.0;
        if (std.mem.indexOf(u8, args_json, "\"startSec\":")) |p| {
            start = parseJsonFloat(args_json[p + 11 ..]) orelse 0.0;
        }
        if (std.mem.indexOf(u8, args_json, "\"endSec\":")) |p| {
            end = parseJsonFloat(args_json[p + 9 ..]) orelse 1.0;
        }
        if (start < 0.0) start = 0.0;
        if (end > dur and dur > 0.0) end = dur;
        if (end <= start) return error.InvalidCutRange;

        const tr = project.TrimRange{
            .id = "ai_cut",
            .clipId = if (doc.timeline.clips.len > 0) doc.timeline.clips[0].id else "clip-1",
            .startSec = start,
            .endSec = end,
        };
        try stack.execute(doc, .{ .add_trim = .{ .range = tr } });
        return try std.fmt.allocPrint(allocator, "Cut added: {s} from {d:.2}s to {d:.2}s", .{ tr.id, start, end });
    } else if (std.mem.eql(u8, tool_name, "add_speed_ramp")) {
        var start: f64 = 0.0;
        var end: f64 = 2.0;
        var speed: f32 = 2.0;
        if (std.mem.indexOf(u8, args_json, "\"startSec\":")) |p| {
            start = parseJsonFloat(args_json[p + 11 ..]) orelse 0.0;
        }
        if (std.mem.indexOf(u8, args_json, "\"endSec\":")) |p| {
            end = parseJsonFloat(args_json[p + 9 ..]) orelse 2.0;
        }
        if (std.mem.indexOf(u8, args_json, "\"speed\":")) |p| {
            speed = @floatCast(parseJsonFloat(args_json[p + 8 ..]) orelse 2.0);
        }
        if (start < 0.0) start = 0.0;
        if (end > dur and dur > 0.0) end = dur;
        if (end <= start) end = start + 1.0;

        const sr = project.SpeedRange{
            .id = "ai_speed",
            .clipId = if (doc.timeline.clips.len > 0) doc.timeline.clips[0].id else "clip-1",
            .startSec = start,
            .endSec = end,
            .speed = speed,
        };
        try stack.execute(doc, .{ .add_speed_range = .{ .range = sr } });
        return try std.fmt.allocPrint(allocator, "Speed ramp added: {s} ({d:.1}x)", .{ sr.id, speed });
    } else if (std.mem.eql(u8, tool_name, "set_style")) {
        if (std.mem.indexOf(u8, args_json, "\"aspectRatio\":")) |p| {
            if (std.mem.indexOf(u8, args_json[p + 14 ..], "\"")) |q1| {
                const s = p + 14 + q1 + 1;
                if (std.mem.indexOf(u8, args_json[s..], "\"")) |q2| {
                    const raw_ar = args_json[s .. s + q2];
                    const new_ar = if (std.mem.eql(u8, raw_ar, "9:16"))
                        "9:16"
                    else if (std.mem.eql(u8, raw_ar, "1:1"))
                        "1:1"
                    else if (std.mem.eql(u8, raw_ar, "4:3"))
                        "4:3"
                    else
                        "16:9";
                    try stack.execute(doc, .{ .set_aspect_ratio = .{ .old_val = doc.legacyEditor.aspectRatio, .new_val = new_ar } });
                }
            }
        }
        if (std.mem.indexOf(u8, args_json, "\"shadow\":")) |p| {
            if (parseJsonFloat(args_json[p + 9 ..])) |val| {
                try stack.execute(doc, .{ .set_shadow_intensity = .{ .old_val = doc.legacyEditor.shadowIntensity, .new_val = @floatCast(val) } });
            }
        }
        if (std.mem.indexOf(u8, args_json, "\"padding\":")) |p| {
            if (parseJsonFloat(args_json[p + 10 ..])) |val| {
                try stack.execute(doc, .{ .set_padding = .{ .old_val = doc.legacyEditor.padding, .new_val = @floatCast(val) } });
            }
        }
        return try allocator.dupe(u8, "Style updated");
    }

    return try allocator.dupe(u8, "Unrecognized tool");
}

fn parseJsonFloat(slice: []const u8) ?f64 {
    var start: usize = 0;
    while (start < slice.len and (slice[start] == ' ' or slice[start] == ':')) : (start += 1) {}
    var end = start;
    while (end < slice.len and ((slice[end] >= '0' and slice[end] <= '9') or slice[end] == '.' or slice[end] == '-')) : (end += 1) {}
    if (end > start) {
        return std.fmt.parseFloat(f64, slice[start..end]) catch null;
    }
    return null;
}

pub fn translateSubtitles(
    allocator: std.mem.Allocator,
    ai: *client.AiClient,
    doc: *project.AxcutDocument,
    target_language: []const u8,
) !usize {
    if (doc.transcripts.len == 0) return 0;
    const t = &doc.transcripts[0];
    if (t.words.len == 0) return 0;

    // Build prompt for translation
    var text_builder: std.ArrayListUnmanaged(u8) = .empty;
    defer text_builder.deinit(allocator);

    for (t.words, 0..) |w, i| {
        if (i > 0) try text_builder.append(allocator, ' ');
        try text_builder.appendSlice(allocator, w.word);
    }

    const prompt = try std.fmt.allocPrint(allocator, "Translate the following subtitle text into {s}:\n\"{s}\"", .{
        target_language,
        text_builder.items,
    });
    defer allocator.free(prompt);

    const msgs = [_]client.Message{
        .{ .role = "system", .content = "You are an expert video subtitle translator. Output only the translated text." },
        .{ .role = "user", .content = prompt },
    };

    var resp = try ai.chat(&msgs, &.{});
    defer resp.deinit();

    // Update transcript language
    t.language = try allocator.dupe(u8, target_language);

    return t.words.len;
}
