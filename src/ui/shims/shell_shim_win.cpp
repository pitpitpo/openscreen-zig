#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include "shell_shim.h"
#include <stdio.h>

static HANDLE g_win_mutex = NULL;
static NOTIFYICONDATAW g_nid = {0};
static OscTrayCallback g_win_tray_cb = NULL;
static void* g_win_tray_user_data = NULL;
static OscShortcutCallback g_win_shortcut_cb = NULL;
static void* g_win_shortcut_user_data = NULL;
static HWND g_tray_hwnd = NULL;

#define WM_TRAY_NOTIFY (WM_USER + 101)

static LRESULT CALLBACK TrayWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_TRAY_NOTIFY) {
        if (lParam == WM_RBUTTONUP || lParam == WM_LBUTTONUP) {
            HMENU hMenu = CreatePopupMenu();
            InsertMenuW(hMenu, 0, MF_BYPOSITION | MF_STRING, OSC_TRAY_ACTION_START_STOP_RECORDING, L"Start/Stop Recording");
            InsertMenuW(hMenu, 1, MF_BYPOSITION | MF_STRING, OSC_TRAY_ACTION_OPEN_EDITOR, L"Open Editor");
            InsertMenuW(hMenu, 2, MF_BYPOSITION | MF_STRING, OSC_TRAY_ACTION_SETTINGS, L"Settings");
            InsertMenuW(hMenu, 3, MF_BYPOSITION | MF_SEPARATOR, 0, NULL);
            InsertMenuW(hMenu, 4, MF_BYPOSITION | MF_STRING, OSC_TRAY_ACTION_QUIT, L"Quit OpenScreen");

            POINT pt;
            GetCursorPos(&pt);
            SetForegroundWindow(hwnd);
            int cmd = TrackPopupMenu(hMenu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, NULL);
            DestroyMenu(hMenu);

            if (cmd > 0 && g_win_tray_cb) {
                g_win_tray_cb((OscTrayAction)cmd, g_win_tray_user_data);
            }
        }
    } else if (msg == WM_HOTKEY) {
        if (wParam == 0x05C && g_win_shortcut_cb) {
            g_win_shortcut_cb(g_win_shortcut_user_data);
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int osc_shell_single_instance_lock(const char* user_data_path) {
    if (g_win_mutex) {
        return 1; /* Already locked by current process */
    }

    char mutex_name[256];
    if (user_data_path && strlen(user_data_path) > 0) {
        snprintf(mutex_name, sizeof(mutex_name), "Local\\OpenScreen_Lock_%u", (unsigned int)strlen(user_data_path));
    } else {
        snprintf(mutex_name, sizeof(mutex_name), "Local\\OpenScreen_Lock_Default");
    }

    g_win_mutex = CreateMutexA(NULL, TRUE, mutex_name);
    if (!g_win_mutex) return 0;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        /* Secondary instance: find and focus primary window */
        HWND existing = FindWindowW(NULL, L"OpenScreen");
        if (existing) {
            ShowWindow(existing, SW_RESTORE);
            SetForegroundWindow(existing);
        }
        CloseHandle(g_win_mutex);
        g_win_mutex = NULL;
        return 0;
    }
    return 1;
}

void osc_shell_single_instance_unlock(void) {
    if (g_win_mutex) {
        ReleaseMutex(g_win_mutex);
        CloseHandle(g_win_mutex);
        g_win_mutex = NULL;
    }
}

int osc_shell_tray_init(const char* tooltip, OscTrayCallback callback, void* user_data) {
    g_win_tray_cb = callback;
    g_win_tray_user_data = user_data;

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = TrayWndProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"OpenScreen_TrayClass";
    RegisterClassW(&wc);

    g_tray_hwnd = CreateWindowExW(0, L"OpenScreen_TrayClass", L"OpenScreenTray", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, wc.hInstance, NULL);
    if (!g_tray_hwnd) return 0;

    memset(&g_nid, 0, sizeof(g_nid));
    g_nid.cbSize = sizeof(NOTIFYICONDATAW);
    g_nid.hWnd = g_tray_hwnd;
    g_nid.uID = 1001;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY_NOTIFY;
    g_nid.hIcon = LoadIconW(NULL, MAKEINTRESOURCEW(32512));
    if (tooltip) {
        MultiByteToWideChar(CP_UTF8, 0, tooltip, -1, g_nid.szTip, sizeof(g_nid.szTip) / sizeof(WCHAR));
    }

    Shell_NotifyIconW(NIM_ADD, &g_nid);
    return 1;
}

void osc_shell_tray_update_state(int is_recording) {
    (void)is_recording;
}

void osc_shell_tray_destroy(void) {
    if (g_tray_hwnd) {
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        DestroyWindow(g_tray_hwnd);
        g_tray_hwnd = NULL;
    }
    g_win_tray_cb = NULL;
    g_win_tray_user_data = NULL;
}

int osc_shell_register_global_shortcut(const char* shortcut_desc, OscShortcutCallback callback, void* user_data) {
    (void)shortcut_desc;
    g_win_shortcut_cb = callback;
    g_win_shortcut_user_data = user_data;
    if (g_tray_hwnd) {
        // Register Ctrl+Shift+O
        RegisterHotKey(g_tray_hwnd, 0x05C, MOD_CONTROL | MOD_SHIFT, 'O');
    }
    return 1;
}

void osc_shell_unregister_global_shortcut(void) {
    if (g_tray_hwnd) {
        UnregisterHotKey(g_tray_hwnd, 0x05C);
    }
    g_win_shortcut_cb = NULL;
    g_win_shortcut_user_data = NULL;
}

int osc_shell_set_window_content_protection(void* native_window_handle, int exclude) {
    if (!native_window_handle) return 0;
    DWORD affinity = exclude ? 0x00000011 /* WDA_EXCLUDEFROMCAPTURE */ : 0x00000000 /* WDA_NONE */;
    return SetWindowDisplayAffinity((HWND)native_window_handle, affinity) ? 1 : 0;
}

/* Native Win32 Windowing */
typedef struct {
    HWND hwnd;
    HDC hdc;
    int is_open;
    int width;
    int height;
    int is_offscreen_dummy;
    uint32_t* bgra_buf;
    int bgra_buf_capacity;
} OscWin32Window;

static LRESULT CALLBACK OscWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    OscWin32Window* win = (OscWin32Window*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
        case WM_CLOSE:
            if (win) win->is_open = 0;
            return 0;
        case WM_DESTROY:
            if (win) win->is_open = 0;
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

void* osc_window_create(const char* title, int width, int height, int resizable) {
    (void)resizable;
    OscWin32Window* win = (OscWin32Window*)calloc(1, sizeof(OscWin32Window));
    if (!win) return NULL;

    win->width = width > 0 ? width : 1280;
    win->height = height > 0 ? height : 800;
    win->is_open = 1;

    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    wc.lpfnWndProc = OscWindowProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = L"OpenScreenMainWindowClass";
    RegisterClassExW(&wc);

    wchar_t title_w[256] = L"OpenScreen 2.0";
    if (title) {
        MultiByteToWideChar(CP_UTF8, 0, title, -1, title_w, 256);
    }

    HWND hwnd = CreateWindowExW(
        WS_EX_APPWINDOW,
        L"OpenScreenMainWindowClass",
        title_w,
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT,
        win->width, win->height,
        NULL, NULL, GetModuleHandleW(NULL), NULL
    );

    if (!hwnd) {
        /* Headless Windows Server runner fallback */
        win->is_offscreen_dummy = 1;
        return (void*)win;
    }

    win->hwnd = hwnd;
    win->hdc = GetDC(hwnd);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)win);

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    return (void*)win;
}

void osc_window_destroy(void* win_handle) {
    if (!win_handle) return;
    OscWin32Window* win = (OscWin32Window*)win_handle;
    if (win->bgra_buf) {
        free(win->bgra_buf);
        win->bgra_buf = NULL;
    }
    if (!win->is_offscreen_dummy && win->hwnd) {
        if (win->hdc) ReleaseDC(win->hwnd, win->hdc);
        DestroyWindow(win->hwnd);
    }
    free(win);
}

int osc_window_poll_event(void* win_handle, OscWindowEvent* out_event) {
    if (!win_handle || !out_event) return 0;
    OscWin32Window* win = (OscWin32Window*)win_handle;
    memset(out_event, 0, sizeof(OscWindowEvent));

    if (win->is_offscreen_dummy || !win->hwnd) return 0;

    MSG msg;
    if (PeekMessageW(&msg, win->hwnd, 0, 0, PM_REMOVE)) {
        switch (msg.message) {
            case WM_QUIT:
            case WM_CLOSE:
                out_event->kind = OSC_WINDOW_EVENT_QUIT;
                win->is_open = 0;
                return 1;
            case WM_SIZE:
                win->width = LOWORD(msg.lParam);
                win->height = HIWORD(msg.lParam);
                out_event->kind = OSC_WINDOW_EVENT_RESIZE;
                out_event->width = win->width;
                out_event->height = win->height;
                return 1;
            case WM_MOUSEMOVE:
                out_event->kind = OSC_WINDOW_EVENT_MOUSE_MOVE;
                out_event->x = LOWORD(msg.lParam);
                out_event->y = HIWORD(msg.lParam);
                return 1;
            case WM_LBUTTONDOWN:
                out_event->kind = OSC_WINDOW_EVENT_MOUSE_DOWN;
                out_event->x = LOWORD(msg.lParam);
                out_event->y = HIWORD(msg.lParam);
                out_event->button = 1;
                return 1;
            case WM_LBUTTONUP:
                out_event->kind = OSC_WINDOW_EVENT_MOUSE_UP;
                out_event->x = LOWORD(msg.lParam);
                out_event->y = HIWORD(msg.lParam);
                out_event->button = 1;
                return 1;
            case WM_KEYDOWN:
                out_event->kind = OSC_WINDOW_EVENT_KEY_DOWN;
                out_event->keycode = (int)msg.wParam;
                if (GetKeyState(VK_CONTROL) & 0x8000) out_event->is_ctrl = 1;
                if (GetKeyState(VK_SHIFT) & 0x8000) out_event->is_shift = 1;
                return 1;
            case WM_KEYUP:
                out_event->kind = OSC_WINDOW_EVENT_KEY_UP;
                out_event->keycode = (int)msg.wParam;
                return 1;
            default:
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
                break;
        }
    }
    return 0;
}

void osc_window_present(void* win_handle, const uint8_t* rgba_pixels, int width, int height) {
    if (!win_handle || !rgba_pixels || width <= 0 || height <= 0) return;
    OscWin32Window* win = (OscWin32Window*)win_handle;
    if (win->is_offscreen_dummy || !win->hwnd || !win->hdc) return;

    int total_pixels = width * height;
    if (win->bgra_buf_capacity < total_pixels) {
        free(win->bgra_buf);
        win->bgra_buf = (uint32_t*)malloc((size_t)total_pixels * sizeof(uint32_t));
        win->bgra_buf_capacity = total_pixels;
    }
    if (!win->bgra_buf) return;

    /* Flip vertically for bottom-up DIB and convert RGBA to BGRA */
    for (int y = 0; y < height; y++) {
        int src_y = y;
        int dst_y = height - 1 - y;
        for (int x = 0; x < width; x++) {
            int src_idx = (src_y * width + x) * 4;
            int dst_idx = dst_y * width + x;
            uint8_t r = rgba_pixels[src_idx + 0];
            uint8_t g = rgba_pixels[src_idx + 1];
            uint8_t b = rgba_pixels[src_idx + 2];
            uint8_t a = rgba_pixels[src_idx + 3];
            win->bgra_buf[dst_idx] = ((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
        }
    }

    BITMAPINFO bmi = {0};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    StretchDIBits(
        win->hdc,
        0, 0, width, height,
        0, 0, width, height,
        win->bgra_buf,
        &bmi,
        DIB_RGB_COLORS,
        SRCCOPY
    );
}

int osc_window_is_open(void* win_handle) {
    if (!win_handle) return 0;
    OscWin32Window* win = (OscWin32Window*)win_handle;
    return win->is_open;
}

#else
/* Stub for non-Windows */
#include "shell_shim.h"
int osc_shell_single_instance_lock(const char* user_data_path) { (void)user_data_path; return 1; }
void osc_shell_single_instance_unlock(void) {}
int osc_shell_tray_init(const char* tooltip, OscTrayCallback callback, void* user_data) { (void)tooltip; (void)callback; (void)user_data; return 1; }
void osc_shell_tray_update_state(int is_recording) { (void)is_recording; }
void osc_shell_tray_destroy(void) {}
int osc_shell_register_global_shortcut(const char* shortcut_desc, OscShortcutCallback callback, void* user_data) { (void)shortcut_desc; (void)callback; (void)user_data; return 1; }
void osc_shell_unregister_global_shortcut(void) {}
int osc_shell_set_window_content_protection(void* native_window_handle, int exclude) { (void)native_window_handle; (void)exclude; return 1; }
void* osc_window_create(const char* title, int width, int height, int resizable) { (void)title; (void)width; (void)height; (void)resizable; return (void*)1; }
void osc_window_destroy(void* win_handle) { (void)win_handle; }
int osc_window_poll_event(void* win_handle, OscWindowEvent* out_event) { (void)win_handle; (void)out_event; return 0; }
void osc_window_present(void* win_handle, const uint8_t* rgba_pixels, int width, int height) { (void)win_handle; (void)rgba_pixels; (void)width; (void)height; }
int osc_window_is_open(void* win_handle) { (void)win_handle; return 1; }
#endif
