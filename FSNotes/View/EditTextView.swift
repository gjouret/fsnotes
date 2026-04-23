//
//  EditTextView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 8/11/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import PDFKit

class EditTextView: NSTextView, NSTextFinderClient, NSSharingServicePickerDelegate, EditorDelegate {
    public var editorViewController: EditorViewController?
    public var textStorageProcessor: TextStorageProcessor?

    /// Phase 2b — strong reference to the `NSTextContentStorage` delegate
    /// that maps `.blockModelKind` attributes onto `BlockModelElement`
    /// subclasses. `NSTextContentStorage.delegate` is weak, so the editor
    /// must retain it for the lifetime of the view.
    public var blockModelContentDelegate: BlockModelContentStorageDelegate?

    /// Phase 2c — strong reference to the `NSTextLayoutManager` delegate
    /// that maps `BlockModelElement` subclasses onto custom
    /// `NSTextLayoutFragment` subclasses. `NSTextLayoutManager.delegate`
    /// is weak; the editor owns the lifetime.
    public var blockModelLayoutDelegate: BlockModelLayoutManagerDelegate?

    /// Explicit save boundary for the editor. Reading the storage remains pure;
    /// no view-state materialization happens here.
    ///
    /// SAFETY: When the block-model pipeline is active, the textStorage
    /// contains RENDERED content with no markdown markers. We MUST
    /// serialize the Document instead of returning the raw storage.
    /// This is a safety net — all save call sites go through
    /// `editor.save()`, but this prevents corruption if any other code
    /// path reads attributedStringForSaving().
    func attributedStringForSaving() -> NSAttributedString {
        if let markdown = serializeViaBlockModel() {
            return NSAttributedString(string: markdown)
        }
        return attributedString()
    }

    func refreshParagraphRendering(range: NSRange) {
        guard let storage = textStorage else { return }

        // Block-model pipeline owns paragraph styles — skip source-mode path.
        if textStorageProcessor?.blockModelActive == true { return }

        if NotesTextProcessor.hideSyntax,
           let processor = textStorageProcessor,
           !processor.blocks.isEmpty {
            processor.phase5_paragraphStyles(textStorage: storage, range: range)
        } else {
            storage.updateParagraphStyle(range: range)
        }

        // Phase 2a: use TK1-safe accessor (reading .layoutManager on
        // a TK2 view silently tears down the TK2 wiring).
        layoutManagerIfTK1?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    }

    /// Phase 2f.1 — TK2 layout invalidation for a character range.
    ///
    /// Used when a storage-level attribute change needs TK2 to re-dispatch
    /// its content-storage elements and rebuild layout fragments (the
    /// concrete case: `TextStorageProcessor.toggleFold` toggling
    /// `.foldedContent`, where the content-storage delegate must
    /// re-substitute `FoldedElement` ↔ normal block elements based on
    /// the new attribute value).
    ///
    /// Converts the NSRange to an NSTextRange and asks the layout manager
    /// to invalidate. Under TK1 `textLayoutManager` is nil and this is a
    /// no-op — callers remain responsible for TK1 invalidation via
    /// `layoutManagers.first`.
    public func invalidateTextKit2Layout(forCharacterRange range: NSRange) {
        guard let tlm = textLayoutManager,
              let contentManager = tlm.textContentManager else { return }
        let docLength = textStorage?.length ?? 0
        let safeStart = max(0, min(range.location, docLength))
        let safeEnd = max(safeStart, min(NSMaxRange(range), docLength))
        guard let startLoc = contentManager.location(
            contentManager.documentRange.location,
            offsetBy: safeStart
        ), let endLoc = contentManager.location(
            contentManager.documentRange.location,
            offsetBy: safeEnd
        ), let textRange = NSTextRange(
            location: startLoc, end: endLoc
        ) else { return }
        tlm.invalidateLayout(for: textRange)
        needsDisplay = true
    }

    public var note: Note?
    public var viewDelegate: ViewController?

    /// True when the user has made an edit since the last fill/save.
    /// Prevents display-only operations (fill, hydration, async rendering)
    /// from triggering saves that could corrupt note content on disk.
    public var hasUserEdits: Bool = false

    /// Range of a code block that was restored from a rendered image and needs re-rendering
    /// when the cursor moves outside it
    public var pendingRenderBlockRange: NSRange?

    /// Storage length at the last call to triggerCodeBlockRenderingIfNeeded.
    /// Used to skip re-scanning when only the cursor moved and no edit occurred.
    
    let storage = Storage.shared()
    let caretWidth: CGFloat = 2
    
    public var timer: Timer?
    public var tagsTimer: Timer?
    /// Debounce timer for autosave during typing. See
    /// `EditTextView+NoteState.scheduleDebouncedSave()` (Perf plan #12).
    public var saveDebounceTimer: Timer?
    public var isLastEdited: Bool = false
    
    @IBOutlet weak var previewMathJax: NSMenuItem!

    public var imagesLoaderQueue = OperationQueue.init()
    public var attributesCachingQueue = OperationQueue.init()
    public lazy var gutterController = GutterController(textView: self)


    public var isScrollPositionSaverLocked = false
    public var skipLoadSelectedRange = false
    var dragDetected = false

    /// Character range of the currently selected image attachment, or
    /// nil when no image is selected.
    ///
    /// Purely view-layer ephemeral state — not persisted, not undoable,
    /// never read by the data layer. Cleared on text edit, note switch,
    /// Escape, or click elsewhere. The `didSet` observer dirties the
    /// stale and new handle rects so the LayoutManager repaints them.
    public var selectedImageRange: NSRange? {
        didSet {
            guard oldValue != selectedImageRange else { return }
            if let old = oldValue { invalidateImageSelectionHandles(for: old) }
            if let new = selectedImageRange { invalidateImageSelectionHandles(for: new) }
        }
    }

    /// Ephemeral drag state for the in-progress image resize. Non-nil
    /// only between mouseDown on a handle and mouseUp. Never persisted.
    public struct ImageResizeDrag {
        /// Character range of the attachment being resized.
        public let range: NSRange
        /// The image's bounds at the start of the drag (natural size
        /// before any live-update mutation).
        public let startBounds: NSRect
        /// The window-relative mouse point where the drag began.
        public let startMouse: NSPoint
        /// height / width at drag start — locked for the whole drag
        /// so aspect ratio is preserved.
        public let aspect: CGFloat
        /// Which handle the user grabbed.
        public let handle: ImageSelectionHandleDrawer.Handle
    }

    /// Non-nil while a handle-drag is in progress. Set on mouseDown
    /// (handle hit), read on mouseDragged, cleared on mouseUp.
    public var currentImageDrag: ImageResizeDrag?

    /// Compute the visible image rect (in view coordinates) for an
    /// image attachment at the given character range.
    ///
    /// Horizontal (x, width) from `boundingRect(forGlyphRange:in:)` —
    /// the layout manager's definitive "where does this glyph draw"
    /// query. This works for both left-aligned and centered
    /// paragraphs as long as `FSNTextAttachmentCell.cellSize()` does
    /// not lie about the cell width (see the block-model branch in
    /// that method — it used to inflate the cell to full container
    /// width, which broke hit-test for centered images).
    ///
    /// Vertical baseline from `lineFragmentRect` + `location(forGlyphAt:)`,
    /// height from the attachment's own `bounds`. We avoid using
    /// `boundingRect.height` because NSLayoutManager includes font
    /// descent + leading below the glyph, which would draw the
    /// selection ring's bottom edge under the image.
    public func imageAttachmentRect(forRange range: NSRange) -> NSRect? {
        // Phase 2a: TK1-only glyph query. Returns nil under TK2 —
        // callers (image selection handle drawing) tolerate nil and
        // fall through to no-op. TK2 image hit-test lands in 2c/2d.
        guard let lm = layoutManagerIfTK1,
              let tc = textContainer,
              let storage = textStorage,
              range.location < storage.length,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
        else { return nil }
        let imageBounds = attachment.bounds
        guard imageBounds.width > 0, imageBounds.height > 0 else { return nil }

        // Force layout through the attachment glyph before querying.
        // A freshly-spliced attachment may not have had its glyph
        // position computed yet; without this, boundingRect returns
        // stale/zero values.
        lm.ensureLayout(forCharacterRange: range)

        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let glyphIndex = glyphRange.location

        let drawingRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLoc = lm.location(forGlyphAt: glyphIndex)
        let baselineY = fragment.origin.y + glyphLoc.y

        let left = drawingRect.origin.x + imageBounds.origin.x
        let top  = baselineY - imageBounds.height - imageBounds.origin.y

        var rect = NSRect(x: left, y: top, width: imageBounds.width, height: imageBounds.height)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// Invalidate the display rectangle around an image attachment's
    /// bounding rect, expanded by the handle half-size so stale corner
    /// handles get repainted cleanly.
    private func invalidateImageSelectionHandles(for range: NSRange) {
        // Phase 2a: TK1-only. TK2 image selection handling is a 2c/2d item.
        guard let lm = layoutManagerIfTK1, let tc = textContainer else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        // Pad for handle size (6pt handle + 2pt ring slack).
        setNeedsDisplay(rect.insetBy(dx: -12, dy: -12))
    }

    override func becomeFirstResponder() -> Bool {
        if let note = self.note {
            if note.container == .encryptedTextPack {
                return false
            }

            textStorage?.removeHighlight()
        }

        // Determine if this becomeFirstResponder was triggered by the
        // user clicking inside this editor. In Cocoa, the window calls
        // makeFirstResponder BEFORE routing the mouseDown event, so our
        // mouseDown override hasn't run yet and skipLoadSelectedRange is
        // still false. If we call loadSelectedRange here, it scrolls to
        // the saved cursor position and the subsequent mouseDown places
        // the cursor at the wrong character (because the view scrolled
        // out from under the mouse), causing a large spurious selection.
        let isClickInSelf: Bool = {
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return false }
            let point = self.convert(event.locationInWindow, from: nil)
            return self.bounds.contains(point)
        }()

        if skipLoadSelectedRange {
            skipLoadSelectedRange = false
        } else if isClickInSelf {
            // The mouse click will handle cursor placement in mouseDown.
            // Do NOT restore saved cursor/scroll here.
        } else {
            loadSelectedRange()
        }

        // Show focus border when editor gains focus
        if let scrollView = enclosingScrollView as? EditorScrollView {
            scrollView.showFocusBorder()
        }

        return super.becomeFirstResponder()
    }

    //MARK: caret width

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw gutter icons (fold carets, H-level badges) in the text view's coordinate space.
        // Must be here (not in LayoutManager.drawBackground) because the gutter is OUTSIDE
        // the text container bounds and would be clipped by the layout manager.
        if NotesTextProcessor.hideSyntax {
            gutterController.drawIcons(in: dirtyRect)
        }

        guard UserDefaultsManagement.inlineTags else { return }

        if #available(OSX 10.16, *) {
            // Phase 2a: inline-tag chip drawing is TK1-only. Under TK2 the
            // draw() path skips chip rendering entirely — the tags still
            // render as inline attributed text (foreground color + font),
            // just without the rounded chip background. Full TK2 inline
            // chip drawing will be reinstated in 2c/2d via a custom
            // NSTextLayoutFragment / NSTextViewportLayoutController hook.
            guard let textStorage = self.textStorage,
                  let layoutManager = self.layoutManagerIfTK1
            else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)

            attributedString().enumerateAttributes(in: fullRange, options: .reverse) { attributes, range, _ in
                guard range.location >= 0,
                      range.location + range.length <= textStorage.length else { return }
                
                guard attributes.index(forKey: .tag) != nil,
                      let font = attributes[.font] as? NSFont
                else { return }

                let tag = attributedString().attributedSubstring(from: range).string
                let tagAttributes = attributedString().attributes(at: range.location, effectiveRange: nil)

                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                
                let ascent = font.ascender
                let descent = abs(font.descender)
                let fontHeight = ascent + descent

                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, textContainer, lineGlyphRange, stop in

                    let intersectionRange = NSIntersectionRange(glyphRange, lineGlyphRange)
                    guard intersectionRange.length > 0 else { return }
                    
                    var fragmentRect = layoutManager.boundingRect(forGlyphRange: intersectionRange, in: textContainer)
                    
                    fragmentRect.origin.x += self.textContainerOrigin.x
                    fragmentRect.origin.y += self.textContainerOrigin.y
                    fragmentRect = self.convertToLayer(fragmentRect)
                    fragmentRect = fragmentRect.integral

                    let verticalInset = max(0, (fragmentRect.height - fontHeight) / 2)
                    var tagRect = NSRect(
                        x: fragmentRect.minX,
                        y: fragmentRect.minY + verticalInset,
                        width: fragmentRect.width - 3,
                        height: fontHeight
                    )

                    let oneCharSize = ("A" as NSString).size(withAttributes: tagAttributes)
                    tagRect.size.width += oneCharSize.width * 0.25
                    tagRect = tagRect.integral

                    NSGraphicsContext.saveGraphicsState()
                    let path = NSBezierPath(roundedRect: tagRect, xRadius: 3, yRadius: 3)
                    NSColor.tagColor.setFill()
                    path.fill()

                    let fragmentCharRange = layoutManager.characterRange(forGlyphRange: intersectionRange, actualGlyphRange: nil)
                    let fragmentText = (tag as NSString).substring(with: NSRange(
                        location: fragmentCharRange.location - range.location,
                        length: fragmentCharRange.length
                    ))

                    var drawAttrs = tagAttributes
                    drawAttrs[.font] = font
                    drawAttrs[.foregroundColor] = NSColor.white
                    drawAttrs.removeValue(forKey: .link)
                    drawAttrs.removeValue(forKey: .baselineOffset)

                    let baselineOrigin = NSPoint(x: tagRect.minX, y: tagRect.minY + descent - 3)

                    (fragmentText as NSString).draw(at: baselineOrigin, withAttributes: drawAttrs)

                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
    }

    /// Phase 2a: Safe accessor for the TextKit 1 `NSLayoutManager`. Returns
    /// `nil` when the view is wired to TextKit 2 (i.e. `textLayoutManager`
    /// is non-nil). Reading `NSTextView.layoutManager` directly on a
    /// TK2 view lazily instantiates a TK1 compatibility shim, which
    /// PERMANENTLY tears down `textLayoutManager` with no way to recover.
    /// Every call site that needs `NSLayoutManager` in order to use a
    /// TK1-only API must go through this accessor and treat `nil` as
    /// "we are on TK2 — skip the TK1 codepath". This property is the
    /// only place `self.layoutManager` may legitimately be read inside
    /// the app. Grep for `self.layoutManager` / `layoutManager?.` to
    /// audit new uses.
    var layoutManagerIfTK1: NSLayoutManager? {
        return textLayoutManager == nil ? layoutManager : nil
    }

    /// Phase 2a: build a text container pre-bound to an
    /// `NSTextLayoutManager` + `NSTextContentStorage` pair. NSTextView
    /// adopts TextKit 2 when it is constructed with a container already
    /// bound to `NSTextLayoutManager` (see the Phase 2 kickoff spike
    /// in `TextKit2FinderSpikeTests` for the proof). A runtime swap via
    /// `replaceTextContainer(_:)` does NOT flip an already-TK1 view —
    /// so we intercept at every designated initializer to ensure the
    /// view is born on TK2.
    private static func makeTextKit2Container(size: CGSize) -> NSTextContainer {
        let contentStorage = NSTextContentStorage()
        let textLayoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(textLayoutManager)
        let container = NSTextContainer(size: size)
        textLayoutManager.textContainer = container
        return container
    }

    /// Designated initializer for programmatic construction (tests,
    /// harness, any runtime `EditTextView(frame:)` call). Routes
    /// through `init(frame:textContainer:)` with a TK2-bound container
    /// so the view adopts TextKit 2 from birth.
    override init(frame frameRect: NSRect) {
        let container = EditTextView.makeTextKit2Container(
            size: CGSize(width: frameRect.width, height: 1e7)
        )
        super.init(frame: frameRect, textContainer: container)
    }

    /// Explicit-container path. Pass-through to super — callers that
    /// already hand us a TK2-bound container get TK2; callers that
    /// hand a TK1 container (old `HeaderTests` helper) get the pre-
    /// Phase 2a behaviour. `adoptTextKit2PostDecode()` is NOT called
    /// here: respect caller intent.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    /// Nib-load path. The storyboard decodes a TK1 NSTextView here.
    /// We do NOT try to flip this view in place — AppKit binds the
    /// TextKit version at init time, and `replaceTextContainer(_:)`
    /// does not override that decision. The view controller is
    /// responsible for calling `migrateNibEditorToTextKit2(...)` during
    /// setup to replace this instance with a programmatic TK2 editor.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Phase 2a: swap a nib-decoded TK1 editor for a programmatically
    /// constructed TK2 editor, in place inside its scroll view. Copies
    /// the NSTextView knobs the storyboard configured. Returns the new
    /// editor — callers must reassign their `editor` outlet to it.
    ///
    /// If `oldEditor` is already on TK2 (e.g. someone re-entered this
    /// path), the function is a no-op and returns `oldEditor`.
    ///
    /// NSTextView.autoresizingMask, isRichText, importsGraphics, etc.
    /// are copied explicitly — we don't clone the whole object because
    /// the only reliable way to instantiate a TK2 EditTextView is
    /// `init(frame:)`, which builds its own container.
    @discardableResult
    static func migrateNibEditorToTextKit2(
        oldEditor: EditTextView,
        scrollView: NSScrollView
    ) -> EditTextView {
        guard oldEditor.textLayoutManager == nil else {
            return oldEditor
        }

        let newEditor = EditTextView(frame: oldEditor.frame)

        // Nib-configured NSTextView knobs we care about. If the
        // storyboard ever adds a new attribute, mirror it here.
        newEditor.autoresizingMask = oldEditor.autoresizingMask
        newEditor.isRichText = oldEditor.isRichText
        newEditor.importsGraphics = oldEditor.importsGraphics
        newEditor.isEditable = oldEditor.isEditable
        newEditor.isSelectable = oldEditor.isSelectable
        newEditor.allowsUndo = oldEditor.allowsUndo
        newEditor.usesFindBar = oldEditor.usesFindBar
        newEditor.usesFontPanel = oldEditor.usesFontPanel
        newEditor.usesRuler = oldEditor.usesRuler
        newEditor.allowsImageEditing = oldEditor.allowsImageEditing
        newEditor.allowsDocumentBackgroundColorChange =
            oldEditor.allowsDocumentBackgroundColorChange
        newEditor.smartInsertDeleteEnabled = oldEditor.smartInsertDeleteEnabled
        newEditor.isAutomaticQuoteSubstitutionEnabled =
            oldEditor.isAutomaticQuoteSubstitutionEnabled
        newEditor.isAutomaticDashSubstitutionEnabled =
            oldEditor.isAutomaticDashSubstitutionEnabled
        newEditor.isAutomaticTextReplacementEnabled =
            oldEditor.isAutomaticTextReplacementEnabled
        newEditor.isAutomaticLinkDetectionEnabled =
            oldEditor.isAutomaticLinkDetectionEnabled
        newEditor.isAutomaticSpellingCorrectionEnabled =
            oldEditor.isAutomaticSpellingCorrectionEnabled
        newEditor.isContinuousSpellCheckingEnabled =
            oldEditor.isContinuousSpellCheckingEnabled
        newEditor.isVerticallyResizable = oldEditor.isVerticallyResizable
        newEditor.isHorizontallyResizable = oldEditor.isHorizontallyResizable
        newEditor.textContainerInset = oldEditor.textContainerInset
        // Resize bounds: required for the view to grow with content so
        // the scroll view has something to scroll. Without these the TK2
        // editor stays at its init frame height forever — long notes
        // just clip at the bottom of the visible area.
        newEditor.minSize = oldEditor.minSize
        newEditor.maxSize = oldEditor.maxSize
        if let font = oldEditor.font {
            newEditor.font = font
        }

        // Mirror the NSTextContainer geometry the storyboard configured.
        // `widthTracksTextView = true` makes wrapping follow the view
        // width; `heightTracksTextView = false` lets the view grow past
        // its initial frame so scrolling works on long notes.
        if let oldContainer = oldEditor.textContainer,
           let newContainer = newEditor.textContainer {
            newContainer.widthTracksTextView = oldContainer.widthTracksTextView
            newContainer.heightTracksTextView = oldContainer.heightTracksTextView
            newContainer.lineFragmentPadding = oldContainer.lineFragmentPadding
            // Use the old container's size as a starting point (height
            // stays huge so vertical growth isn't capped).
            newContainer.size = NSSize(
                width: oldContainer.size.width,
                height: max(oldContainer.size.height, 1e7)
            )
        }

        scrollView.documentView = newEditor
        return newEditor
    }

    /// Phase 2a: wire the `TextStorageProcessor` as delegate of the
    /// compatibility `NSTextStorage` that `NSTextContentStorage` exposes
    /// back through `NSTextView.textStorage`. The TK2 layout stack is
    /// already installed via the initializers above — this function
    /// only hooks the processor into the edit-callback chain.
    ///
    /// Accepted 2a regressions (deferred to 2c/2d): the custom
    /// `LayoutManager.drawBackground` visuals (bullets, HR lines,
    /// blockquote borders, kbd boxes) no longer fire under TK2. All
    /// other editing behaviour (typing, selection, Find, scroll,
    /// copy/paste) rides the default TK2 paragraph-element path.
    public func initTextStorage() {
        let processor = TextStorageProcessor()
        processor.editor = self
        textStorageProcessor = processor
        textStorage?.delegate = processor

        // Phase 2b: install the content-storage delegate so TK2 hands
        // block-tagged paragraphs back as `BlockModelElement` subclasses.
        // Safe on TK1 (where `textLayoutManager` is nil) — we just skip.
        if let contentStorage =
            textLayoutManager?.textContentManager as? NSTextContentStorage {
            let delegate = BlockModelContentStorageDelegate()
            blockModelContentDelegate = delegate
            contentStorage.delegate = delegate
        }

        // Phase 2c: install the layout-manager delegate so
        // `BlockModelElement` subclasses get routed to their custom
        // `NSTextLayoutFragment` subclasses (e.g. horizontal rule →
        // `HorizontalRuleLayoutFragment`). TK1-safe: skipped when
        // `textLayoutManager` is nil.
        if let layoutManager = textLayoutManager {
            let delegate = BlockModelLayoutManagerDelegate()
            blockModelLayoutDelegate = delegate
            layoutManager.delegate = delegate
        }

    }
    
    public func configure() {
        DispatchQueue.main.async {
            self.updateTextContainerInset()
        }

        attributesCachingQueue.qualityOfService = .background
        textContainerInset.height = 10
        isEditable = false

        let isOpenedWindow = window?.contentViewController as? NoteViewController != nil

        // Phase 2a: TK1-only knobs. TK2's NSTextLayoutManager manages its
        // own viewport-based layout and doesn't expose these. The TK2
        // equivalents live on `textLayoutManager` directly; for now we
        // accept default TK2 behaviour in those paths.
        layoutManagerIfTK1?.allowsNonContiguousLayout =
            isOpenedWindow
                ? false
                : UserDefaultsManagement.nonContiguousLayout

        layoutManagerIfTK1?.defaultAttachmentScaling = .scaleProportionallyDown

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        defaultParagraphStyle = paragraphStyle
        typingAttributes[.paragraphStyle] = paragraphStyle
        typingAttributes[.font] = UserDefaultsManagement.noteFont
    }

    public func invalidateLayout() {
        // Phase 2a: route through the TK1-safe accessor. Previously this
        // read `textStorage.layoutManagers.first`, which under TK2 is
        // empty (no TK1 NSLayoutManager attached) — safe, but relying on
        // that empty-collection quirk was fragile. TK2 viewport layout
        // invalidation is an NSTextViewportLayoutController concern and
        // lands in 2c.
        guard let lm = layoutManagerIfTK1,
              let length = self.textStorage?.length else { return }
        lm.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: length),
            actualCharacterRange: nil
        )
    }

    private var lastLayoutWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.size.width
        super.setFrameSize(newSize)
        if abs(newSize.width - oldWidth) > 0.5 {
            invalidateRenderedBlockAttachmentLayout()
        }
        lastLayoutWidth = newSize.width
    }

    /// Force NSLayoutManager to re-query cellFrame(for:...) on rendered block
    /// attachments (mermaid/math images) after a width change so they can shrink/grow.
    private func invalidateRenderedBlockAttachmentLayout() {
        // Phase 2a: rendered block attachment layout invalidation is
        // TK1-only. TK2 attachment re-layout on width change lands in
        // 2d with the NSTextLayoutFragment override path.
        guard let storage = textStorage, let lm = layoutManagerIfTK1 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            guard value is NSTextAttachment else { return }
            if storage.attribute(.renderedBlockSource, at: range.location, effectiveRange: nil) != nil {
                lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
        }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        return []
    }

    @IBAction func moveSelectedLinesDown(_ sender: NSMenuItem) {
        self.moveSelectedLinesDown()
    }
    
    @IBAction func moveSelectedLinesUp(_ sender: NSMenuItem) {
        self.moveSelectedLinesUp()
    }
    
    @IBAction func clearCompletedTodos(_ sender: NSMenuItem) {
        self.clearCompletedTodos()
    }
    
    // MARK: Autocomplete overrides
    
    var suppressCompletion = false
    
    public var forceSystemAutocomplete = false
    private var isSystemCompletionSession = false
    
    override func didChangeText() {
        super.didChangeText()

        // Any text edit invalidates an image selection: the attachment
        // may have moved, been deleted, or re-rendered with new bounds.
        if selectedImageRange != nil {
            selectedImageRange = nil
        }

        if suppressCompletion {
            suppressCompletion = false
            return
        }
        
        if detectCompletionContext() != .none {
            complete(nil)
        }
    }
    
    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {

        if forceSystemAutocomplete {
            isSystemCompletionSession = true
            forceSystemAutocomplete = false
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }

        return handleCompletions(index: index)
    }

    override func insertCompletion(_ word: String,
                                   forPartialWordRange charRange: NSRange,
                                   movement: Int,
                                   isFinal flag: Bool) {

        if isSystemCompletionSession {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)

            if flag {
                isSystemCompletionSession = false
            }
            return
        }

        handleInsertCompletion(word: word, movement: movement, isFinal: flag)
    }

    override var rangeForUserCompletion: NSRange {
        if isSystemCompletionSession {
            return super.rangeForUserCompletion
        }

        return calculateCompletionRange()
    }
    
    @objc public func scanTagsAndAutoRename() {
        guard let vc = ViewController.shared() else { return }
        let notes = vc.tagsScannerQueue

        attributesCachingQueue.addOperation {
            for note in notes {
                note.cache()
            }
        }
        
        for note in notes {
            let result = note.scanContentTags()
            guard let outline = ViewController.shared()?.sidebarOutlineView else { return }

            let added = result.0
            let removed = result.1

            if removed.count > 0 {
                outline.removeTags(removed)
            }

            if added.count > 0 {
                outline.addTags(added)
            }

            // Re-derive the title from the current content. loadPreviewInfo
            // is guarded by `isParsed`; callers that edit content (block-model
            // path) set `isParsed = false` to opt in. No-op otherwise.
            note.loadPreviewInfo()
            bmLog("🏷️ scanTagsAndAutoRename: note.fileName='\(note.fileName)' note.title='\(note.title)' isParsed=\(note.isParsed)")

            if let title = note.getAutoRenameTitle() {
                bmLog("🏷️ rename → '\(title)'")
                note.rename(to: title)

                if let editorViewController = getEVC() {
                    editorViewController.vcTitleLabel?.updateNotesTableView()
                    editorViewController.updateTitle(note: note)
                }
            }

            ViewController.shared()?.tagsScannerQueue.removeAll(where: { $0 === note })
        }
    }

    func setEditorTextColor(_ color: NSColor) {
        if let note = self.note, !note.isMarkdown() {
            textColor = color
        }
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y - 7)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        // During block-model storage splicing (isRendering == true),
        // NSLayoutManager._resizeTextViewForTextContainer calls
        // scrollRangeToVisible with the entire edited region. That
        // causes a scroll jump. The block-model edit path handles
        // cursor positioning itself — no scrolling is needed.
        if textStorageProcessor?.isRendering == true { return }

        // DIAGNOSTIC: log caller stack whenever scrollRangeToVisible
        // fires while a table cell's field editor owns focus. This
        // captures the "Space-scrolls-note" root cause.
        if let window = self.window,
           let fe = window.fieldEditor(false, for: nil) as? NSTextView,
           fe !== self,
           fe.delegate is NSTextField {
            // Phase 2a: diagnostic-only; under TK2 this simply logs .zero.
            let rect = layoutManagerIfTK1?.boundingRect(
                forGlyphRange: layoutManagerIfTK1?.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil
                ) ?? NSRange(location: 0, length: 0),
                in: textContainer!
            ) ?? .zero
            let visible = visibleRect
            let logDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("log")
            try? FileManager.default.createDirectory(
                at: logDir, withIntermediateDirectories: true
            )
            let logURL = logDir.appendingPathComponent("scroll-debug.log")
            let entry = """
            [scrollRangeToVisible] range=\(range) \
            rect=\(rect) visible=\(visible)
            stack:
            \(Thread.callStackSymbols.prefix(20).joined(separator: "\n"))
            -----

            """
            if let data = entry.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: logURL)
                }
            }
        }

        super.scrollRangeToVisible(range)
    }

    // drawGutterIcons moved to GutterController

    /// Width of the left-hand gutter for header fold/unfold controls.
    public static let gutterWidth: CGFloat = 32

    @available(OSX 10.12.2, *)
    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [
            NSTouchBarItem.Identifier("Todo"),
            NSTouchBarItem.Identifier("Bold"),
            NSTouchBarItem.Identifier("Italic"),
            .fixedSpaceSmall,
            NSTouchBarItem.Identifier("Link"),
            NSTouchBarItem.Identifier("Image or file"),
            NSTouchBarItem.Identifier("CodeBlock"),
            .fixedSpaceSmall,
            NSTouchBarItem.Identifier("Indent"),
            NSTouchBarItem.Identifier("UnIndent")
        ]
        return touchBar
    }

    @available(OSX 10.12.2, *)
    override func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case NSTouchBarItem.Identifier("Todo"):
            if let im = NSImage(named: "todo"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(todo(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Bold"):
            if let im = NSImage(named: "bold"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(pressBold(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Italic"):
            if let im = NSImage(named: "italic"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(pressItalic(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Image or file"):
            if let im = NSImage(named: "image"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(insertFileOrImage(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }

        case NSTouchBarItem.Identifier("Indent"):
            if let im = NSImage(named: "indent"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(shiftRight(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }

        case NSTouchBarItem.Identifier("UnIndent"):
            if let im = NSImage(named: "unindent"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(shiftLeft(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("CodeBlock"):
            if let im = NSImage(named: "codeblock"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(insertCodeBlock(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Link"):
            if let im = NSImage(named: "tb_link"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(insertLink(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        default: break
        }

        return super.touchBar(touchBar, makeItemForIdentifier: identifier)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)

        let editTitle = NSLocalizedString("Edit Link…", comment: "")
        if let editLink = menu?.item(withTitle: editTitle) {
            menu?.removeItem(editLink)
        }

        let removeTitle = NSLocalizedString("Remove Link", comment: "")
        if let removeLink = menu?.item(withTitle: removeTitle) {
            menu?.removeItem(removeLink)
        }

        // If the right-click lands on or immediately adjacent to a
        // table attachment, add a "Delete Table" item. This gives the
        // user a way to remove a table without having to select it
        // with the keyboard first (the delete-key path works too, via
        // `EditingOps.delete` with the block's full span).
        if let deleteItem = makeDeleteTableMenuItemIfNeeded(for: event) {
            menu?.insertItem(NSMenuItem.separator(), at: 0)
            menu?.insertItem(deleteItem, at: 0)
        }

        return menu
    }

    /// If `event`'s location falls inside a `.table` block, return an
    /// `NSMenuItem` whose action removes that block (routing through
    /// `EditingOps.delete` so the removal is an undoable block-model
    /// edit). Otherwise return nil and the menu is unchanged.
    ///
    /// The block index is captured on `representedObject` of the
    /// menu item so the action handler doesn't need to re-run the
    /// hit test.
    private func makeDeleteTableMenuItemIfNeeded(for event: NSEvent) -> NSMenuItem? {
        guard let projection = documentProjection,
              let storage = textStorage else { return nil }
        let pointInView = convert(event.locationInWindow, from: nil)
        let charIdx = characterIndexForInsertion(at: pointInView)
        guard charIdx >= 0, charIdx < storage.length else { return nil }
        guard let (blockIdx, _) = projection.blockContaining(storageIndex: charIdx) else {
            return nil
        }
        guard case .table = projection.document.blocks[blockIdx] else { return nil }

        let item = NSMenuItem(
            title: NSLocalizedString("Delete Table", comment: ""),
            action: #selector(deleteTableFromContextMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = blockIdx
        return item
    }

    /// Menu-action handler for "Delete Table". Reads the block index
    /// from `sender.representedObject`, re-derives the block's span
    /// against the current projection, and calls the same
    /// `EditingOps.delete` path the keyboard delete key uses.
    @objc private func deleteTableFromContextMenu(_ sender: NSMenuItem) {
        guard let blockIdx = sender.representedObject as? Int,
              let projection = documentProjection,
              blockIdx < projection.blockSpans.count else { return }
        let span = projection.blockSpans[blockIdx]
        // Route through the standard delete path so the operation is
        // undoable and the splice goes through `applyEditResultWithUndo`.
        _ = handleEditViaBlockModel(in: span, replacementString: "")
    }

    /**
     Handoff methods
     */
    override func updateUserActivityState(_ userActivity: NSUserActivity) {
        guard let note = self.note else { return }

        let position =
            window?.firstResponder == self ? selectedRange().location : -1
        let data =
            [
                "note-file-name": note.name,
                "position": String(position)
            ]

        userActivity.addUserInfoEntries(from: data)
    }

    override func resignFirstResponder() -> Bool {
        userActivity?.needsSave = true

        if let scrollView = enclosingScrollView as? EditorScrollView {
            scrollView.hideFocusBorder()
        }

        return super.resignFirstResponder()
    }

    public func registerHandoff(note: Note) {
        self.userActivity?.invalidate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let updateDict:  [String: String] = ["note-file-name": note.name]
            let activity = NSUserActivity(activityType: "es.fsnot.handoff-open-note")
            activity.isEligibleForHandoff = true
            activity.userInfo = updateDict
            activity.title = NSLocalizedString("Open note", comment: "Document opened")
            self.userActivity = activity
            self.userActivity?.becomeCurrent()
        }
    }
    
    public func scheduleTagScan(for note: Note) {
        if let vc = ViewController.shared(),
           !vc.tagsScannerQueue.contains(note) {
            vc.tagsScannerQueue.append(note)
        }

        tagsTimer?.invalidate()
        tagsTimer = Timer.scheduledTimer(
            timeInterval: 2.5,
            target: self,
            selector: #selector(scanTagsAndAutoRename),
            userInfo: nil,
            repeats: false
        )
    }

    public func resetTypingAttributes() {
        typingAttributes.removeValue(forKey: .attachmentUrl)
        typingAttributes.removeValue(forKey: .attachmentTitle)
        typingAttributes.removeValue(forKey: .attachmentPath)
        typingAttributes.removeValue(forKey: .attachmentSave)
        typingAttributes.removeValue(forKey: .tag)

        if let style = typingAttributes[.paragraphStyle] as? NSMutableParagraphStyle {
            style.alignment = .left
        }
        
        typingAttributes[.font] = UserDefaultsManagement.noteFont
    }
}
