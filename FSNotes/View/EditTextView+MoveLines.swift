//
//  EditTextView+MoveLines.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 15.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

extension EditTextView {
    func moveSelectedLinesUp() {
        // Block-model path: swap blocks in the document model.
        if let proj = documentProjection {
            let cursorLoc = selectedRange().location
            guard let info = proj.blockContaining(storageIndex: cursorLoc) else {
                NSSound.beep()
                return
            }
            // Inside a list? Try item-level sibling swap first; fall back
            // to block swap only if we're on the first sibling at every
            // depth (handled inside moveListItemOrBlockUp).
            let isList: Bool = {
                if case .list = proj.document.blocks[info.blockIndex] { return true }
                return false
            }()
            if !isList, info.blockIndex == 0 {
                NSSound.beep()
                return
            }
            let blockIdx = info.blockIndex
            do {
                let result: EditResult
                if isList {
                    result = try EditingOps.moveListItemOrBlockUp(at: cursorLoc, in: proj)
                } else {
                    result = try EditingOps.moveBlockUp(blockIndex: blockIdx, in: proj)
                }
                // Preserve offset within the block so the cursor stays on
                // the moved line (which now lives in the same block for
                // sibling swaps, or at blockIdx-1 for block-level moves).
                let oldSpan = proj.blockSpans[blockIdx]
                let offsetInBlock = cursorLoc - oldSpan.location
                let destBlockIdx = isList ? blockIdx : blockIdx - 1
                let newSpan = result.newProjection.blockSpans[destBlockIdx]
                let newCursor: Int
                if isList {
                    // For sibling swaps inside a list, the cursor's
                    // offset-in-block shifts; we can't reuse the old
                    // offset. Place it at the start of the item that
                    // moved — by re-finding the item path. As a simple
                    // approximation, clamp to the block's new length.
                    newCursor = min(cursorLoc, newSpan.location + newSpan.length)
                } else {
                    newCursor = newSpan.location + min(offsetInBlock, newSpan.length)
                }
                applyBlockModelResult(result, actionName: "Move")
                setSelectedRange(NSRange(location: newCursor, length: 0))
                scrollRangeToVisible(selectedRange())
            } catch {
                NSSound.beep()
            }
            return
        }

        // Source-mode fallback.
        guard let textStorage = textStorage,
              textStorage.length > 0 else { return }

        let selectedRange = selectedRange()

        let lineRange = textStorage.mutableString.lineRange(for: selectedRange)
        if lineRange.location == 0 {
            NSSound.beep()
            return
        }

        let previousLineStart = textStorage.mutableString.lineRange(
            for: NSRange(location: lineRange.location - 1, length: 0)
        ).location

        let previousLineRange = NSRange(
            location: previousLineStart,
            length: lineRange.location - previousLineStart
        )

        let currentLinesAttr = textStorage.attributedSubstring(from: lineRange)
        let previousLineAttr = textStorage.attributedSubstring(from: previousLineRange)

        let offsetInLine = selectedRange.location - lineRange.location

        let currentLinesString = currentLinesAttr.string
        let needsNewline = !currentLinesString.hasSuffix("\n")

        let newContent = NSMutableAttributedString()
        newContent.append(currentLinesAttr)

        if needsNewline {
            let attrs = currentLinesAttr.length > 0
                ? currentLinesAttr.attributes(at: currentLinesAttr.length - 1, effectiveRange: nil)
                : [:]
            newContent.append(NSAttributedString(string: "\n", attributes: attrs))
        }

        var previousToAppend = previousLineAttr
        if needsNewline && previousLineAttr.string.hasSuffix("\n") {
            let trimmedPrevious = NSMutableAttributedString(attributedString: previousLineAttr)
            trimmedPrevious.deleteCharacters(in: NSRange(location: trimmedPrevious.length - 1, length: 1))
            previousToAppend = trimmedPrevious
        }

        newContent.append(previousToAppend)

        let combinedRange = NSRange(
            location: previousLineRange.location,
            length: previousLineRange.length + lineRange.length
        )

        newContent.saveData()
        if shouldChangeText(in: combinedRange, replacementString: newContent.string) {
            insertText(newContent, replacementRange: combinedRange)
            didChangeText()
        }

        let newSelectionLocation = previousLineRange.location + offsetInLine

        setSelectedRange(NSRange(
            location: newSelectionLocation,
            length: selectedRange.length
        ))

        scrollRangeToVisible(self.selectedRange())
    }

    func moveSelectedLinesDown() {
        // Block-model path: swap blocks in the document model.
        if let proj = documentProjection {
            let cursorLoc = selectedRange().location
            guard let info = proj.blockContaining(storageIndex: cursorLoc) else {
                NSSound.beep()
                return
            }
            let isList: Bool = {
                if case .list = proj.document.blocks[info.blockIndex] { return true }
                return false
            }()
            if !isList, info.blockIndex >= proj.document.blocks.count - 1 {
                NSSound.beep()
                return
            }
            let blockIdx = info.blockIndex
            do {
                let result: EditResult
                if isList {
                    result = try EditingOps.moveListItemOrBlockDown(at: cursorLoc, in: proj)
                } else {
                    result = try EditingOps.moveBlockDown(blockIndex: blockIdx, in: proj)
                }
                let oldSpan = proj.blockSpans[blockIdx]
                let offsetInBlock = cursorLoc - oldSpan.location
                let destBlockIdx = isList ? blockIdx : blockIdx + 1
                let newSpan = result.newProjection.blockSpans[destBlockIdx]
                let newCursor: Int
                if isList {
                    newCursor = min(cursorLoc + 1, newSpan.location + newSpan.length)
                } else {
                    newCursor = newSpan.location + min(offsetInBlock, newSpan.length)
                }
                applyBlockModelResult(result, actionName: "Move")
                setSelectedRange(NSRange(location: newCursor, length: 0))
                scrollRangeToVisible(selectedRange())
            } catch {
                NSSound.beep()
            }
            return
        }

        // Source-mode fallback.
        guard let textStorage = textStorage,
              textStorage.length > 0 else { return }

        let selectedRange = selectedRange()
        let lineRange = textStorage.mutableString.lineRange(for: selectedRange)

        if NSMaxRange(lineRange) >= textStorage.length {
            NSSound.beep()
            return
        }

        let nextLineRange = textStorage.mutableString.lineRange(
            for: NSRange(location: NSMaxRange(lineRange), length: 0)
        )

        let currentLinesAttr = textStorage.attributedSubstring(from: lineRange)
        let nextLineAttr = textStorage.attributedSubstring(from: nextLineRange)

        let offsetInLine = selectedRange.location - lineRange.location

        let nextLineString = nextLineAttr.string
        let needsNewline = !nextLineString.hasSuffix("\n")

        let newContent = NSMutableAttributedString()
        var nextLineFinalLength = nextLineAttr.length

        newContent.append(nextLineAttr)

        if needsNewline {
            let attrs = nextLineAttr.length > 0
                ? nextLineAttr.attributes(at: nextLineAttr.length - 1, effectiveRange: nil)
                : [:]
            newContent.append(NSAttributedString(string: "\n", attributes: attrs))
            nextLineFinalLength += 1
        }

        var currentToAppend = currentLinesAttr
        if needsNewline && currentLinesAttr.string.hasSuffix("\n") {
            let trimmedCurrent = NSMutableAttributedString(attributedString: currentLinesAttr)
            trimmedCurrent.deleteCharacters(in: NSRange(location: trimmedCurrent.length - 1, length: 1))
            currentToAppend = trimmedCurrent
        }

        newContent.append(currentToAppend)

        let combinedRange = NSRange(
            location: lineRange.location,
            length: lineRange.length + nextLineRange.length
        )

        newContent.saveData()
        if shouldChangeText(in: combinedRange, replacementString: newContent.string) {
            textStorage.replaceCharacters(in: combinedRange, with: newContent)
            didChangeText()
        }

        let newSelectionLocation = lineRange.location + nextLineFinalLength + offsetInLine

        setSelectedRange(NSRange(
            location: newSelectionLocation,
            length: selectedRange.length
        ))

        scrollRangeToVisible(self.selectedRange())
    }
}
