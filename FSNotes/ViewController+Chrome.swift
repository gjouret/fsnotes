//
//  ViewController+Chrome.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Cocoa

extension ViewController {
    func configureTitleLabel() {
        let clickGesture = NSClickGestureRecognizer()
        clickGesture.target = self
        clickGesture.numberOfClicksRequired = 2
        clickGesture.buttonMask = 0x1
        clickGesture.action = #selector(switchTitleToEditMode)

        titleLabel.addGestureRecognizer(clickGesture)
    }

    func configureTitleBarAdditionalView() {
        let layer = CALayer()
        layer.frame = titleBarAdditionalView.bounds
        layer.backgroundColor = .clear
        titleBarAdditionalView.wantsLayer = true
        titleBarAdditionalView.layer = layer
        titleBarAdditionalView.alphaValue = 0
    }

    func configureTitleBarView() {
        titleBarView.onMouseExitedClosure = { [weak self] in
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.35
                    self?.titleBarAdditionalView.alphaValue = 0
                    self?.titleLabel.backgroundColor = .clear
                }, completionHandler: nil)
            }
        }

        titleBarView.onMouseEnteredClosure = { [weak self] in
            DispatchQueue.main.async {
                guard self?.titleLabel.isEnabled == false || self?.titleLabel.isEditable == false else { return }

                if let note = self?.editor.note {
                    if note.isEncryptedAndLocked() {
                        self?.lockUnlock.image = NSImage(named: NSImage.lockLockedTemplateName)
                    } else {
                        self?.lockUnlock.image = NSImage(named: NSImage.lockUnlockedTemplateName)
                    }
                }

                self?.lockUnlock.isHidden = (self?.editor.note == nil)

                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.35
                    self?.titleBarAdditionalView.alphaValue = 1
                }, completionHandler: nil)
            }
        }
    }
}
