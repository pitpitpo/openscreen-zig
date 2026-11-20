# OpenScreen Parity Specification (Ground-Truth Contracts)

This document establishes the authoritative, mathematically exact specification for `openscreen-zig`, extracted directly from the upstream reference implementation (`.reference/`). Every subsystem, data structure, mathematical formula, uniform layout, and interface defined here must be implemented in Zig 0.17 without omission or stub.

---

## 1. Document Model (`.openscreen`) & Schemas

### 1.1 Schema Versions & Top-Level Document
The current document schema version is **`schemaVersion: 9`**.

```json
{
  "schemaVersion": 9,
  "project": {
    "id": "uuid-v4",
    "title": "string",
    "createdAt": "ISO-8601 string",
    "updatedAt": "ISO-8601 string",
    "primaryAssetId": "uuid-v4 (optional)"
  },
  "assets": [
    {
      "id": "uuid-v4",
      "kind": "video" | "audio" | "image",
      "originalPath": "string (filesystem path)",
      "cameraTrack": "string (optional filesystem path to webcam video)",
      "durationSec": 12.34,
      "width": 1920,
      "height": 1080,
      "fps": 60.0
    }
  ],
  "transcripts": [
    {
      "assetId": "uuid-v4",
      "language": "en",
      "words": [
        {
          "word": "Hello",
          "startSec": 0.5,
          "endSec": 0.8,
          "confidence": 0.98
        }
      ],
      "silences": [
        {
          "startSec": 1.2,
          "endSec": 2.5,
          "durationSec": 1.3
        }
      ]
    }
  ],
  "timeline": {
    "clips": [
      {
        "id": "clip-uuid",
        "assetId": "uuid-v4",
        "sourceStartSec": 0.0,
        "sourceEndSec": 10.0,
        "timelineStartSec": 0.0
      }
    ],
    "trimRanges": [
      {
        "id": "trim-uuid",
        "clipId": "clip-uuid",
        "startSec": 0.0,
        "endSec": 1.2
      }
    ],
    "speedRanges": [
      {
        "id": "speed-uuid",
        "clipId": "clip-uuid",
        "startSec": 3.0,
        "endSec": 5.0,
        "speed": 2.0
      }
    ]
  },
  "zoomRanges": [
    {
      "id": "zoom-uuid",
      "clipId": "clip-uuid",
      "startSec": 2.0,
      "endSec": 6.0,
      "depth": 3,
      "customScale": null,
      "focus": { "cx": 0.5, "cy": 0.4 },
      "focusMode": "manual" | "auto-cursor",
      "rotation": "flat" | "left" | "right" | "iso"
    }
  ],
  "annotations": [
    {
      "id": "ann-uuid",
      "clipId": "clip-uuid",
      "startSec": 1.0,
      "endSec": 4.0,
      "type": "text" | "arrow" | "image" | "blur",
      "content": "string",
      "position": { "x": 10.0, "y": 20.0 },
      "size": { "width": 30.0, "height": 10.0 },
      "style": {
        "fontSize": 24,
        "color": "#ffffff",
        "backgroundColor": "rgba(0,0,0,0.6)",
        "borderRadius": 8,
        "padding": 12,
        "animation": "none" | "fade" | "typewriter" | "slide-up"
      },
      "arrow": {
        "direction": "up" | "down" | "left" | "right",
        "color": "#ff3b30",
        "thickness": 6.0
      },
      "blur": {
        "shape": "rectangle" | "oval" | "polygon",
        "kind": "gaussian" | "mosaic",
        "radius": 16.0,
        "polygonPoints": [{ "x": 0.1, "y": 0.2 }]
      }
    }
  ],
  "layoutRegions": [
    {
      "id": "layout-uuid",
      "clipId": "clip-uuid",
      "startSec": 0.0,
      "endSec": 10.0,
      "preset": "picture-in-picture" | "dual-frame" | "vertical-stack" | "no-webcam" | "camera-only"
    }
  ],
  "legacyEditor": {
    "wallpaper": "/wallpapers/wallpaper11.jpg",
    "wallpaperMotion": "none" | "drift" | "aurora" | "waves",
    "frame": "none" | "window" | "laptop" | "phone" | "monitor",
    "frameTheme": "light" | "dark",
    "aspectRatio": "auto" | "16:9" | "9:16" | "1:1" | "4:3" | "4:5" | "16:10" | "10:16",
    "shadowIntensity": 0.6,
    "backgroundBlur": 0.0,
    "motionBlurAmount": 0.2,
    "depthOfField": true,
    "borderRadius": 40.0,
    "padding": 50.0,
    "webcamLayoutPreset": "picture-in-picture",
    "webcamMaskShape": "square" | "rectangle",
    "webcamRoundness": 0.7,
    "webcamMirrored": false,
    "webcamReactiveZoom": true,
    "webcamSizePreset": 40.0,
    "webcamShadowIntensity": 0.6,
    "webcamAnchor": "bottom-right",
    "webcamBackgroundMode": "none" | "transparent" | "blur" | "custom",
    "webcamWallpaper": "/wallpapers/wallpaper11.jpg",
    "webcamBlurIntensity": 0.5,
    "cursor": {
      "size": 3.6,
      "smoothing": 0.3,
      "motionBlur": 0.35,
      "clickBounce": 1.0,
      "model3d": false,
      "asArrow": ["text", "grab", "resize", "busy", "crosshair", "not-allowed", "help", "up-arrow"],
      "clickImpact": false,
      "clickSound": false,
      "clickSoundGainDb": 0.0,
      "autoHide": false
    },
    "cursorShow": true,
    "cursorTheme": "default"
  }
}
```

### 1.2 Setting Bounds Table
All numerical properties are strictly clamped to `SETTING_BOUNDS`:
- `shadowIntensity`: `[0.0, 1.0]` (default 0.6)
- `webcamShadowIntensity`: `[0.0, 1.0]` (default 0.6)
- `backgroundBlur`: `[0.0, 1.0]` (default 0.0)
- `motionBlurAmount`: `[0.0, 1.0]` (default 0.2)
- `borderRadius`: `[0.0, 64.0]` (default 40.0)
- `padding`: `[0.0, 100.0]` (default 50.0)
- `webcamSizePreset`: `[15.0, 60.0]` (default 40.0)
- `webcamRoundness`: `[0.0, 1.0]` (default: 0.7 for square, 0.4 for rectangle)
- `webcamBlurIntensity`: `[0.0, 1.0]` (default 0.5)
- `cursorSize`: `[1.5, 6.0]` (default 3.6)
- `cursorSmoothing`: `[0.0, 1.0]` (default 0.3)
- `cursorMotionBlur`: `[0.0, 1.0]` (default 0.35)
- `cursorClickBounce`: `[0.0, 2.0]` (default 1.0)
- `cursorClickSoundGainDb`: `[-24.0, 0.0]` (default 0.0)
- `playbackSpeed`: `[0.25, 16.0]`
- `annotationFontSize`: `[8.0, 200.0]` (default 24.0)

### 1.3 Forward-Only Migrations
- **Legacy v2 → v4 Draft → v9**: Reads `{ version: 2, media: { screenVideoPath, webcamVideoPath }, editor }`. Single clip minted, kept ranges in `trimRegions` inverted to source-anchored `timeline.trimRanges`.
- **v3 → v4**: Lifts project-level `cameraTrack` onto primary asset.
- **v4 → v5**: Anchors zooms, annotations, speed regions, and camera fullscreen to individual clips with `sourceStartSec`/`sourceEndSec`.
- **v5 → v6**: Bakes `"native"` AspectRatio into concrete `"W:H"` token when source dimensions are known.
- **v6 → v7**: Anchors trims to clip (`clipId`), ventilating spans across multiple clips sharing an asset.
- **v7 → v8**: Pins missing `legacyEditor.aspectRatio` to `"16:9"` so documents created before Auto default do not re-shape.
- **v8 → v9**: Converts full camera envelopes to `camera-only` layout regions in `layoutRegions[]`.

---

## 2. Cursor Telemetry & Mathematical Physics

### 2.1 Sidecar File Format (`.cursor.json` / `.cursor.jsonl`)
The sidecar records pointer events sampled during capture:
- Monotonic timestamp `timeMs: f64` relative to take start (0.0 ms).
- Normalized position `cx: f32`, `cy: f32` clamped to `[0.0, 1.0]` (0,0 is top-left of source capture).
- Visibility `visible: bool`.
- Interaction type `interactionType`: `"move"`, `"click"`, `"double-click"`, `"right-click"`, `"middle-click"`, `"mouseup"`.
- Button state `button`: 0 (none), 1 (left), 2 (right), 4 (middle).
- Cursor shape: `"default"`, `"pointer"`, `"text"`, `"crosshair"`, `"grab"`, `"grabbing"`, `"resize-ns"`, `"resize-ew"`, `"not-allowed"`, `"help"`.

### 2.2 Spring-Damper Cursor Smoothing (Semi-Implicit Symplectic Euler)
Smoothing is evaluated deterministically at a fixed simulation rate of **240 Hz** (`STEP_S = 1.0 / 240.0`):
$$\text{accel} = \frac{-k \cdot (x - x_{\text{target}}) - c \cdot v}{m}$$
$$v \mathrel{+}= \text{accel} \cdot \Delta t$$
$$x \mathrel{+}= v \cdot \Delta t$$

Where spring configuration $(k, c, m)$ is derived piecewise from user setting $s \in [0.0, 2.0]$:
1. If $s \le 0.0$:
   $$k = 1000.0, \quad c = 100.0, \quad m = 1.0$$
2. If $s \le 0.5$ (normalized $\hat{s} = s / 0.5$):
   $$k = 760.0 - 420.0 \cdot \hat{s}$$
   $$c = 34.0 + 24.0 \cdot \hat{s}$$
   $$m = 0.55 + 0.45 \cdot \hat{s}$$
3. If $s > 0.5$ (normalized $\hat{s} = (s - 0.5) / 1.5$):
   $$k = 340.0 - 180.0 \cdot \hat{s}$$
   $$c = 58.0 + 22.0 \cdot \hat{s}$$
   $$m = 1.0 + 0.35 \cdot \hat{s}$$

### 2.3 Click Bounce Physics
On click down, cursor scale undergoes a decaying oscillation:
$$\text{scale}(t) = 1.0 - \text{bounce} \cdot 0.35 \cdot \cos(2\pi \cdot 6.0 \cdot t) \cdot e^{-12.0 \cdot t}$$
where $t$ is time since click in seconds, active for $t \in [0.0, 0.35]$ s.

---

## 3. Auto-Zoom & Easing Specification

### 3.1 Auto-Zoom Planner Parameters
- `OPENING_WIDE_MS = 2500.0`: No zoom begins before this.
- `CLOSING_WIDE_MS = 1000.0`: Last zoom is fully restored before end.
- `STOP_CLICK_GUARD_MS = 1000.0`: Ignores clicks within 1s of stop.
- `SHOT_MERGE_GAP_MS = 3000.0`: Clicks within 3s cluster into one shot.
- `SHOT_LEAD_MS = 500.0`: Zoom is fully in 500ms before first click.
- `SHOT_TAIL_MS = 1500.0`: Zoom holds 1500ms after last click.
- `MIN_SHOT_HOLD_MS = 1800.0`: Minimum hold duration.
- `MIN_WIDE_BETWEEN_MS = 1500.0`: Minimum wide gap between zooms to avoid yo-yo.
- `SHOT_FIT_MARGIN = 0.12`: Margin around click clusters.

### 3.2 Zoom Depths & Scales
| Depth Ordinal | Scale Factor | Field of View Coverage |
| :---: | :---: | :---: |
| **1** | **1.25×** | 80% width / height |
| **2** | **1.50×** | 66.7% |
| **3** (default) | **1.80×** | 55.5% |
| **4** | **2.20×** | 45.4% |
| **5** | **3.50×** | 28.5% |
| **6** | **5.00×** | 20.0% |

### 3.3 Dynamic Zoom Transition Durations
$$\text{duration}(S) = 600.0 + 550.0 \cdot \ln(\max(1.0, S)) \quad \text{[ms]}$$
- At 1.25×: ~722 ms
- At 1.80×: ~923 ms
- At 5.00×: ~1485 ms
- Chained pan gap threshold: `1500 ms`
- Connected pan duration: `1000 ms`

### 3.4 Easing Functions
1. **Critical Spring Rise (`ease_spring`, no bounce overshoot):**
   $$\Omega = 7.0$$
   $$x = \Omega \cdot \text{clamp}_{0,1}(t)$$
   $$\text{end} = 1.0 - (1.0 + \Omega) \cdot e^{-\Omega}$$
   $$\text{ease\_spring}(t) = \frac{1.0 - (1.0 + x) \cdot e^{-x}}{\text{end}}$$

2. **Connected Pan (`ease_connected_pan`):**
   $$\text{cubic\_bezier}(0.10, 0.00, 0.20, 1.00, t)$$

3. **Screen Studio Ease-Out (`ease_out_screen_studio`):**
   $$\text{cubic\_bezier}(0.16, 1.00, 0.30, 1.00, t)$$

4. **Logarithmic Scale Interpolation:**
   $$\text{scale\_lerp}(a, b, t) = a \cdot \left(\frac{b}{a}\right)^t$$

---

## 4. Unified GPU & CPU Compositor Specification

### 4.1 WGSL Layer Uniform Layout (Exact 192-byte struct)
All backends share the identical C-ABI and WGSL uniform layout:

```rust
struct Layer {
    dst: vec4<f32>,       // [x, y, w, h] in output normalized coordinates (0..1)
    src: vec4<f32>,       // [u0, v0, u1, v1] in source texture normalized coordinates
    quad_px: vec2<f32>,   // Output quad size in physical pixels (for isotropic SDFs)
    radius_px: f32,       // Corner radius in pixels
    mode: f32,            // Rasterization mode enum (0.0 through 18.0)
    color: vec4<f32>,     // Primary color, tint, or mode-specific parameters
    fx: vec4<f32>,        // Shadow spread, animation uniforms, or 3D corners TL, TR
    src_prev: vec4<f32>,  // 3D corners BR, BL or arrow barb 1
    dst_prev: vec4<f32>,  // 3D plan dims, title bar height, or clip rect
    mb: vec4<f32>,        // Motion blur taps/strength, DoF parameters [gx, gy, z_focus, k]
    trail_a: vec4<f32>,   // Motion trail previous frame corners TL, TR
    trail_b: vec4<f32>,   // Motion trail previous frame corners BR, BL
    trail_mb: vec4<f32>,  // Motion trail blur parameters
};
```

### 4.2 Compositor Modes
- `0`: NV12 YUV video plane (BT.709 limited color matrix) with rounded corners and motion blur.
- `1`: Solid color / UI rectangle with rounded corners and border.
- `2`: Drop shadow with Gaussian feathering.
- `5`: Procedural animated backgrounds (0: solid, 1: gradient, 2: drift, 3: aurora, 4: waves).
- `8`: 3D perspective-tilted screen with bilateral lighting and Depth of Field.
- `9`: Vector annotation arrow with rounded tips.
- `10`: Privacy blur region (Gaussian or mosaic) with rectangular, oval, or polygon mask.
- `12`: Projected 3D drop shadow quad.
- `13`: Tilted 3D cursor quad.
- `14`: Native window frame chrome (title bar, window control buttons).
- `15`: Modelled 3D cursor with ray-traced ambient occlusion and thickness bevel.
- `16`: Click impact ripple wave.
- `17`: Modelled 3D device frame (Laptop, Phone, Monitor).
- `18`: Multi-pass framed screen composite.

### 4.3 3D Camera Angles
Presets for zoom 3D rotation $[R_x, R_y, R_z]$ in degrees:
- **Left / Iso:** `[-12.0°, -18.0°, -2.0°]`
- **Right:** `[-12.0°, 18.0°, 2.0°]`
- **Flat:** `[0.0°, 0.0°, 0.0°]`
Depth of Field max LOD: `1.5`.

---

## 5. Headless CLI Contract

### 5.1 Subcommands & Options
1. `openscreen sources [--json]`
2. `openscreen record [--display <n> | --window <title>] [--mic] [--system-audio] [--camera] [--cursor <editable-overlay|system>] [--duration <sec>] --project <out.openscreen> [--json]`
3. `openscreen captions <project.openscreen> [--min-words <n>] [--max-words <n>] [--language <iso>] [--json]`
4. `openscreen edit <project.openscreen> ...`
5. `openscreen export <project.openscreen> -o <out.mp4|out.gif> [--resolution 720p|1080p|source] [--fps 24|30|60] [--aspect ...] [--auto-zoom] [--audio <file>] [--audio-mode mix|replace] [--json]`
6. `openscreen pack <project.openscreen> -o <bundle.openscreen>`
7. `openscreen info <project.openscreen> [--json]`
8. `openscreen mcp` (stdio MCP server)

### 5.2 NDJSON Stream Schemas (`--json`)
Every event is an atomic line:
```json
{"event":"progress","phase":"render","current":120,"total":360,"percent":33.3,"fps":58.2}
{"event":"status","message":"Probing hardware H.264 encoder"}
{"event":"done","outputPath":"/path/to/out.mp4","durationSec":6.0,"fileSizeBytes":2415920}
{"event":"error","code":"ERR_CAPTURE_DENIED","message":"Screen capture permission was denied by OS"}
```

Exit codes:
- `0`: Success
- `1`: Operational error (missing file, capture failed)
- `2`: Bad arguments / CLI validation error

---

## 6. Local MCP Server Contract (`openscreen mcp`)

Protocol: JSON-RPC 2.0 over standard I/O (`stdin`/`stdout`).
Registered Tools:
1. `listProjects`: Enumerates local projects.
2. `listSources`: Lists screens and windows available for capture.
3. `startRecording`: Begins capture session.
4. `stopRecording`: Finalizes capture and returns project metadata.
5. `waitForRecording`: Awaits fixed-duration take.
6. `setPointerTrack`: Injects or overrides `.cursor.jsonl` telemetry.
7. `exportVideo`: Triggers headless MP4/GIF export.
8. `exportAudio`: Extracts mixed audio track.
9. `getFrames`: **Extracts rendered frames at arbitrary timestamp as P6 PPM or PNG** for frame-by-frame visual verification by external agents.
10. `createProject`: Initializes new empty or media-linked `.openscreen` project.
11. `transcribe`: Runs local Whisper transcription.
12. `createCheckpoint` / `restoreCheckpoint`: Atomic undoable checkpointing.
13. `setProjectInfo`: Updates title/metadata.
14. `importMedia` / `removeMedia`: Modifies asset list.
15. `getCurrentDocument`: Inspects full `AxcutDocument`.
16. `setEditorSettings`: Configures appearance, cursor, wallpapers, framing.
17. `setAspectRatio`: Updates frame aspect ratio.
18. `replaceTimeline`: Modifies clip layout.
19. `addAutoZooms`: Executes click-driven auto-zoom planner over document clicks.
20. `addZoom` / `removeZoom`: Programmatic zoom region editing.
21. `addAnnotation` / `removeAnnotation`: Overlays editing.
22. `addSpeedRegion` / `removeSpeedRegion`: Speed ramp editing.
23. `addEffect` / `removeEffect`: Custom shader effect editing.
24. `getCaptions` / `setCaptionSettings` / `getCaptionTranslationUnits` / `putCaptionTranslation`: Subtitle tools.

---

## 7. Native Capture Shims Contract (`capture_shim.h`)

All OS capture implementations link through a unified C ABI:

```c
typedef struct {
    uint32_t width;
    uint32_t height;
    double fps;
    bool has_audio;
    bool has_webcam;
} CaptureConfig;

typedef struct {
    int64_t timestamp_ns;
    const uint8_t* y_plane;
    const uint8_t* uv_plane;
    uint32_t stride_y;
    uint32_t stride_uv;
    uint32_t width;
    uint32_t height;
} VideoFrame;

typedef struct {
    int64_t timestamp_ns;
    double cx;
    double cy;
    bool visible;
    uint32_t button_mask;
    const char* cursor_shape;
} CursorSample;

typedef void (*VideoFrameCallback)(const VideoFrame* frame, void* user_data);
typedef void (*CursorSampleCallback)(const CursorSample* sample, void* user_data);
typedef void (*AudioPcmCallback)(const float* samples, uint32_t frame_count, uint32_t channels, void* user_data);

typedef struct CaptureSession CaptureSession;

CaptureSession* capture_session_create(const CaptureConfig* config);
int capture_session_start(CaptureSession* session, VideoFrameCallback on_video, CursorSampleCallback on_cursor, AudioPcmCallback on_audio, void* user_data);
void capture_session_pause(CaptureSession* session);
void capture_session_resume(CaptureSession* session);
int capture_session_stop(CaptureSession* session);
void capture_session_destroy(CaptureSession* session);
```

- **macOS (`macos_sck.m`):** Implements `ScreenCaptureKit` + `SCContentFilter` with HUD exclusion + `CGEventTap` for cursor sidecar.
- **Windows (`win_wgc.cpp`):** Implements Windows Graphics Capture + WASAPI loopback + Win32 low-level mouse hook + `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`.
- **Linux (`linux_pw.c`):** Implements `xdg-desktop-portal` ScreenCast over PipeWire + X11 `XShm`/`XFixes` fallback + `evdev`/XInput2.
