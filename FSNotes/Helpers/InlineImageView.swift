//
//  InlineImageView.swift
//  FSNotes
//
//  TK2 view-provider machinery for inline image attachments. Parallels
//  `InlinePDFView.swift` and `InlineQuickLookView.swift` exactly: an
//  `NSTextAttachment` subclass holds the hosted image, overrides
//  `viewProvider(for:location:textContainer:)` to vend a
//  `NSTextAttachmentViewProvider`, and that provider hands a live
//  `InlineImageView` (an `NSImageView` subclass) to TextKit 2. TK2 then
//  owns the view's lifecycle, position, and viewport visibility.
//
//  This file covers Slices 1–4 of the image-resize TK2 migration plus
//  Phase 2f.5 (live invalidation):
//    - Slice 1: minimal display
//    - Slice 2: hit-testing + size measurement plumbing
//    - Slice 3: click-to-select and handle-overlay drawing
//    - Slice 4: drag-to-resize with width-hint commit
//    - Phase 2f.5: live TK2 layout invalidation mid-drag so surrounding
//      text reflows in real time while the user drags a corner handle
//      (previously the view frame grew but the surrounding line
//      geometry only updated on mouseUp — visible "text jumps" effect).
//
//  The TK1 path in `ImageAttachmentHydrator.swift` (via
//  `FSNTextAttachmentCell`) is untouched by this file and remains in
//  place for source-mode / fallback rendering.
//

import Cocoa

// MARK: - ImageNSTextAttachment (TK2)

/// TK2 `NSTextAttachment` subclass for inline images. Holds the loaded
/// `NSImage` (mutable, because the hydrator may set it asynchronously
/// after attachment creation) and vends an `ImageAttachmentViewProvider`
/// so TextKit 2 can host a live `InlineImageView`. Under TK2,
/// `NSTextAttachmentCell.draw(...)` is never called — view hosting must
/// go through `NSTextAttachmentViewProvider`.
public final class ImageNSTextAttachment: NSTextAttachment {

    /// The loaded image hosted by the view provider. Mutable — the
    /// hydrator may set this AFTER the attachment was created (for
    /// async image loading). When it mutates, call `invalidateDisplay()`
    /// on the attachment or invalidate layout externally.
    public var hostedImage: NSImage?

    public init(image: NSImage?, size: NSSize) {
        self.hostedImage = image
        super.init(data: nil, ofType: nil)
        // TK1 still reads `.image` for FSNTextAttachmentCell sizing, so
        // keep the base property in sync when we have an image.
        self.image = image
        self.bounds = NSRect(origin: .zero, size: size)
    }

    public required init?(coder: NSCoder) {
        fatalError("ImageNSTextAttachment is not NSCoder-backed")
    }

    public override func viewProvider(
        for parentView: NSView?,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = ImageAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

// MARK: - ImageAttachmentViewProvider (TK2)

/// `NSTextAttachmentViewProvider` that constructs an `InlineImageView`
/// seeded with the attachment's hosted image and bounds, then hands it
/// to TextKit 2. TK2 manages inserting the view into the text view's
/// hierarchy and positioning it within the viewport.
public final class ImageAttachmentViewProvider: NSTextAttachmentViewProvider {

    public override func loadView() {
        super.loadView()
        let imageView = InlineImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = (textAttachment as? ImageNSTextAttachment)?.hostedImage
        imageView.frame = NSRect(
            origin: .zero,
            size: textAttachment?.bounds.size ?? .zero
        )
        // Slice 4: wire commit-on-mouseUp back to the editor. The closure
        // captures the provider weakly so the attachment + location +
        // textLayoutManager can be resolved lazily at commit time (they
        // may mutate between load and drag-end if the document reflowed).
        // The provider walks the view hierarchy to find the hosting
        // EditTextView, then routes through a public commit method which
        // resolves (blockIndex, inlineOffset) and calls EditingOps.setImageSize.
        imageView.onResizeCommit = { [weak self, weak imageView] newWidth in
            guard let self = self, let imageView = imageView else { return }
            self.commitResize(from: imageView, newWidth: newWidth)
        }
        // Phase 2f.5: live mid-drag invalidation. As the user drags a
        // corner handle, the view's frame grows (see
        // `InlineImageView.mouseDragged`), but the surrounding line
        // fragments won't reflow until something invalidates layout on
        // the hosting `NSTextLayoutManager`. `tracksTextAttachmentViewBounds`
        // above nudges TK2 when the view's bounds observably change,
        // but the nudge is not guaranteed to fire on every drag step,
        // and TK2 still reads `attachment.bounds` (not the view frame)
        // for line-fragment sizing. Update both explicitly on every
        // drag tick so text reflow is immediate.
        imageView.onResizeLiveUpdate = { [weak self] newSize in
            guard let self = self else { return }
            Self.applyLiveResize(
                attachment: self.textAttachment,
                newSize: newSize,
                textLayoutManager: self.textLayoutManager,
                location: self.location
            )
        }
        self.view = imageView
    }

    /// Pure helper extracted for Phase 2f.5 unit-testability. Given a
    /// live-drag tick (new proposed view size) and the TK2 triple
    /// (attachment, layout manager, location), update
    /// `attachment.bounds` and invalidate layout for the attachment's
    /// single-character range so the hosting line fragment re-measures.
    ///
    /// No-op if any input is missing or the location → NSTextRange
    /// conversion fails (the document may have mutated between the
    /// drag start and this tick). Returns `true` iff invalidation was
    /// actually issued — the boolean is for test assertions, callers
    /// don't need to read it.
    @discardableResult
    public static func applyLiveResize(
        attachment: NSTextAttachment?,
        newSize: NSSize,
        textLayoutManager: NSTextLayoutManager?,
        location: NSTextLocation?
    ) -> Bool {
        guard let attachment = attachment else { return false }
        // Update attachment bounds so TK2 line-fragment sizing sees
        // the new dimensions. The bounds origin is kept at .zero — TK2
        // positions the attachment via the view-provider, not via a
        // non-zero bounds origin.
        attachment.bounds = NSRect(origin: .zero, size: newSize)

        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let loc = location,
              let endLoc = tcs.location(loc, offsetBy: 1),
              let range = NSTextRange(location: loc, end: endLoc)
        else { return false }
        tlm.invalidateLayout(for: range)
        return true
    }

    /// Resolve the hosting `EditTextView` + storage character index for
    /// this attachment, then ask the editor to commit the new width via
    /// its block-model commit entry point. No-op if any link is missing
    /// (e.g. the view got detached between drag-start and drag-end).
    private func commitResize(from imageView: InlineImageView, newWidth: CGFloat) {
        // Walk superview chain to find the hosting text view. TK2 hosts
        // provider views inside the text view's hierarchy, so `superview`
        // chain resolves to the EditTextView eventually.
        var candidate: NSView? = imageView.superview
        while let v = candidate, !(v is EditTextView) {
            candidate = v.superview
        }
        guard let editor = candidate as? EditTextView,
              let attachment = textAttachment
        else { return }

        editor.commitImageResize(attachment: attachment, newWidth: newWidth)
    }
}

// MARK: - InlineImageView

/// NSImageView subclass for inline image attachments under TK2.
/// Hosted by `ImageAttachmentViewProvider` — TK2 manages the view's
/// lifecycle, position, and viewport visibility automatically.
///
/// Slice 1: minimal display.
/// Slice 3 (this file): click-to-select + handle-overlay drawing. A
/// click toggles `isSelected`. When selected the view paints a 2pt
/// accent-color ring plus 4 corner handles (8×8 white fill, 1pt accent
/// stroke) on top of the image content. Visual parity with the TK1
/// `ImageSelectionHandleDrawer` is intentional — users shouldn't see
/// a cosmetic difference when we flip pipelines.
/// Slice 4 will add drag-to-resize + width-hint commit; `handleHitTest`
/// is exposed here as the seam that slice will consume.
public class InlineImageView: NSImageView {

    /// Identifier for the 4 corner handles. Used by Slice 4's drag
    /// logic to know which corner the user grabbed.
    public enum ResizeHandle {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Whether this image is currently the selected image attachment.
    /// Flipping this redraws the overlay.
    public var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
        }
    }

    /// Slice 4: callback fired on mouseUp when a resize drag ended with
    /// a committed width change. The argument is the new width in points.
    /// `ImageAttachmentViewProvider.loadView()` wires this to route
    /// through `EditTextView.commitImageResize`.
    public var onResizeCommit: ((CGFloat) -> Void)?

    /// Phase 2f.5: callback fired on every `mouseDragged` tick while a
    /// resize is in progress. The argument is the proposed new view
    /// size (width, height). `ImageAttachmentViewProvider.loadView()`
    /// wires this to `applyLiveResize`, which updates
    /// `attachment.bounds` and invalidates the hosting fragment's
    /// layout so surrounding text reflows in real time. Without this
    /// the view frame grows but the text around it doesn't move until
    /// mouseUp — visible "text jumps" at commit.
    public var onResizeLiveUpdate: ((NSSize) -> Void)?

    // MARK: - Drag state (Slice 4)

    /// Non-nil while the user is actively dragging a resize handle.
    private var activeHandle: ResizeHandle?
    /// Window-space mouse location at drag start. Window coordinates are
    /// used (not view-local) so horizontal deltas are unaffected by
    /// the view reflowing mid-drag — the mouse location is the user's
    /// intent and stays in a stable frame.
    private var dragStartPoint: NSPoint = .zero
    /// Frame size at drag start. Subsequent frames are computed as
    /// (startSize + delta), not (currentFrame + delta), so micro-deltas
    /// don't compound and the reverse direction unwinds cleanly.
    private var dragStartSize: NSSize = .zero

    /// Minimum width (in points) a handle drag can shrink to. Matches
    /// the clamp in `EditTextView+Interaction.swift`'s TK1 drag path
    /// (20pt) plus a margin so two handles don't overlap at min size.
    private static let minResizeWidth: CGFloat = 50

    public override init(frame: NSRect) {
        super.init(frame: frame)
        imageFrameStyle = .none
        isEditable = false
    }

    public required init?(coder: NSCoder) {
        fatalError("InlineImageView is not NSCoder-backed")
    }

    // MARK: - Interaction

    public override func mouseDown(with event: NSEvent) {
        // Slice 4: if the click landed on a corner handle, prime the
        // drag. Otherwise fall through to Slice 3's toggle-selection
        // behavior. The handle path deliberately asserts `isSelected =
        // true` (not toggle) — you cannot grab a handle on an
        // unselected image (handles aren't drawn), so a hit here always
        // means the image is already selected and must stay selected.
        let localPoint = convert(event.locationInWindow, from: nil)
        if let handle = handleHitTest(at: localPoint) {
            activeHandle = handle
            dragStartPoint = event.locationInWindow
            dragStartSize = bounds.size
            isSelected = true
            return
        }

        // Clicking this image selects it. Deselecting other images is
        // the responsibility of a coordinator (not implemented here —
        // this image just flips its own state).
        isSelected = !isSelected
        // Do NOT call super — default NSImageView mouseDown opens a
        // menu / enables editing, which we don't want.
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let handle = activeHandle else {
            super.mouseDragged(with: event)
            return
        }

        let dx = event.locationInWindow.x - dragStartPoint.x
        // Horizontal delta drives the new width. Sign depends on which
        // corner the user grabbed: left-side handles grow as the mouse
        // moves left (negative dx), right-side handles grow as the
        // mouse moves right. Aspect ratio is locked — height derives
        // from width.
        let widthDelta: CGFloat
        switch handle {
        case .topLeft, .bottomLeft:
            widthDelta = -dx
        case .topRight, .bottomRight:
            widthDelta = dx
        }
        let newWidth = max(Self.minResizeWidth, dragStartSize.width + widthDelta)
        let aspect = dragStartSize.width > 0
            ? dragStartSize.height / dragStartSize.width
            : 1.0
        let newHeight = newWidth * aspect

        // Live visual update. No EditingOps call here — that runs once
        // on mouseUp. Resizing the frame re-triggers draw(...) which
        // repositions the handle overlay to match.
        let newSize = NSSize(width: newWidth, height: newHeight)
        frame = NSRect(
            x: frame.origin.x, y: frame.origin.y,
            width: newSize.width, height: newSize.height
        )
        needsDisplay = true

        // Phase 2f.5: notify the provider so it can update
        // `attachment.bounds` and invalidate the hosting TK2 fragment.
        // This keeps surrounding line fragments in sync with the
        // live-resizing image — without it, text reflow only happens
        // at commit time and the user sees a visible "jump".
        onResizeLiveUpdate?(newSize)
    }

    public override func mouseUp(with event: NSEvent) {
        // Capture whether a drag was in-progress BEFORE clearing, so the
        // defer-based cleanup cannot race with the callback dispatch.
        let hadActiveDrag = activeHandle != nil
        activeHandle = nil
        guard hadActiveDrag else {
            super.mouseUp(with: event)
            return
        }
        // Skip the commit if the frame width didn't change (handle
        // click-and-release with no motion). Avoids a no-op undo step.
        if abs(frame.width - dragStartSize.width) < 0.5 {
            return
        }
        onResizeCommit?(frame.width)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSelected else { return }
        drawSelectionOverlay()
    }

    private func drawSelectionOverlay() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Selection ring: 2pt stroke inset so the line sits inside the
        // image edge rather than clipping outside the bounds.
        let ringInset = Self.ringWidth / 2
        let ringRect = bounds.insetBy(dx: ringInset, dy: ringInset)
        context.setStrokeColor(Self.selectionColor.cgColor)
        context.setLineWidth(Self.ringWidth)
        context.stroke(ringRect)

        // 4 corner handles: white fill with a 1pt accent border for
        // contrast against both light and dark image content.
        for center in Self.handleCenters(in: bounds) {
            let handleRect = CGRect(
                x: center.x - Self.handleSize / 2,
                y: center.y - Self.handleSize / 2,
                width: Self.handleSize,
                height: Self.handleSize
            )
            context.setFillColor(NSColor.white.cgColor)
            context.fill(handleRect)
            context.setStrokeColor(Self.selectionColor.cgColor)
            context.setLineWidth(1.0)
            context.stroke(handleRect)
        }
    }

    // MARK: - Handle hit-testing (public seam for Slice 4)

    /// Given a point in this view's local coordinates, return which
    /// corner handle (if any) it falls inside. Slice 4 will call this
    /// from `mouseDown(with:)` BEFORE flipping selection, so a click
    /// on a handle starts a drag instead of toggling selection.
    public func handleHitTest(at localPoint: CGPoint) -> ResizeHandle? {
        let s = Self.handleSize
        let corners: [(ResizeHandle, CGPoint)] = [
            (.topLeft,     CGPoint(x: bounds.minX, y: bounds.minY)),
            (.topRight,    CGPoint(x: bounds.maxX, y: bounds.minY)),
            (.bottomLeft,  CGPoint(x: bounds.minX, y: bounds.maxY)),
            (.bottomRight, CGPoint(x: bounds.maxX, y: bounds.maxY)),
        ]
        for (handle, center) in corners {
            let rect = CGRect(
                x: center.x - s / 2,
                y: center.y - s / 2,
                width: s,
                height: s
            )
            if rect.contains(localPoint) {
                return handle
            }
        }
        return nil
    }

    // MARK: - Constants (match TK1 ImageSelectionHandleDrawer for visual parity)

    private static let ringWidth: CGFloat = 2.0
    private static let handleSize: CGFloat = 8.0
    private static let selectionColor = NSColor.controlAccentColor

    /// Geometric centers of the 4 corner handles for a given rect.
    /// Kept as a single source of truth shared between `draw` and
    /// `handleHitTest` so the two can't drift.
    private static func handleCenters(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }
}
