const std = @import("std");

pub const PlatformTag = enum {
    linux,
    macos,
    windows,
};

pub const ByokProvider = enum {
    claude,
    openai,
    gemini,
    mistral,
    openrouter,
    minimax,
    custom,

    pub fn to_string(self: ByokProvider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .openai => "openai",
            .gemini => "gemini",
            .mistral => "mistral",
            .openrouter => "openrouter",
            .minimax => "minimax",
            .custom => "custom",
        };
    }
};

pub const ByokConfig = struct {
    provider: ByokProvider = .claude,
    api_key: []const u8 = "",
    custom_endpoint: []const u8 = "",
    model_override: []const u8 = "",
};

pub const AppConfig = struct {
    global_shortcut: []const u8 = "CommandOrControl+Shift+O",
    content_protection_enabled: bool = true,
    byok: ByokConfig = .{},
    mcp_edits_allowed: bool = false,
};

pub fn resolve_user_data_dir(allocator: std.mem.Allocator, platform: PlatformTag, is_dev: bool, home_or_appdata: []const u8) ![]u8 {
    const app_name = if (is_dev) "openscreen-dev" else "openscreen";

    return switch (platform) {
        .windows => try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ home_or_appdata, app_name }),
        .macos => try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/{s}", .{ home_or_appdata, app_name }),
        .linux => try std.fmt.allocPrint(allocator, "{s}/.config/{s}", .{ home_or_appdata, app_name }),
    };
}

pub fn resolve_lock_file_path(allocator: std.mem.Allocator, platform: PlatformTag, is_dev: bool, home_or_appdata: []const u8) ![]u8 {
    const user_dir = try resolve_user_data_dir(allocator, platform, is_dev, home_or_appdata);
    defer allocator.free(user_dir);

    const sep = if (platform == .windows) "\\" else "/";
    return try std.fmt.allocPrint(allocator, "{s}{s}singleton.lock", .{ user_dir, sep });
}

test "platform-pinned user data and lock paths" {
    // Test Windows path unconditionally
    const win_prod = try resolve_lock_file_path(std.testing.allocator, .windows, false, "C:\\Users\\dev\\AppData\\Local");
    defer std.testing.allocator.free(win_prod);
    try std.testing.expectEqualStrings("C:\\Users\\dev\\AppData\\Local\\openscreen\\singleton.lock", win_prod);

    const win_dev = try resolve_lock_file_path(std.testing.allocator, .windows, true, "C:\\Users\\dev\\AppData\\Local");
    defer std.testing.allocator.free(win_dev);
    try std.testing.expectEqualStrings("C:\\Users\\dev\\AppData\\Local\\openscreen-dev\\singleton.lock", win_dev);

    // Test macOS path unconditionally
    const mac_prod = try resolve_lock_file_path(std.testing.allocator, .macos, false, "/Users/dev");
    defer std.testing.allocator.free(mac_prod);
    try std.testing.expectEqualStrings("/Users/dev/Library/Application Support/openscreen/singleton.lock", mac_prod);

    const mac_dev = try resolve_lock_file_path(std.testing.allocator, .macos, true, "/Users/dev");
    defer std.testing.allocator.free(mac_dev);
    try std.testing.expectEqualStrings("/Users/dev/Library/Application Support/openscreen-dev/singleton.lock", mac_dev);

    // Test Linux path unconditionally
    const linux_prod = try resolve_lock_file_path(std.testing.allocator, .linux, false, "/home/dev");
    defer std.testing.allocator.free(linux_prod);
    try std.testing.expectEqualStrings("/home/dev/.config/openscreen/singleton.lock", linux_prod);

    const linux_dev = try resolve_lock_file_path(std.testing.allocator, .linux, true, "/home/dev");
    defer std.testing.allocator.free(linux_dev);
    try std.testing.expectEqualStrings("/home/dev/.config/openscreen-dev/singleton.lock", linux_dev);
}
