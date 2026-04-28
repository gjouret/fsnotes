//
//  InlineQuickLookView.swift
//  FSNotes
//
//  Inline file preview for WYSIWYG mode. Uses Apple's QLPreviewView to
//  render any file type that QuickLook supports (.numbers, .pages, .key,
//  .docx, .xlsx, .pptx, .rtf, .zip, etc.) inline in the note editor.
//
//  Architecture (mirrors InlinePDFView, TK2):
//  - InlineQuickLookView wraps a QLPreviewView with an "Open" button.
//  - QuickLookNSTextAttachment stores value types only (URL + size).
//    It does NOT cache an InlineQuickLookView; the view is built fresh
//    by the provider each time TK2 attaches it.
//  - QuickLookAttachmentViewProvider constructs a fresh InlineQuickLookView
//    in loadView(), seeded from the attachment's URL + size. This
//    mirrors the image / PDF pattern and avoids a scroll-recycle bug
//    where a cached QLPreviewView loses its rendered thumbnail after
//    being detached from the window and reattached.
//  - QuickLookAttachmentProcessor scans textStorage for non-image,
//    non-PDF attachments and replaces them with attachment characters.
//
//  Bug #19 — async re-render on scroll-recycle:
//    Even with a fresh InlineQuickLookView per loadView(), QLPreviewView's
//    async render does not always re-fire after scroll-recycle (most
//    visibly with `.numbers`). Two-layer fix:
//      1. Re-set `previewItem` in `viewDidMoveToWindow` to force reload.
//      2. NSImageView fallback rendered behind the preview from a
//         process-wide `QuickLookThumbnailCache` so the user always sees
//         the document while QLPreviewView re-hydrates.
//

import Cocoa
import Quartz
import QuickLookThumbnailing

// MARK: - QuickLookThumbnailCache

/// Process-wide cache of rendered QuickLook thumbnails keyed by URL.
/// Used as a synchronously-displayable fallback while `QLPreviewView`
/// re-hydrates after a scroll-recycle. Without this cache the user sees
/// an empty preview frame for a few hundred milliseconds (or, for some
/// file types like `.numbers`, indefinitely if QLPreviewView fails to
/// kick its render after the view re-enters the window hierarchy).
///
/// The cache is cheap — a thumbnail for a typical embed is a 600x400
/// NSImage, ~1 MB peak; we cap the cache by NSCache's count limit.
enum QuickLookThumbnailCache {

    /// Process-wide cache. NSCache is thread-safe and self-evicts under
    /// memory pressure.
    static let shared: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Synchronously return a cached thumbnail for `url`, or nil if not
    /// yet rendered. Callers must tolerate a nil return — rendering is
    /// asynchronous and the cache fills opportunistically.
    static func cachedThumbnail(for url: URL) -> NSImage? {
        return shared.object(forKey: url as NSURL)
    }

    /// Render a thumbnail for `url` at `size` (points) using
    /// `QLThumbnailGenerator` and store it in the cache when ready.
    /// `completion` runs on the main thread with the rendered image
    /// (or nil on failure). Idempotent: if a thumbnail is already
    /// cached, the completion fires synchronously with the cached value.
    static func renderThumbnail(
        for url: URL,
        size: NSSize,
        completion: @escaping (NSImage?) -> Void
    ) {
        if let cached = cachedThumbnail(for: url) {
            completion(cached)
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image: NSImage?
            if let rep = rep {
                image = rep.nsImage
            } else {
                image = nil
            }
            DispatchQueue.main.async {
                if let image = image {
                    shared.setObject(image, forKey: url as NSURL)
                }
                completion(image)
            }
        }
    }
}

// MARK: - InlineQuickLookView

/// A container view that wraps QLPreviewView for inline display in
/// the note editor. Shows a QuickLook preview with a toolbar containing
/// the filename and an "Open" button that launches the native app.
class InlineQuickLookView: NSView {

    // MARK: - Properties

    let fileURL: URL
    private var previewView: QLPreviewView!
    private var toolbarView: NSView!
    private var filenameLabel: NSTextField!
    private var openButton: NSButton!
    private var separatorView: NSView!
    private var containerWidth: CGFloat
    /// Fallback thumbnail layer rendered behind the QLPreviewView.
    /// Stays visible as long as we have a cached thumbnail; covers the
    /// brief gap while QLPreviewView async-renders after the view is
    /// reattached to the window (Bug #19 — Numbers thumbnail loss on
    /// scroll-recycle).
    private var thumbnailFallback: NSImageView!

    /// Maximum height for the preview (scales with note font).
    private var maxHeight: CGFloat {
        return Self.maxHeight(forFontSize: UserDefaultsManagement.noteFont.pointSize)
    }

    /// Toolbar height derived from note font.
    private var toolbarHeight: CGFloat {
        return Self.toolbarHeight(forFontSize: UserDefaultsManagement.noteFont.pointSize)
    }

    /// Font-derived maximum preview height. Static so the processor
    /// path can compute size from URL + container width alone.
    static func maxHeight(forFontSize fontSize: CGFloat) -> CGFloat {
        return max(400, fontSize * 30)
    }

    /// Font-derived toolbar height. Static to mirror `maxHeight`.
    static func toolbarHeight(forFontSize fontSize: CGFloat) -> CGFloat {
        return ceil(fontSize * 2.8)
    }

    // MARK: - Init

    init(url: URL, containerWidth: CGFloat) {
        self.fileURL = url
        self.containerWidth = containerWidth
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5

        let fontSize = UserDefaultsManagement.noteFont.pointSize * 1.0
        let smallFont = NSFont.systemFont(ofSize: fontSize)

        // --- Toolbar at top ---
        toolbarView = NSView()
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        addSubview(toolbarView)

        separatorView = NSView()
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separatorView)

        // File icon + name label (left side)
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = NSSize(width: fontSize + 2, height: fontSize + 2)
        let iconView = NSImageView(image: icon)
        iconView.frame = NSRect(x: 8, y: 0, width: fontSize + 4, height: fontSize + 4)
        iconView.tag = 100
        addSubview(iconView)

        filenameLabel = NSTextField(labelWithString: fileURL.lastPathComponent)
        filenameLabel.font = smallFont
        filenameLabel.textColor = NSColor.secondaryLabelColor
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(filenameLabel)

        // "Open" button (right side)
        openButton = NSButton(title: "Open", target: self, action: #selector(openInNativeApp))
        openButton.bezelStyle = .accessoryBarAction
        openButton.font = smallFont
        openButton.controlSize = .small
        addSubview(openButton)

        // --- Thumbnail fallback (rendered BEHIND the QLPreviewView) ---
        // Bug #19: when TK2 scrolls a QuickLook attachment out and back
        // in, the QLPreviewView's async render sometimes does not
        // re-fire (most reliably observed with `.numbers` files). The
        // fallback layer displays a cached thumbnail so the user always
        // sees the document while QLPreviewView re-hydrates. If the
        // cache is empty, the fallback stays hidden and we render the
        // thumbnail lazily for next time.
        thumbnailFallback = NSImageView()
        thumbnailFallback.imageScaling = .scaleProportionallyUpOrDown
        thumbnailFallback.imageAlignment = .alignCenter
        thumbnailFallback.isHidden = true
        addSubview(thumbnailFallback)

        // --- QuickLook preview ---
        previewView = QLPreviewView(frame: .zero, style: .compact)!
        previewView.autostarts = true
        previewView.previewItem = fileURL as QLPreviewItem
        addSubview(previewView)

        // Bug #23: double-click anywhere on the inline preview opens
        // the underlying file in its default macOS app (Numbers,
        // Pages, etc.). Same rationale as InlinePDFView — QLPreviewView
        // consumes mouse events on its own surface, so a `mouseDown`
        // override on the container would never fire for clicks
        // landing on the preview content. A click gesture recognizer
        // intercepts before subviews see the event. Single clicks are
        // not captured, so default selection / focus behavior in the
        // QuickLook content is preserved.
        let doubleClick = NSClickGestureRecognizer(
            target: self, action: #selector(handleDoubleClick(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)

        // Show cached thumbnail (if any) and kick off async render so
        // it's available next time the view recycles.
        refreshThumbnailFallback()

        layoutSubviews()
    }

    /// Update the fallback thumbnail image from the process-wide cache.
    /// If the cache is empty, request a render so the next mount shows
    /// the thumbnail immediately. Called on init and on
    /// `viewDidMoveToWindow` so a recycled view always reflects the
    /// latest cached thumbnail.
    private func refreshThumbnailFallback() {
        if let cached = QuickLookThumbnailCache.cachedThumbnail(for: fileURL) {
            thumbnailFallback.image = cached
            thumbnailFallback.isHidden = false
            return
        }
        // No cached thumbnail — render asynchronously so the cache is
        // warm for the next loadView() / window-attach.
        let size = NSSize(
            width: max(64, containerWidth),
            height: max(64, frame.height > 0 ? frame.height - toolbarHeight : 300)
        )
        QuickLookThumbnailCache.renderThumbnail(for: fileURL, size: size) { [weak self] image in
            guard let self = self, let image = image else { return }
            self.thumbnailFallback.image = image
            self.thumbnailFallback.isHidden = false
        }
    }

    // MARK: - Layout

    private func layoutSubviews() {
        let w = frame.width > 0 ? frame.width : containerWidth
        let tbH = toolbarHeight

        toolbarView.frame = NSRect(x: 0, y: frame.height - tbH, width: w, height: tbH)

        separatorView.frame = NSRect(x: 0, y: frame.height - tbH, width: w, height: 1)

        let btnY = frame.height - tbH
        let fontSize = UserDefaultsManagement.noteFont.pointSize

        // Icon
        if let iconView = viewWithTag(100) {
            iconView.frame.origin = NSPoint(x: 8, y: btnY + (tbH - (fontSize + 4)) / 2)
        }

        // Filename label
        let labelLeft: CGFloat = 8 + fontSize + 4 + 4
        openButton.sizeToFit()
        let labelRight = w - openButton.frame.width - 16
        filenameLabel.frame = NSRect(
            x: labelLeft,
            y: btnY + (tbH - 16) / 2,
            width: max(0, labelRight - labelLeft),
            height: 16
        )

        // Open button on the right
        openButton.frame.origin = NSPoint(
            x: w - openButton.frame.width - 8,
            y: btnY + (tbH - openButton.frame.height) / 2
        )

        // QuickLook preview fills area below toolbar
        let contentHeight = frame.height - tbH
        let previewFrame = NSRect(x: 0, y: 0, width: w, height: contentHeight)
        previewView.frame = previewFrame
        // Fallback thumbnail occupies the same area, behind the preview.
        thumbnailFallback.frame = previewFrame
    }

    override func layout() {
        super.layout()
        layoutSubviews()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutSubviews()
    }

    // MARK: - Re-attach lifecycle (Bug #19)

    /// `QLPreviewView`'s async render does not always re-fire after the
    /// host view detaches and reattaches to a window — the symptom the
    /// user reported is `.numbers` files showing an empty preview frame
    /// after the user scrolls past the embed and back. Re-setting
    /// `previewItem` here forces QLPreviewView to reload, and refreshing
    /// the thumbnail fallback covers the gap until the live preview
    /// finishes loading.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        refreshThumbnailFallback()
        // Force QLPreviewView to re-load its preview item. The nil-then-
        // set sequence is the documented pattern for forcing a reload
        // (Apple sample: PreviewKit / QLPreviewView). Without this the
        // view sometimes stays blank after a scroll-recycle because the
        // first load fired before the view was in the hierarchy.
        previewView.previewItem = nil
        previewView.previewItem = fileURL as QLPreviewItem
    }

    // MARK: - Computed Size

    /// Compute the ideal size for this QuickLook viewer.
    func computeSize(forWidth width: CGFloat) -> NSSize {
        return Self.computeSize(
            forWidth: width,
            maxHeight: maxHeight,
            toolbarHeight: toolbarHeight
        )
    }

    /// Pure size computation. Exposed as a static helper so the
    /// processor path can compute size without building a live view.
    static func computeSize(
        forWidth width: CGFloat,
        maxHeight: CGFloat,
        toolbarHeight: CGFloat
    ) -> NSSize {
        // Use a reasonable preview height — about the same as the PDF viewer.
        let previewHeight = min(maxHeight, max(300, width * 0.6))
        return NSSize(width: width, height: previewHeight + toolbarHeight)
    }

    // MARK: - Actions

    @objc private func openInNativeApp() {
        NSWorkspace.shared.open(fileURL)
    }

    /// Bug #23: double-click anywhere on the inline preview opens the
    /// file in its default macOS app. Routes through the same
    /// `NSWorkspace.open` call as the toolbar "Open" button so
    /// behavior is identical regardless of trigger.
    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended,
              InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick(clickCount: recognizer.numberOfClicksRequired)
        else { return }
        NSWorkspace.shared.open(fileURL)
    }

    // MARK: - Scroll Behavior

    /// Pure predicate used by `scrollWheel(with:)` to decide whether a
    /// vertical scroll event should propagate up to the parent note's
    /// scroll view, or be consumed by the inline preview's inner scroll
    /// view.
    ///
    /// - Parameters:
    ///   - deltaY: `event.scrollingDeltaY`. Positive = content scrolling
    ///     down (user gesture is upward). Negative = content scrolling up.
    ///   - contentOffsetY: the inner scroll view's `contentView.bounds.origin.y`
    ///     (ignoring sign-flip — caller normalizes for unflipped views).
    ///   - contentHeight: the inner scroll view's documentView height.
    ///   - viewportHeight: the inner scroll view's contentView height.
    ///   - canScroll: whether an inner scroll view exists at all. If false,
    ///     all scrolls propagate (no inner content to consume them).
    /// - Returns: `true` when the event should be forwarded to the parent
    ///   note's responder (boundary reached or no inner scroll view);
    ///   `false` when the inner scroll view should consume the event.
    static func shouldPropagateVerticalScroll(
        deltaY: CGFloat,
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        canScroll: Bool
    ) -> Bool {
        guard canScroll else { return true }
        // Content fits in viewport — nothing to scroll, propagate.
        if contentHeight <= viewportHeight { return true }

        // Tolerance for floating-point boundary detection. macOS scroll
        // views can sit at offsets like 0.0001 or `maxOffset - 0.0001`
        // after a momentum animation; treat sub-pixel residue as "at
        // boundary."
        let epsilon: CGFloat = 0.5
        let maxOffsetY = contentHeight - viewportHeight

        // deltaY > 0: gesture is upward → content offset would decrease
        //   → forward when already at top (offset ≈ 0).
        // deltaY < 0: gesture is downward → content offset would increase
        //   → forward when already at bottom (offset ≈ maxOffsetY).
        if deltaY > 0 && contentOffsetY <= epsilon {
            return true
        }
        if deltaY < 0 && contentOffsetY >= maxOffsetY - epsilon {
            return true
        }
        return false
    }

    /// Find the first descendant `NSScrollView` of `root`. `QLPreviewView`
    /// hosts its content inside a private scroll view; we walk the
    /// hierarchy because the exact subview path is not part of Apple's
    /// public API.
    static func findInnerScrollView(in root: NSView) -> NSScrollView? {
        if let sv = root as? NSScrollView { return sv }
        for sub in root.subviews {
            if let sv = findInnerScrollView(in: sub) { return sv }
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Horizontal scroll always stays in the preview (for spreadsheets,
        // wide PDFs, etc.). Vertical scroll is consumed by the inner
        // QuickLook scroll view until it reaches a boundary, at which
        // point it propagates to the parent note (Obsidian-style).
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }

        let innerScroll = Self.findInnerScrollView(in: previewView)
        let canScroll = innerScroll != nil
        let contentOffsetY = innerScroll?.contentView.bounds.origin.y ?? 0
        let contentHeight = innerScroll?.documentView?.frame.height ?? 0
        let viewportHeight = innerScroll?.contentView.bounds.height ?? 0

        let propagate = Self.shouldPropagateVerticalScroll(
            deltaY: event.scrollingDeltaY,
            contentOffsetY: contentOffsetY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            canScroll: canScroll
        )

        if propagate {
            nextResponder?.scrollWheel(with: event)
        } else {
            innerScroll?.scrollWheel(with: event)
        }
    }
}

// MARK: - QuickLookAttachmentCell (DEPRECATED — TK1 only)

/// Legacy TK1 NSTextAttachmentCell. Under TK2, the
/// `draw(withFrame:in:characterIndex:layoutManager:)` method is never
/// called — Apple replaced it with `NSTextAttachmentViewProvider`. See
/// `QuickLookAttachmentViewProvider` / `QuickLookNSTextAttachment` below.
///
/// Kept during TK1-fallback period; remove when TK1 source-mode is
/// deleted (Phase 4).
class QuickLookAttachmentCell: NSTextAttachmentCell {

    let inlineView: InlineQuickLookView
    private let desiredSize: NSSize

    init(quickLookView: InlineQuickLookView, size: NSSize) {
        self.inlineView = quickLookView
        self.desiredSize = size
        super.init()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cellSize() -> NSSize {
        return desiredSize
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }
}

// MARK: - QuickLookAttachmentViewProvider (TK2)

/// TK2-idiomatic view provider that builds a fresh `InlineQuickLookView`
/// in `loadView()` from the attachment's stored URL + size. Apple
/// handles positioning.
///
/// Building a new view (with its own fresh `QLPreviewView` child) on
/// every call is the same pattern `ImageAttachmentViewProvider` uses. It
/// prevents the scroll-recycle bug where a cached `QLPreviewView` loses
/// its thumbnail after being detached from the window and reattached —
/// the user would see the attachment frame without the preview content.
///
/// See: https://developer.apple.com/documentation/appkit/nstextattachmentviewprovider
final class QuickLookAttachmentViewProvider: NSTextAttachmentViewProvider {

    override func loadView() {
        guard let attachment = textAttachment as? QuickLookNSTextAttachment else {
            super.loadView()
            return
        }
        let view = InlineQuickLookView(
            url: attachment.fileURL,
            containerWidth: attachment.size.width
        )
        view.frame = NSRect(origin: .zero, size: attachment.size)
        self.view = view
    }
}

// MARK: - QuickLookNSTextAttachment (TK2)

/// NSTextAttachment subclass that stores value types only (the file URL
/// and the size computed once at construction) and vends a
/// `QuickLookAttachmentViewProvider`. The live `InlineQuickLookView` +
/// its hosted `QLPreviewView` are built fresh by the provider on each
/// `loadView()` call — see the provider's doc comment for why.
///
/// See: https://developer.apple.com/documentation/appkit/nstextattachment/3773879-viewprovider
final class QuickLookNSTextAttachment: NSTextAttachment {

    let fileURL: URL
    let size: NSSize

    init(url: URL, size: NSSize) {
        self.fileURL = url
        self.size = size
        super.init(data: nil, ofType: nil)
        self.bounds = NSRect(origin: .zero, size: size)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Compute size for a QuickLook attachment without building a live
    /// view. Size is derived from container width + font size only —
    /// the file content does not affect the preview box dimensions.
    static func computeSize(
        forWidth width: CGFloat,
        fontSize: CGFloat = UserDefaultsManagement.noteFont.pointSize
    ) -> NSSize {
        let maxH = InlineQuickLookView.maxHeight(forFontSize: fontSize)
        let tbH = InlineQuickLookView.toolbarHeight(forFontSize: fontSize)
        return InlineQuickLookView.computeSize(
            forWidth: width,
            maxHeight: maxH,
            toolbarHeight: tbH
        )
    }

    override func viewProvider(for parentView: NSView?,
                               location: NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = QuickLookAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

// MARK: - QuickLookAttachmentProcessor

/// Scans textStorage for non-image, non-PDF attachment characters and
/// replaces them with inline QuickLook preview viewers.
enum QuickLookAttachmentProcessor {

    /// File extensions that are already handled by dedicated renderers
    /// (images by ImageAttachmentHydrator, PDFs by PDFAttachmentProcessor).
    /// Everything else with a non-empty extension gets a QuickLook preview.
    private static let excludedExtensions: Set<String> = {
        var excluded = InlineRenderer.renderableImageExtensions
        excluded.formUnion(InlineRenderer.renderablePDFExtensions)
        return excluded
    }()

    /// Scan textStorage for non-image/non-PDF attachments and replace
    /// them with live QuickLook viewers.
    ///
    /// Call AFTER PDFAttachmentProcessor and ImageAttachmentHydrator
    /// have run, so we only process files they didn't handle.
    static func renderQuickLookAttachments(
        in textStorage: NSTextStorage,
        containerWidth: CGFloat
    ) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var replacements: [(NSRange, NSTextAttachment)] = []

        bmLog("📎 QuickLookProcessor: scanning storage length=\(textStorage.length)")
        var attachmentCount = 0

        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachmentCount += 1

            // Skip if already rendered as a QuickLook or PDF attachment
            if attachment is QuickLookNSTextAttachment { return }
            if attachment.attachmentCell is QuickLookAttachmentCell { return }
            if attachment.attachmentCell is PDFAttachmentCell { return }

            let maybeURL = textStorage.attribute(.attachmentUrl, at: range.location, effectiveRange: nil) as? URL
            guard let url = maybeURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                bmLog("📎   skip @\(range.location): url=\(maybeURL?.lastPathComponent ?? "nil")")
                return
            }

            // Skip images and PDFs (handled by their own processors)
            let ext = url.pathExtension.lowercased()
            if excludedExtensions.contains(ext) { return }
            guard !ext.isEmpty else { return }

            let size = QuickLookNSTextAttachment.computeSize(forWidth: containerWidth)
            let newAttachment = QuickLookNSTextAttachment(url: url, size: size)

            bmLog("📎   PENDING @\(range.location): \(url.lastPathComponent)")
            replacements.append((range, newAttachment))
        }

        bmLog("📎 QuickLookProcessor: \(attachmentCount) attachments found, \(replacements.count) to replace")

        // Apply replacements in reverse order. Each `range` covers
        // exactly one U+FFFC attachment character; the swap is
        // attribute-only (NSTextAttachment instance + class).
        // Metadata attributes (.attachmentUrl / .attachmentPath /
        // .attachmentTitle) stay intact. No character change → no
        // `.editedCharacters` event → no Phase 5a assertion trip → no
        // `performingLegacyStorageWrite` wrapper needed.
        for (range, attachment) in replacements.reversed() {
            textStorage.beginEditing()
            textStorage.addAttribute(.attachment, value: attachment, range: range)
            textStorage.endEditing()
        }
    }
}
