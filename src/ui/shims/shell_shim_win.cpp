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
#endif
