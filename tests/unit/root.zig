const std = @import("std");
const core = @import("core");

test "unit tests root" {
    try std.testing.expect(true);
}

test {
    _ = core;
}
