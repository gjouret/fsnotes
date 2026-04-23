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

        bmLog("🖼️ ImageAttachmentHydrator: scanning storage length=\(textStorage.length)")

        // Collect first, mutate after. enumerateAttribute can't safely
        // coexist with attachment.cell mutation during the walk.
        var pending: [(NSTextAttachment, URL, NSRange)] = []
        var attachmentCount = 0

        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachmentCount += 1

            // Skip if already hydrated (any non-default cell means some
            // other pipeline already took responsibility for drawing).
            if attachment.attachmentCell is FSNTextAttachmentCell {
                bmLog("🖼️   skip @\(range.location): already FSNTextAttachmentCell")
                return
            }
            if attachment.image != nil {
                bmLog("🖼️   skip @\(range.location): already has image")
                return
            }

            let rawType = textStorage.attribute(.renderedBlockType, at: range.location, effectiveRange: nil) as? String
            guard rawType == RenderedBlockType.image.rawValue else {
                bmLog("🖼️   skip @\(range.location): blockType=\(rawType ?? "nil") (not image)")
                return
            }

            guard let url = textStorage.attribute(.attachmentUrl, at: range.location, effectiveRange: nil) as? URL else {
                bmLog("🖼️   skip @\(range.location): no attachmentUrl")
                return
            }

            // Accept both local files and remote URLs (http/https).
            let isRemote = url.scheme == "http" || url.scheme == "https"
            if !isRemote {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    bmLog("🖼️   skip @\(range.location): file not found: \(url.path)")
                    return
                }
            }

            bmLog("🖼️   PENDING @\(range.location): \(url.lastPathComponent)")
            pending.append((attachment, url, range))
        }

        bmLog("🖼️ ImageAttachmentHydrator: \(attachmentCount) attachments found, \(pending.count) pending")
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
        let isRemote = url.scheme == "http" || url.scheme == "https"

        // Read the optional per-image width hint (from the CommonMark
        // title field `"width=N"`). The renderer sets this attribute
        // on the attachment character when the inline carries a width.
        let widthHint: CGFloat? = {
            guard range.location < textStorage.length else { return nil }
            if let n = textStorage.attribute(.renderedImageWidth, at: range.location, effectiveRange: nil) as? NSNumber {
                let v = CGFloat(n.intValue)
                return v > 0 ? v : nil
            }
            return nil
        }()

        if isRemote {
            // Fetch remote image via URLSession.
            let task = URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let image = NSImage(data: data) else { return }
                let naturalSize = image.size
                let loadedSize: CGSize
                if let hint = widthHint {
                    // Honor explicit width. Clamp to container width as
                    // a safety cap (prevents runaway layout from a
                    // hand-edited title like `"width=999999"`).
                    let targetWidth = min(hint, maxWidth)
                    let aspect = naturalSize.height / max(naturalSize.width, 1)
                    loadedSize = CGSize(width: targetWidth, height: targetWidth * aspect)
                } else {
                    // Natural size clamped to container width.
                    let scale = naturalSize.width > maxWidth ? maxWidth / naturalSize.width : 1.0
                    loadedSize = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
                }

                DispatchQueue.main.async {
                    guard range.location + range.length <= textStorage.length else { return }
                    guard let storedAttachment = textStorage.attribute(
                        .attachment, at: range.location, effectiveRange: nil
                    ) as? NSTextAttachment,
                          storedAttachment === attachment else { return }

                    installLoadedImage(
                        attachment: attachment,
                        image: image,
                        loadedSize: loadedSize,
                        range: range,
                        textStorage: textStorage,
                        editor: editor
                    )
                }
            }
            task.resume()
            return
        }

        editor.imagesLoaderQueue.addOperation { [weak editor] in
            var image: PlatformImage?
            var size: CGSize?

            if url.isMedia {
                // getBorderSize returns the natural-scaled size clamped
                // to maxWidth. If a width hint is set, override with
                // (hint, hint * natural-aspect) — but still clamp to
                // maxWidth as a safety cap.
                let naturalScaled = url.getBorderSize(maxWidth: maxWidth)
                let renderedSize: CGSize
                if let hint = widthHint {
                    let targetWidth = min(hint, maxWidth)
                    // Derive aspect from naturalScaled — it's already at
                    // the correct shape, just the wrong dimensions.
                    let aspect = naturalScaled.height / max(naturalScaled.width, 1)
                    renderedSize = CGSize(width: targetWidth, height: targetWidth * aspect)
                } else {
                    renderedSize = naturalScaled
                }
                size = renderedSize
                image = NoteAttachment.getImage(url: url, size: renderedSize)
            } else {
                let noteAttachment = NoteAttachment(url: url)
                if let attachmentImage = noteAttachment.getAttachmentImage() {
                    size = attachmentImage.size
                    image = attachmentImage
                }
            }

            DispatchQueue.main.async {
                guard let editor = editor,
                      let loadedImage = image,
                      let loadedSize = size else { return }

                guard range.location + range.length <= textStorage.length else { return }
                guard let storedAttachment = textStorage.attribute(
                    .attachment, at: range.location, effectiveRange: nil
                ) as? NSTextAttachment,
                      storedAttachment === attachment else { return }

                installLoadedImage(
                    attachment: attachment,
                    image: loadedImage,
                    loadedSize: loadedSize,
                    range: range,
                    textStorage: textStorage,
                    editor: editor
                )
            }
        }
    }

    /// Phase 2a completion — attach the loaded image to the placeholder
    /// `NSTextAttachment` and invalidate layout. Branches on TK1 vs TK2:
    ///
    /// - **TK1 (source-mode / non-markdown):** keep the legacy
    ///   `FSNTextAttachmentCell` path. The cell owns the image, its
    ///   `draw(withFrame:in:characterIndex:layoutManager:)` override
    ///   handles folded-region suppression, and layout invalidation
    ///   goes through `NSLayoutManager.invalidateLayout`.
    /// - **TK2 (block-model WYSIWYG):** attachments are created by
    ///   `InlineRenderer` as `ImageNSTextAttachment` — an
    ///   `NSTextAttachment` subclass that carries a `hostedImage`
    ///   property. The paired `ImageAttachmentViewProvider.loadView()`
    ///   reads `hostedImage` and vends an `InlineImageView` (an
    ///   `NSImageView` subclass) to TK2, which then manages view
    ///   lifecycle and viewport visibility automatically. Feeding the
    ///   loaded image into `hostedImage` here is what makes the view
    ///   provider render the actual bytes rather than a placeholder.
    ///
    ///   `attachment.image = image` is still set as a backward-
    ///   compatibility safety net so a plain `NSTextAttachment` (one
    ///   that didn't come through the `InlineRenderer` subclass path)
    ///   can still render via TK2's default attachment contract
    ///   (`image(forBounds:textContainer:characterIndex:)`), though
    ///   the image may appear at a wrong size in that legacy path.
    ///   Layout invalidation happens on the `NSTextLayoutManager` via
    ///   a converted `NSTextRange`.
    ///
    /// Folded-region suppression is intentionally not carried over to
    /// the TK2 branch — TK2 folding uses a different mechanism
    /// (paragraph-level visibility) and is an orthogonal concern.
    private static func installLoadedImage(
        attachment: NSTextAttachment,
        image: PlatformImage,
        loadedSize: CGSize,
        range: NSRange,
        textStorage: NSTextStorage,
        editor: EditTextView
    ) {
        // Phase 4.5: TK1 branch (`FSNTextAttachmentCell` +
        // `NSLayoutManager.invalidateLayout`) removed with the custom
        // layout-manager subclass. The app is TK2-only; hand the loaded
        // image to the NSTextAttachment and invalidate via
        // `NSTextLayoutManager`.
        image.size = loadedSize
        attachment.attachmentCell = nil
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: loadedSize.width, height: loadedSize.height)

        // Slice 1 (image-resize TK2 migration): when the placeholder
        // attachment was created by InlineRenderer as an
        // `ImageNSTextAttachment`, feed the loaded image into the subclass
        // so `ImageAttachmentViewProvider.loadView()` hands TK2 an
        // `InlineImageView` with the bytes drawn. For plain `NSTextAttachment`
        // the `.image` setter above is all TK2 has to go on — this is the
        // legacy path and may render invisibly under some TK2 contexts.
        if let imageAttachment = attachment as? ImageNSTextAttachment {
            imageAttachment.hostedImage = image
        }

        textStorage.edited(.editedAttributes, range: range, changeInLength: 0)

        if let tlm = editor.textLayoutManager,
           let tcs = tlm.textContentManager as? NSTextContentStorage,
           let textRange = tk2TextRange(for: range, in: tcs) {
            tlm.invalidateLayout(for: textRange)
        }
    }

    /// Convert an `NSRange` over the bridged `NSTextStorage` to an
    /// `NSTextRange` in the TK2 `NSTextContentStorage`'s coordinate
    /// space. Uses the content storage's documentRange origin +
    /// per-location offset arithmetic; returns nil if the endpoints
    /// fall outside the document (e.g. a race between hydration and a
    /// splice that shortened the storage).
    private static func tk2TextRange(
        for range: NSRange,
        in tcs: NSTextContentStorage
    ) -> NSTextRange? {
        let docStart = tcs.documentRange.location
        guard let startLocation = tcs.location(docStart, offsetBy: range.location),
              let endLocation = tcs.location(startLocation, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: startLocation, end: endLocation)
    }
}
