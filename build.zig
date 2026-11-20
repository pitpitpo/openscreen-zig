const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library module
    const openscreen_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Core module
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("core", openscreen_core_mod);

    // Main executable: openscreen
    const exe = b.addExecutable(.{
        .name = "openscreen",
        .root_module = core_mod,
    });
    b.installArtifact(exe);

    // Run command: zig build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the OpenScreen application");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: zig build test
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_mod.addImport("core", openscreen_core_mod);
    const unit_tests = b.addTest(.{
        .root_module = unit_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Golden pixel & SSIM tests: zig build test-golden
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);
    const golden_step = b.step("test-golden", "Run golden pixel and SSIM regression tests");
    golden_step.dependOn(&run_golden_tests.step);

    // End-to-end integration tests: zig build test-e2e
    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    const e2e_step = b.step("test-e2e", "Run end-to-end integration tests");
    e2e_step.dependOn(&run_e2e_tests.step);

    // Tools: cursor-diag
    const cursor_diag_exe = b.addExecutable(.{
        .name = "cursor-diag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cursor_diag.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_diag = b.addInstallArtifact(cursor_diag_exe, .{});
    const diag_step = b.step("cursor-diag", "Build cursor diagnostics tool");
    diag_step.dependOn(&install_diag.step);

    // Tools: stt-eval
    const stt_eval_exe = b.addExecutable(.{
        .name = "stt-eval",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/stt_eval.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_stt = b.addInstallArtifact(stt_eval_exe, .{});
    const stt_step = b.step("stt-eval", "Build STT evaluation tool");
    stt_step.dependOn(&install_stt.step);

    // Step: i18n-check
    const i18n_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/i18n.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_i18n = b.addRunArtifact(i18n_test);
    const i18n_step = b.step("i18n-check", "Validate all 17 locale files");
    i18n_step.dependOn(&run_i18n.step);
}
