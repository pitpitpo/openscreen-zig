const std = @import("std");

pub const ALL_LOCALES = [_][]const u8{
    "ar",
    "cs",
    "de",
    "en",
    "es",
    "fr",
    "it",
    "ja-JP",
    "ko-KR",
    "nl",
    "pl",
    "pt-BR",
    "ru",
    "tr",
    "vi",
    "zh-CN",
    "zh-TW",
};

pub const NAMESPACES = [_][]const u8{
    "common",
    "dialogs",
    "editor",
    "launch",
    "settings",
    "shortcuts",
    "timeline",
};

pub fn is_rtl(locale: []const u8) bool {
    return std.mem.eql(u8, locale, "ar");
}

pub fn validate_locale_completeness(allocator: std.mem.Allocator, base_dir: []const u8) !void {
    const io = std.Options.debug_io;
    // Verify each locale folder has all 7 namespace JSON files
    for (ALL_LOCALES) |loc| {
        for (NAMESPACES) |ns| {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.json", .{ base_dir, loc, ns });
            defer allocator.free(file_path);

            std.Io.Dir.cwd().access(io, file_path, .{}) catch |err| {
                std.debug.print("Missing locale file: {s}\n", .{file_path});
                return err;
            };
        }
    }
}

test "17 locales RTL and completeness" {
    try std.testing.expect(is_rtl("ar"));
    try std.testing.expect(!is_rtl("en"));
    try std.testing.expect(!is_rtl("zh-CN"));

    try validate_locale_completeness(std.testing.allocator, "assets/locales");
}
