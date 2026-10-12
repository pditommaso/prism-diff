// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismTestWindowGuard
import Testing

/// Windows that tests put on screen stay invisible to the developer.
@MainActor
@Test func testWindowsAreInvisible() {
    _ = NSApplication.shared
    #expect(prism_test_window_guard_install() == 1)
    // Borderless and far off-screen, so nothing shows even if the guard failed.
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 50, height: 50),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    #expect(window.isVisible)
    #expect(window.alphaValue == 0)
    #expect(window.ignoresMouseEvents)
    window.orderOut(nil)
    let other = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 50, height: 50),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    other.orderFrontRegardless()
    #expect(other.alphaValue == 0)
    other.orderOut(nil)
}
