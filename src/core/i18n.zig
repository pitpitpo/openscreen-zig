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

fn check_json_key_parity(en_val: std.json.Value, loc_val: std.json.Value, loc: []const u8, ns: []const u8) !void {
    switch (en_val) {
        .object => |en_obj| {
            if (loc_val != .object) {
                std.debug.print("[{s}/{s}] expected object, got different type\n", .{ loc, ns });
                return error.TypeMismatch;
            }
            const loc_obj = loc_val.object;

            // Check that every key in en exists in loc
            var en_it = en_obj.iterator();
            while (en_it.next()) |entry| {
                const key = entry.key_ptr.*;
                const loc_child = loc_obj.get(key) orelse {
                    std.debug.print("[{s}/{s}] missing key: {s}\n", .{ loc, ns, key });
                    return error.MissingKey;
                };
                try check_json_key_parity(entry.value_ptr.*, loc_child, loc, ns);
            }

            // Check that no extra keys exist in loc that aren't in en
            var loc_it = loc_obj.iterator();
            while (loc_it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!en_obj.contains(key)) {
                    std.debug.print("[{s}/{s}] extra key: {s}\n", .{ loc, ns, key });
                    return error.ExtraKey;
                }
            }
        },
        else => {},
    }
}

pub fn validate_locale_completeness(allocator: std.mem.Allocator, base_dir: []const u8) !void {
    const io = std.Options.debug_io;

    // For each namespace, load English reference and compare every other locale against it
    for (NAMESPACES) |ns| {
        const en_path = try std.fmt.allocPrint(allocator, "{s}/en/{s}.json", .{ base_dir, ns });
        defer allocator.free(en_path);

        const en_content = std.Io.Dir.cwd().readFileAlloc(io, en_path, allocator, .limited(1024 * 1024)) catch |err| {
            std.debug.print("Failed to read reference locale file: {s}\n", .{en_path});
            return err;
        };
        defer allocator.free(en_content);

        const en_parsed = try std.json.parseFromSlice(std.json.Value, allocator, en_content, .{});
        defer en_parsed.deinit();

        for (ALL_LOCALES) |loc| {
            if (std.mem.eql(u8, loc, "en")) continue;

            const loc_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.json", .{ base_dir, loc, ns });
            defer allocator.free(loc_path);

            const loc_content = std.Io.Dir.cwd().readFileAlloc(io, loc_path, allocator, .limited(1024 * 1024)) catch |err| {
                std.debug.print("Missing or unreadable locale file: {s}\n", .{loc_path});
                return err;
            };
            defer allocator.free(loc_content);

            const loc_parsed = std.json.parseFromSlice(std.json.Value, allocator, loc_content, .{}) catch |err| {
                std.debug.print("Malformed JSON in locale file: {s}\n", .{loc_path});
                return err;
            };
            defer loc_parsed.deinit();

            try check_json_key_parity(en_parsed.value, loc_parsed.value, loc, ns);
        }
    }
}

test "17 locales RTL and completeness" {
    try std.testing.expect(is_rtl("ar"));
    try std.testing.expect(!is_rtl("en"));
    try std.testing.expect(!is_rtl("zh-CN"));

    try validate_locale_completeness(std.testing.allocator, "assets/locales");
}
