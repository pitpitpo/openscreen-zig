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

pub const DipRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const PhysicalRect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// Converts bounds from virtual DIP coordinate space to native helper physical pixels.
/// Windows: per-monitor-v2 DPI unvirtualized physical pixels relative to monitor origin.
/// macOS & Linux: Points / logical pixels (identity scale factor in ScreenCaptureKit and PipeWire).
pub fn dip_to_physical_rect(
    platform: PlatformTag,
    bounds: DipRect,
    scale_factor: f32,
    monitor_origin_x: f32,
    monitor_origin_y: f32,
) PhysicalRect {
    if (platform == .macos or platform == .linux) {
        return .{
            .x = @intFromFloat(bounds.x),
            .y = @intFromFloat(bounds.y),
            .width = @as(u32, @intFromFloat(@max(1.0, bounds.width))),
            .height = @as(u32, @intFromFloat(@max(1.0, bounds.height))),
        };
    }

    // Windows per-monitor-v2 scaling: (DIP - Origin) * Scale + Origin
    const rel_x = bounds.x - monitor_origin_x;
    const rel_y = bounds.y - monitor_origin_y;
    const phys_x = @as(i32, @intFromFloat(monitor_origin_x + rel_x * scale_factor));
    const phys_y = @as(i32, @intFromFloat(monitor_origin_y + rel_y * scale_factor));
    const phys_w = @as(u32, @intFromFloat(@max(1.0, bounds.width * scale_factor)));
    const phys_h = @as(u32, @intFromFloat(@max(1.0, bounds.height * scale_factor)));

    return .{
        .x = phys_x,
        .y = phys_y,
        .width = phys_w,
        .height = phys_h,
    };
}

test "platform-pinned DPI coordinate conversion" {
    const dip = DipRect{ .x = 100.0, .y = 50.0, .width = 1920.0, .height = 1080.0 };

    // macOS: 1:1 points
    const mac_rect = dip_to_physical_rect(.macos, dip, 2.0, 0.0, 0.0);
    try std.testing.expectEqual(@as(i32, 100), mac_rect.x);
    try std.testing.expectEqual(@as(i32, 50), mac_rect.y);
    try std.testing.expectEqual(@as(u32, 1920), mac_rect.width);
    try std.testing.expectEqual(@as(u32, 1080), mac_rect.height);

    // Linux: 1:1 logical pixels
    const linux_rect = dip_to_physical_rect(.linux, dip, 1.5, 0.0, 0.0);
    try std.testing.expectEqual(@as(i32, 100), linux_rect.x);
    try std.testing.expectEqual(@as(i32, 50), linux_rect.y);
    try std.testing.expectEqual(@as(u32, 1920), linux_rect.width);
    try std.testing.expectEqual(@as(u32, 1080), linux_rect.height);

    // Windows 100% scale
    const win_100 = dip_to_physical_rect(.windows, dip, 1.0, 0.0, 0.0);
    try std.testing.expectEqual(@as(i32, 100), win_100.x);
    try std.testing.expectEqual(@as(i32, 50), win_100.y);
    try std.testing.expectEqual(@as(u32, 1920), win_100.width);
    try std.testing.expectEqual(@as(u32, 1080), win_100.height);

    // Windows 150% scale on primary display (origin 0,0)
    const win_150 = dip_to_physical_rect(.windows, dip, 1.5, 0.0, 0.0);
    try std.testing.expectEqual(@as(i32, 150), win_150.x);
    try std.testing.expectEqual(@as(i32, 75), win_150.y);
    try std.testing.expectEqual(@as(u32, 2880), win_150.width);
    try std.testing.expectEqual(@as(u32, 1620), win_150.height);

    // Windows 200% scale on secondary display with non-zero origin (1920, 0)
    const sec_dip = DipRect{ .x = 2020.0, .y = 100.0, .width = 800.0, .height = 600.0 };
    const win_200_sec = dip_to_physical_rect(.windows, sec_dip, 2.0, 1920.0, 0.0);
    // rel_x = 2020 - 1920 = 100 -> phys_x = 1920 + 100 * 2.0 = 2120
    try std.testing.expectEqual(@as(i32, 2120), win_200_sec.x);
    try std.testing.expectEqual(@as(i32, 200), win_200_sec.y);
    try std.testing.expectEqual(@as(u32, 1600), win_200_sec.width);
    try std.testing.expectEqual(@as(u32, 1200), win_200_sec.height);
}
