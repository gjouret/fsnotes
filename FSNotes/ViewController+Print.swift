//
//  ViewController+Print.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 2/15/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import AppKit

extension EditorViewController {

    public func printMarkdownPreview() {
        guard let editor = vcEditor else { return }

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let printOp = NSPrintOperation(view: editor, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }
}
