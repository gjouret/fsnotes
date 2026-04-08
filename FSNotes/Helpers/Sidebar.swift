//
//  Sidebar.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 4/7/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
typealias Image = NSImage

class Sidebar {
    private let list: [Any]

    init(storage: Storage = Storage.shared()) {
        self.list = SidebarListBuilder.makeMacSidebarItems(storage: storage)
    }

    public func getList() -> [Any] {
        return list
    }
}

final class SidebarDisplayController {
    unowned let viewController: ViewController

    init(viewController: ViewController) {
        self.viewController = viewController
    }

    func makeSidebarItems() -> [Any] {
        return Sidebar(storage: viewController.storage).getList()
    }

    func restoreSidebar() {
        viewController.sidebarOutlineView.sidebarItems = makeSidebarItems()
        viewController.sidebarOutlineView.reloadData()

        viewController.storage.restoreProjectsExpandState()

        for project in viewController.storage.getProjects() where project.isExpanded {
            viewController.sidebarOutlineView.expandItem(project)
        }
    }

    func configureSidebar() {
        guard isVisible else { return }

        restoreSidebar()

        if let welcome = Storage.shared().welcomeProject {
            select(item: welcome)
            return
        }

        if let lastSidebarItem = UserDefaultsManagement.lastSidebarItem {
            let sidebarItem = viewController.sidebarOutlineView.sidebarItems?.first {
                ($0 as? SidebarItem)?.type.rawValue == lastSidebarItem
            }
            select(item: sidebarItem)
            return
        }

        if let lastURL = UserDefaultsManagement.lastProjectURL,
           let project = viewController.storage.getProjectBy(url: lastURL) {
            select(item: project)
        }
    }

    func toggleVisibility() {
        guard let splitView = viewController.sidebarSplitView,
              let first = splitView.subviews.first else { return }

        if isVisible {
            UserDefaultsManagement.sidebarTableWidth = first.frame.width
            splitView.setPosition(0, ofDividerAt: 0)
        } else {
            splitView.setPosition(UserDefaultsManagement.sidebarTableWidth, ofDividerAt: 0)
            viewController.reloadSideBar()
        }

        viewController.editor?.updateTextContainerInset()
    }

    func checkConstraint() {
        let sidebarWidth = viewController.sidebarSplitView?.subviews.first?.frame.width ?? 0

        if sidebarWidth > 50 {
            viewController.searchTopConstraint.constant = 8
            return
        }

        if UserDefaultsManagement.hideSidebarTable || sidebarWidth < 50 {
            viewController.searchTopConstraint.constant = 25
            return
        }

        viewController.searchTopConstraint.constant = 8
    }

    var isVisible: Bool {
        guard let first = viewController.sidebarSplitView?.subviews.first else { return false }
        return Int(first.frame.width) != 0
    }

    private func select(item: Any?) {
        let row = viewController.sidebarOutlineView.row(forItem: item)
        if row > -1 {
            viewController.sidebarOutlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }
}

extension ViewController {
    public func restoreSidebar() {
        sidebarDisplayController.restoreSidebar()
    }

    public func configureSidebar() {
        sidebarDisplayController.configureSidebar()
    }

    func viewDidResize() {
        checkSidebarConstraint()
    }

    func reloadSideBar() {
        guard let outline = sidebarOutlineView else { return }

        sidebarTimer.invalidate()
        sidebarTimer = Timer.scheduledTimer(timeInterval: 1.2, target: outline, selector: #selector(outline.reloadSidebar), userInfo: nil, repeats: false)
    }

    func checkSidebarConstraint() {
        sidebarDisplayController.checkConstraint()
    }

    public func isVisibleSidebar() -> Bool {
        return sidebarDisplayController.isVisible
    }

    @IBAction func sidebarItemVisibility(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        let isChecked = sender.state == .on

        switch sender.tag {
        case 1:
            UserDefaultsManagement.sidebarVisibilityInbox = isChecked
        case 2:
            UserDefaultsManagement.sidebarVisibilityNotes = isChecked
        case 3:
            UserDefaultsManagement.sidebarVisibilityTodo = isChecked
        case 5:
            UserDefaultsManagement.sidebarVisibilityTrash = isChecked
        case 6:
            UserDefaultsManagement.sidebarVisibilityUntagged = isChecked
        default:
            break
        }

        sidebarOutlineView.reloadSidebar()
    }
}
