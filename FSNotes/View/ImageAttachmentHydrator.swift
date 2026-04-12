//
//  ImageAttachmentHydrator.swift
//  FSNotes
//
//  Block-model companion to TextStorageProcessor.loadImage(). Scans a
//  textStorage that was produced by DocumentRenderer for image
//  attachment placeholders (emitted by InlineRenderer for `.image`
//  inlines) and loads the real images asynchronously.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: a textStorage + an editor (for imagesLoaderQueue, textContainer,
//    layoutManager) + a note (to resolve relative paths already done by
//    the renderer — we only consume the `.attachmentUrl` attribute).
//  - Output: the in-place mutation of matching attachments:
//    (a) attachment.bounds set to the image's natural size (clamped to
//        container width)
//    (b) attachment.attachmentCell set to an FSNTextAttachmentCell with
//        the loaded image
//  - Idempotent: re-hydrating an already-hydrated attachment is a no-op.
//    Skips attachments whose cell is already an FSNTextAttachmentCell
//    (or any non-default cell — e.g. PDFAttachmentCell, which is
//    hydrated separately by PDFAttachmentProcessor).
//  - PDFs are NOT handled here. InlineRenderer tags PDF attachments
//    with `.renderedBlockType == "pdf"` and PDFAttachmentProcessor
//    picks them up via its own existing-attachment scanner.
//  - Loading happens on the editor's imagesLoaderQueue (same queue the
//    source-mode pipeline uses). When the load completes we hop back
//    to the main queue, install the cell, mark attributes edited, and
//    invalidate layout for the affected range.
//

import Foundation
import Cocoa

enum ImageAttachmentHydrator {

    /// Walk the text storage and load any block-model image attachments
    /// that haven't been hydrated yet. Safe to call multiple times.
    ///
    /// - Parameters:
    ///   - textStorage: the storage to scan.
    ///   - editor: the EditTextView hosting the storage — used for the
    ///     image loader queue, text container, and layout manager.
    static func hydrate(
        textStorage: NSTextStorage,
        editor: EditTextView
    ) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let maxWidth = containerMaxWidth(for: editor)

        // Collect first, mutate after. enumerateAttribute can't safely
        // coexist with attachment.cell mutation during the walk.
        var pending: [(NSTextAttachment, URL, NSRange)] = []

        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }

            // Skip if already hydrated (any non-default cell means some
            // other pipeline already took responsibility for drawing).
            if attachment.attachmentCell is FSNTextAttachmentCell { return }
            if attachment.image != nil { return }

            // Only hydrate attachments marked as image by InlineRenderer.
            // PDFs are handled by PDFAttachmentProcessor.
            guard let rawType = textStorage.attribute(.renderedBlockType, at: range.location, effectiveRange: nil) as? String,
                  rawType == RenderedBlockType.image.rawValue else { return }

            guard let url = textStorage.attribute(.attachmentUrl, at: range.location, effectiveRange: nil) as? URL else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }

            pending.append((attachment, url, range))
        }

        guard !pending.isEmpty else { return }

        for (attachment, url, range) in pending {
            loadImage(
                attachment: attachment,
                url: url,
                range: range,
                maxWidth: maxWidth,
                textStorage: textStorage,
                editor: editor
            )
        }
    }

    // MARK: - Private

    private static func containerMaxWidth(for editor: EditTextView) -> CGFloat {
        if let container = editor.textContainer {
            let lfp = container.lineFragmentPadding
            let w = container.size.width - lfp * 2
            if w > 0 { return w }
        }
        if let editorWidth = editor.enclosingScrollView?.contentView.bounds.width {
            return editorWidth - 40
        }
        return CGFloat(UserDefaultsManagement.imagesWidth)
    }

    private static func loadImage(
        attachment: NSTextAttachment,
        url: URL,
        range: NSRange,
        maxWidth: CGFloat,
        textStorage: NSTextStorage,
        editor: EditTextView
    ) {
        editor.imagesLoaderQueue.addOperation { [weak editor] in
            var image: PlatformImage?
            var size: CGSize?

            if url.isMedia {
                let imageSize = url.getBorderSize(maxWidth: maxWidth)
                size = imageSize
                image = NoteAttachment.getImage(url: url, size: imageSize)
            } else {
                let noteAttachment = NoteAttachment(url: url)
                if let attachmentImage = noteAttachment.getAttachmentImage() {
                    size = attachmentImage.size
                    image = attachmentImage
                }
            }

            DispatchQueue.main.async {
                guard let editor = editor,
                      let manager = editor.layoutManager,
                      let container = editor.textContainer,
                      let loadedImage = image,
                      let loadedSize = size else { return }

                // Verify the attachment is still at `range` — a concurrent
                // edit may have shifted it. enumerate instead of trusting
                // the saved range.
                guard range.location + range.length <= textStorage.length else { return }
                guard let storedAttachment = textStorage.attribute(
                    .attachment, at: range.location, effectiveRange: nil
                ) as? NSTextAttachment,
                      storedAttachment === attachment else { return }

                let cell = FSNTextAttachmentCell(textContainer: container, image: loadedImage)
                cell.image?.size = loadedSize
                attachment.image = nil
                attachment.attachmentCell = cell
                attachment.bounds = NSRect(
                    x: 0, y: 0,
                    width: loadedSize.width, height: loadedSize.height
                )

                textStorage.edited(.editedAttributes, range: range, changeInLength: 0)
                manager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
        }
    }
}
