# AGENTS.md — OpenScreen Engineering & AI Agent Guide

OpenScreen is a native, high-performance screen recording and video editing suite written in **Zig (0.17.1)** with C-ABI FFI shims for native platform capture, GPU compositing (`wgpu-native`), FFmpeg LGPL export, Whisper speech-to-text, and ONNX Runtime webcam matting.

This document serves as the authoritative operational manual for any AI coding agent working in this repository.

---

## Architecture Overview

The repository is modularized into distinct Zig packages and C shims:

- `src/core/`: Project document model (`.openscreen` / `AxcutDocument`), JSON schema serialization, timeline math, i18n localization (17 locales with bidirectional Arabic RTL support).
- `src/capture/`: Cross-platform capture orchestration (`CaptureSession`), stream synchronization, monotonic timestamp alignment, pause/resume excision, `.cursor.jsonl` writer.
  - `src/capture/shims/`: OS-native C-ABI shims for ScreenCaptureKit (macOS), Windows Graphics Capture / WASAPI (Windows), PipeWire / X11 (Linux).
- `src/compositor/`: Hardware-accelerated multi-track video compositor backed by `wgpu-native` with automatic CPU fallback. Golden-pixel tested with SSIM $\ge 0.98$.
- `src/media/`: Audio/video decoders, encoders, Whisper STT integration (`whisper.cpp`), and ONNX Runtime background segmentation.
- `src/cli/`: Headless CLI dispatch, argument parsing, project manipulation, and JSON-RPC 2.0 / Model Context Protocol (MCP) server.
- `src/ui/`: Immediate-mode native desktop GUI (`DVUI`), window management, floating HUD, editor shell, timeline tracks, true-type font rasterization (`stb_truetype`), and RTL cursive shaper.
- `src/ffi/`: 100% Zig 0.17 manual C-ABI bindings (NO `@cImport`).

---

## Core Development Principles & Invariants

1. **Strict C-ABI Declarations (No `@cImport`):**
   - Never use `@cImport` in Zig code. All C library functions, structs, and enums must be manually declared using `extern "c" fn`, `extern struct`, and enum types in `src/ffi/`.
2. **Zero Memory Leaks:**
   - Every allocation must be paired with a deallocation. All tests in `tests/` and test runners run against `std.testing.allocator`, which asserts zero leaks on exit.
3. **Strict `stdout` Hygiene in CLI / MCP Modes:**
   - When running CLI commands with `--json` or running `openscreen mcp`, `stdout` is strictly reserved for valid JSON / NDJSON / JSON-RPC lines.
   - Any diagnostic messages, FFmpeg logs (`av_log`), Whisper logs, or warnings must be directed to `stderr`.
4. **Content Protection Integrity:**
   - Floating recording HUD and privacy overlays must be excluded from screen recordings (`NSWindowSharingNone`, `WDA_EXCLUDEFROMCAPTURE`, window ID exclusion).
   - In environments where `OPENSCREEN_DISABLE_CONTENT_PROTECTION=1` is set (e.g. computer-use UI testing), log `[content-protection] OFF` to `stderr`.
5. **Headless Execution Compatibility:**
   - Headless CLI and MCP server must never initialize display handles, X11 connections, or window contexts.
   - Set `OPENSCREEN_TEST_HEADLESS=1` in automated environments.

---

## Inner Loop Commands

```bash
# Verify formatting across all Zig files
zig fmt --check build.zig build.zig.zon src/ tests/ tools/

# Build project in ReleaseSafe and ReleaseFast
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast

# Validate all 17 locale files
zig build i18n-check

# Run unit tests (memory leak verification)
zig build test

# Run offscreen UI test suite (<16.6ms frame budget, RTL shaping, 0 overlaps)
zig build test-ui

# Run golden pixel render tests (SSIM >= 0.98)
zig build test-golden

# Run end-to-end integration tests (CLI, MCP server, export)
zig build test-e2e

# Render visual proof screenshot artifacts
zig build render-screenshots
```

---

## Continuous Integration Structure

- **Tier 1 CI (`.github/workflows/ci.yml`):**
  - Runs on every push and PR across **Ubuntu 24.04**, **Windows Server 2025**, and **macOS 15 Sequoia**.
  - Exercises full headless tests, unit tests, golden tests (WARP / CPU fallback), E2E subprocess tests, and visual proof screenshot generation.
- **Tier 2 Hardware E2E (`.github/workflows/hardware-e2e.yml`):**
  - Triggered on tags (`v*.*.*`) or manual workflow dispatch on self-hosted machines with real display, webcam, and hardware encoders (`VideoToolbox`, `NVENC`, `VAAPI`).
