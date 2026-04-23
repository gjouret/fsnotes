//
//  BlockModelLayoutManagerDelegate.swift
//  FSNotesCore
//
//  Phase 2c — NSTextLayoutManagerDelegate that maps block-model element
//  subclasses (from Phase 2b) onto custom NSTextLayoutFragment
//  subclasses. Installed on `EditTextView.textLayoutManager` at migrate
//  time so every paragraph-tagged element gets its block-kind-specific
//  fragment.
//
//  Dispatch is by element class, not by the `.blockModelKind` attribute
//  on the backing storage. Phase 2b's content-storage delegate is
//  responsible for producing the right element subclass; this delegate
//  trusts the class it receives.
//
//  When no custom fragment is needed (paragraph, heading — text-flow
//  elements that render correctly via the default NSTextLayoutFragment)
//  the delegate returns `nil` to fall back to the default behaviour.
//

import AppKit

public final class BlockModelLayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {

    public override init() {
        super.init()
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        // Phase 2f.1 — folded content comes first. A `FoldedElement`
        // wins over every block-type dispatch below: regardless of
        // whether the paragraph's unfolded kind is paragraph, list,
        // heading, or code block, once it's tagged as folded the TK2
        // analogue of TK1's glyph-draw skip is a zero-height no-op
        // fragment. Keeps every block type foldable with one dispatch.
        if textElement is FoldedElement {
            return FoldedLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Horizontal rule: custom fragment draws the 4pt gray bar.
        if textElement is HorizontalRuleElement {
            return HorizontalRuleLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Blockquote: custom fragment draws the depth-stacked gray bars
        // on the left of the paragraph. Paragraph text still renders via
        // the default path (the fragment calls super.draw).
        if textElement is BlockquoteElement {
            return BlockquoteLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Heading: custom fragment draws the 0.5pt hairline below H1/H2
        // after the text renders. H3-H6 return the same fragment type but
        // skip the draw — the fragment reads `.headingLevel` off the
        // backing string at draw time and short-circuits for level > 2.
        if textElement is HeadingElement {
            return HeadingLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Mermaid: custom fragment renders the diagram widget in place of
        // the code-block text. Dispatched on the element subclass emitted
        // by the content-storage delegate for fenced mermaid blocks.
        if textElement is MermaidElement {
            return MermaidLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Math: custom fragment renders the TeX/MathJax widget in place of
        // the code-block text. Dispatched on the element subclass emitted
        // by the content-storage delegate for fenced math blocks.
        if textElement is MathElement {
            return MathLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Display math: paragraph whose sole inline is `$$…$$`. Renders
        // as a centered pseudo-block equation, identical machinery to
        // `MathLayoutFragment` but dispatched for the inline-wrapping
        // paragraph shape instead of a fenced code block.
        if textElement is DisplayMathElement {
            return DisplayMathLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Native-cell-text table element: dispatch to `TableLayoutFragment`
        // for grid rendering.
        if textElement is TableElement {
            return TableLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Paragraph containing kbd tags: custom fragment draws a
        // rounded "keyboard key" box behind each `.kbdTag` run, then
        // delegates to super for the text. All other paragraphs fall
        // through to the default NSTextLayoutFragment (the common case
        // — zero dispatch overhead for 99%+ of paragraphs).
        if textElement is ParagraphWithKbdElement {
            return KbdBoxParagraphLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Code block: custom fragment draws the gray rounded-rect
        // background + 1pt lightGray border behind the code text,
        // matching the TK1 `LayoutManager.drawCodeBlockBackground`
        // visual. Text renders via super.draw on top of the fill.
        // Mermaid/math code blocks are handled by their own fragments
        // above — by this point `CodeBlockElement` only ever represents
        // a plain/generic fenced code block.
        if textElement is CodeBlockElement {
            return CodeBlockLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
        }

        // Other block types (paragraph, list item) currently render via
        // the default fragment. List-item bullets / checkboxes are baked
        // into storage as NSTextAttachments so they draw via the
        // attachment cell. A fragment-level list-marker draw is a
        // follow-up 2d sub-slice.
        return NSTextLayoutFragment(
            textElement: textElement,
            range: textElement.elementRange
        )
    }
}
