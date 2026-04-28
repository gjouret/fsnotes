//
//  CodeBlockBlockEditor.swift
//  FSNotesCore
//
//  Phase 12.B.3 — Per-block-kind dispatch (codeBlock kind).
//
//  Code blocks have the simplest editing semantics: render offset
//  equals content offset (no fence characters in the rendered output).
//  Insert/replace also runs `maybePromoteDiagramLanguage` so a user
//  who types a known diagram-language identifier on its own line at
//  the top of a no-language code block gets the block upgraded to
//  the matching renderer (Bug #41 — block-model WYSIWYG mode hides
//  the fences from storage, so this is the only way to upgrade an
//  untagged code block to mermaid/math via keystrokes alone).
//

import Foundation

#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// In-block editor for the `.codeBlock(language:, content:, fence:)` block kind.
public enum CodeBlockBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .codeBlock(let language, let content, let fence) = block else {
            throw EditingError.unsupported(reason: "CodeBlockBlockEditor.insert called with non-codeBlock block")
        }
        let newContent = EditingOps.spliceString(
            content, at: offsetInBlock, replacing: 0, with: string
        )
        let spliced = Block.codeBlock(language: language, content: newContent, fence: fence)
        return EditingOps.maybePromoteDiagramLanguage(spliced)
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .codeBlock(let language, let content, let fence) = block else {
            throw EditingError.unsupported(reason: "CodeBlockBlockEditor.delete called with non-codeBlock block")
        }
        let length = toOffset - fromOffset
        let newContent = EditingOps.spliceString(
            content, at: fromOffset, replacing: length, with: ""
        )
        return .codeBlock(language: language, content: newContent, fence: fence)
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .codeBlock(let language, let content, let fence) = block else {
            throw EditingError.unsupported(reason: "CodeBlockBlockEditor.replace called with non-codeBlock block")
        }
        let length = toOffset - fromOffset
        let newContent = EditingOps.spliceString(
            content, at: fromOffset, replacing: length, with: replacement
        )
        let spliced = Block.codeBlock(language: language, content: newContent, fence: fence)
        return EditingOps.maybePromoteDiagramLanguage(spliced)
    }
}
