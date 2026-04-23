//
//  BlockModelElements.swift
//  FSNotesCore
//
//  Phase 2b — TextKit 2 element subclasses per block-model block type.
//
//  These classes are intentionally empty. They exist so the
//  `NSTextContentStorageDelegate` installed on `NSTextContentStorage`
//  can dispatch on the `.blockModelKind` attribute and hand the
//  matching subclass back to the layout manager. The custom
//  `NSTextLayoutFragment` subclasses that land in Phase 2c will route
//  their drawing on the element's concrete class.
//
//  Today every class inherits `NSTextParagraph` without override, so
//  the TK2 layout engine treats them identically to a plain paragraph.
//  This is deliberate — 2b is plumbing, not behaviour.
//

import AppKit

/// Base class for block-model paragraph elements. Subclasses add no
/// behaviour in 2b; 2c will override layout-fragment selection.
public class BlockModelElement: NSTextParagraph {
    public var blockKind: BlockModelKind { .paragraph }
}

public final class ParagraphElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .paragraph }
}

public final class ParagraphWithKbdElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .paragraphWithKbd }
}

public final class HeadingElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .heading }
}

public final class ListItemElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .list }
}

public final class BlockquoteElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .blockquote }
}

public final class CodeBlockElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .codeBlock }
}

public final class HorizontalRuleElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .horizontalRule }
}

public final class MermaidElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .mermaid }
}

public final class MathElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .math }
}

/// Paragraph whose sole inline is `Inline.displayMath`. Dispatched
/// to `DisplayMathLayoutFragment` by the layout-manager delegate, which
/// reads the LaTeX source off `.renderedBlockSource` and renders the
/// centered equation bitmap in place of the source text. Sibling of
/// `MathElement` (fenced ```math``` code blocks) — the two elements
/// share `BlockRenderer.BlockType.math` but differ in source shape
/// (fenced content vs. paragraph-embedded `$$…$$`).
public final class DisplayMathElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .displayMath }
}

/// Phase 2f.1 — paragraph element whose backing content is folded by a
/// header collapse. The content-storage delegate returns this whenever
/// the paragraph range carries `.foldedContent`, regardless of the
/// block-model kind underneath. The layout-manager delegate dispatches
/// it to `FoldedLayoutFragment`, a zero-height no-op fragment.
///
/// `blockKind` is reported as `.paragraph` for fall-through safety — no
/// production code should key visuals off a folded element's kind
/// (there's nothing to draw).
public final class FoldedElement: BlockModelElement {
    public override var blockKind: BlockModelKind { .paragraph }
}

/// Maps a `BlockModelKind` to the matching `BlockModelElement`
/// subclass. Called by the content-storage delegate with the
/// attributed string for the paragraph range; returns an initialised
/// element pointing at the same storage.
public enum BlockModelElementFactory {
    public static func element(
        for kind: BlockModelKind,
        attributedString: NSAttributedString
    ) -> BlockModelElement {
        switch kind {
        case .paragraph: return ParagraphElement(attributedString: attributedString)
        case .paragraphWithKbd: return ParagraphWithKbdElement(attributedString: attributedString)
        case .heading: return HeadingElement(attributedString: attributedString)
        case .list: return ListItemElement(attributedString: attributedString)
        case .blockquote: return BlockquoteElement(attributedString: attributedString)
        case .codeBlock: return CodeBlockElement(attributedString: attributedString)
        case .horizontalRule: return HorizontalRuleElement(attributedString: attributedString)
        case .mermaid: return MermaidElement(attributedString: attributedString)
        case .math: return MathElement(attributedString: attributedString)
        case .displayMath: return DisplayMathElement(attributedString: attributedString)
        }
    }
}

/// Phase 2b — `NSTextContentStorageDelegate` that reads the
/// `.blockModelKind` attribute tagged by `DocumentRenderer` and returns
/// the matching `BlockModelElement` subclass for each paragraph. The
/// layout manager receives the subclass via the content-storage
/// substitution hook; Phase 2c will override layout-fragment selection
/// on the subclass to take over block visuals.
///
/// If the paragraph carries no `.blockModelKind` attribute (tables still
/// flow through attachments; untagged ranges during edit reconciliation)
/// the delegate returns `nil` so `NSTextContentStorage` falls back to
/// its default `NSTextParagraph`. This keeps TK2 happy during the edit
/// windows when storage is mid-splice.
public final class BlockModelContentStorageDelegate: NSObject, NSTextContentStorageDelegate {
    public override init() {
        super.init()
    }

    public func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage else { return nil }
        // Clamp: paragraph ranges the content storage hands us are
        // always valid, but the call can race with an in-flight splice
        // where length has shrunk. Defensive clamp keeps us off the
        // out-of-bounds path.
        let storageLength = storage.length
        guard range.location >= 0, range.location < storageLength else {
            return nil
        }
        let clampedLength = min(range.length, storageLength - range.location)
        guard clampedLength > 0 else { return nil }
        let clamped = NSRange(location: range.location, length: clampedLength)

        // Phase 2f.1 — if any character in this paragraph carries
        // `.foldedContent`, route to `FoldedElement` so the layout
        // manager delegate can dispatch to `FoldedLayoutFragment`
        // (zero-height, no-op draw). We check the paragraph's full
        // range rather than just the leading character because fold
        // toggles apply to a range that may or may not include the
        // paragraph terminator.
        var folded = false
        storage.enumerateAttribute(
            .foldedContent, in: clamped, options: []
        ) { value, _, stop in
            if value != nil {
                folded = true
                stop.pointee = true
            }
        }
        if folded {
            let substring = storage.attributedSubstring(from: clamped)
            return FoldedElement(attributedString: substring)
        }

        let rawKind = storage.attribute(
            .blockModelKind,
            at: clamped.location,
            effectiveRange: nil
        ) as? String
        guard let raw = rawKind, let kind = BlockModelKind(rawValue: raw) else {
            return nil
        }

        let substring = storage.attributedSubstring(from: clamped)
        return BlockModelElementFactory.element(
            for: kind,
            attributedString: substring
        )
    }
}
