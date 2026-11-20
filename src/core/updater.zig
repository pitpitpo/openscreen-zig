const std = @import("std");

pub const CURRENT_VERSION = "2.0.0";

pub const ReleaseInfo = struct {
    tag_name: []const u8,
    html_url: []const u8,
    is_newer: bool,
};

pub fn compare_semver(current: []const u8, candidate: []const u8) bool {
    // Returns true if candidate > current
    var curr_clean = current;
    if (std.mem.startsWith(u8, curr_clean, "v")) curr_clean = curr_clean[1..];
    var cand_clean = candidate;
    if (std.mem.startsWith(u8, cand_clean, "v")) cand_clean = cand_clean[1..];

    var curr_it = std.mem.splitScalar(u8, curr_clean, '.');
    var cand_it = std.mem.splitScalar(u8, cand_clean, '.');

    while (true) {
        const c_part = curr_it.next();
        const cand_part = cand_it.next();

        if (c_part == null and cand_part == null) return false;
        if (c_part == null) return true;
        if (cand_part == null) return false;

        const c_num = std.fmt.parseInt(u32, c_part.?, 10) catch 0;
        const cand_num = std.fmt.parseInt(u32, cand_part.?, 10) catch 0;

        if (cand_num > c_num) return true;
        if (cand_num < c_num) return false;
    }
}

test "semver comparison logic" {
    try std.testing.expect(compare_semver("2.0.0", "v2.0.1"));
    try std.testing.expect(compare_semver("2.0.0", "2.1.0"));
    try std.testing.expect(compare_semver("2.0.0", "3.0.0"));
    try std.testing.expect(!compare_semver("2.0.0", "2.0.0"));
    try std.testing.expect(!compare_semver("2.0.0", "1.9.9"));
    try std.testing.expect(!compare_semver("2.0.0", "v1.5.0"));
}
