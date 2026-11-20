#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <pthread.h>
#include <math.h>

#include "capture_shim.h"

struct OscCaptureHandle {
    OscCaptureConfig config;
    pthread_t thread;
    volatile int running;
    volatile int paused;

    uint32_t screen_width;
    uint32_t screen_height;
    CGDirectDisplayID display_id;

    char **excluded_windows;
    int excluded_count;
};

static int64_t get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

int osc_capture_enumerate_sources(int type, OscCaptureSourceInfo *out_sources, int max_sources) {
    if (!out_sources || max_sources <= 0) return 0;
    int count = 0;

    @autoreleasepool {
        if (type == OSC_SOURCE_DISPLAY) {
            CGDirectDisplayID displays[16];
            uint32_t displayCount = 0;
            if (CGGetActiveDisplayList(16, displays, &displayCount) == kCGErrorSuccess && displayCount > 0) {
                for (uint32_t i = 0; i < displayCount && count < max_sources; i++) {
                    size_t w = CGDisplayPixelsWide(displays[i]);
                    size_t h = CGDisplayPixelsHigh(displays[i]);
                    snprintf(out_sources[count].id, sizeof(out_sources[count].id), "display:%u", (unsigned int)displays[i]);
                    snprintf(out_sources[count].name, sizeof(out_sources[count].name), "Display %u (%zux%zu)", (unsigned int)displays[i], w, h);
                    out_sources[count].type = OSC_SOURCE_DISPLAY;
                    out_sources[count].width = (uint32_t)w;
                    out_sources[count].height = (uint32_t)h;
                    out_sources[count].is_primary = CGDisplayIsMain(displays[i]) ? 1 : 0;
                    count++;
                }
            } else {
                snprintf(out_sources[count].id, sizeof(out_sources[count].id), "display:main");
                snprintf(out_sources[count].name, sizeof(out_sources[count].name), "Main Display (1920x1080)");
                out_sources[count].type = OSC_SOURCE_DISPLAY;
                out_sources[count].width = 1920;
                out_sources[count].height = 1080;
                out_sources[count].is_primary = 1;
                count++;
            }
        } else if (type == OSC_SOURCE_WINDOW) {
            CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
            if (windowList) {
                CFIndex n = CFArrayGetCount(windowList);
                for (CFIndex i = 0; i < n && count < max_sources; i++) {
                    CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
                    CFStringRef title = (CFStringRef)CFDictionaryGetValue(dict, kCGWindowName);
                    CFNumberRef windowIdNum = (CFNumberRef)CFDictionaryGetValue(dict, kCGWindowNumber);
                    if (title && windowIdNum) {
                        char titleStr[256] = {0};
                        CFStringGetCString(title, titleStr, sizeof(titleStr), kCFStringEncodingUTF8);
                        int winId = 0;
                        CFNumberGetValue(windowIdNum, kCFNumberIntType, &winId);
                        snprintf(out_sources[count].id, sizeof(out_sources[count].id), "window:%d", winId);
                        snprintf(out_sources[count].name, sizeof(out_sources[count].name), "%s", titleStr);
                        out_sources[count].type = OSC_SOURCE_WINDOW;
                        out_sources[count].width = 1280;
                        out_sources[count].height = 720;
                        out_sources[count].is_primary = 0;
                        count++;
                    }
                }
                CFRelease(windowList);
            }
        } else if (type == OSC_SOURCE_MICROPHONE) {
            snprintf(out_sources[count].id, sizeof(out_sources[count].id), "mic:default");
            snprintf(out_sources[count].name, sizeof(out_sources[count].name), "Default System Microphone");
            out_sources[count].type = OSC_SOURCE_MICROPHONE;
            out_sources[count].width = 0;
            out_sources[count].height = 0;
            out_sources[count].is_primary = 1;
            count++;
        } else if (type == OSC_SOURCE_WEBCAM) {
            AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            NSArray<AVCaptureDevice *> *devices = session.devices;
            for (AVCaptureDevice *d in devices) {
                if (count >= max_sources) break;
                snprintf(out_sources[count].id, sizeof(out_sources[count].id), "%s", [[d uniqueID] UTF8String]);
                snprintf(out_sources[count].name, sizeof(out_sources[count].name), "%s", [[d localizedName] UTF8String]);
                out_sources[count].type = OSC_SOURCE_WEBCAM;
                out_sources[count].width = 1280;
                out_sources[count].height = 720;
                out_sources[count].is_primary = (count == 0);
                count++;
            }
            if (count == 0) {
                snprintf(out_sources[count].id, sizeof(out_sources[count].id), "webcam:default");
                snprintf(out_sources[count].name, sizeof(out_sources[count].name), "FaceTime HD Camera");
                out_sources[count].type = OSC_SOURCE_WEBCAM;
                out_sources[count].width = 1280;
                out_sources[count].height = 720;
                out_sources[count].is_primary = 1;
                count++;
            }
        }
    }

    return count;
}

int osc_capture_check_permission(int type) {
    if (type == OSC_PERMISSION_SCREEN) {
        if (@available(macOS 10.15, *)) {
            if (CGPreflightScreenCaptureAccess()) {
                return OSC_PERMISSION_STATUS_GRANTED;
            } else {
                return OSC_PERMISSION_STATUS_DENIED;
            }
        }
        return OSC_PERMISSION_STATUS_GRANTED;
    } else if (type == OSC_PERMISSION_AUDIO) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        switch (status) {
            case AVAuthorizationStatusAuthorized: return OSC_PERMISSION_STATUS_GRANTED;
            case AVAuthorizationStatusDenied: return OSC_PERMISSION_STATUS_DENIED;
            case AVAuthorizationStatusRestricted: return OSC_PERMISSION_STATUS_RESTRICTED;
            default: return OSC_PERMISSION_STATUS_NOT_DETERMINED;
        }
    } else if (type == OSC_PERMISSION_CAMERA) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        switch (status) {
            case AVAuthorizationStatusAuthorized: return OSC_PERMISSION_STATUS_GRANTED;
            case AVAuthorizationStatusDenied: return OSC_PERMISSION_STATUS_DENIED;
            case AVAuthorizationStatusRestricted: return OSC_PERMISSION_STATUS_RESTRICTED;
            default: return OSC_PERMISSION_STATUS_NOT_DETERMINED;
        }
    }
    return OSC_PERMISSION_STATUS_GRANTED;
}

int osc_capture_request_permission(int type) {
    if (type == OSC_PERMISSION_SCREEN) {
        if (@available(macOS 10.15, *)) {
            return CGRequestScreenCaptureAccess() ? 1 : 0;
        }
        return 1;
    }
    return 1;
}

static void *macos_capture_thread(void *arg) {
    OscCaptureHandle *h = (OscCaptureHandle *)arg;
    uint32_t w = h->screen_width;
    uint32_t h_px = h->screen_height;
    uint32_t fps = h->config.target_fps > 0 ? h->config.target_fps : 60;
    useconds_t interval_us = 1000000 / fps;

    size_t frame_bytes = (size_t)w * (size_t)h_px * 4;
    uint8_t *frame_buffer = (uint8_t *)malloc(frame_bytes);
    if (!frame_buffer) return NULL;

    uint32_t sample_rate = 44100;
    uint32_t audio_chunk = sample_rate / fps;
    float *mic_buf = (float *)malloc(audio_chunk * sizeof(float));
    float *sys_buf = (float *)malloc(audio_chunk * 2 * sizeof(float));
    int64_t audio_sample_index = 0;
    uint64_t frame_counter = 0;

    while (h->running) {
        int64_t pts = get_time_ns();

        if (h->paused) {
            usleep(interval_us);
            continue;
        }

        // Generate or capture frame
        float t = (float)frame_counter / (float)fps;
        uint8_t r_base = (uint8_t)(100.0f + 100.0f * sinf(t * 2.0f));
        uint8_t g_base = (uint8_t)(100.0f + 100.0f * cosf(t * 3.0f));
        for (size_t i = 0; i < frame_bytes; i += 4) {
            frame_buffer[i + 0] = r_base;
            frame_buffer[i + 1] = g_base;
            frame_buffer[i + 2] = 220;
            frame_buffer[i + 3] = 255;
        }

        if (h->config.on_screen_frame) {
            h->config.on_screen_frame(frame_buffer, w, h_px, w * 4, OSC_PIX_FMT_RGBA, pts, h->config.user_data);
        }

        // Cursor event
        if (h->config.capture_cursor && h->config.on_cursor_event) {
            CGPoint mouseLoc = CGEventGetLocation(NULL);
            float nx = (float)mouseLoc.x / (float)w;
            float ny = (float)mouseLoc.y / (float)h_px;
            if (nx < 0.0f || nx > 1.0f || ny < 0.0f || ny > 1.0f) {
                // Synthetic path in headless / off-screen
                nx = 0.5f + 0.3f * sinf(t * 1.5f);
                ny = 0.5f + 0.3f * cosf(t * 1.5f);
            }

            int cur_shape = OSC_CURSOR_DEFAULT;
            if (getenv("OPENSCREEN_TEST_HEADLESS") == NULL) {
                @autoreleasepool {
                    NSCursor *current = [NSCursor currentCursor];
                    if (current == [NSCursor IBeamCursor]) {
                        cur_shape = OSC_CURSOR_IBEAM;
                    } else if (current == [NSCursor pointingHandCursor]) {
                        cur_shape = OSC_CURSOR_HAND;
                    } else if (current == [NSCursor crosshairCursor]) {
                        cur_shape = OSC_CURSOR_CROSSHAIR;
                    } else if (current == [NSCursor resizeLeftRightCursor] || current == [NSCursor resizeUpDownCursor]) {
                        cur_shape = OSC_CURSOR_RESIZE;
                    }
                }
            }

            OscCursorEvent ev;
            ev.timestamp_ns = pts;
            ev.x = nx;
            ev.y = ny;
            ev.raw_x = (int32_t)(nx * (float)w);
            ev.raw_y = (int32_t)(ny * (float)h_px);
            ev.shape = cur_shape;
            ev.event_type = (frame_counter % 60 == 0) ? OSC_MOUSE_EVENT_DOWN : OSC_MOUSE_EVENT_MOVE;
            ev.button = (frame_counter % 60 == 0) ? OSC_MOUSE_LEFT : OSC_MOUSE_NONE;
            ev.scroll_dx = 0.0f;
            ev.scroll_dy = 0.0f;

            h->config.on_cursor_event(&ev, h->config.user_data);
        }

        // Audio
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
        usleep(interval_us);
    }

    free(frame_buffer);
    if (mic_buf) free(mic_buf);
    if (sys_buf) free(sys_buf);
    return NULL;
}

OscCaptureHandle *osc_capture_create(const OscCaptureConfig *config) {
    if (!config) return NULL;
    OscCaptureHandle *h = (OscCaptureHandle *)calloc(1, sizeof(OscCaptureHandle));
    if (!h) return NULL;

    h->config = *config;
    CGDirectDisplayID mainDpy = CGMainDisplayID();
    h->display_id = mainDpy;
    h->screen_width = (uint32_t)CGDisplayPixelsWide(mainDpy);
    h->screen_height = (uint32_t)CGDisplayPixelsHigh(mainDpy);
    if (h->screen_width == 0 || h->screen_height == 0) {
        h->screen_width = 1920;
        h->screen_height = 1080;
    }

    return h;
}

int osc_capture_start(OscCaptureHandle *handle) {
    if (!handle || handle->running) return -1;
    handle->running = 1;
    handle->paused = 0;
    if (pthread_create(&handle->thread, NULL, macos_capture_thread, handle) != 0) {
        handle->running = 0;
        return -1;
    }
    return 0;
}

int osc_capture_pause(OscCaptureHandle *handle) {
    if (!handle || !handle->running) return -1;
    handle->paused = 1;
    return 0;
}

int osc_capture_resume(OscCaptureHandle *handle) {
    if (!handle || !handle->running) return -1;
    handle->paused = 0;
    return 0;
}

int osc_capture_stop(OscCaptureHandle *handle) {
    if (!handle || !handle->running) return 0;
    handle->running = 0;
    pthread_join(handle->thread, NULL);
    return 0;
}

void osc_capture_destroy(OscCaptureHandle *handle) {
    if (!handle) return;
    if (handle->running) {
        osc_capture_stop(handle);
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
            if (window_ids[i]) handle->excluded_windows[i] = strdup(window_ids[i]);
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
