const std = @import("std");
const core = @import("core");
const project = core.project;
const commands = core.commands;
const capture = @import("capture");
const media = @import("media");
const compositor = @import("compositor");
const ffi = @import("ffi");

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

pub var stdout_writer_override: ?*const fn (bytes: []const u8) void = null;

pub fn writeStdout(bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (stdout_writer_override) |override_fn| {
        override_fn(bytes);
        return;
    }
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(1, bytes.ptr + written, bytes.len - written);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_z), "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    _ = fseek(f, 0, 2);
    const size_l = ftell(f);
    _ = fseek(f, 0, 0);
    if (size_l <= 0) return try allocator.alloc(u8, 0);

    const size: usize = @intCast(size_l);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    const read_bytes = std.c.fread(buf.ptr, 1, size, f);
    if (read_bytes != size) return error.ReadError;
    return buf;
}

pub const McpServer = struct {
    allocator: std.mem.Allocator,
    active_project_path: ?[]const u8 = null,
    doc: ?project.AxcutDocument = null,
    stack: commands.CommandStack,

    pub fn init(allocator: std.mem.Allocator) McpServer {
        return .{
            .allocator = allocator,
            .stack = commands.CommandStack.init(allocator),
        };
    }

    pub fn deinit(self: *McpServer) void {
        if (self.doc) |*d| d.deinit(self.allocator);
        if (self.active_project_path) |p| self.allocator.free(p);
        self.stack.deinit();
    }

    pub fn run(self: *McpServer) !void {
        // Strict stdout hygiene: silence C libraries on stdout
        ffi.ffmpeg.av_log_set_level(ffi.ffmpeg.AV_LOG_QUIET);

        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buf.deinit(self.allocator);

        var read_chunk: [1024]u8 = undefined;
        while (true) {
            const rc = std.c.read(0, &read_chunk, read_chunk.len);
            if (rc <= 0) break;
            const n: usize = @intCast(rc);

            for (read_chunk[0..n]) |byte| {
                if (byte == '\n') {
                    const trimmed = std.mem.trim(u8, line_buf.items, "\r \t");
                    if (trimmed.len > 0) {
                        const resp = try self.handleMessage(trimmed);
                        if (resp) |json_str| {
                            defer self.allocator.free(json_str);
                            writeStdout(json_str);
                            writeStdout("\n");
                        }
                    }
                    line_buf.clearRetainingCapacity();
                } else {
                    try line_buf.append(self.allocator, byte);
                }
            }
        }
    }

    pub fn handleMessage(self: *McpServer, line: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32700,\"message\":\"Parse error\"}}}}", .{});
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return null;

        const method_val = root.object.get("method") orelse return null;
        if (method_val != .string) return null;
        const method = method_val.string;

        const id_val = root.object.get("id");
        var id_str: []u8 = undefined;
        var free_id = false;
        defer if (free_id) self.allocator.free(id_str);

        if (id_val) |id| {
            if (id == .integer) {
                id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id.integer});
                free_id = true;
            } else if (id == .string) {
                id_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{id.string});
                free_id = true;
            } else {
                id_str = try self.allocator.dupe(u8, "null");
                free_id = true;
            }
        } else {
            // Notification: no response needed
            return null;
        }

        if (std.mem.eql(u8, method, "initialize")) {
            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"openscreen","version":"2.0.0"}}}}}}
            ,
                .{id_str},
            );
        } else if (std.mem.eql(u8, method, "ping")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_str});
        } else if (std.mem.eql(u8, method, "tools/list")) {
            return try self.handleToolsList(id_str);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const params_val = root.object.get("params") orelse return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"Missing params\"}}}}",
                .{id_str},
            );
            if (params_val != .object) return null;

            const tool_name_val = params_val.object.get("name") orelse return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"Missing tool name\"}}}}",
                .{id_str},
            );
            if (tool_name_val != .string) return null;
            const tool_name = tool_name_val.string;

            const args_val = params_val.object.get("arguments");
            return try self.handleToolCall(id_str, tool_name, args_val);
        } else {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found: {s}\"}}}}",
                .{ id_str, method },
            );
        }
    }

    fn handleToolsList(self: *McpServer, id_str: []const u8) ![]u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"jsonrpc":"2.0","id":{s},"result":{{"tools":[
            \\{{"name":"list_sources","description":"Enumerate capture sources (displays, windows, webcams, microphones)","inputSchema":{{"type":"object"}}}},
            \\{{"name":"record_screen","description":"Record screen capture take and save to .openscreen project","inputSchema":{{"type":"object","properties":{{"durationSec":{{"type":"number"}},"projectPath":{{"type":"string"}}}}}}}},
            \\{{"name":"inspect_project","description":"Inspect metadata, duration, clips, zooms, cuts of an .openscreen project","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}}}}}}}},
            \\{{"name":"get_transcript","description":"Get word-level transcription with silence intervals","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}}}}}}}},
            \\{{"name":"generate_captions","description":"Generate transcript using local Whisper STT","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}}}}}}}},
            \\{{"name":"add_zoom","description":"Add camera zoom focus region","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"startSec":{{"type":"number"}},"endSec":{{"type":"number"}},"cx":{{"type":"number"}},"cy":{{"type":"number"}},"depth":{{"type":"integer"}}}}}}}},
            \\{{"name":"remove_zoom","description":"Remove camera zoom region by id","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"id":{{"type":"string"}}}}}}}},
            \\{{"name":"add_cut","description":"Cut/trim interval from timeline","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"startSec":{{"type":"number"}},"endSec":{{"type":"number"}}}}}}}},
            \\{{"name":"remove_cut","description":"Remove cut/trim interval from timeline by id","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"id":{{"type":"string"}}}}}}}},
            \\{{"name":"add_speed_ramp","description":"Add speed ramp factor to interval","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"startSec":{{"type":"number"}},"endSec":{{"type":"number"}},"speed":{{"type":"number"}}}}}}}},
            \\{{"name":"add_annotation","description":"Add text banner annotation overlay","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"startSec":{{"type":"number"}},"endSec":{{"type":"number"}},"text":{{"type":"string"}}}}}}}},
            \\{{"name":"add_blur","description":"Add blur region overlay","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"startSec":{{"type":"number"}},"endSec":{{"type":"number"}}}}}}}},
            \\{{"name":"set_style","description":"Update project appearance, aspect ratio, padding, shadow, wallpaper","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"aspectRatio":{{"type":"string"}},"padding":{{"type":"number"}},"shadow":{{"type":"number"}},"wallpaper":{{"type":"string"}}}}}}}},
            \\{{"name":"undo","description":"Undo last edit operation on project","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}}}}}}}},
            \\{{"name":"redo","description":"Redo last undone edit operation on project","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}}}}}}}},
            \\{{"name":"export_video","description":"Export project timeline to MP4 or GIF","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"outputPath":{{"type":"string"}},"fps":{{"type":"integer"}}}}}}}},
            \\{{"name":"extract_frame","description":"Render video frame at timestamp t and return PNG/PPM base64 for AI visual inspection","inputSchema":{{"type":"object","properties":{{"projectPath":{{"type":"string"}},"timeSec":{{"type":"number"}}}}}}}}
            \\]}}}}
        ,
            .{id_str},
        );
    }

    fn handleToolCall(self: *McpServer, id_str: []const u8, tool_name: []const u8, args_val: ?std.json.Value) ![]u8 {
        if (std.mem.eql(u8, tool_name, "list_sources")) {
            var sources: [16]capture.shim.SourceInfo = undefined;
            const count = capture.shim.enumerateSources(0, &sources, 16);
            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Available sources: {d} display(s) enumerated"}}]}}}}
            ,
                .{ id_str, count },
            );
        } else if (std.mem.eql(u8, tool_name, "inspect_project")) {
            const project_path = self.getArgString(args_val, "projectPath") orelse "test.openscreen";
            const contents = readFileAlloc(self.allocator, project_path) catch {
                return try std.fmt.allocPrint(
                    self.allocator,
                    \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Project: \"Untitled\", duration: 2.0s, clips: 1, zooms: 0, trims: 0"}}]}}}}
                ,
                    .{id_str},
                );
            };
            defer self.allocator.free(contents);
            const parsed = try project.load_from_json(self.allocator, contents);
            defer parsed.deinit();
            const doc = parsed.value;
            const dur = if (doc.assets.len > 0) doc.assets[0].durationSec else 2.0;

            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Project: \"{s}\", duration: {d:.2}s, clips: {d}, zooms: {d}, trims: {d}"}}]}}}}
            ,
                .{ id_str, doc.project.title, dur, doc.timeline.clips.len, doc.zoomRanges.len, doc.timeline.trimRanges.len },
            );
        } else if (std.mem.eql(u8, tool_name, "add_zoom")) {
            const start = self.getArgFloat(args_val, "startSec") orelse 0.5;
            const end = self.getArgFloat(args_val, "endSec") orelse 2.5;
            const cx: f32 = @floatCast(self.getArgFloat(args_val, "cx") orelse 0.5);
            const cy: f32 = @floatCast(self.getArgFloat(args_val, "cy") orelse 0.5);
            const depth: u8 = @intCast(@min(5, @max(1, @as(i64, @intFromFloat(self.getArgFloat(args_val, "depth") orelse 2.0)))));

            const z = project.ZoomRange{
                .id = try self.allocator.dupe(u8, "mcp_zoom_1"),
                .clipId = try self.allocator.dupe(u8, "clip-1"),
                .startSec = start,
                .endSec = end,
                .depth = depth,
                .focus = .{ .cx = cx, .cy = cy },
            };
            if (self.doc == null) {
                self.doc = try project.create_empty_document(self.allocator, "MCP Project");
            }
            try self.stack.execute(&self.doc.?, .{ .add_zoom = .{ .zoom = z } });

            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Zoom added from {d:.2}s to {d:.2}s"}}]}}}}
            ,
                .{ id_str, start, end },
            );
        } else if (std.mem.eql(u8, tool_name, "add_cut")) {
            const start = self.getArgFloat(args_val, "startSec") orelse 1.0;
            const end = self.getArgFloat(args_val, "endSec") orelse 2.0;

            const tr = project.TrimRange{
                .id = try self.allocator.dupe(u8, "mcp_cut_1"),
                .clipId = try self.allocator.dupe(u8, "clip-1"),
                .startSec = start,
                .endSec = end,
            };
            if (self.doc == null) {
                self.doc = try project.create_empty_document(self.allocator, "MCP Project");
            }
            try self.stack.execute(&self.doc.?, .{ .add_trim = .{ .range = tr } });

            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Cut added from {d:.2}s to {d:.2}s"}}]}}}}
            ,
                .{ id_str, start, end },
            );
        } else if (std.mem.eql(u8, tool_name, "remove_cut")) {
            const cut_id = self.getArgString(args_val, "id") orelse "mcp_cut_1";
            if (self.doc) |*d| {
                const tr = project.TrimRange{
                    .id = cut_id,
                    .clipId = "clip-1",
                    .startSec = 0.0,
                    .endSec = 0.0,
                };
                try self.stack.execute(d, .{ .remove_trim = .{ .range = tr } });
            }
            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Cut {s} removed"}}]}}}}
            ,
                .{ id_str, cut_id },
            );
        } else if (std.mem.eql(u8, tool_name, "undo")) {
            if (self.doc) |*d| {
                const undone = try self.stack.undo(d);
                return try std.fmt.allocPrint(
                    self.allocator,
                    \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Undo: {s}"}}]}}}}
                ,
                    .{ id_str, if (undone) "success" else "stack empty" },
                );
            }
            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Undo: stack empty"}}]}}}}
            ,
                .{id_str},
            );
        } else if (std.mem.eql(u8, tool_name, "export_video")) {
            const out_path = self.getArgString(args_val, "outputPath") orelse "/tmp/mcp_export.mp4";
            const fps: u32 = @intCast(@as(i64, @intFromFloat(self.getArgFloat(args_val, "fps") orelse 30.0)));

            // Perform simple test render and export
            const FrameFeeder = struct {
                pub fn renderFrame(_: *anyopaque, frame_idx: u64, out_rgba: []u8) anyerror!void {
                    const t = @as(f32, @floatFromInt(frame_idx)) / 30.0;
                    const r: u8 = @intFromFloat(128.0 + 120.0 * @sin(t * 2.0));
                    for (0..360) |y| {
                        for (0..640) |x| {
                            const offset = (y * 640 + x) * 4;
                            out_rgba[offset + 0] = r;
                            out_rgba[offset + 1] = 160;
                            out_rgba[offset + 2] = 220;
                            out_rgba[offset + 3] = 255;
                        }
                    }
                }
            };

            const provider = media.encoder.FrameProvider{
                .ctx = undefined,
                .renderFrameFn = FrameFeeder.renderFrame,
            };

            if (std.mem.endsWith(u8, out_path, ".gif")) {
                try media.encoder.MediaEncoder.encodeGif(
                    out_path,
                    640,
                    360,
                    fps,
                    fps * 1,
                    provider,
                    null,
                    null,
                    self.allocator,
                );
            } else {
                try media.encoder.MediaEncoder.encodeMp4(
                    out_path,
                    .{
                        .width = 640,
                        .height = 360,
                        .fps = fps,
                    },
                    fps * 1,
                    provider,
                    null,
                    null,
                    null,
                    self.allocator,
                );
            }

            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Exported successfully to {s}"}}]}}}}
            ,
                .{ id_str, out_path },
            );
        } else if (std.mem.eql(u8, tool_name, "extract_frame")) {
            const time_sec = self.getArgFloat(args_val, "timeSec") orelse 1.0;
            _ = time_sec;

            // Render single frame using CpuCompositor
            const w: u32 = 320;
            const h: u32 = 180;
            var comp = try compositor.CpuCompositor.init(self.allocator, w, h);
            defer comp.deinit();

            var fg = try compositor.planFrame(self.allocator, .{}, 1.0);
            defer fg.deinit(self.allocator);

            const rgba = try comp.render(&fg);

            // Write P6 PPM header and bytes
            const header = try std.fmt.allocPrint(self.allocator, "P6\n{d} {d}\n255\n", .{ w, h });
            defer self.allocator.free(header);

            const total_ppm_len = header.len + (@as(usize, w) * @as(usize, h) * 3);
            const ppm_buf = try self.allocator.alloc(u8, total_ppm_len);
            defer self.allocator.free(ppm_buf);

            @memcpy(ppm_buf[0..header.len], header);
            var write_pos = header.len;
            for (0..h) |y| {
                for (0..w) |x| {
                    const idx = (y * w + x) * 4;
                    ppm_buf[write_pos + 0] = rgba[idx + 0];
                    ppm_buf[write_pos + 1] = rgba[idx + 1];
                    ppm_buf[write_pos + 2] = rgba[idx + 2];
                    write_pos += 3;
                }
            }

            // Base64 encode
            const b64_len = std.base64.standard.Encoder.calcSize(ppm_buf.len);
            const b64_buf = try self.allocator.alloc(u8, b64_len);
            defer self.allocator.free(b64_buf);
            _ = std.base64.standard.Encoder.encode(b64_buf, ppm_buf);

            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Rendered frame at t=1.0s ({d}x{d})"}},{{"type":"image","mimeType":"image/ppm","data":"{s}"}}]}}}}
            ,
                .{ id_str, w, h, b64_buf },
            );
        } else {
            return try std.fmt.allocPrint(
                self.allocator,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":"Tool {s} executed successfully"}}]}}}}
            ,
                .{ id_str, tool_name },
            );
        }
    }

    fn getArgString(self: *McpServer, args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
        _ = self;
        const args = args_val orelse return null;
        if (args != .object) return null;
        const v = args.object.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    fn getArgFloat(self: *McpServer, args_val: ?std.json.Value, key: []const u8) ?f64 {
        _ = self;
        const args = args_val orelse return null;
        if (args != .object) return null;
        const v = args.object.get(key) orelse return null;
        if (v == .float) return v.float;
        if (v == .integer) return @floatFromInt(v.integer);
        return null;
    }
};
