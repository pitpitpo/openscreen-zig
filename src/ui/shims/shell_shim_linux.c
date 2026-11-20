#include "shell_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <signal.h>
#include <errno.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

static int g_lock_fd = -1;
static char g_lock_path[1024] = {0};
static OscTrayCallback g_tray_cb = NULL;
static void* g_tray_user_data = NULL;
static int g_tray_recording = 0;
static OscShortcutCallback g_shortcut_cb = NULL;
static void* g_shortcut_user_data = NULL;

int osc_shell_single_instance_lock(const char* user_data_path) {
    if (g_lock_fd >= 0) {
        return 1; /* Already locked by current process */
    }

    if (user_data_path && strlen(user_data_path) > 0) {
        mkdir(user_data_path, 0755);
        snprintf(g_lock_path, sizeof(g_lock_path), "%s/openscreen.lock", user_data_path);
    } else {
        const char* tmp = getenv("TMPDIR");
        if (!tmp) tmp = "/tmp";
        snprintf(g_lock_path, sizeof(g_lock_path), "%s/openscreen_%d.lock", tmp, getuid());
    }

    int fd = open(g_lock_path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) {
        return 0;
    }

    struct flock fl;
    memset(&fl, 0, sizeof(fl));
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0;

    if (fcntl(fd, F_SETLK, &fl) < 0) {
        /* Lock held by another instance */
        char pid_buf[32] = {0};
        ssize_t n = read(fd, pid_buf, sizeof(pid_buf) - 1);
        if (n > 0) {
            pid_t pid = (pid_t)atoi(pid_buf);
            if (pid > 0 && pid != getpid()) {
                /* Signal existing instance to focus/restore */
                kill(pid, SIGUSR1);
            }
        }
        close(fd);
        return 0; /* Secondary instance */
    }

    /* Lock acquired */
    if (ftruncate(fd, 0) == 0) {
        char pid_buf[32];
        int len = snprintf(pid_buf, sizeof(pid_buf), "%d\n", getpid());
        if (len > 0) {
            (void)write(fd, pid_buf, (size_t)len);
        }
    }

    g_lock_fd = fd;
    return 1; /* Primary instance */
}

void osc_shell_single_instance_unlock(void) {
    if (g_lock_fd >= 0) {
        struct flock fl;
        memset(&fl, 0, sizeof(fl));
        fl.l_type = F_UNLCK;
        fl.l_whence = SEEK_SET;
        fl.l_start = 0;
        fl.l_len = 0;
        fcntl(g_lock_fd, F_SETLK, &fl);
        close(g_lock_fd);
        g_lock_fd = -1;
        if (g_lock_path[0]) {
            unlink(g_lock_path);
            g_lock_path[0] = '\0';
        }
    }
}

int osc_shell_tray_init(const char* tooltip, OscTrayCallback callback, void* user_data) {
    (void)tooltip;
    g_tray_cb = callback;
    g_tray_user_data = user_data;
    g_tray_recording = 0;
    return 1;
}

void osc_shell_tray_update_state(int is_recording) {
    g_tray_recording = is_recording;
}

void osc_shell_tray_destroy(void) {
    g_tray_cb = NULL;
    g_tray_user_data = NULL;
    g_tray_recording = 0;
}

int osc_shell_register_global_shortcut(const char* shortcut_desc, OscShortcutCallback callback, void* user_data) {
    (void)shortcut_desc;
    g_shortcut_cb = callback;
    g_shortcut_user_data = user_data;
    return 1;
}

void osc_shell_unregister_global_shortcut(void) {
    g_shortcut_cb = NULL;
    g_shortcut_user_data = NULL;
}

int osc_shell_set_window_content_protection(void* native_window_handle, int exclude) {
    (void)native_window_handle;
    (void)exclude;
    /* On Linux X11/Wayland, capture shims exclude HUD based on window ID matching */
    return 1;
}

/* Native Windowing & Event Loop Implementation */
typedef struct {
    Display* display;
    Window window;
    GC gc;
    Atom wm_delete_window;
    int is_open;
    int width;
    int height;
    int is_offscreen_dummy;
    uint32_t* x_image_buf;
    int x_image_buf_capacity;
} OscLinuxWindow;

void* osc_window_create(const char* title, int width, int height, int resizable) {
    (void)resizable;
    OscLinuxWindow* win = (OscLinuxWindow*)calloc(1, sizeof(OscLinuxWindow));
    if (!win) return NULL;

    win->width = width > 0 ? width : 1280;
    win->height = height > 0 ? height : 800;
    win->is_open = 1;

    Display* display = XOpenDisplay(NULL);
    if (!display) {
        /* Headless environment (e.g. CI without DISPLAY/xvfb) */
        win->is_offscreen_dummy = 1;
        return (void*)win;
    }

    win->display = display;
    int screen = DefaultScreen(display);
    Window root = RootWindow(display, screen);

    Window w = XCreateSimpleWindow(
        display, root,
        100, 100, (unsigned int)win->width, (unsigned int)win->height,
        1,
        BlackPixel(display, screen),
        WhitePixel(display, screen)
    );
    win->window = w;

    if (title) {
        XStoreName(display, w, title);
    }

    Atom wm_delete = XInternAtom(display, "WM_DELETE_WINDOW", False);
    win->wm_delete_window = wm_delete;
    XSetWMProtocols(display, w, &wm_delete, 1);

    long event_mask = ExposureMask | KeyPressMask | KeyReleaseMask |
                      ButtonPressMask | ButtonReleaseMask |
                      PointerMotionMask | StructureNotifyMask;
    XSelectInput(display, w, event_mask);

    XMapWindow(display, w);
    XFlush(display);

    win->gc = XCreateGC(display, w, 0, NULL);
    return (void*)win;
}

void osc_window_destroy(void* win_handle) {
    if (!win_handle) return;
    OscLinuxWindow* win = (OscLinuxWindow*)win_handle;
    if (win->x_image_buf) {
        free(win->x_image_buf);
        win->x_image_buf = NULL;
    }
    if (!win->is_offscreen_dummy && win->display) {
        if (win->gc) {
            XFreeGC(win->display, win->gc);
            win->gc = NULL;
        }
        if (win->window) {
            XDestroyWindow(win->display, win->window);
            win->window = 0;
        }
        XCloseDisplay(win->display);
        win->display = NULL;
    }
    free(win);
}

int osc_window_poll_event(void* win_handle, OscWindowEvent* out_event) {
    if (!win_handle || !out_event) return 0;
    OscLinuxWindow* win = (OscLinuxWindow*)win_handle;
    memset(out_event, 0, sizeof(OscWindowEvent));

    if (win->is_offscreen_dummy || !win->display) {
        return 0;
    }

    if (XPending(win->display) > 0) {
        XEvent xev;
        XNextEvent(win->display, &xev);

        switch (xev.type) {
            case ClientMessage:
                if ((Atom)xev.xclient.data.l[0] == win->wm_delete_window) {
                    out_event->kind = OSC_WINDOW_EVENT_CLOSE;
                    win->is_open = 0;
                    return 1;
                }
                break;
            case DestroyNotify:
                out_event->kind = OSC_WINDOW_EVENT_QUIT;
                win->is_open = 0;
                return 1;
            case ConfigureNotify:
                if (xev.xconfigure.width != win->width || xev.xconfigure.height != win->height) {
                    win->width = xev.xconfigure.width;
                    win->height = xev.xconfigure.height;
                    out_event->kind = OSC_WINDOW_EVENT_RESIZE;
                    out_event->width = win->width;
                    out_event->height = win->height;
                    return 1;
                }
                break;
            case MotionNotify:
                out_event->kind = OSC_WINDOW_EVENT_MOUSE_MOVE;
                out_event->x = xev.xmotion.x;
                out_event->y = xev.xmotion.y;
                return 1;
            case ButtonPress:
                out_event->kind = OSC_WINDOW_EVENT_MOUSE_DOWN;
                out_event->x = xev.xbutton.x;
                out_event->y = xev.xbutton.y;
                out_event->button = (int)xev.xbutton.button;
                return 1;
            case ButtonRelease:
                out_event->kind = OSC_WINDOW_EVENT_MOUSE_UP;
                out_event->x = xev.xbutton.x;
                out_event->y = xev.xbutton.y;
                out_event->button = (int)xev.xbutton.button;
                return 1;
            case KeyPress: {
                out_event->kind = OSC_WINDOW_EVENT_KEY_DOWN;
                KeySym sym = XLookupKeysym(&xev.xkey, 0);
                out_event->keycode = (int)(sym & 0xFF);
                if (xev.xkey.state & ControlMask) out_event->is_ctrl = 1;
                if (xev.xkey.state & ShiftMask) out_event->is_shift = 1;
                return 1;
            }
            case KeyRelease: {
                out_event->kind = OSC_WINDOW_EVENT_KEY_UP;
                KeySym sym = XLookupKeysym(&xev.xkey, 0);
                out_event->keycode = (int)(sym & 0xFF);
                if (xev.xkey.state & ControlMask) out_event->is_ctrl = 1;
                if (xev.xkey.state & ShiftMask) out_event->is_shift = 1;
                return 1;
            }
            default:
                break;
        }
    }
    return 0;
}

void osc_window_present(void* win_handle, const uint8_t* rgba_pixels, int width, int height) {
    if (!win_handle || !rgba_pixels || width <= 0 || height <= 0) return;
    OscLinuxWindow* win = (OscLinuxWindow*)win_handle;
    if (win->is_offscreen_dummy || !win->display || !win->window || !win->gc) {
        return;
    }

    int screen = DefaultScreen(win->display);
    int total_pixels = width * height;
    if (win->x_image_buf_capacity < total_pixels) {
        free(win->x_image_buf);
        win->x_image_buf = (uint32_t*)malloc((size_t)total_pixels * sizeof(uint32_t));
        win->x_image_buf_capacity = total_pixels;
    }

    if (!win->x_image_buf) return;

    /* Convert RGBA to BGRA (standard for 24/32-bit X11 visuals) */
    for (int i = 0; i < total_pixels; i++) {
        uint8_t r = rgba_pixels[i * 4 + 0];
        uint8_t g = rgba_pixels[i * 4 + 1];
        uint8_t b = rgba_pixels[i * 4 + 2];
        uint8_t a = rgba_pixels[i * 4 + 3];
        win->x_image_buf[i] = ((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    }

    XImage* img = XCreateImage(
        win->display,
        DefaultVisual(win->display, screen),
        (unsigned int)DefaultDepth(win->display, screen),
        ZPixmap,
        0,
        (char*)win->x_image_buf,
        (unsigned int)width,
        (unsigned int)height,
        32,
        0
    );

    if (img) {
        XPutImage(
            win->display,
            win->window,
            win->gc,
            img,
            0, 0,
            0, 0,
            (unsigned int)width,
            (unsigned int)height
        );
        img->data = NULL; /* Prevent XDestroyImage from freeing x_image_buf */
        XDestroyImage(img);
        XFlush(win->display);
    }
}

int osc_window_is_open(void* win_handle) {
    if (!win_handle) return 0;
    OscLinuxWindow* win = (OscLinuxWindow*)win_handle;
    return win->is_open;
}
