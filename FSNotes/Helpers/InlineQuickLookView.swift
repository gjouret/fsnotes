//
//  InlineQuickLookView.swift
//  FSNotes
//
//  Inline file preview for WYSIWYG mode. Uses Apple's QLPreviewView to
//  render any file type that QuickLook supports (.numbers, .pages, .key,
//  .docx, .xlsx, .pptx, .rtf, .zip, etc.) inline in the note editor.
//
//  Architecture (mirrors InlinePDFView):
//  - InlineQuickLookView wraps a QLPreviewView with an "Open" button
//  - QuickLookAttachmentCell hosts the view as a live subview
//  - QuickLookAttachmentProcessor scans textStorage for non-image
//    attachments and replaces them with QuickLook viewers
//

import Cocoa
import Quartz

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
    private var containerWidth: CGFloat

    /// Maximum height for the preview (scales with note font).
    private var maxHeight: CGFloat {
        return max(400, UserDefaultsManagement.noteFont.pointSize * 30)
    }

    /// Toolbar height derived from note font.
    private var toolbarHeight: CGFloat {
        return ceil(UserDefaultsManagement.noteFont.pointSize * 2.8)
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

        // --- QuickLook preview ---
        previewView = QLPreviewView(frame: .zero, style: .compact)!
        previewView.autostarts = true
        previewView.previewItem = fileURL as QLPreviewItem
        addSubview(previewView)

        layoutSubviews()
    }

    // MARK: - Layout

    private func layoutSubviews() {
        let w = frame.width > 0 ? frame.width : containerWidth
        let tbH = toolbarHeight

        toolbarView.frame = NSRect(x: 0, y: frame.height - tbH, width: w, height: tbH)

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
        previewView.frame = NSRect(x: 0, y: 0, width: w, height: contentHeight)
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

    /// Compute the ideal size for this QuickLook viewer.
    func computeSize(forWidth width: CGFloat) -> NSSize {
        // Use a reasonable preview height — about the same as the PDF viewer.
        let previewHeight = min(maxHeight, max(300, width * 0.6))
        return NSSize(width: width, height: previewHeight + toolbarHeight)
    }

    // MARK: - Actions

    @objc private func openInNativeApp() {
        NSWorkspace.shared.open(fileURL)
    }

    // MARK: - Scroll Behavior

    override func scrollWheel(with event: NSEvent) {
        // Horizontal scroll stays in the preview (for spreadsheets, etc.).
        // Vertical scroll passes through to the note editor.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

// MARK: - QuickLookAttachmentCell

/// Custom NSTextAttachmentCell that hosts an InlineQuickLookView as a
/// live subview of the text view. Mirrors PDFAttachmentCell.
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

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // No-op: wait for the characterIndex variant.
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        // Don't draw if inside a folded region
        if let ts = layoutManager.textStorage,
           charIndex < ts.length,
           ts.attribute(.foldedContent, at: charIndex, effectiveRange: nil) != nil {
            inlineView.isHidden = true
            return
        }
        guard let textView = controlView as? NSTextView else { return }

        // Guard against invalid frames from non-contiguous layout
        let hasContentBefore = charIndex > 10
        let frameNearTop = cellFrame.origin.y < 50
        if hasContentBefore && frameNearTop {
            return
        }

        // Position the live QuickLook view and make it visible
        inlineView.frame = cellFrame
        inlineView.isHidden = false
        if inlineView.superview !== textView {
            textView.addSubview(inlineView)
        }
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

        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }

            // Skip if already rendered as a QuickLook or PDF cell
            if attachment.attachmentCell is QuickLookAttachmentCell { return }
            if attachment.attachmentCell is PDFAttachmentCell { return }

            // Must have a URL pointing to an existing file
            guard let url = textStorage.attribute(.attachmentUrl, at: range.location, effectiveRange: nil) as? URL,
                  FileManager.default.fileExists(atPath: url.path) else { return }

            // Skip images and PDFs (handled by their own processors)
            let ext = url.pathExtension.lowercased()
            if excludedExtensions.contains(ext) { return }
            guard !ext.isEmpty else { return }

            let qlView = InlineQuickLookView(url: url, containerWidth: containerWidth)
            let size = qlView.computeSize(forWidth: containerWidth)
            qlView.frame = NSRect(origin: .zero, size: size)

            let newAttachment = NSTextAttachment()
            let cell = QuickLookAttachmentCell(quickLookView: qlView, size: size)
            newAttachment.attachmentCell = cell
            newAttachment.bounds = NSRect(origin: .zero, size: size)

            replacements.append((range, newAttachment))
        }

        // Apply replacements in reverse order
        for (range, attachment) in replacements.reversed() {
            let url = textStorage.attribute(.attachmentUrl, at: range.location, effectiveRange: nil)
            let path = textStorage.attribute(.attachmentPath, at: range.location, effectiveRange: nil)
            let title = textStorage.attribute(.attachmentTitle, at: range.location, effectiveRange: nil)

            let replacement = NSMutableAttributedString(attachment: attachment)
            let repRange = NSRange(location: 0, length: replacement.length)
            if let url = url { replacement.addAttribute(.attachmentUrl, value: url, range: repRange) }
            if let path = path { replacement.addAttribute(.attachmentPath, value: path, range: repRange) }
            if let title = title { replacement.addAttribute(.attachmentTitle, value: title, range: repRange) }

            textStorage.replaceCharacters(in: range, with: replacement)
        }
    }
}
