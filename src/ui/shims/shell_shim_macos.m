#import <Cocoa/Cocoa.h>
#include "shell_shim.h"
#include <sys/file.h>
#include <unistd.h>
#include <fcntl.h>

static int g_mac_lock_fd = -1;
static char g_mac_lock_path[1024] = {0};
static NSStatusItem* g_status_item = nil;
static OscTrayCallback g_mac_tray_cb = NULL;
static void* g_mac_tray_user_data = NULL;
static id g_shortcut_monitor = nil;

@interface OscTrayTarget : NSObject
- (void)onStartStop:(id)sender;
- (void)onOpenEditor:(id)sender;
- (void)onSettings:(id)sender;
- (void)onQuit:(id)sender;
@end

@implementation OscTrayTarget
- (void)onStartStop:(id)sender {
    (void)sender;
    if (g_mac_tray_cb) g_mac_tray_cb(OSC_TRAY_ACTION_START_STOP_RECORDING, g_mac_tray_user_data);
}
- (void)onOpenEditor:(id)sender {
    (void)sender;
    if (g_mac_tray_cb) g_mac_tray_cb(OSC_TRAY_ACTION_OPEN_EDITOR, g_mac_tray_user_data);
}
- (void)onSettings:(id)sender {
    (void)sender;
    if (g_mac_tray_cb) g_mac_tray_cb(OSC_TRAY_ACTION_SETTINGS, g_mac_tray_user_data);
}
- (void)onQuit:(id)sender {
    (void)sender;
    if (g_mac_tray_cb) g_mac_tray_cb(OSC_TRAY_ACTION_QUIT, g_mac_tray_user_data);
}
@end

static OscTrayTarget* g_tray_target = nil;

int osc_shell_single_instance_lock(const char* user_data_path) {
    if (g_mac_lock_fd >= 0) return 1;

    if (user_data_path && strlen(user_data_path) > 0) {
        mkdir(user_data_path, 0755);
        snprintf(g_mac_lock_path, sizeof(g_mac_lock_path), "%s/openscreen.lock", user_data_path);
    } else {
        snprintf(g_mac_lock_path, sizeof(g_mac_lock_path), "/tmp/openscreen_%d.lock", getuid());
    }

    int fd = open(g_mac_lock_path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return 0;

    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        /* Already running: focus existing app */
        @autoreleasepool {
            NSRunningApplication* app = [NSRunningApplication currentApplication];
            [app activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
        }
        close(fd);
        return 0;
    }

    g_mac_lock_fd = fd;
    return 1;
}

void osc_shell_single_instance_unlock(void) {
    if (g_mac_lock_fd >= 0) {
        flock(g_mac_lock_fd, LOCK_UN);
        close(g_mac_lock_fd);
        g_mac_lock_fd = -1;
        if (g_mac_lock_path[0]) {
            unlink(g_mac_lock_path);
            g_mac_lock_path[0] = '\0';
        }
    }
}

int osc_shell_tray_init(const char* tooltip, OscTrayCallback callback, void* user_data) {
    g_mac_tray_cb = callback;
    g_mac_tray_user_data = user_data;

    @autoreleasepool {
        g_status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        if (!g_status_item) return 0;

        NSImage* icon = [NSImage imageNamed:@"NSStatusAvailable"];
        if (g_status_item.button) {
            g_status_item.button.image = icon;
            if (tooltip) {
                g_status_item.button.toolTip = [NSString stringWithUTF8String:tooltip];
            }
        }

        g_tray_target = [[OscTrayTarget alloc] init];
        NSMenu* menu = [[NSMenu alloc] initWithTitle:@"OpenScreen"];

        NSMenuItem* itemRec = [[NSMenuItem alloc] initWithTitle:@"Start/Stop Recording" action:@selector(onStartStop:) keyEquivalent:@""];
        [itemRec setTarget:g_tray_target];
        [menu addItem:itemRec];

        NSMenuItem* itemEd = [[NSMenuItem alloc] initWithTitle:@"Open Editor" action:@selector(onOpenEditor:) keyEquivalent:@""];
        [itemEd setTarget:g_tray_target];
        [menu addItem:itemEd];

        NSMenuItem* itemSet = [[NSMenuItem alloc] initWithTitle:@"Settings" action:@selector(onSettings:) keyEquivalent:@""];
        [itemSet setTarget:g_tray_target];
        [menu addItem:itemSet];

        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem* itemQuit = [[NSMenuItem alloc] initWithTitle:@"Quit OpenScreen" action:@selector(onQuit:) keyEquivalent:@"q"];
        [itemQuit setTarget:g_tray_target];
        [menu addItem:itemQuit];

        g_status_item.menu = menu;
    }
    return 1;
}

void osc_shell_tray_update_state(int is_recording) {
    if (!g_status_item || !g_status_item.menu) return;
    @autoreleasepool {
        NSMenuItem* item = [g_status_item.menu itemAtIndex:0];
        if (item) {
            [item setTitle:is_recording ? @"Stop Recording" : @"Start Recording"];
        }
    }
}

void osc_shell_tray_destroy(void) {
    if (g_status_item) {
        [[NSStatusBar systemStatusBar] removeStatusItem:g_status_item];
        g_status_item = nil;
    }
    g_tray_target = nil;
    g_mac_tray_cb = NULL;
    g_mac_tray_user_data = NULL;
}

int osc_shell_register_global_shortcut(const char* shortcut_desc, OscShortcutCallback callback, void* user_data) {
    (void)shortcut_desc;
    @autoreleasepool {
        g_shortcut_monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^(NSEvent* event) {
            // Check Cmd+Shift+O: 0x1F is kVK_ANSI_O
            NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
            if ((flags == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) && [event keyCode] == 0x1F) {
                if (callback) callback(user_data);
            }
        }];
    }
    return 1;
}

void osc_shell_unregister_global_shortcut(void) {
    if (g_shortcut_monitor) {
        [NSEvent removeMonitor:g_shortcut_monitor];
        g_shortcut_monitor = nil;
    }
}

int osc_shell_set_window_content_protection(void* native_window_handle, int exclude) {
    if (!native_window_handle) return 0;
    @autoreleasepool {
        NSWindow* window = (__bridge NSWindow*)native_window_handle;
        if ([window respondsToSelector:@selector(setSharingType:)]) {
            [window setSharingType:exclude ? NSWindowSharingNone : NSWindowSharingReadOnly];
            return 1;
        }
    }
    return 0;
}
