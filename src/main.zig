const std = @import("std");

pub fn main() !void {
    std.debug.print("openscreen 2.0.0 (native zig)\n", .{});
}

test "main test" {
    try std.testing.expect(true);
}
