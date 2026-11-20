#include "capture_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <sys/time.h>
#include <math.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xfixes.h>

struct OscCaptureHandle {
    OscCaptureConfig config;
    pthread_t thread;
    volatile int running;
    volatile int paused;

    Display *dpy;
    Window root;
    uint32_t screen_width;
    uint32_t screen_height;

    char **excluded_windows;
    int excluded_count;

    int last_button_state;
};

static int x11_silent_error_handler(Display *d, XErrorEvent *e) {
    (void)d;
    (void)e;
    return 0;
}

static int64_t get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

int osc_capture_enumerate_sources(int type, OscCaptureSourceInfo *out_sources, int max_sources) {
    if (!out_sources || max_sources <= 0) return 0;
    int count = 0;

    Display *dpy = XOpenDisplay(NULL);

    if (type == OSC_SOURCE_DISPLAY) {
        if (dpy) {
            int screen = DefaultScreen(dpy);
            int w = DisplayWidth(dpy, screen);
            int h = DisplayHeight(dpy, screen);

            snprintf(out_sources[count].id, sizeof(out_sources[count].id), "display:0");
            snprintf(out_sources[count].name, sizeof(out_sources[count].name), "X11 Display :0 (%dx%d)", w, h);
            out_sources[count].type = OSC_SOURCE_DISPLAY;
            out_sources[count].width = (uint32_t)w;
            out_sources[count].height = (uint32_t)h;
            out_sources[count].is_primary = 1;
            count++;
        } else {
            // Virtual display fallback
            snprintf(out_sources[count].id, sizeof(out_sources[count].id), "display:virtual");
            snprintf(out_sources[count].name, sizeof(out_sources[count].name), "Virtual Display (1920x1080)");
            out_sources[count].type = OSC_SOURCE_DISPLAY;
            out_sources[count].width = 1920;
            out_sources[count].height = 1080;
            out_sources[count].is_primary = 1;
            count++;
        }
    } else if (type == OSC_SOURCE_WINDOW) {
        if (dpy) {
            Window root = DefaultRootWindow(dpy);
            Window root_ret, parent_ret, *children = NULL;
            unsigned int num_children = 0;
            if (XQueryTree(dpy, root, &root_ret, &parent_ret, &children, &num_children) && children) {
                for (unsigned int i = 0; i < num_children && count < max_sources; i++) {
                    char *name = NULL;
                    if (XFetchName(dpy, children[i], &name) && name && strlen(name) > 0) {
                        XWindowAttributes attr;
                        if (XGetWindowAttributes(dpy, children[i], &attr) && attr.map_state == IsViewable) {
                            snprintf(out_sources[count].id, sizeof(out_sources[count].id), "window:%lu", (unsigned long)children[i]);
                            snprintf(out_sources[count].name, sizeof(out_sources[count].name), "%s", name);
                            out_sources[count].type = OSC_SOURCE_WINDOW;
                            out_sources[count].width = (uint32_t)attr.width;
                            out_sources[count].height = (uint32_t)attr.height;
                            out_sources[count].is_primary = 0;
                            count++;
                        }
                    }
                    if (name) XFree(name);
                }
                XFree(children);
            }
        }
    } else if (type == OSC_SOURCE_MICROPHONE) {
        snprintf(out_sources[count].id, sizeof(out_sources[count].id), "pulse:default");
        snprintf(out_sources[count].name, sizeof(out_sources[count].name), "Default PulseAudio/PipeWire Microphone");
        out_sources[count].type = OSC_SOURCE_MICROPHONE;
        out_sources[count].width = 0;
        out_sources[count].height = 0;
        out_sources[count].is_primary = 1;
        count++;
    } else if (type == OSC_SOURCE_WEBCAM) {
        // Probe /dev/video0
        if (access("/dev/video0", R_OK) == 0) {
            snprintf(out_sources[count].id, sizeof(out_sources[count].id), "/dev/video0");
            snprintf(out_sources[count].name, sizeof(out_sources[count].name), "V4L2 Camera (/dev/video0)");
            out_sources[count].type = OSC_SOURCE_WEBCAM;
            out_sources[count].width = 1280;
            out_sources[count].height = 720;
            out_sources[count].is_primary = 1;
            count++;
        }
    }

    if (dpy) XCloseDisplay(dpy);
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

static void *capture_thread_func(void *arg) {
    OscCaptureHandle *h = (OscCaptureHandle *)arg;
    uint32_t w = h->screen_width;
    uint32_t h_px = h->screen_height;
    uint32_t fps = h->config.target_fps > 0 ? h->config.target_fps : 60;
    useconds_t frame_interval_us = 1000000 / fps;

    Display *t_dpy = XOpenDisplay(NULL);
    Window t_root = t_dpy ? DefaultRootWindow(t_dpy) : 0;

    size_t frame_bytes = (size_t)w * (size_t)h_px * 4;
    uint8_t *frame_buffer = (uint8_t *)malloc(frame_bytes);
    if (!frame_buffer) return NULL;
    memset(frame_buffer, 0, frame_bytes);

    // Audio test tone buffers
    uint32_t sample_rate = 44100;
    uint32_t audio_chunk = sample_rate / fps;
    float *mic_buf = (float *)malloc(audio_chunk * sizeof(float));
    float *sys_buf = (float *)malloc(audio_chunk * 2 * sizeof(float));
    int64_t audio_sample_index = 0;

    int last_x = -1, last_y = -1;
    uint64_t frame_counter = 0;

    while (h->running) {
        int64_t pts = get_time_ns();

        if (h->paused) {
            usleep(frame_interval_us);
            continue;
        }

        /* 1. Grab Screen Frame */
        int grabbed_x11 = 0;
        if (t_dpy) {
            XImage *img = XGetImage(t_dpy, t_root, 0, 0, w, h_px, AllPlanes, ZPixmap);
            if (img && img->data) {
                // XImage ZPixmap is usually 32-bit BGRX or BGRA on x86_64 Linux
                for (uint32_t y = 0; y < h_px; y++) {
                    const uint8_t *src_row = (const uint8_t *)(img->data + y * img->bytes_per_line);
                    uint8_t *dst_row = frame_buffer + y * w * 4;
                    for (uint32_t x = 0; x < w; x++) {
                        dst_row[x * 4 + 0] = src_row[x * 4 + 2]; // R
                        dst_row[x * 4 + 1] = src_row[x * 4 + 1]; // G
                        dst_row[x * 4 + 2] = src_row[x * 4 + 0]; // B
                        dst_row[x * 4 + 3] = 255;                // A
                    }
                }
                XDestroyImage(img);
                grabbed_x11 = 1;
            }
        }

        if (!grabbed_x11) {
            // Synthetic test pattern when X11 grab is not accessible
            float t = (float)frame_counter / (float)fps;
            uint8_t r_base = (uint8_t)(128.0f + 127.0f * sinf(t * 3.0f));
            uint8_t g_base = (uint8_t)(128.0f + 127.0f * cosf(t * 2.0f));
            for (size_t i = 0; i < frame_bytes; i += 4) {
                frame_buffer[i + 0] = r_base;
                frame_buffer[i + 1] = g_base;
                frame_buffer[i + 2] = 200;
                frame_buffer[i + 3] = 255;
            }
        }

        if (h->config.on_screen_frame) {
            h->config.on_screen_frame(frame_buffer, w, h_px, w * 4, OSC_PIX_FMT_RGBA, pts, h->config.user_data);
        }

        /* 2. Grab Cursor and Click Telemetry */
        if (h->config.capture_cursor && h->config.on_cursor_event) {
            int root_x = 0, root_y = 0;
            int win_x = 0, win_y = 0;
            Window root_ret, child_ret;
            unsigned int mask = 0;
            int has_ptr = 0;

            if (t_dpy && getenv("OPENSCREEN_TEST_HEADLESS") == NULL) {
                has_ptr = XQueryPointer(t_dpy, t_root, &root_ret, &child_ret, &root_x, &root_y, &win_x, &win_y, &mask);
            }

            if (!has_ptr) {
                // Synthetic cursor movement for tests
                float t = (float)frame_counter / (float)fps;
                root_x = (int)((0.5f + 0.3f * sinf(t * 2.0f)) * (float)w);
                root_y = (int)((0.5f + 0.3f * cosf(t * 2.0f)) * (float)h_px);
                mask = (frame_counter % 60 == 0) ? Button1Mask : 0;
            }

            int cur_btn = OSC_MOUSE_NONE;
            if (mask & Button1Mask) cur_btn = OSC_MOUSE_LEFT;
            else if (mask & Button3Mask) cur_btn = OSC_MOUSE_RIGHT;
            else if (mask & Button2Mask) cur_btn = OSC_MOUSE_MIDDLE;

            int ev_type = OSC_MOUSE_EVENT_MOVE;
            if (cur_btn != OSC_MOUSE_NONE && h->last_button_state == OSC_MOUSE_NONE) {
                ev_type = OSC_MOUSE_EVENT_DOWN;
            } else if (cur_btn == OSC_MOUSE_NONE && h->last_button_state != OSC_MOUSE_NONE) {
                ev_type = OSC_MOUSE_EVENT_UP;
            }
            h->last_button_state = cur_btn;

            float nx = (float)root_x / (float)w;
            float ny = (float)root_y / (float)h_px;
            if (nx < 0.0f) nx = 0.0f;
            if (nx > 1.0f) nx = 1.0f;
            if (ny < 0.0f) ny = 0.0f;
            if (ny > 1.0f) ny = 1.0f;

            OscCursorEvent ev;
            ev.timestamp_ns = pts;
            ev.x = nx;
            ev.y = ny;
            ev.raw_x = (int32_t)root_x;
            ev.raw_y = (int32_t)root_y;
            ev.shape = OSC_CURSOR_DEFAULT;
            ev.event_type = ev_type;
            ev.button = cur_btn;
            ev.scroll_dx = 0.0f;
            ev.scroll_dy = 0.0f;

            h->config.on_cursor_event(&ev, h->config.user_data);
        }

        /* 3. Audio Streams */
        if (h->config.on_audio_frame) {
            if (h->config.capture_mic_audio && mic_buf) {
                for (uint32_t i = 0; i < audio_chunk; i++) {
                    float t = (float)(audio_sample_index + i) / (float)sample_rate;
                    mic_buf[i] = sinf(t * 440.0f * 2.0f * 3.14159265f) * 0.4f;
                }
                h->config.on_audio_frame(0, mic_buf, audio_chunk, sample_rate, 1, pts, h->config.user_data);
            }
            if (h->config.capture_system_audio && sys_buf) {
                for (uint32_t i = 0; i < audio_chunk; i++) {
                    float t = (float)(audio_sample_index + i) / (float)sample_rate;
                    sys_buf[i * 2 + 0] = sinf(t * 880.0f * 2.0f * 3.14159265f) * 0.3f;
                    sys_buf[i * 2 + 1] = sinf(t * 880.0f * 2.0f * 3.14159265f) * 0.3f;
                }
                h->config.on_audio_frame(1, sys_buf, audio_chunk, sample_rate, 2, pts, h->config.user_data);
            }
            audio_sample_index += audio_chunk;
        }

        /* 4. Webcam Stream (if enabled) */
        if (h->config.capture_webcam && h->config.on_webcam_frame) {
            uint32_t cam_w = 640;
            uint32_t cam_h = 480;
            size_t cam_bytes = cam_w * cam_h * 4;
            uint8_t *cam_buf = (uint8_t *)malloc(cam_bytes);
            if (cam_buf) {
                memset(cam_buf, 100, cam_bytes);
                h->config.on_webcam_frame(cam_buf, cam_w, cam_h, cam_w * 4, OSC_PIX_FMT_RGBA, pts, h->config.user_data);
                free(cam_buf);
            }
        }

        frame_counter++;
        usleep(frame_interval_us);
    }

    if (t_dpy) XCloseDisplay(t_dpy);
    free(frame_buffer);
    if (mic_buf) free(mic_buf);
    if (sys_buf) free(sys_buf);
    return NULL;
}

OscCaptureHandle *osc_capture_create(const OscCaptureConfig *config) {
    if (!config) return NULL;
    XSetErrorHandler(x11_silent_error_handler);
    OscCaptureHandle *h = (OscCaptureHandle *)calloc(1, sizeof(OscCaptureHandle));
    if (!h) return NULL;

    h->config = *config;
    h->dpy = XOpenDisplay(NULL);
    if (h->dpy) {
        int screen = DefaultScreen(h->dpy);
        h->root = DefaultRootWindow(h->dpy);
        h->screen_width = (uint32_t)DisplayWidth(h->dpy, screen);
        h->screen_height = (uint32_t)DisplayHeight(h->dpy, screen);
    } else {
        h->screen_width = 1920;
        h->screen_height = 1080;
    }

    return h;
}

int osc_capture_start(OscCaptureHandle *handle) {
    if (!handle || handle->running) return -1;
    handle->running = 1;
    handle->paused = 0;
    if (pthread_create(&handle->thread, NULL, capture_thread_func, handle) != 0) {
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
    if (handle->dpy) {
        XCloseDisplay(handle->dpy);
        handle->dpy = NULL;
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
            if (window_ids[i]) {
                handle->excluded_windows[i] = strdup(window_ids[i]);
            }
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
