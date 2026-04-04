//
//  NSAttributedString+.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 03.05.2020.
//  Copyright © 2020 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

extension NSAttributedString {
    public func hasTodoAttribute() -> Bool {
        let string = self.string.lowercased()
        return string.contains("- [ ] ")
            || string.contains("- [x] ")
            || string.contains("* [ ] ")
            || string.contains("* [x] ")
            || string.contains("+ [ ] ")
            || string.contains("+ [x] ")
    }
}
