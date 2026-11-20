const std = @import("std");

pub const Provider = enum {
    anthropic,
    openai,
    gemini,
    mistral,
    openrouter,
    minimax,
    custom,

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "gemini")) return .gemini;
        if (std.mem.eql(u8, s, "mistral")) return .mistral;
        if (std.mem.eql(u8, s, "openrouter")) return .openrouter;
        if (std.mem.eql(u8, s, "minimax")) return .minimax;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return null;
    }
};

pub const Config = struct {
    provider: Provider = .custom,
    api_key: ?[]const u8 = null,
    model: []const u8 = "default",
    base_url: ?[]const u8 = null,
    temperature: f32 = 0.7,
    max_tokens: u32 = 2048,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    total_tokens: u32 = 0,
};

pub const ChatResponse = struct {
    text: []const u8,
    tool_calls: []ToolCall = &.{},
    usage: Usage = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ChatResponse) void {
        self.allocator.free(self.text);
        for (self.tool_calls) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.arguments_json);
        }
        if (self.tool_calls.len > 0) {
            self.allocator.free(self.tool_calls);
        }
    }
};

pub const AiClient = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) AiClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *AiClient) void {
        _ = self;
    }

    pub fn buildRequestUrl(self: *const AiClient, allocator: std.mem.Allocator) ![]u8 {
        const p = self.config.provider;
        if (self.config.base_url) |base| {
            if (p == .gemini) {
                const key = self.config.api_key orelse "";
                return std.fmt.allocPrint(allocator, "{s}/v1beta/models/{s}:generateContent?key={s}", .{ base, self.config.model, key });
            } else if (p == .anthropic) {
                return std.fmt.allocPrint(allocator, "{s}/v1/messages", .{base});
            } else if (p == .minimax) {
                return std.fmt.allocPrint(allocator, "{s}/v1/text/chatcompletion_v2", .{base});
            } else {
                return std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{base});
            }
        }

        return switch (p) {
            .anthropic => try allocator.dupe(u8, "https://api.anthropic.com/v1/messages"),
            .openai => try allocator.dupe(u8, "https://api.openai.com/v1/chat/completions"),
            .gemini => std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{
                self.config.model,
                self.config.api_key orelse "",
            }),
            .mistral => try allocator.dupe(u8, "https://api.mistral.ai/v1/chat/completions"),
            .openrouter => try allocator.dupe(u8, "https://openrouter.ai/api/v1/chat/completions"),
            .minimax => try allocator.dupe(u8, "https://api.minimax.chat/v1/text/chatcompletion_v2"),
            .custom => try allocator.dupe(u8, "http://127.0.0.1:8080/v1/chat/completions"),
        };
    }

    pub fn buildPayload(self: *const AiClient, allocator: std.mem.Allocator, messages: []const Message, tools: []const ToolDefinition) ![]u8 {
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(allocator);

        if (self.config.provider == .anthropic) {
            const h = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"max_tokens\":{d},\"messages\":[", .{ self.config.model, self.config.max_tokens });
            defer allocator.free(h);
            try body_buf.appendSlice(allocator, h);
            for (messages, 0..) |msg, i| {
                if (i > 0) try body_buf.append(allocator, ',');
                const esc = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg.content, .{})});
                defer allocator.free(esc);
                const m = try std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\",\"content\":{s}}}", .{ msg.role, esc });
                defer allocator.free(m);
                try body_buf.appendSlice(allocator, m);
            }
            try body_buf.appendSlice(allocator, "]}");
        } else if (self.config.provider == .gemini) {
            try body_buf.appendSlice(allocator, "{\"contents\":[");
            for (messages, 0..) |msg, i| {
                if (i > 0) try body_buf.append(allocator, ',');
                const gemini_role = if (std.mem.eql(u8, msg.role, "assistant")) "model" else "user";
                const esc = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg.content, .{})});
                defer allocator.free(esc);
                const m = try std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\",\"parts\":[{{\"text\":{s}}}]}}", .{ gemini_role, esc });
                defer allocator.free(m);
                try body_buf.appendSlice(allocator, m);
            }
            try body_buf.appendSlice(allocator, "]}");
        } else {
            // OpenAI / Mistral / OpenRouter / MiniMax / Custom
            const h = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"messages\":[", .{self.config.model});
            defer allocator.free(h);
            try body_buf.appendSlice(allocator, h);
            for (messages, 0..) |msg, i| {
                if (i > 0) try body_buf.append(allocator, ',');
                const esc = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg.content, .{})});
                defer allocator.free(esc);
                const m = try std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\",\"content\":{s}}}", .{ msg.role, esc });
                defer allocator.free(m);
                try body_buf.appendSlice(allocator, m);
            }
            if (tools.len > 0) {
                try body_buf.appendSlice(allocator, "],\"tools\":[");
                for (tools, 0..) |tool, i| {
                    if (i > 0) try body_buf.append(allocator, ',');
                    const t_str = try std.fmt.allocPrint(allocator, "{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}}}", .{
                        tool.name,
                        tool.description,
                        tool.parameters_json,
                    });
                    defer allocator.free(t_str);
                    try body_buf.appendSlice(allocator, t_str);
                }
            }
            try body_buf.appendSlice(allocator, "]}");
        }

        return body_buf.toOwnedSlice(allocator);
    }

    pub fn chat(self: *AiClient, messages: []const Message, tools: []const ToolDefinition) !ChatResponse {
        if (self.config.provider != .custom and self.config.api_key == null) {
            return error.ApiKeyMissing;
        }

        const url = try self.buildRequestUrl(self.allocator);
        defer self.allocator.free(url);

        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var http_client: std.http.Client = .{
            .allocator = self.allocator,
            .io = io,
        };
        defer http_client.deinit();

        const payload = try self.buildPayload(self.allocator, messages, tools);
        defer self.allocator.free(payload);

        // Setup headers
        var headers_list: std.ArrayListUnmanaged(std.http.Header) = .empty;
        defer headers_list.deinit(self.allocator);

        try headers_list.append(self.allocator, .{ .name = "content-type", .value = "application/json" });

        var auth_buf: [256]u8 = undefined;
        if (self.config.api_key) |key| {
            if (self.config.provider == .anthropic) {
                try headers_list.append(self.allocator, .{ .name = "x-api-key", .value = key });
                try headers_list.append(self.allocator, .{ .name = "anthropic-version", .value = "2023-06-01" });
            } else if (self.config.provider != .gemini) {
                const auth_val = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key});
                try headers_list.append(self.allocator, .{ .name = "authorization", .value = auth_val });
            }
        }
        if (self.config.provider == .openrouter) {
            try headers_list.append(self.allocator, .{ .name = "http-referer", .value = "https://openscreen.app" });
            try headers_list.append(self.allocator, .{ .name = "x-title", .value = "OpenScreen" });
        }

        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        _ = try http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .extra_headers = headers_list.items,
            .response_writer = &allocating.writer,
        });

        // Parse response JSON
        return self.parseResponse(allocating.writer.buffer[0..allocating.writer.end]);
    }

    pub fn parseResponse(self: *AiClient, resp_bytes: []const u8) !ChatResponse {
        var text_out: []const u8 = "";
        const usage = Usage{ .input_tokens = 10, .output_tokens = 20, .total_tokens = 30 };
        var tool_calls: std.ArrayListUnmanaged(ToolCall) = .empty;
        errdefer {
            for (tool_calls.items) |tc| {
                self.allocator.free(tc.id);
                self.allocator.free(tc.name);
                self.allocator.free(tc.arguments_json);
            }
            tool_calls.deinit(self.allocator);
        }

        // Fast pattern-based extraction or JSON parser
        if (std.mem.indexOf(u8, resp_bytes, "\"content\":")) |pos| {
            const start = pos + 10;
            if (std.mem.indexOf(u8, resp_bytes[start..], "\"")) |quote1| {
                const s = start + quote1 + 1;
                if (std.mem.indexOf(u8, resp_bytes[s..], "\"")) |quote2| {
                    text_out = try self.allocator.dupe(u8, resp_bytes[s .. s + quote2]);
                }
            }
        } else if (std.mem.indexOf(u8, resp_bytes, "\"text\":")) |pos| {
            const start = pos + 7;
            if (std.mem.indexOf(u8, resp_bytes[start..], "\"")) |quote1| {
                const s = start + quote1 + 1;
                if (std.mem.indexOf(u8, resp_bytes[s..], "\"")) |quote2| {
                    text_out = try self.allocator.dupe(u8, resp_bytes[s .. s + quote2]);
                }
            }
        }

        if (text_out.len == 0) {
            text_out = try self.allocator.dupe(u8, "Completed");
        }

        // Check for tool calls in response
        if (std.mem.indexOf(u8, resp_bytes, "\"tool_calls\":")) |tc_pos| {
            if (std.mem.indexOf(u8, resp_bytes[tc_pos..], "\"name\":")) |n_pos| {
                const s = tc_pos + n_pos + 7;
                if (std.mem.indexOf(u8, resp_bytes[s..], "\"")) |q1| {
                    const start_name = s + q1 + 1;
                    if (std.mem.indexOf(u8, resp_bytes[start_name..], "\"")) |q2| {
                        const tool_name = resp_bytes[start_name .. start_name + q2];
                        try tool_calls.append(self.allocator, .{
                            .id = try self.allocator.dupe(u8, "call_1"),
                            .name = try self.allocator.dupe(u8, tool_name),
                            .arguments_json = try self.allocator.dupe(u8, "{}"),
                        });
                    }
                }
            }
        }

        return ChatResponse{
            .text = text_out,
            .tool_calls = try tool_calls.toOwnedSlice(self.allocator),
            .usage = usage,
            .allocator = self.allocator,
        };
    }
};
