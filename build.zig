const std = @import("std");

fn linkWgpu(
    b: *std.Build,
    compile_step: *std.Build.Step.Compile,
    wgpu_dep: ?*std.Build.Dependency,
    target: std.Build.ResolvedTarget,
) void {
    _ = b;
    if (wgpu_dep) |dep| {
        const mod = compile_step.root_module;
        mod.addLibraryPath(dep.path("lib"));
        mod.link_libc = true;
        const target_os = target.result.os.tag;
        if (target_os == .linux) {
            mod.addObjectFile(dep.path("lib/libwgpu_native.a"));
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("gcc_s", .{});
        } else if (target_os == .macos) {
            mod.addObjectFile(dep.path("lib/libwgpu_native.a"));
            mod.linkFramework("Metal", .{});
            mod.linkFramework("QuartzCore", .{});
            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("CoreGraphics", .{});
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("IOKit", .{});
            mod.linkFramework("IOSurface", .{});
        } else if (target_os == .windows) {
            mod.linkSystemLibrary("wgpu_native", .{});
            mod.linkSystemLibrary("d3d12", .{});
            mod.linkSystemLibrary("dxgi", .{});
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("kernel32", .{});
            mod.linkSystemLibrary("ntdll", .{});
            mod.linkSystemLibrary("ws2_32", .{});
            mod.linkSystemLibrary("userenv", .{});
            mod.linkSystemLibrary("bcrypt", .{});
        }
    }
}

fn linkOpenScreenLibs(
    b: *std.Build,
    compile_step: *std.Build.Step.Compile,
    wgpu_dep: ?*std.Build.Dependency,
    target: std.Build.ResolvedTarget,
) void {
    linkWgpu(b, compile_step, wgpu_dep, target);

    const mod = compile_step.root_module;
    mod.link_libc = true;
    mod.link_libcpp = true;

    mod.addIncludePath(b.path("src/ffi"));
    mod.addIncludePath(b.path("src/ffi/include"));
    mod.addIncludePath(b.path("src/ffi/whisper"));
    mod.addIncludePath(b.path("src/ffi/onnx"));
    mod.addIncludePath(b.path("src/capture/shims"));

    const target_os = target.result.os.tag;
    if (target_os == .linux) {
        mod.addIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
        mod.addLibraryPath(b.path("src/ffi/lib/linux-x86_64"));
        mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("pthread", .{});
        mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xext", .{});
        mod.linkSystemLibrary("Xfixes", .{});
        mod.addCSourceFiles(.{
            .root = b.path("src/capture/shims"),
            .files = &.{"linux_pw.c"},
            .flags = &.{ "-D_GNU_SOURCE", "-O3" },
        });
    } else if (target_os == .macos) {
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        mod.linkFramework("ScreenCaptureKit", .{});
        mod.linkFramework("AVFoundation", .{});
        mod.linkFramework("CoreGraphics", .{});
        mod.linkFramework("CoreMedia", .{});
        mod.linkFramework("CoreVideo", .{});
        mod.linkFramework("CoreAudio", .{});
        mod.linkFramework("ApplicationServices", .{});
        mod.linkFramework("Foundation", .{});
        mod.addCSourceFiles(.{
            .root = b.path("src/capture/shims"),
            .files = &.{"macos_sck.m"},
            .flags = &.{ "-fobjc-arc", "-O3", "-Wno-deprecated-declarations" },
        });
    } else if (target_os == .windows) {
        mod.addLibraryPath(b.path("lib"));
        mod.addIncludePath(b.path("include"));
        mod.linkSystemLibrary("d3d11", .{});
        mod.linkSystemLibrary("dxgi", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("oleaut32", .{});
        mod.addCSourceFiles(.{
            .root = b.path("src/capture/shims"),
            .files = &.{"win_wgc.cpp"},
            .flags = &.{ "-std=c++17", "-O3" },
        });
    }

    mod.linkSystemLibrary("avformat", .{});
    mod.linkSystemLibrary("avcodec", .{});
    mod.linkSystemLibrary("avutil", .{});
    mod.linkSystemLibrary("swscale", .{});
    mod.linkSystemLibrary("swresample", .{});

    const c_flags: []const []const u8 = &.{ "-D_GNU_SOURCE", "-O3" };
    const cpp_flags: []const []const u8 = &.{ "-D_GNU_SOURCE", "-O3", "-std=c++11" };

    mod.addCSourceFiles(.{
        .root = b.path("src/ffi"),
        .files = &.{
            "ffmpeg_shim.c",
            "whisper_shim.c",
            "onnx_shim.c",
        },
        .flags = c_flags,
    });

    mod.addCSourceFiles(.{
        .root = b.path("src/ffi/whisper"),
        .files = &.{
            "ggml.c",
            "ggml-alloc.c",
            "ggml-backend.c",
            "ggml-quants.c",
        },
        .flags = c_flags,
    });

    mod.addCSourceFiles(.{
        .root = b.path("src/ffi/whisper"),
        .files = &.{
            "whisper.cpp",
        },
        .flags = cpp_flags,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const target_os = target.result.os.tag;
    const target_arch = target.result.cpu.arch;

    var wgpu_dep: ?*std.Build.Dependency = null;
    if (target_os == .linux and target_arch == .x86_64) {
        wgpu_dep = b.lazyDependency("wgpu_linux_x86_64", .{});
    } else if (target_os == .macos and target_arch == .aarch64) {
        wgpu_dep = b.lazyDependency("wgpu_macos_aarch64", .{});
    } else if (target_os == .windows and target_arch == .x86_64) {
        wgpu_dep = b.lazyDependency("wgpu_windows_x86_64", .{});
    }

    // Core library module
    const openscreen_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // FFI module
    const openscreen_ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Media pipeline module
    const openscreen_media_mod = b.createModule(.{
        .root_source_file = b.path("src/media/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    openscreen_media_mod.addImport("ffi", openscreen_ffi_mod);

    // Compositor module
    const openscreen_compositor_mod = b.createModule(.{
        .root_source_file = b.path("src/compositor/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    openscreen_compositor_mod.addImport("core", openscreen_core_mod);
    openscreen_compositor_mod.addImport("ffi", openscreen_ffi_mod);
    openscreen_compositor_mod.addImport("media", openscreen_media_mod);

    // Capture module
    const openscreen_capture_mod = b.createModule(.{
        .root_source_file = b.path("src/capture/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    openscreen_capture_mod.addImport("core", openscreen_core_mod);
    openscreen_capture_mod.addImport("ffi", openscreen_ffi_mod);
    openscreen_capture_mod.addImport("media", openscreen_media_mod);

    // Cursor diag module
    const cursor_diag_mod = b.createModule(.{
        .root_source_file = b.path("tools/cursor_diag.zig"),
        .target = target,
        .optimize = optimize,
    });
    cursor_diag_mod.link_libc = true;

    // Main executable module
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("core", openscreen_core_mod);
    core_mod.addImport("compositor", openscreen_compositor_mod);
    core_mod.addImport("ffi", openscreen_ffi_mod);
    core_mod.addImport("media", openscreen_media_mod);
    core_mod.addImport("capture", openscreen_capture_mod);

    // Main executable: openscreen
    const exe = b.addExecutable(.{
        .name = "openscreen",
        .root_module = core_mod,
    });
    linkOpenScreenLibs(b, exe, wgpu_dep, target);
    b.installArtifact(exe);

    if (target_os == .windows) {
        if (wgpu_dep) |dep| {
            const install_dll = b.addInstallFileWithDir(dep.path("lib/wgpu_native.dll"), .bin, "wgpu_native.dll");
            b.getInstallStep().dependOn(&install_dll.step);
        }
    }

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
    unit_mod.addImport("compositor", openscreen_compositor_mod);
    unit_mod.addImport("ffi", openscreen_ffi_mod);
    unit_mod.addImport("media", openscreen_media_mod);
    unit_mod.addImport("capture", openscreen_capture_mod);
    unit_mod.addImport("cursor_diag", cursor_diag_mod);
    const unit_tests = b.addTest(.{
        .root_module = unit_mod,
    });
    linkOpenScreenLibs(b, unit_tests, wgpu_dep, target);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Golden pixel & SSIM tests: zig build test-golden
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("tests/golden/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_mod.addImport("core", openscreen_core_mod);
    golden_mod.addImport("compositor", openscreen_compositor_mod);
    golden_mod.addImport("ffi", openscreen_ffi_mod);
    golden_mod.addImport("media", openscreen_media_mod);
    const golden_tests = b.addTest(.{
        .root_module = golden_mod,
    });
    linkOpenScreenLibs(b, golden_tests, wgpu_dep, target);
    const run_golden_tests = b.addRunArtifact(golden_tests);
    const golden_step = b.step("test-golden", "Run golden pixel and SSIM regression tests");
    golden_step.dependOn(&run_golden_tests.step);

    // End-to-end integration tests: zig build test-e2e
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("core", openscreen_core_mod);
    e2e_mod.addImport("compositor", openscreen_compositor_mod);
    e2e_mod.addImport("ffi", openscreen_ffi_mod);
    e2e_mod.addImport("media", openscreen_media_mod);
    e2e_mod.addImport("capture", openscreen_capture_mod);
    e2e_mod.addImport("cursor_diag", cursor_diag_mod);
    const e2e_tests = b.addTest(.{
        .root_module = e2e_mod,
    });
    linkOpenScreenLibs(b, e2e_tests, wgpu_dep, target);
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    const e2e_step = b.step("test-e2e", "Run end-to-end integration tests");
    e2e_step.dependOn(&run_e2e_tests.step);

    // Tools: cursor-diag
    const cursor_diag_exe = b.addExecutable(.{
        .name = "cursor-diag",
        .root_module = cursor_diag_mod,
    });
    const install_diag = b.addInstallArtifact(cursor_diag_exe, .{});
    const diag_step = b.step("cursor-diag", "Build cursor diagnostics tool");
    diag_step.dependOn(&install_diag.step);

    // Tools: stt-eval
    const stt_eval_mod = b.createModule(.{
        .root_source_file = b.path("tools/stt_eval.zig"),
        .target = target,
        .optimize = optimize,
    });
    stt_eval_mod.addImport("core", openscreen_core_mod);
    stt_eval_mod.addImport("ffi", openscreen_ffi_mod);
    stt_eval_mod.addImport("media", openscreen_media_mod);
    const stt_eval_exe = b.addExecutable(.{
        .name = "stt-eval",
        .root_module = stt_eval_mod,
    });
    linkOpenScreenLibs(b, stt_eval_exe, wgpu_dep, target);
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
