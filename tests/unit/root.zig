const std = @import("std");
const core = @import("core");
const compositor = @import("compositor");

test "unit tests root" {
    try std.testing.expect(true);
}

test {
    _ = core;
    _ = compositor;
}
