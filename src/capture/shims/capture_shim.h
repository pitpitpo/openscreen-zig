#ifndef OPENSCREEN_CAPTURE_SHIM_H
#define OPENSCREEN_CAPTURE_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Capture source types */
enum {
    OSC_SOURCE_DISPLAY    = 0,
    OSC_SOURCE_WINDOW     = 1,
    OSC_SOURCE_MICROPHONE = 2,
    OSC_SOURCE_WEBCAM     = 3
};

/* Permissions */
enum {
    OSC_PERMISSION_SCREEN = 0,
    OSC_PERMISSION_AUDIO  = 1,
    OSC_PERMISSION_CAMERA = 2
};

enum {
    OSC_PERMISSION_STATUS_NOT_DETERMINED = 0,
    OSC_PERMISSION_STATUS_RESTRICTED     = 1,
    OSC_PERMISSION_STATUS_DENIED         = 2,
    OSC_PERMISSION_STATUS_GRANTED        = 3
};

/* Pixel formats */
enum {
    OSC_PIX_FMT_RGBA = 0,
    OSC_PIX_FMT_NV12 = 1,
    OSC_PIX_FMT_BGRA = 2,
    OSC_PIX_FMT_YUYV = 3
};

/* Cursor shapes */
enum {
    OSC_CURSOR_DEFAULT   = 0,
    OSC_CURSOR_POINTER   = 1,
    OSC_CURSOR_IBEAM     = 2,
    OSC_CURSOR_CROSSHAIR = 3,
    OSC_CURSOR_HAND      = 4,
    OSC_CURSOR_RESIZE    = 5
};

/* Mouse buttons */
enum {
    OSC_MOUSE_NONE   = 0,
    OSC_MOUSE_LEFT   = 1,
    OSC_MOUSE_RIGHT  = 2,
    OSC_MOUSE_MIDDLE = 3
};

/* Mouse event types */
enum {
    OSC_MOUSE_EVENT_MOVE   = 0,
    OSC_MOUSE_EVENT_DOWN   = 1,
    OSC_MOUSE_EVENT_UP     = 2,
    OSC_MOUSE_EVENT_SCROLL = 3
};

/* Capture source descriptor */
typedef struct {
    char id[256];
    char name[256];
    int type;
    uint32_t width;
    uint32_t height;
    int is_primary;
} OscCaptureSourceInfo;

/* Cursor and click event */
typedef struct {
    int64_t timestamp_ns;
    float x; // Normalized 0.0 .. 1.0 (relative to captured display)
    float y; // Normalized 0.0 .. 1.0
    int32_t raw_x;
    int32_t raw_y;
    int shape;
    int event_type;
    int button;
    float scroll_dx;
    float scroll_dy;
} OscCursorEvent;

/* Frame and telemetry callbacks */
typedef void (*OscScreenFrameCallback)(
    const uint8_t *data,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    int format,
    int64_t pts_ns,
    void *user_data
);

typedef void (*OscWebcamFrameCallback)(
    const uint8_t *data,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    int format,
    int64_t pts_ns,
    void *user_data
);

typedef void (*OscAudioFrameCallback)(
    int is_system,
    const float *pcm_samples,
    uint32_t num_samples,
    uint32_t sample_rate,
    uint32_t channels,
    int64_t pts_ns,
    void *user_data
);

typedef void (*OscCursorEventCallback)(
    const OscCursorEvent *event,
    void *user_data
);

/* Configuration struct */
typedef struct {
    char display_id[256];
    char window_id[256];
    char mic_id[256];
    char webcam_id[256];
    uint32_t target_fps;
    int capture_cursor;
    int capture_webcam;
    int capture_system_audio;
    int capture_mic_audio;

    OscScreenFrameCallback on_screen_frame;
    OscWebcamFrameCallback on_webcam_frame;
    OscAudioFrameCallback on_audio_frame;
    OscCursorEventCallback on_cursor_event;
    void *user_data;
} OscCaptureConfig;

/* Opaque capture handle */
typedef struct OscCaptureHandle OscCaptureHandle;

/* Public API */
int osc_capture_enumerate_sources(int type, OscCaptureSourceInfo *out_sources, int max_sources);
int osc_capture_check_permission(int type);
int osc_capture_request_permission(int type);

OscCaptureHandle *osc_capture_create(const OscCaptureConfig *config);
int osc_capture_start(OscCaptureHandle *handle);
int osc_capture_pause(OscCaptureHandle *handle);
int osc_capture_resume(OscCaptureHandle *handle);
int osc_capture_stop(OscCaptureHandle *handle);
void osc_capture_destroy(OscCaptureHandle *handle);

int osc_capture_set_excluded_windows(OscCaptureHandle *handle, const char **window_ids, int count);
int osc_capture_get_normalized_cursor(OscCaptureHandle *handle, int raw_x, int raw_y, float *out_nx, float *out_ny);

#ifdef __cplusplus
}
#endif

#endif /* OPENSCREEN_CAPTURE_SHIM_H */
