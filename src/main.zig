const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var it = try init.minimal.args.iterateAllocator(allocator);
    defer it.deinit();

    var arg_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer arg_list.deinit(allocator);

    while (it.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    var cli_app = cli.Cli.init(allocator);
    const exit_code = try cli_app.run(arg_list.items);
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

test "main tests" {
    _ = cli;
}
