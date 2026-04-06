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
    /// The window is positioned just outside the main screen (at screen origin - window size)
    /// so it inherits the main screen's backingScaleFactor for retina rendering. A window
    /// positioned at (-10000, -10000) is off all screens and reports backingScaleFactor = 1.0,
    /// producing fuzzy snapshots on retina Macs.
    static func makeOffscreen(width: CGFloat, height: CGFloat) -> NSWindow {
        // Anchor to the main screen's origin, offset by the window size so the window
        // is fully off-visible-area but still associated with the main screen.
        let screenOrigin = NSScreen.main?.frame.origin ?? .zero
        let origin = NSPoint(x: screenOrigin.x - width - 20, y: screenOrigin.y)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        return window
    }
}
