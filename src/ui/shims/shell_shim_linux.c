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
