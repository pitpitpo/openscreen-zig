const std = @import("std");
const cli = @import("cli");
const ui = @import("ui");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var it = try init.minimal.args.iterateAllocator(allocator);
    defer it.deinit();

    var arg_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer arg_list.deinit(allocator);

    while (it.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    // Check if arguments specify headless CLI / MCP mode
    if (arg_list.items.len > 1) {
        const subcmd = arg_list.items[1];
        const is_headless_cmd = std.mem.eql(u8, subcmd, "help") or
            std.mem.eql(u8, subcmd, "--help") or
            std.mem.eql(u8, subcmd, "-h") or
            std.mem.eql(u8, subcmd, "--version") or
            std.mem.eql(u8, subcmd, "-v") or
            std.mem.eql(u8, subcmd, "version") or
            std.mem.eql(u8, subcmd, "sources") or
            std.mem.eql(u8, subcmd, "record") or
            std.mem.eql(u8, subcmd, "captions") or
            std.mem.eql(u8, subcmd, "edit") or
            std.mem.eql(u8, subcmd, "export") or
            std.mem.eql(u8, subcmd, "mcp");

        if (is_headless_cmd) {
            // Strictly headless CLI / MCP - never touches SDL or display handles
            var cli_app = cli.Cli.init(allocator);
            const exit_code = try cli_app.run(arg_list.items);
            if (exit_code != 0) {
                std.process.exit(exit_code);
            }
            return;
        }
    }

    // Check if arguments specify --test-gui-smoke
    if (arg_list.items.len > 1 and std.mem.eql(u8, arg_list.items[1], "--test-gui-smoke")) {
        var app = ui.App.init(allocator);
        defer app.deinit();
        const exit_code = try app.runSmokeTest();
        if (exit_code != 0) {
            std.process.exit(exit_code);
        }
        return;
    }

    // GUI Mode: either launched without arguments or with a project file path
    const maybe_proj: ?[]const u8 = if (arg_list.items.len > 1) arg_list.items[1] else null;
    var app = ui.App.init(allocator);
    defer app.deinit();
    const exit_code = try app.run(maybe_proj);
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

test "main tests" {
    _ = cli;
    _ = ui;
}
