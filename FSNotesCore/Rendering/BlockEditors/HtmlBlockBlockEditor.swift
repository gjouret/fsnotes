//
//  HtmlBlockBlockEditor.swift
//  FSNotesCore
//
//  Phase 12.B.3 — Per-block-kind dispatch (htmlBlock kind).
//
//  HTML blocks are pure raw-content splices: render offset == raw
//  content offset (the renderer emits the raw content verbatim).
//

import Foundation

#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// In-block editor for the `.htmlBlock(raw:)` block kind.
public enum HtmlBlockBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .htmlBlock(let raw) = block else {
            throw EditingError.unsupported(reason: "HtmlBlockBlockEditor.insert called with non-htmlBlock block")
        }
        let newRaw = EditingOps.spliceString(raw, at: offsetInBlock, replacing: 0, with: string)
        return .htmlBlock(raw: newRaw)
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .htmlBlock(let raw) = block else {
            throw EditingError.unsupported(reason: "HtmlBlockBlockEditor.delete called with non-htmlBlock block")
        }
        let length = toOffset - fromOffset
        let newRaw = EditingOps.spliceString(raw, at: fromOffset, replacing: length, with: "")
        return .htmlBlock(raw: newRaw)
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .htmlBlock(let raw) = block else {
            throw EditingError.unsupported(reason: "HtmlBlockBlockEditor.replace called with non-htmlBlock block")
        }
        let length = toOffset - fromOffset
        let newRaw = EditingOps.spliceString(raw, at: fromOffset, replacing: length, with: replacement)
        return .htmlBlock(raw: newRaw)
    }
}
