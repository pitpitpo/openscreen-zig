# OpenScreen Manual & Hardware E2E Verification Checklist

This document tracks manual and hardware-in-the-loop (Tier 2) validation procedures for OpenScreen releases across Linux, Windows, and macOS.

## Test Environment Matrix

| Platform | Display Capture | Audio Capture | GPU Compositor | HW Encoder | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **macOS 14+** | ScreenCaptureKit | System Audio + Mic | Metal (wgpu) | VideoToolbox (H.264) | Verified |
| **Windows 10/11** | WinRT WGC | WASAPI Loopback + Mic | D3D12 / WARP | NVENC / QSV / AMF | Verified |
| **Linux (Ubuntu 24.04)** | PipeWire / X11 | PulseAudio / ALSA | Vulkan / CPU Fallback | VAAPI / Software | Verified |

---

## Interactive QA Test Cases

### 1. Launch & Single-Instance Lock
- [ ] Launch `openscreen` without arguments: verify main editor window opens at native display DPI.
- [ ] Attempt secondary launch: verify secondary process exits `0` and primary window is focused.
- [ ] Launch with `--test-gui-smoke`: verify clean headless/offscreen event loop termination with code `0`.

### 2. Floating Recording HUD & Window Controls
- [ ] Click "Record" in Editor: verify borderless floating HUD appears on active monitor.
- [ ] Verify HUD is always-on-top (`NSFloatingWindowLevel`, `WS_EX_TOPMOST`, `_NET_WM_STATE_ABOVE`).
- [ ] Verify Content Protection:
  - macOS: `[window setSharingType:NSWindowSharingNone]` (recording ignores HUD).
  - Windows: `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` (recording ignores HUD).
  - Linux: Window ID excluded from capture pipeline.
  - Environment override: Set `OPENSCREEN_DISABLE_CONTENT_PROTECTION=1` -> verify `[content-protection] OFF` in stderr.
- [ ] Toggle Notes window from HUD: verify independent draggable notes scratchpad.

### 3. Screen, Audio & Webcam Capture
- [ ] Record a 10-second segment with screen, mic, and system audio loopback enabled.
- [ ] Verify pause and resume: verify pause duration is cleanly excised with 0 A/V drift.
- [ ] Stop capture: verify valid `.openscreen` bundle created containing `screen.mp4`, `mic.wav`, `system.wav`, and `.cursor.jsonl`.
- [ ] Verify `cursor-diag` parses `.cursor.jsonl` with coordinates, clicks, and OS cursor shape IDs.

### 4. Interactive Editor & Canvas Navigation
- [ ] Pan canvas with Middle-Click or Space+Drag.
- [ ] Zoom canvas with Ctrl+MouseWheel.
- [ ] Scrub timeline with mouse click/drag; verify immediate visual preview update.
- [ ] Snap PiP webcam to all 8 snap positions (TL, TC, TR, LC, RC, BL, BC, BR).
- [ ] Apply Freehand Polygon blur and verify preview obscuration.
- [ ] Verify Off-Menu effects (Flyout Left/Right).

### 5. Multi-Language & RTL Layout
- [ ] Switch UI language to Arabic (`ar`): verify layout mirrors cleanly (RTL).
- [ ] Verify Arabic cursive shaping (Presentation Forms-B mapping) renders properly connected characters.
- [ ] Verify CJK glyph rendering for Chinese, Japanese, and Korean text.

### 6. Subtitles & Background Transcription
- [ ] Trigger audio transcription: verify background `std.Thread` worker starts without dropping UI frames below 60 fps.
- [ ] Verify atomic progress bar updates in real time.
- [ ] Verify cancel button stops transcription cleanly.

### 7. Export Pipeline
- [ ] Export video to 1080p 60fps MP4.
- [ ] Verify with `ffprobe`: assert video stream is `h264`, audio stream is `aac`, and duration matches timeline.

---

## Tier 2 Hardware CI Execution Log

- **Run 44774909628**: macOS passed with encoder h264_videotoolbox
- **Run 44774909628**: Windows passed with encoder h264_nvenc
- **Run 44774909628**: Linux passed with encoder h264_vaapi
