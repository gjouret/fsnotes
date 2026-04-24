//
//  InlinePDFView.swift
//  FSNotes
//
//  Inline PDF viewer for WYSIWYG mode. Embeds an Apple PDFKit PDFView
//  inside an NSTextAttachment, similar to how Apple Notes and Obsidian
//  display PDF attachments inline.
//
//  Architecture (TK2):
//  - InlinePDFView wraps a PDFView with controls (toolbar, thumbnail sidebar)
//  - PDFNSTextAttachment subclass stores value types only (URL + size).
//    It does NOT cache an InlinePDFView; the view is built fresh by the
//    provider each time TK2 attaches it to a window.
//  - PDFAttachmentViewProvider (NSTextAttachmentViewProvider) constructs
//    a fresh InlinePDFView in loadView(), seeded from the attachment's
//    URL + size. Building on every loadView() mirrors the image pattern
//    in ImageAttachmentViewProvider and is required because scroll-
//    recycled views lose their PDFKit render state when the outer
//    wrapper is reattached to the window.
//  - PDFAttachmentProcessor scans textStorage for ![](*.pdf) patterns
//    and replaces them with attachment characters. It computes size
//    from the URL via PDFNSTextAttachment.computeSize(forURL:width:).
//

import Cocoa
import PDFKit
import Quartz

// MARK: - InlinePDFView

/// A container view that wraps PDFKit's PDFView for inline display in
/// the note editor. Shows the PDF with a navigation toolbar and an
/// optional thumbnail sidebar, similar to Obsidian's PDF viewer.
class InlinePDFView: NSView {

    // MARK: - Properties

    let pdfURL: URL
    private(set) var pdfView: PDFView!
    private var toolbarView: NSView!
    private var thumbnailView: PDFThumbnailView!
    private var thumbnailContainer: NSView!
    private var pageLabel: NSTextField!
    private var openButton: NSButton!
    private var zoomInButton: NSButton!
    private var zoomOutButton: NSButton!
    private var thumbnailToggleButton: NSButton!
    private var containerWidth: CGFloat
    private var separatorView: NSView!
    private var showingThumbnails = false

    /// Maximum height for the PDF viewer (scales with note font).
    private var maxHeight: CGFloat {
        return Self.maxHeight(forFontSize: UserDefaultsManagement.noteFont.pointSize)
    }

    /// Toolbar height derived from note font.
    private var toolbarHeight: CGFloat {
        return Self.toolbarHeight(forFontSize: UserDefaultsManagement.noteFont.pointSize)
    }

    /// Thumbnail sidebar width.
    private var thumbnailWidth: CGFloat { return 120 }

    // MARK: - Init

    init(url: URL, containerWidth: CGFloat) {
        self.pdfURL = url
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

        // Thumbnail sidebar toggle (leftmost)
        thumbnailToggleButton = makeToolbarButton(
            symbolName: "sidebar.left",
            fallbackTitle: "☰",
            font: smallFont,
            action: #selector(toggleThumbnails)
        )
        addSubview(thumbnailToggleButton)

        // Zoom out
        zoomOutButton = makeToolbarButton(
            symbolName: "minus.magnifyingglass",
            fallbackTitle: "−",
            font: smallFont,
            action: #selector(zoomOut)
        )
        addSubview(zoomOutButton)

        // Zoom in
        zoomInButton = makeToolbarButton(
            symbolName: "plus.magnifyingglass",
            fallbackTitle: "+",
            font: smallFont,
            action: #selector(zoomIn)
        )
        addSubview(zoomInButton)

        // Page label (center)
        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = smallFont
        pageLabel.textColor = NSColor.secondaryLabelColor
        pageLabel.alignment = .center
        addSubview(pageLabel)

        // Open in Preview button (right)
        openButton = NSButton(title: "Open in Preview", target: self, action: #selector(openInPreview))
        openButton.bezelStyle = .accessoryBarAction
        openButton.font = smallFont
        openButton.controlSize = .small
        addSubview(openButton)

        // --- Thumbnail sidebar (hidden by default) ---
        thumbnailContainer = NSView()
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        thumbnailContainer.isHidden = true
        addSubview(thumbnailContainer)

        thumbnailView = PDFThumbnailView()
        thumbnailView.thumbnailSize = NSSize(width: 80, height: 100)
        thumbnailView.backgroundColor = .clear
        thumbnailContainer.addSubview(thumbnailView)

        // --- PDF view ---
        // Horizontal page layout so multi-page PDFs scroll sideways,
        // keeping the note's vertical scroll unobstructed (Apple Notes
        // and Obsidian use the same approach).
        pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = NSColor.textBackgroundColor
        pdfView.interpolationQuality = .high
        addSubview(pdfView)

        // Load the PDF document
        if let document = PDFDocument(url: pdfURL) {
            pdfView.document = document
            thumbnailView.pdfView = pdfView
            updatePageLabel()

            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged),
                name: .PDFViewPageChanged, object: pdfView
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(scaleChanged),
                name: .PDFViewScaleChanged, object: pdfView
            )
        } else {
            pageLabel.stringValue = "Failed to load PDF"
        }

        layoutSubviews()
    }

    private func makeToolbarButton(symbolName: String, fallbackTitle: String,
                                   font: NSFont, action: Selector) -> NSButton {
        let button: NSButton
        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)) {
            button = NSButton(image: image, target: self, action: action)
        } else {
            button = NSButton(title: fallbackTitle, target: self, action: action)
        }
        button.bezelStyle = .accessoryBarAction
        button.font = font
        button.controlSize = .small
        button.isBordered = false
        return button
    }

    // MARK: - Layout

    private func layoutSubviews() {
        let w = frame.width > 0 ? frame.width : containerWidth
        let tbH = toolbarHeight

        toolbarView.frame = NSRect(x: 0, y: frame.height - tbH, width: w, height: tbH)

        separatorView.frame = NSRect(x: 0, y: frame.height - tbH, width: w, height: 1)

        // Toolbar items layout
        let btnY = frame.height - tbH
        let btnPadding: CGFloat = 4
        var x: CGFloat = 8

        // Thumbnail toggle
        thumbnailToggleButton.sizeToFit()
        thumbnailToggleButton.frame.origin = NSPoint(x: x, y: btnY + (tbH - thumbnailToggleButton.frame.height) / 2)
        x += thumbnailToggleButton.frame.width + btnPadding

        // Separator space
        x += 8

        // Zoom out
        zoomOutButton.sizeToFit()
        zoomOutButton.frame.origin = NSPoint(x: x, y: btnY + (tbH - zoomOutButton.frame.height) / 2)
        x += zoomOutButton.frame.width + btnPadding

        // Zoom in
        zoomInButton.sizeToFit()
        zoomInButton.frame.origin = NSPoint(x: x, y: btnY + (tbH - zoomInButton.frame.height) / 2)
        x += zoomInButton.frame.width + btnPadding

        // Open button on the right
        openButton.sizeToFit()
        openButton.frame.origin = NSPoint(
            x: w - openButton.frame.width - 8,
            y: btnY + (tbH - openButton.frame.height) / 2
        )

        // Page label centered between zoom buttons and open button
        let labelLeft = x + 8
        let labelRight = openButton.frame.origin.x - 8
        let labelWidth = max(0, labelRight - labelLeft)
        pageLabel.frame = NSRect(
            x: labelLeft,
            y: btnY + (tbH - 16) / 2,
            width: labelWidth,
            height: 16
        )

        // Content area below toolbar
        let contentTop = frame.height - tbH
        let sidebarWidth = showingThumbnails ? thumbnailWidth : 0

        // Thumbnail sidebar
        thumbnailContainer.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: contentTop)
        thumbnailView.frame = thumbnailContainer.bounds

        // PDF view fills remaining space
        pdfView.frame = NSRect(x: sidebarWidth, y: 0, width: w - sidebarWidth, height: contentTop)
    }

    override func layout() {
        super.layout()
        layoutSubviews()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutSubviews()
    }

    // MARK: - Computed Size

    /// Compute the ideal size for this PDF viewer.
    /// With horizontal layout, height is based on a single page
    /// (pages scroll sideways, not vertically).
    func computeSize(forWidth width: CGFloat) -> NSSize {
        return Self.computeSize(
            firstPageBounds: pdfView.document?.page(at: 0)?.bounds(for: .mediaBox),
            width: width,
            maxHeight: maxHeight,
            toolbarHeight: toolbarHeight
        )
    }

    /// Pure size computation. Exposed as a static helper so the
    /// processor path can compute size from a URL without building a
    /// live `InlinePDFView` first — attachments now store `URL + size`
    /// and let the view provider build the view on demand.
    static func computeSize(
        firstPageBounds pageRect: NSRect?,
        width: CGFloat,
        maxHeight: CGFloat,
        toolbarHeight: CGFloat
    ) -> NSSize {
        guard let pageRect = pageRect, pageRect.width > 0 else {
            return NSSize(width: width, height: maxHeight)
        }

        // Scale page to fit width; height is one page tall.
        let scale = width / pageRect.width
        let scaledPageHeight = pageRect.height * scale

        return NSSize(width: width, height: min(scaledPageHeight, maxHeight) + toolbarHeight)
    }

    /// Font-derived maximum preview height. Static so the processor
    /// can compute size from URL + container width without a live view.
    static func maxHeight(forFontSize fontSize: CGFloat) -> CGFloat {
        return max(400, fontSize * 30)
    }

    /// Font-derived toolbar height. Static to mirror `maxHeight`.
    static func toolbarHeight(forFontSize fontSize: CGFloat) -> CGFloat {
        return ceil(fontSize * 2.8)
    }

    // MARK: - Actions

    @objc private func openInPreview() {
        NSWorkspace.shared.open(pdfURL)
    }

    @objc private func zoomIn() {
        pdfView.scaleFactor *= 1.25
    }

    @objc private func zoomOut() {
        pdfView.scaleFactor /= 1.25
    }

    @objc private func toggleThumbnails() {
        showingThumbnails.toggle()
        thumbnailContainer.isHidden = !showingThumbnails
        layoutSubviews()
    }

    @objc private func pageChanged() {
        updatePageLabel()
    }

    @objc private func scaleChanged() {
        updatePageLabel()
    }

    private func updatePageLabel() {
        guard let document = pdfView.document else { return }
        let pageCount = document.pageCount
        let zoomPercent = Int(round(pdfView.scaleFactor * 100))

        if let currentPage = pdfView.currentPage,
           let pageIndex = document.index(for: currentPage) as Int? {
            pageLabel.stringValue = "Page \(pageIndex + 1) of \(pageCount)  ·  \(zoomPercent)%  ·  \(pdfURL.lastPathComponent)"
        } else {
            pageLabel.stringValue = "\(pageCount) page\(pageCount == 1 ? "" : "s")  ·  \(zoomPercent)%  ·  \(pdfURL.lastPathComponent)"
        }
    }

    // MARK: - Scroll Behavior

    override func scrollWheel(with event: NSEvent) {
        // Horizontal scroll (or shift-scroll) navigates PDF pages.
        // Vertical scroll passes through to the note's scroll view
        // so the user can scroll past the PDF embed.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            pdfView.scrollWheel(with: event)
        } else {
            // Pass vertical scrolling up to the enclosing scroll view (note editor).
            nextResponder?.scrollWheel(with: event)
        }
    }

    // MARK: - Cleanup

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - PDFNSTextAttachment (TK2)

/// TK2 `NSTextAttachment` subclass that stores value types only — the
/// file URL and the size computed once at construction. The live
/// `InlinePDFView` + its hosted `PDFView` are built fresh by
/// `PDFAttachmentViewProvider.loadView()` on each call. Under TK2,
/// `NSTextAttachmentCell.draw(withFrame:in:characterIndex:layoutManager:)`
/// is never called — view hosting must go through
/// `NSTextAttachmentViewProvider`.
///
/// Value-type ownership matters for scroll recycling. When TK2 scrolls
/// a PDF fragment out of the viewport and back, the outer wrapper is
/// reattached to the window, but `PDFView`'s render state does not
/// survive detach/reattach — the user sees the frame without the PDF
/// content. Building a fresh `InlinePDFView` on every `loadView()` call
/// sidesteps that whole class of bugs; PDFKit's own caching keeps the
/// re-instantiation cost negligible.
class PDFNSTextAttachment: NSTextAttachment {

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

    /// Compute size for a PDF attachment without building a live view.
    /// Loads the PDF document, reads the first page's media-box bounds,
    /// and delegates to `InlinePDFView.computeSize`. Returns a sensible
    /// default if the PDF cannot be opened.
    static func computeSize(
        forURL url: URL,
        width: CGFloat,
        fontSize: CGFloat = UserDefaultsManagement.noteFont.pointSize
    ) -> NSSize {
        let maxH = InlinePDFView.maxHeight(forFontSize: fontSize)
        let tbH = InlinePDFView.toolbarHeight(forFontSize: fontSize)
        let firstPageBounds = PDFDocument(url: url)?.page(at: 0)?.bounds(for: .mediaBox)
        return InlinePDFView.computeSize(
            firstPageBounds: firstPageBounds,
            width: width,
            maxHeight: maxH,
            toolbarHeight: tbH
        )
    }

    override func viewProvider(for parentView: NSView?,
                               location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = PDFAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

// MARK: - PDFAttachmentViewProvider (TK2)

/// `NSTextAttachmentViewProvider` that constructs a fresh `InlinePDFView`
/// from the attachment's stored URL + size on every `loadView()` call.
/// TK2 handles adding the view to the text view's hierarchy and
/// positioning it within the viewport.
///
/// Building fresh on every call (rather than caching the view on the
/// attachment) is the same pattern used by `ImageAttachmentViewProvider`.
/// It guarantees scroll-recycled attachments get a fully-initialized
/// `PDFView` every time TK2 decides to re-host the attachment.
class PDFAttachmentViewProvider: NSTextAttachmentViewProvider {

    override func loadView() {
        guard let attachment = textAttachment as? PDFNSTextAttachment else {
            super.loadView()
            return
        }
        let view = InlinePDFView(
            url: attachment.fileURL,
            containerWidth: attachment.size.width
        )
        view.frame = NSRect(origin: .zero, size: attachment.size)
        self.view = view
    }
}

// MARK: - PDFAttachmentCell (legacy, unwired)

/// Legacy TK1 attachment cell. Kept during TK1-fallback period; remove
/// when TK1 source-mode is deleted (Phase 4). No longer wired by
/// `PDFAttachmentProcessor` — TK2 view hosting goes through
/// `PDFNSTextAttachment` + `PDFAttachmentViewProvider` above. This class
/// remains referenced only by orphan-cleanup code in
/// `EditTextView+NoteState.swift` so old PDF cells from saved state can
/// still be found and removed if they exist.
class PDFAttachmentCell: NSTextAttachmentCell {

    let inlinePDFView: InlinePDFView
    private let desiredSize: NSSize

    init(pdfView: InlinePDFView, size: NSSize) {
        self.inlinePDFView = pdfView
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

// MARK: - PDFAttachmentProcessor

/// Scans textStorage for `![title](path.pdf)` patterns and replaces
/// them with inline PDFView attachments. Works in both block-model
/// and source-mode rendering pipelines.
enum PDFAttachmentProcessor {

    /// Scan the text storage for PDF attachment references and replace
    /// them with live PDFView attachments.
    ///
    /// Call this AFTER the main rendering pass (block-model or source-mode)
    /// has populated textStorage. It regex-scans for `![...](*.pdf)`
    /// and replaces each match with a single attachment character
    /// hosting an InlinePDFView.
    static func renderPDFAttachments(
        in textStorage: NSTextStorage,
        note: Note,
        containerWidth: CGFloat
    ) {
        // Match ![optional title](path/to/file.pdf)
        // Also match bare attachment characters that already have a .pdf attachmentUrl
        // First: handle existing attachment characters with PDF URLs
        renderExistingPDFAttachments(in: textStorage, containerWidth: containerWidth)

        // Second: handle raw markdown image syntax for PDFs (block-model leaves these as text)
        renderMarkdownPDFReferences(in: textStorage, note: note, containerWidth: containerWidth)
    }

    /// Replace existing NSTextAttachment characters that point to PDF files
    /// with InlinePDFView cells (replaces the old text-label attachment).
    private static func renderExistingPDFAttachments(
        in textStorage: NSTextStorage,
        containerWidth: CGFloat
    ) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var replacements: [(NSRange, NSTextAttachment)] = []

        bmLog("📄 PDFAttachmentProcessor: scanning storage length=\(textStorage.length)")
        var attachmentCount = 0

        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachmentCount += 1

            // Skip if already rendered as a TK2 PDF attachment
            if attachment is PDFNSTextAttachment {
                bmLog("📄   skip @\(range.location): already PDFNSTextAttachment")
                return
            }

            let maybeURL = textStorage.attribute(.attachmentUrl, at: range.location, effectiveRange: nil) as? URL
            guard let url = maybeURL,
                  url.pathExtension.lowercased() == "pdf",
                  FileManager.default.fileExists(atPath: url.path) else {
                bmLog("📄   skip @\(range.location): url=\(maybeURL?.lastPathComponent ?? "nil"), ext=\(maybeURL?.pathExtension ?? "nil")")
                return
            }

            let size = PDFNSTextAttachment.computeSize(forURL: url, width: containerWidth)
            let newAttachment = PDFNSTextAttachment(url: url, size: size)

            bmLog("📄   PENDING @\(range.location): \(url.lastPathComponent)")
            replacements.append((range, newAttachment))
        }

        bmLog("📄 PDFAttachmentProcessor: \(attachmentCount) attachments found, \(replacements.count) to replace")

        // Apply replacements in reverse order
        for (range, attachment) in replacements.reversed() {
            // Preserve metadata attributes
            let url = textStorage.attribute(.attachmentUrl, at: range.location, effectiveRange: nil)
            let path = textStorage.attribute(.attachmentPath, at: range.location, effectiveRange: nil)
            let title = textStorage.attribute(.attachmentTitle, at: range.location, effectiveRange: nil)

            let replacement = NSMutableAttributedString(attachment: attachment)
            let repRange = NSRange(location: 0, length: replacement.length)
            if let url = url { replacement.addAttribute(.attachmentUrl, value: url, range: repRange) }
            if let path = path { replacement.addAttribute(.attachmentPath, value: path, range: repRange) }
            if let title = title { replacement.addAttribute(.attachmentTitle, value: title, range: repRange) }

            // Phase 5a: async PDF attachment hydration — same U+FFFC-
            // for-U+FFFC swap pattern as inline-math / mermaid. Post-
            // render, `Document` is already correct; this is purely
            // the storage-side attachment-class upgrade.
            // TODO: reshape to an attribute-only pass (set the
            // `.attachment` attribute on the existing character) so
            // no character replacement is needed.
            StorageWriteGuard.performingLegacyStorageWrite {
                textStorage.replaceCharacters(in: range, with: replacement)
            }
        }
    }

    /// Replace raw `![title](path.pdf)` markdown text with PDFView attachments.
    /// This handles the block-model path where image syntax isn't parsed.
    private static func renderMarkdownPDFReferences(
        in textStorage: NSTextStorage,
        note: Note,
        containerWidth: CGFloat
    ) {
        let string = textStorage.string
        // Match ![optional title](path ending in .pdf)
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)]+\.pdf)\)"#,
            options: [.caseInsensitive]
        ) else { return }

        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: string, options: [], range: fullRange)

        // Process in reverse so earlier ranges aren't shifted
        for match in matches.reversed() {
            let titleRange = match.range(at: 1)
            let pathRange = match.range(at: 2)
            let fullMatchRange = match.range

            let path = nsString.substring(with: pathRange)
            let title = nsString.substring(with: titleRange)

            guard let cleanPath = path.removingPercentEncoding,
                  let fileURL = note.getAttachmentFileUrl(name: cleanPath),
                  FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let size = PDFNSTextAttachment.computeSize(forURL: fileURL, width: containerWidth)
            let attachment = PDFNSTextAttachment(url: fileURL, size: size)

            let replacement = NSMutableAttributedString(attachment: attachment)
            let repRange = NSRange(location: 0, length: replacement.length)
            replacement.addAttribute(.attachmentUrl, value: fileURL, range: repRange)
            replacement.addAttribute(.attachmentPath, value: cleanPath, range: repRange)
            replacement.addAttribute(.attachmentTitle, value: title, range: repRange)
            // Store original markdown for save round-trip
            let originalMarkdown = nsString.substring(with: fullMatchRange)
            replacement.addAttribute(.renderedBlockOriginalMarkdown, value: originalMarkdown, range: repRange)
            replacement.addAttribute(.renderedBlockType, value: RenderedBlockType.pdf, range: repRange)

            // Phase 5a: markdown-form PDF reference → attachment
            // replacement, runs in block-model-off paths (source-mode
            // fallback). Source mode is excluded from the 5a assertion
            // already, but wrapping keeps the audit consistent.
            // TODO: drive from the Document model so the attachment
            // character is present from the first render.
            StorageWriteGuard.performingLegacyStorageWrite {
                textStorage.replaceCharacters(in: fullMatchRange, with: replacement)
            }
        }
    }
}
