// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

// Test-only: keeps windows created by unit tests invisible on the
// developer's screen. Just before a window is ordered in, it is made fully
// transparent and click-through. AppKit still reports it visible, so tests
// that depend on window state behave the same; offscreen rendering
// (cacheDisplay) is unaffected. Set PRISM_SHOW_TEST_WINDOWS=1 to see them.
// Linked into test targets only (through PrismTestSupport), never the app.

#include "PrismTestWindowGuard.h"
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef void (*OrderIMP)(id, SEL, long, long);
typedef void (*PlainIMP)(id, SEL);

static OrderIMP originalOrderWindow;
static PlainIMP originalOrderFrontRegardless;
static int installed;

static void hide(id window) {
    ((void (*)(id, SEL, double))objc_msgSend)(window, sel_registerName("setAlphaValue:"), 0.0);
    ((void (*)(id, SEL, bool))objc_msgSend)(window, sel_registerName("setIgnoresMouseEvents:"), true);
    ((void (*)(id, SEL, bool))objc_msgSend)(window, sel_registerName("setHasShadow:"), false);
}

static void hiddenOrderWindow(id self, SEL cmd, long place, long other) {
    if (place != 0) hide(self);   // 0 is NSWindowOut
    originalOrderWindow(self, cmd, place, other);
}

static void hiddenOrderFrontRegardless(id self, SEL cmd) {
    hide(self);
    originalOrderFrontRegardless(self, cmd);
}

int prism_test_window_guard_install(void) {
    if (installed) return installed > 0;
    const char *show = getenv("PRISM_SHOW_TEST_WINDOWS");
    if (show && strcmp(show, "1") == 0) { installed = -1; return 0; }
    Class window = objc_getClass("NSWindow");
    if (!window) return 0;
    Method order = class_getInstanceMethod(window, sel_registerName("orderWindow:relativeTo:"));
    Method regardless = class_getInstanceMethod(window, sel_registerName("orderFrontRegardless"));
    if (!order || !regardless) return 0;
    originalOrderWindow = (OrderIMP)method_setImplementation(order, (IMP)hiddenOrderWindow);
    originalOrderFrontRegardless = (PlainIMP)method_setImplementation(regardless, (IMP)hiddenOrderFrontRegardless);
    installed = 1;
    return 1;
}

__attribute__((constructor)) static void prism_test_window_guard_load(void) {
    prism_test_window_guard_install();
}
