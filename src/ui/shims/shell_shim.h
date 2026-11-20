#ifndef OPENSCREEN_SHELL_SHIM_H
#define OPENSCREEN_SHELL_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Single-Instance Lock */
/* Returns 1 if lock acquired (primary instance). Returns 0 if already locked (secondary instance, signals primary). */
int osc_shell_single_instance_lock(const char* user_data_path);
void osc_shell_single_instance_unlock(void);

/* Tray Menu Actions */
typedef enum {
    OSC_TRAY_ACTION_START_STOP_RECORDING = 1,
    OSC_TRAY_ACTION_OPEN_EDITOR          = 2,
    OSC_TRAY_ACTION_SETTINGS             = 3,
    OSC_TRAY_ACTION_QUIT                 = 4
} OscTrayAction;

typedef void (*OscTrayCallback)(OscTrayAction action, void* user_data);

/* System Tray */
int osc_shell_tray_init(const char* tooltip, OscTrayCallback callback, void* user_data);
void osc_shell_tray_update_state(int is_recording);
void osc_shell_tray_destroy(void);

/* Global Shortcut (Cmd/Ctrl + Shift + O) */
typedef void (*OscShortcutCallback)(void* user_data);
int osc_shell_register_global_shortcut(const char* shortcut_desc, OscShortcutCallback callback, void* user_data);
void osc_shell_unregister_global_shortcut(void);

/* Content-Protection Exclusion */
/* Excludes native window handle from screen capture */
int osc_shell_set_window_content_protection(void* native_window_handle, int exclude);

/* Native Windowing & Event Loop */
typedef enum {
    OSC_WINDOW_EVENT_NONE       = 0,
    OSC_WINDOW_EVENT_QUIT       = 1,
    OSC_WINDOW_EVENT_CLOSE      = 2,
    OSC_WINDOW_EVENT_RESIZE     = 3,
    OSC_WINDOW_EVENT_MOUSE_MOVE = 4,
    OSC_WINDOW_EVENT_MOUSE_DOWN = 5,
    OSC_WINDOW_EVENT_MOUSE_UP   = 6,
    OSC_WINDOW_EVENT_KEY_DOWN   = 7,
    OSC_WINDOW_EVENT_KEY_UP     = 8
} OscWindowEventKind;

typedef struct {
    int kind;      /* OscWindowEventKind */
    int x;
    int y;
    int button;    /* 1: left, 2: middle, 3: right */
    int keycode;   /* ASCII or key identifier */
    int width;
    int height;
    int is_ctrl;
    int is_shift;
} OscWindowEvent;

void* osc_window_create(const char* title, int width, int height, int resizable);
void osc_window_destroy(void* win_handle);
int osc_window_poll_event(void* win_handle, OscWindowEvent* out_event);
void osc_window_present(void* win_handle, const uint8_t* rgba_pixels, int width, int height);
int osc_window_is_open(void* win_handle);

#ifdef __cplusplus
}
#endif

#endif /* OPENSCREEN_SHELL_SHIM_H */
