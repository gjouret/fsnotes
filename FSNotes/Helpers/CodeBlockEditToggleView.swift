//
//  CodeBlockEditToggleView.swift
//  FSNotes
//
//  Phase 8 — Code-Block Edit Toggle — Slice 3.
//
//  A small rounded-rect NSView with an SF Symbol
//  `chevron.left.forwardslash.chevron.right` that sits at the top-right
//  of each visible code block. Click toggles the block's membership in
//  `EditTextView.editingCodeBlocks`; the overlay controller
//  (`CodeBlockEditToggleOverlay`) owns positioning and pooling.
//
//  Three visual states:
//    - idle   : alpha 0.0 (invisible, but still hit-testable by mouse
//               hover via the tracking area).
//    - hover  : alpha 0.5, `backgroundHover` fill.
//    - active : alpha 0.9, `backgroundActive` fill. Used when the
//               block is currently in editing form — so the user can
//               see where they are and click to exit.
//    - active + hover collapses to active (alpha 0.9).
//
//  Colors and geometry come from
//  `Theme.shared.chrome.codeBlockEditToggle`. No hardcoded values
//  inside this view — add them to `ThemeCodeBlockEditToggle` if a new
//  knob is needed.
//
//  Click handling is delegated to `onClick`, a closure the overlay sets
//  at creation time. The view itself does nothing with the click except
//  call the closure. This keeps the view pure (no reference to
//  `EditTextView` or `BlockRef`); the overlay holds the block-identity
//  state.
//

import Cocoa

final class CodeBlockEditToggleView: NSView {

    // MARK: - External API

    /// Whether the toggle is "active" — i.e. the owning code block is
    /// currently in editing form (`editingCodeBlocks.contains(ref)`).
    /// Changes drive the visual state via `updateAppearance()`.
    var isActive: Bool = false {
        didSet {
            guard oldValue != isActive else { return }
            updateAppearance()
        }
    }

    /// Invoked on mouseUp inside the view. The overlay installs the
    /// handler; the view itself is identity-agnostic.
    var onClick: (() -> Void)?

    // MARK: - Internals

    private let iconImageView: NSImageView = {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.isEditable = false
        return iv
    }()

    private var trackingArea: NSTrackingArea?
    private var isHovering: Bool = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateAppearance()
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = Theme.shared.chrome.codeBlockEditToggle.cornerRadius
        layer?.masksToBounds = true

        addSubview(iconImageView)
        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.7),
            iconImageView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.7)
        ])

        // SF Symbol `chevron.left.forwardslash.chevron.right` is
        // available on macOS 11+ (the app's min deployment target).
        let image: NSImage? = NSImage(
            systemSymbolName: "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: "Toggle code block edit form"
        )
        iconImageView.image = image

        alphaValue = 0.0
        updateAppearance()
    }

    // MARK: - Tracking area (hover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect,
            .assumeInside
        ]
        let area = NSTrackingArea(
            rect: bounds, options: options, owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            onClick?()
        }
    }

    // MARK: - Appearance

    /// Recompute `alphaValue`, `layer.backgroundColor`, and the icon
    /// tint from the current (isActive, isHovering) state against the
    /// active theme.
    private func updateAppearance() {
        let toggle = Theme.shared.chrome.codeBlockEditToggle
        let isDark = effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua

        // Foreground: secondary label if the asset resolves, else the
        // hex fallback. On macOS with the (non-existent) "secondaryLabel"
        // asset this falls through to `NSColor.secondaryLabelColor`.
        let fgFallback: NSColor = NSColor.secondaryLabelColor
        let fg = toggle.foreground.resolved(
            dark: isDark, fallback: fgFallback
        )
        iconImageView.contentTintColor = fg

        // Background + alpha by state.
        let alpha: CGFloat
        let bg: NSColor
        switch (isActive, isHovering) {
        case (true, _):
            alpha = 0.9
            bg = toggle.backgroundActive.resolved(
                dark: isDark, fallback: .clear
            )
        case (false, true):
            alpha = 0.5
            bg = toggle.backgroundHover.resolved(
                dark: isDark, fallback: .clear
            )
        case (false, false):
            alpha = 0.0
            bg = .clear
        }

        layer?.cornerRadius = toggle.cornerRadius
        layer?.backgroundColor = bg.cgColor
        alphaValue = alpha
    }

    // MARK: - Appearance change (dark/light)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
}
