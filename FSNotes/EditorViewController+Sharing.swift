//
//  EditorViewController+Sharing.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 03.07.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa
import ObjectiveC

extension EditorViewController: NSSharingServicePickerDelegate {
    func exportAttributedContent(for note: Note) -> NSAttributedString {
        if let editor = vcEditor, editor.note === note {
            return editor.attributedStringForSaving()
        }

        return NSAttributedString(attributedString: note.content)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        var share = proposedServices

        if #available(macOS 11.0, *) {
            guard let image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: nil),
                  let webImage = NSImage(named: "web") else {

                return proposedServices
            }

            let titleWeb = NSLocalizedString("Web", comment: "")
            let web = NSSharingService(title: titleWeb, image: webImage, alternateImage: nil, handler: {
                ViewController.shared()?.uploadWebNote(NSMenuItem())
            })
            share.insert(web, at: 0)

            let titlePlain = NSLocalizedString("Copy Plain Text", comment: "")
            let plainText = NSSharingService(title: titlePlain, image: image, alternateImage: image, handler: {
                self.saveTextAtClipboard()
            })
            share.insert(plainText, at: 1)

            let titleHTML = NSLocalizedString("Copy HTML", comment: "")
            let html = NSSharingService(title: titleHTML, image: image, alternateImage: image, handler: {
                self.saveHtmlAtClipboard()
            })
            share.insert(html, at: 2)

            // Share as PDF
            let pdfImage = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil) ?? image
            let titlePDF = NSLocalizedString("Share as PDF", comment: "")
            let sharePDF = NSSharingService(title: titlePDF, image: pdfImage, alternateImage: nil, handler: {
                self.shareAsPDF()
            })
            share.insert(sharePDF, at: 3)

            // Share note file (TextBundle or markdown file)
            let fileImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? image
            let titleFile = NSLocalizedString("Share Note File", comment: "")
            let shareFile = NSSharingService(title: titleFile, image: fileImage, alternateImage: nil, handler: {
                self.shareNoteFile()
            })
            share.insert(shareFile, at: 4)
        }

        return share
    }

    //MARK: Share Service

    public func saveTextAtClipboard() {
        if let note = vcEditor?.note {
            let unloadedText = NoteSerializer.prepareForSave(
                NSMutableAttributedString(attributedString: exportAttributedContent(for: note))
            )
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
            pasteboard.setString(unloadedText.string, forType: NSPasteboard.PasteboardType.string)
        }
    }

    public func saveHtmlAtClipboard() {
        if let note = vcEditor?.note {
            if let render = WebNotePublisher.renderHTML(
                title: note.title,
                content: exportAttributedContent(for: note)
            ) {
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
                pasteboard.setString(render, forType: NSPasteboard.PasteboardType.string)
            }
        }
    }

    public func shareAsPDF() {
        guard let note = vcEditor?.note,
              let textView = vcEditor else { return }

        let safeName = note.title.replacingOccurrences(of: "/", with: "-")
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(safeName).pdf")

        guard let pdfURL = PDFExporter.export(textView: textView, to: outputURL) else { return }

        let picker = NSSharingServicePicker(items: [pdfURL])
        if let button = findShareButton() {
            picker.show(relativeTo: NSZeroRect, of: button, preferredEdge: .minY)
        }
    }

    public func shareNoteFile() {
        guard let note = vcEditor?.note else { return }
        let noteURL = note.url

        let picker = NSSharingServicePicker(items: [noteURL])
        if let button = findShareButton() {
            picker.show(relativeTo: NSZeroRect, of: button, preferredEdge: .minY)
        }
    }

    private func findShareButton() -> NSButton? {
        if let vc = self as? NoteViewController {
            return vc.shareButton
        }
        return ViewController.shared()?.shareButton
    }
}
