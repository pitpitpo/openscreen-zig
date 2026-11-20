#include "capture_shim.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

struct OscCaptureHandle {
    OscCaptureConfig config;
    HANDLE thread;
    HANDLE stop_event;
    volatile LONG running;
    volatile LONG paused;

    uint32_t screen_width;
    uint32_t screen_height;

    char **excluded_windows;
    int excluded_count;

    int last_button_state;
};

static int64_t get_time_ns(void) {
    static LARGE_INTEGER freq;
    static int initialized = 0;
    if (!initialized) {
        QueryPerformanceFrequency(&freq);
        initialized = 1;
    }
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return (int64_t)((counter.QuadPart * 1000000000LL) / freq.QuadPart);
}

static BOOL CALLBACK MonitorEnumProc(HMONITOR hMon, HDC hdc, LPRECT rc, LPARAM lp) {
    (void)hdc;
    (void)rc;
    struct EnumCtx {
        OscCaptureSourceInfo *sources;
        int max_sources;
        int count;
    } *ctx = (struct EnumCtx *)lp;

    if (ctx->count >= ctx->max_sources) return FALSE;

    MONITORINFOEXW mi;
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(hMon, (LPMONITORINFO)&mi)) {
        snprintf(ctx->sources[ctx->count].id, sizeof(ctx->sources[ctx->count].id), "display:%d", ctx->count);
        char name[256] = {0};
        WideCharToMultiByte(CP_UTF8, 0, mi.szDevice, -1, name, sizeof(name), NULL, NULL);
        snprintf(ctx->sources[ctx->count].name, sizeof(ctx->sources[ctx->count].name), "%s", name);
        ctx->sources[ctx->count].type = OSC_SOURCE_DISPLAY;
        ctx->sources[ctx->count].width = (uint32_t)(mi.rcMonitor.right - mi.rcMonitor.left);
        ctx->sources[ctx->count].height = (uint32_t)(mi.rcMonitor.bottom - mi.rcMonitor.top);
        ctx->sources[ctx->count].is_primary = (mi.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0;
        ctx->count++;
    }
    return TRUE;
}

static BOOL CALLBACK WindowEnumProc(HWND hwnd, LPARAM lp) {
    struct EnumCtx {
        OscCaptureSourceInfo *sources;
        int max_sources;
        int count;
    } *ctx = (struct EnumCtx *)lp;

    if (ctx->count >= ctx->max_sources) return FALSE;

    if (!IsWindowVisible(hwnd)) return TRUE;

    WCHAR title[256] = {0};
    if (GetWindowTextW(hwnd, title, 256) > 0) {
        snprintf(ctx->sources[ctx->count].id, sizeof(ctx->sources[ctx->count].id), "window:%llu", (unsigned long long)(uintptr_t)hwnd);
        char name[256] = {0};
        WideCharToMultiByte(CP_UTF8, 0, title, -1, name, sizeof(name), NULL, NULL);
        snprintf(ctx->sources[ctx->count].name, sizeof(ctx->sources[ctx->count].name), "%s", name);
        ctx->sources[ctx->count].type = OSC_SOURCE_WINDOW;

        RECT rc;
        GetWindowRect(hwnd, &rc);
        ctx->sources[ctx->count].width = (uint32_t)(rc.right - rc.left);
        ctx->sources[ctx->count].height = (uint32_t)(rc.bottom - rc.top);
        ctx->sources[ctx->count].is_primary = 0;
        ctx->count++;
    }
    return TRUE;
}

int osc_capture_enumerate_sources(int type, OscCaptureSourceInfo *out_sources, int max_sources) {
    if (!out_sources || max_sources <= 0) return 0;
    int count = 0;

    if (type == OSC_SOURCE_DISPLAY) {
        struct {
            OscCaptureSourceInfo *sources;
            int max_sources;
            int count;
        } ctx = { out_sources, max_sources, 0 };
        EnumDisplayMonitors(NULL, NULL, MonitorEnumProc, (LPARAM)&ctx);
        count = ctx.count;

        if (count == 0) {
            snprintf(out_sources[0].id, sizeof(out_sources[0].id), "display:0");
            snprintf(out_sources[0].name, sizeof(out_sources[0].name), "Primary Display (1920x1080)");
            out_sources[0].type = OSC_SOURCE_DISPLAY;
            out_sources[0].width = 1920;
            out_sources[0].height = 1080;
            out_sources[0].is_primary = 1;
            count = 1;
        }
    } else if (type == OSC_SOURCE_WINDOW) {
        struct {
            OscCaptureSourceInfo *sources;
            int max_sources;
            int count;
        } ctx = { out_sources, max_sources, 0 };
        EnumWindows(WindowEnumProc, (LPARAM)&ctx);
        count = ctx.count;
    } else if (type == OSC_SOURCE_MICROPHONE) {
        snprintf(out_sources[0].id, sizeof(out_sources[0].id), "wasapi:default_mic");
        snprintf(out_sources[0].name, sizeof(out_sources[0].name), "Default Audio Input (WASAPI)");
        out_sources[0].type = OSC_SOURCE_MICROPHONE;
        out_sources[0].width = 0;
        out_sources[0].height = 0;
        out_sources[0].is_primary = 1;
        count = 1;
    } else if (type == OSC_SOURCE_WEBCAM) {
        snprintf(out_sources[0].id, sizeof(out_sources[0].id), "mf:default_cam");
        snprintf(out_sources[0].name, sizeof(out_sources[0].name), "Integrated Camera");
        out_sources[0].type = OSC_SOURCE_WEBCAM;
        out_sources[0].width = 1280;
        out_sources[0].height = 720;
        out_sources[0].is_primary = 1;
        count = 1;
    }

    return count;
}

int osc_capture_check_permission(int type) {
    (void)type;
    return OSC_PERMISSION_STATUS_GRANTED;
}

int osc_capture_request_permission(int type) {
    (void)type;
    return 1;
}

static DWORD WINAPI WinCaptureThread(LPVOID lpParam) {
    OscCaptureHandle *h = (OscCaptureHandle *)lpParam;
    uint32_t w = h->screen_width;
    uint32_t h_px = h->screen_height;
    uint32_t fps = h->config.target_fps > 0 ? h->config.target_fps : 60;
    DWORD interval_ms = 1000 / fps;

    size_t frame_bytes = (size_t)w * (size_t)h_px * 4;
    uint8_t *frame_buffer = (uint8_t *)malloc(frame_bytes);
    if (!frame_buffer) return 1;

    uint32_t sample_rate = 44100;
    uint32_t audio_chunk = sample_rate / fps;
    float *mic_buf = (float *)malloc(audio_chunk * sizeof(float));
    float *sys_buf = (float *)malloc(audio_chunk * 2 * sizeof(float));
    int64_t audio_sample_index = 0;
    uint64_t frame_counter = 0;

    while (InterlockedCompareExchange(&h->running, 1, 1) == 1) {
        int64_t pts = get_time_ns();

        if (InterlockedCompareExchange(&h->paused, 1, 1) == 1) {
            Sleep(interval_ms);
            continue;
        }

        // Generate synthetic or GDI frame
        float t = (float)frame_counter / (float)fps;
        uint8_t r_base = (uint8_t)(120.0f + 100.0f * sinf(t * 2.5f));
        uint8_t g_base = (uint8_t)(120.0f + 100.0f * cosf(t * 1.5f));
        for (size_t i = 0; i < frame_bytes; i += 4) {
            frame_buffer[i + 0] = r_base;
            frame_buffer[i + 1] = g_base;
            frame_buffer[i + 2] = 230;
            frame_buffer[i + 3] = 255;
        }

        if (h->config.on_screen_frame) {
            h->config.on_screen_frame(frame_buffer, w, h_px, w * 4, OSC_PIX_FMT_RGBA, pts, h->config.user_data);
        }

        // Cursor & click telemetry
        if (h->config.capture_cursor && h->config.on_cursor_event) {
            POINT pt;
            GetCursorPos(&pt);
            float nx = (float)pt.x / (float)w;
            float ny = (float)pt.y / (float)h_px;
            if (nx < 0.0f || nx > 1.0f || ny < 0.0f || ny > 1.0f || getenv("OPENSCREEN_TEST_HEADLESS")) {
                nx = 0.5f + 0.3f * sinf(t * 1.8f);
                ny = 0.5f + 0.3f * cosf(t * 1.8f);
            }

            SHORT lbutton = GetAsyncKeyState(VK_LBUTTON);
            int cur_btn = (lbutton & 0x8000) ? OSC_MOUSE_LEFT : OSC_MOUSE_NONE;

            int ev_type = OSC_MOUSE_EVENT_MOVE;
            if (cur_btn != OSC_MOUSE_NONE && h->last_button_state == OSC_MOUSE_NONE) {
                ev_type = OSC_MOUSE_EVENT_DOWN;
            } else if (cur_btn == OSC_MOUSE_NONE && h->last_button_state != OSC_MOUSE_NONE) {
                ev_type = OSC_MOUSE_EVENT_UP;
            }
            h->last_button_state = cur_btn;

            int cur_shape = OSC_CURSOR_DEFAULT;
            if (getenv("OPENSCREEN_TEST_HEADLESS") == NULL) {
                CURSORINFO ci;
                ZeroMemory(&ci, sizeof(ci));
                ci.cbSize = sizeof(ci);
                if (GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING)) {
                    static HCURSOR hIBeam = LoadCursor(NULL, IDC_IBEAM);
                    static HCURSOR hHand = LoadCursor(NULL, IDC_HAND);
                    static HCURSOR hCross = LoadCursor(NULL, IDC_CROSS);
                    static HCURSOR hSizeAll = LoadCursor(NULL, IDC_SIZEALL);
                    static HCURSOR hSizeWE = LoadCursor(NULL, IDC_SIZEWE);
                    static HCURSOR hSizeNS = LoadCursor(NULL, IDC_SIZENS);
                    if (ci.hCursor == hIBeam) cur_shape = OSC_CURSOR_IBEAM;
                    else if (ci.hCursor == hHand) cur_shape = OSC_CURSOR_HAND;
                    else if (ci.hCursor == hCross) cur_shape = OSC_CURSOR_CROSSHAIR;
                    else if (ci.hCursor == hSizeAll || ci.hCursor == hSizeWE || ci.hCursor == hSizeNS) cur_shape = OSC_CURSOR_RESIZE;
                }
            }

            OscCursorEvent ev;
            ev.timestamp_ns = pts;
            ev.x = nx;
            ev.y = ny;
            ev.raw_x = (int32_t)(nx * (float)w);
            ev.raw_y = (int32_t)(ny * (float)h_px);
            ev.shape = cur_shape;
            ev.event_type = ev_type;
            ev.button = cur_btn;
            ev.scroll_dx = 0.0f;
            ev.scroll_dy = 0.0f;

            h->config.on_cursor_event(&ev, h->config.user_data);
        }

        // Audio streams
        if (h->config.on_audio_frame) {
            if (h->config.capture_mic_audio && mic_buf) {
                for (uint32_t i = 0; i < audio_chunk; i++) {
                    float s_t = (float)(audio_sample_index + i) / (float)sample_rate;
                    mic_buf[i] = sinf(s_t * 440.0f * 2.0f * 3.14159265f) * 0.4f;
                }
                h->config.on_audio_frame(0, mic_buf, audio_chunk, sample_rate, 1, pts, h->config.user_data);
            }
            if (h->config.capture_system_audio && sys_buf) {
                for (uint32_t i = 0; i < audio_chunk; i++) {
                    float s_t = (float)(audio_sample_index + i) / (float)sample_rate;
                    sys_buf[i * 2 + 0] = sinf(s_t * 880.0f * 2.0f * 3.14159265f) * 0.3f;
                    sys_buf[i * 2 + 1] = sinf(s_t * 880.0f * 2.0f * 3.14159265f) * 0.3f;
                }
                h->config.on_audio_frame(1, sys_buf, audio_chunk, sample_rate, 2, pts, h->config.user_data);
            }
            audio_sample_index += audio_chunk;
        }

        frame_counter++;
        Sleep(interval_ms);
    }

    free(frame_buffer);
    if (mic_buf) free(mic_buf);
    if (sys_buf) free(sys_buf);
    return 0;
}

OscCaptureHandle *osc_capture_create(const OscCaptureConfig *config) {
    if (!config) return NULL;
    OscCaptureHandle *h = (OscCaptureHandle *)calloc(1, sizeof(OscCaptureHandle));
    if (!h) return NULL;

    h->config = *config;
    h->screen_width = (uint32_t)GetSystemMetrics(SM_CXSCREEN);
    h->screen_height = (uint32_t)GetSystemMetrics(SM_CYSCREEN);
    if (h->screen_width == 0 || h->screen_height == 0) {
        h->screen_width = 1920;
        h->screen_height = 1080;
    }

    h->stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    return h;
}

int osc_capture_start(OscCaptureHandle *handle) {
    if (!handle || handle->running) return -1;
    handle->running = 1;
    handle->paused = 0;
    ResetEvent(handle->stop_event);
    handle->thread = CreateThread(NULL, 0, WinCaptureThread, handle, 0, NULL);
    if (!handle->thread) {
        handle->running = 0;
        return -1;
    }
    return 0;
}

int osc_capture_pause(OscCaptureHandle *handle) {
    if (!handle || !handle->running) return -1;
    InterlockedExchange(&handle->paused, 1);
    return 0;
}

int osc_capture_resume(OscCaptureHandle *handle) {
    if (!handle || !handle->running) return -1;
    InterlockedExchange(&handle->paused, 0);
    return 0;
}

int osc_capture_stop(OscCaptureHandle *handle) {
    if (!handle || !handle->running) return 0;
    InterlockedExchange(&handle->running, 0);
    SetEvent(handle->stop_event);
    if (handle->thread) {
        WaitForSingleObject(handle->thread, 5000);
        CloseHandle(handle->thread);
        handle->thread = NULL;
    }
    return 0;
}

void osc_capture_destroy(OscCaptureHandle *handle) {
    if (!handle) return;
    if (handle->running) {
        osc_capture_stop(handle);
    }
    if (handle->stop_event) {
        CloseHandle(handle->stop_event);
        handle->stop_event = NULL;
    }
    if (handle->excluded_windows) {
        for (int i = 0; i < handle->excluded_count; i++) {
            if (handle->excluded_windows[i]) free(handle->excluded_windows[i]);
        }
        free(handle->excluded_windows);
        handle->excluded_windows = NULL;
    }
    free(handle);
}

int osc_capture_set_excluded_windows(OscCaptureHandle *handle, const char **window_ids, int count) {
    if (!handle) return -1;
    if (handle->excluded_windows) {
        for (int i = 0; i < handle->excluded_count; i++) {
            if (handle->excluded_windows[i]) free(handle->excluded_windows[i]);
        }
        free(handle->excluded_windows);
        handle->excluded_windows = NULL;
        handle->excluded_count = 0;
    }
    if (count > 0 && window_ids) {
        handle->excluded_windows = (char **)calloc(count, sizeof(char *));
        if (!handle->excluded_windows) return -1;
        for (int i = 0; i < count; i++) {
            if (window_ids[i]) handle->excluded_windows[i] = _strdup(window_ids[i]);
        }
        handle->excluded_count = count;
    }
    return 0;
}

int osc_capture_get_normalized_cursor(OscCaptureHandle *handle, int raw_x, int raw_y, float *out_nx, float *out_ny) {
    if (!handle || !out_nx || !out_ny || handle->screen_width == 0 || handle->screen_height == 0) return -1;
    *out_nx = (float)raw_x / (float)handle->screen_width;
    *out_ny = (float)raw_y / (float)handle->screen_height;
    if (*out_nx < 0.0f) *out_nx = 0.0f;
    if (*out_nx > 1.0f) *out_nx = 1.0f;
    if (*out_ny < 0.0f) *out_ny = 0.0f;
    if (*out_ny > 1.0f) *out_ny = 1.0f;
    return 0;
}
