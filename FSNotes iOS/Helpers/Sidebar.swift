//
//  Sideabr.swift
//  FSNotes iOS
//
//  Created by Олександр Глущенко on 02.11.2019.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import UIKit
typealias Image = UIImage

enum SidebarSection: Int {
    case System   = 0x00
    case Projects = 0x01
    case Tags     = 0x02
    case Settings = 0x03
}

class Sidebar {
    let storage = Storage.shared()
    public var items = [[SidebarItem]]()
    public var allItems = [[SidebarItem]]()

    init() {
        items = SidebarListBuilder.makeIOSidebarSections(storage: storage)
        allItems = items
    }
}
