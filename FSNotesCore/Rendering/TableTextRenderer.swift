//
//  TableTextRenderer.swift
//  FSNotesCore
//
//  Renders a Block.table as a single NSTextAttachment character.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: header cells, data rows, raw markdown, body font.
//  - Output: NSAttributedString containing ONE attachment character
//    (TableBlockAttachment). The attachment stores the parsed table
//    data and raw markdown so the app-level code can configure the
//    visual cell (InlineTableView widget) without re-parsing.
//  - Single character output means block spans stay valid — no
//    multi-line text that must be replaced by a post-pass.
//  - Pure function: same input → equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Table Attachment Cell Marker

/// Marker protocol conformed to by the app target's
/// `InlineTableAttachmentCell`. Lives in `FSNotesCore` so that
/// `LayoutManager` and other framework code can identify
/// table-hosting attachment cells via `cell is TableAttachmentHosting`
/// without a cross-module type dependency.
///
/// Phase 2e (TK2): conforming cells also expose the live widget as
/// `hostedView`. `TableBlockAttachment.viewProvider(...)` reads this to
/// hand the same `InlineTableView` instance — the one the TK1 cell
/// `draw(...)` path currently installs as a subview — to TextKit 2 via
/// `TableAttachmentViewProvider`. The cross-module split is preserved:
/// the concrete `InlineTableView` type stays in the app target and the
/// core layer only sees an `NSView`.
#if os(OSX)
public protocol TableAttachmentHosting: AnyObject {
    var hostedView: NSView { get }
}
#else
public protocol TableAttachmentHosting: AnyObject {
    var hostedView: UIView { get }
}
#endif

// MARK: - Table Block Attachment

/// NSTextAttachment subclass that carries the parsed table data.
/// The block-model renderer emits this as a single attachment character.
/// The app target configures the visual cell (InlineTableAttachmentCell)
/// after fill — DocumentRenderer (in FSNotesCore) can't reference
/// InlineTableView (in the app target).
public class TableBlockAttachment: NSTextAttachment {
    public let header: [TableCell]
    public let rows: [[TableCell]]
    public let alignments: [TableAlignment]
    public let rawMarkdown: String

    /// Weak reference to the live widget the app has installed for this
    /// attachment. The app-side `TableRenderController.renderTables()`
    /// sets this alongside `self.attachmentCell`; the TK2 view-provider
    /// reads it to hand the widget to TextKit 2 directly — see
    /// `viewProvider(for:location:textContainer:)`.
    ///
    /// Why a weak property in addition to `attachmentCell`:
    /// `NSTextAttachmentViewProvider.textAttachment` holds the attachment
    /// weakly. In unit tests (and in short-lived construction windows at
    /// runtime) the attachment can be released before `loadView()` runs,
    /// which leaves `super.loadView()` to install an empty default view.
    /// Storing the widget reference directly on the attachment lets the
    /// provider locate the live view even under that lifetime window,
    /// while keeping the app/core module separation — the stored type
    /// is the bare `NSView` parent of `InlineTableView`.
    #if os(OSX)
    public weak var liveHostedView: NSView?
    #else
    public weak var liveHostedView: UIView?
    #endif

    public init(header: [TableCell], rows: [[TableCell]], alignments: [TableAlignment], rawMarkdown: String) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
        self.rawMarkdown = rawMarkdown
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableBlockAttachment else { return false }
        return header == other.header && rows == other.rows
    }

    public override var hash: Int {
        var h = Hasher()
        for cell in header { h.combine(cell.rawText) }
        for row in rows { for cell in row { h.combine(cell.rawText) } }
        return h.finalize()
    }

    // MARK: - TK2 View Provider (Phase 2e)

    /// Under TextKit 2, `NSTextAttachmentCell.draw(...)` is never called —
    /// the TK1 draw path that `InlineTableAttachmentCell` uses to position
    /// the live `InlineTableView` as a subview of the text view doesn't
    /// fire. View hosting under TK2 must go through
    /// `NSTextAttachmentViewProvider`.
    ///
    /// This override mirrors the proven view-provider pattern from PDF,
    /// QuickLook, image, and bullet/checkbox list markers: return a
    /// `TableAttachmentViewProvider` that hands the already-constructed
    /// `InlineTableView` (held by `self.attachmentCell` via
    /// `TableAttachmentHosting`) to TK2.
    ///
    /// **TK1 gate**: we return `nil` when the container has no
    /// `NSTextLayoutManager`. This preserves TK1 behavior for source mode
    /// and for any code path that still uses TK1 — TK1 continues to
    /// position the view via `InlineTableAttachmentCell.draw(...)`.
    ///
    /// **Cell-timing invariant**: `TableRenderController.renderTables()`
    /// assigns `attachmentCell` (and hence the `hostedView`) synchronously
    /// before TK2 composes its viewport. If the cell isn't assigned yet
    /// (attachment freshly inserted, render pass pending), we return `nil`
    /// and TK2 will re-ask on the next layout pass.
    #if os(OSX)
    public override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        guard textContainer?.textLayoutManager != nil else {
            return nil
        }
        let provider = TableAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
    #endif
}

// MARK: - TableAttachmentViewProvider (TK2)

#if os(OSX)
/// `NSTextAttachmentViewProvider` that hands the live `InlineTableView`
/// (held by the attachment cell conforming to `TableAttachmentHosting`)
/// to TextKit 2. TK2 handles adding the view to the text view's hierarchy
/// and positioning it within the viewport.
///
/// Mirror of `PDFAttachmentViewProvider`, `QuickLookAttachmentViewProvider`,
/// `ImageAttachmentViewProvider`, and `BulletAttachmentViewProvider` —
/// the pattern proven 4× in Phase 2f.
public class TableAttachmentViewProvider: NSTextAttachmentViewProvider {

    public override func loadView() {
        // Resolve the live widget in three preference-ordered steps:
        //   1. `attachment.liveHostedView` — direct strong→weak handoff
        //      from the app's rendering pass. Populated by
        //      `TableRenderController.renderTables()` alongside the
        //      attachmentCell assignment.
        //   2. `attachment.attachmentCell as? TableAttachmentHosting` —
        //      legacy path for callers that set only the cell (the TK1
        //      draw path still relies on this).
        //   3. Fall through to `super.loadView()` — the attachment has
        //      no hosted view yet; TK2 will re-query on the next layout
        //      pass after the app's render controller runs.
        let attachment = textAttachment as? TableBlockAttachment
        let hosted: NSView? = attachment?.liveHostedView
            ?? (attachment?.attachmentCell as? TableAttachmentHosting)?.hostedView
        guard let attachment = attachment, let hosted = hosted else {
            super.loadView()
            return
        }
        // Pin the hosted view's frame to the attachment's bounds. TK2
        // uses attachment.bounds to reserve inline space; matching the
        // view's frame guarantees the widget fills exactly that space.
        hosted.frame = NSRect(origin: .zero, size: attachment.bounds.size)
        self.view = hosted
    }
}
#endif

// MARK: - Renderer

public enum TableTextRenderer {

    /// Render a table to an attributed string.
    ///
    /// - When `FeatureFlag.nativeTableElements == false` (default):
    ///   emits a single `U+FFFC` character backed by a
    ///   `TableBlockAttachment`. The app target configures the visual
    ///   cell (`InlineTableView`) after `fillViaBlockModel`.
    /// - When `FeatureFlag.nativeTableElements == true` (2e-T2-b):
    ///   emits a flat, separator-encoded string of each cell's
    ///   inline-rendered attributed text. Header cells come first
    ///   (cells joined by U+001F), then U+001E, then body rows (cells
    ///   joined by U+001F, rows joined by U+001E). The range is
    ///   tagged with `.blockModelKind = .table`; header-cell subranges
    ///   additionally carry `.tableHeader = true`. The TK2 content-
    ///   storage delegate picks up the tag and vends a `TableElement`.
    public static func render(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        if FeatureFlag.nativeTableElements {
            return renderNative(
                header: header,
                rows: rows,
                alignments: alignments,
                rawMarkdown: rawMarkdown,
                bodyFont: bodyFont
            )
        }
        return renderAttachment(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: rawMarkdown,
            bodyFont: bodyFont
        )
    }

    // MARK: - Legacy attachment path (flag off, default)

    /// Legacy attachment path. Emits one `U+FFFC` character backed by
    /// a `TableBlockAttachment` holding the parsed cells. Untouched
    /// from pre-2e-T2-b behaviour.
    private static func renderAttachment(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let attachment = TableBlockAttachment(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: rawMarkdown
        )
        // Placeholder bounds — the app target resizes after configuring
        // the InlineTableView cell. Use a reasonable default so the
        // attachment character occupies space.
        attachment.bounds = CGRect(x: 0, y: 0, width: 400, height: 100)

        let result = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: bodyFont, range: range)
        result.addAttribute(.renderedBlockType, value: RenderedBlockType.table.rawValue, range: range)
        result.addAttribute(.renderedBlockOriginalMarkdown, value: rawMarkdown, range: range)
        return result
    }

    // MARK: - Native element path (flag on, 2e-T2-b)

    /// Native-element path. Cells are rendered through the same
    /// `InlineRenderer` paragraphs use; the per-cell attributed
    /// strings are concatenated with U+001F between cells in a row
    /// and U+001E between rows. The result carries
    /// `.blockModelKind = .table` so the TK2 content-storage delegate
    /// (see `BlockModelContentStorageDelegate`) vends a `TableElement`,
    /// which is then routed to `TableLayoutFragment` by the layout-
    /// manager delegate.
    ///
    /// The separator characters themselves are rendered with `bodyFont`
    /// so they contribute zero visual kerning damage if any downstream
    /// path paints them (2e-T2-c's `TableLayoutFragment.draw` suppresses
    /// `super.draw` precisely to keep them invisible). They appear in
    /// `.string` — that is the whole point: `NSTextFinder` can now see
    /// "Alice"/"Bob" across cells.
    ///
    /// Invariant: the emitted storage contains ZERO `U+FFFC` characters.
    /// A test-time grep asserts this.
    #if os(OSX)
    private static func renderNative(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
        let cellSep = NSAttributedString(
            string: TableElement.cellSeparatorString,
            attributes: separatorAttrs
        )
        let rowSep = NSAttributedString(
            string: TableElement.rowSeparatorString,
            attributes: separatorAttrs
        )

        // Header row first.
        appendRow(
            to: result,
            cells: header,
            baseAttrs: baseAttrs,
            cellSeparator: cellSep,
            isHeader: true
        )
        // Header → body boundary. Always emit a U+001E, even if there
        // are zero body rows, so the decode path sees an explicit
        // "header done" marker and downstream cell-locator math can
        // index from a stable offset.
        result.append(rowSep)

        // Body rows, row-separated. No trailing separator after the
        // last body row — the element range ends cleanly on cell text.
        for (rowIdx, row) in rows.enumerated() {
            appendRow(
                to: result,
                cells: row,
                baseAttrs: baseAttrs,
                cellSeparator: cellSep,
                isHeader: false
            )
            if rowIdx < rows.count - 1 {
                result.append(rowSep)
            }
        }

        // Tag the entire range with `.blockModelKind = .table` so the
        // content-storage delegate returns a `TableElement`. Also keep
        // the legacy `.renderedBlockType`/`renderedBlockOriginalMarkdown`
        // tags so any code that already introspects for tables (save
        // path, export path, etc.) keeps working during the transition.
        let fullRange = NSRange(location: 0, length: result.length)
        if fullRange.length > 0 {
            result.addAttribute(.blockModelKind, value: BlockModelKind.table.rawValue, range: fullRange)
            result.addAttribute(.renderedBlockType, value: RenderedBlockType.table.rawValue, range: fullRange)
            result.addAttribute(.renderedBlockOriginalMarkdown, value: rawMarkdown, range: fullRange)
        }

        return result
    }
    #else
    private static func renderNative(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        // iOS currently retains the attachment path. The native-element
        // migration is macOS-first; the iOS build stays on the legacy
        // renderer regardless of the flag.
        return renderAttachment(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: rawMarkdown,
            bodyFont: bodyFont
        )
    }
    #endif

    #if os(OSX)
    /// Append a single table row to `result`: cells are rendered via
    /// `InlineRenderer.render(...)` and joined by `cellSeparator`.
    /// Header cells additionally get `.tableHeader = true` tagged on
    /// their rendered-text range (not on the separator).
    private static func appendRow(
        to result: NSMutableAttributedString,
        cells: [TableCell],
        baseAttrs: [NSAttributedString.Key: Any],
        cellSeparator: NSAttributedString,
        isHeader: Bool
    ) {
        for (cellIdx, cell) in cells.enumerated() {
            let rendered = InlineRenderer.render(
                cell.inline,
                baseAttributes: baseAttrs,
                note: nil,
                theme: .shared
            )
            let start = result.length
            result.append(rendered)
            let cellRange = NSRange(location: start, length: result.length - start)
            if isHeader, cellRange.length > 0 {
                result.addAttribute(.tableHeader, value: true, range: cellRange)
            }
            if cellIdx < cells.count - 1 {
                result.append(cellSeparator)
            }
        }
    }
    #endif
}
