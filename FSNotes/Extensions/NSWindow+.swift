//
//  NSWindow+.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 10.07.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

// MARK: - NSView Focus Border

extension NSView {
    /// Shows a 1-point accent-color focus border on this view's layer.
    func showFocusBorder() {
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.0
    }

    /// Removes the focus border from this view's layer.
    func hideFocusBorder() {
        layer?.borderWidth = 0
    }
}

extension NSWindow {
    public func setFrameOriginToPositionWindowInCenterOfScreen() {
        if let screenSize = screen?.frame.size {
            let origin = NSPoint(x: (screenSize.width-800)/2, y: (screenSize.height-600)/2)
            self.setFrame(NSRect(origin: origin, size: CGSize(width: 800, height: 600)), display: true)
        }
    }

    /// Creates a borderless, offscreen window suitable for hosting a WKWebView that
    /// needs to be in a window hierarchy to render content (required on recent macOS).
    /// The window must be placed INSIDE the main screen's frame so macOS associates it
    /// with the correct `NSScreen` and the window's `backingScaleFactor` returns the
    /// screen's scale (2× on Retina). A window placed outside all screens — or with
    /// no `screen` property — reports `backingScaleFactor = 1.0`, which produces
    /// fuzzy snapshots on Retina Macs even when the content was rendered at 2×.
    ///
    /// HiDPI v2 (2026-04-24): the prior implementation placed the window at
    /// `screenOrigin - (width + 20, 0)`, which on a main screen starting at (0, 0)
    /// means a NEGATIVE origin — fully off every screen — and macOS did NOT associate
    /// the window with a screen. This method now anchors at the main screen's
    /// `visibleFrame` origin (top-left of the main screen's usable area), forces
    /// association via `setFrame(display:)`, and verifies via an assertion that the
    /// window's `backingScaleFactor` matches the main screen's. The window is
    /// visible in principle but never ordered-front, so the user won't see it.
    static func makeOffscreen(width: CGFloat, height: CGFloat) -> NSWindow {
        let screen = NSScreen.main
        // Position at the main screen's visibleFrame origin so the window is
        // definitely INSIDE a screen's bounds. Using `visibleFrame` (not `frame`)
        // lands us below the menu bar but still on the main display.
        let origin = screen?.visibleFrame.origin ?? .zero
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // Force screen association. `setFrame(_:display:)` updates the window's
        // screen-association and `backingScaleFactor` based on the new frame.
        window.setFrame(frame, display: false, animate: false)
        return window
    }
}
