//
//  SidebarItem.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 4/7/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

#if os(OSX)
    import Cocoa
#else
    import UIKit
#endif

enum SidebarSystemBuilder {
    /// Build system sidebar items and assign virtual projects on storage.
    /// NOTE: This method intentionally mutates `storage.allNotesProject`,
    /// `.todoProject`, `.untaggedProject` as a side effect — these virtual
    /// projects are created here and must be registered on storage for
    /// filtering to work. Callers should be aware of this mutation.
    static func makeSystemItems(storage: Storage) -> [SidebarItem] {
        guard let defaultProject = storage.getDefault(),
              let defaultURL = defaultProject.url as URL? else { return [] }

        var system = [SidebarItem]()

        if UserDefaultsManagement.sidebarVisibilityNotes {
            let notesLabel = NSLocalizedString("Notes", comment: "Sidebar label")
            let notesProject = makeVirtualProject(
                storage: storage,
                url: defaultURL.appendingPathComponent("Fake Virtual Notes Dir"),
                label: notesLabel
            )
            storage.allNotesProject = notesProject
            system.append(SidebarItem(name: notesLabel, project: notesProject, type: .All))
        }

        if UserDefaultsManagement.sidebarVisibilityInbox {
            system.append(SidebarItem(name: NSLocalizedString("Inbox", comment: "Sidebar label"), project: defaultProject, type: .Inbox))
        }

        if UserDefaultsManagement.sidebarVisibilityTodo {
            let todoLabel = NSLocalizedString("Todo", comment: "Sidebar label")
            let todoProject = makeVirtualProject(
                storage: storage,
                url: defaultURL.appendingPathComponent("Fake Virtual Todo Dir"),
                label: todoLabel
            )
            storage.todoProject = todoProject
            system.append(SidebarItem(name: todoLabel, project: todoProject, type: .Todo))
        }

        if UserDefaultsManagement.sidebarVisibilityUntagged {
            let untaggedLabel = NSLocalizedString("Untagged", comment: "Sidebar label")
            let untaggedProject = makeVirtualProject(
                storage: storage,
                url: defaultURL.appendingPathComponent("Fake Virtual Utagged Dir"),
                label: untaggedLabel
            )
            storage.untaggedProject = untaggedProject
            system.append(SidebarItem(name: untaggedLabel, project: untaggedProject, type: .Untagged))
        }

        if UserDefaultsManagement.sidebarVisibilityTrash {
            system.append(
                SidebarItem(
                    name: NSLocalizedString("Trash", comment: "Sidebar label"),
                    project: storage.getDefaultTrash(),
                    type: .Trash
                )
            )
        }

        return system
    }

    static func makeProjectItems(storage: Storage) -> [SidebarItem] {
        return storage
            .getAvailableProjects()
            .sorted(by: { $0.label < $1.label })
            .map { SidebarItem(name: $0.label, project: $0, type: .Project) }
    }

    private static func makeVirtualProject(storage: Storage, url: URL, label: String) -> Project {
        return Project(storage: storage, url: url, label: label, isVirtual: true)
    }
}

enum SidebarListBuilder {
    static func makeMacSidebarItems(storage: Storage) -> [Any] {
        var items = [Any]()
        let systemItems = SidebarSystemBuilder.makeSystemItems(storage: storage)

        if !systemItems.isEmpty {
            items.append(contentsOf: systemItems)
        }

        items.append(SidebarItem(name: "projects", type: .Separator))
        items.append(contentsOf: storage.getSidebarProjects())
        items.append(SidebarItem(name: "tags", type: .Separator))

        return items
    }

    static func makeIOSidebarSections(storage: Storage) -> [[SidebarItem]] {
        return [
            SidebarSystemBuilder.makeSystemItems(storage: storage),
            SidebarSystemBuilder.makeProjectItems(storage: storage),
            []
        ]
    }
}

class SidebarItem {
    var name: String
    var project: Project?
    var type: SidebarItemType
    public var icon: Image?
    public var tag: FSTag?
    
    init(name: String, project: Project? = nil, type: SidebarItemType, icon: Image? = nil, tag: FSTag? = nil) {
        self.name = name
        self.project = project
        self.type = type
        self.icon = icon
        self.tag = tag

    #if os(iOS)
        if let icon = type.icon {
            self.icon = getIcon(name: icon)
        }

        guard let project = project, type == .Project else { return }

        if project.isEncrypted {
            if project.isLocked() {
                self.type = .ProjectEncryptedLocked
            } else {
                self.type = .ProjectEncryptedUnlocked
            }
        } else {
            self.type = .Project
        }

        if let icon = self.type.icon {
            self.icon = getIcon(name: icon)
        }
    #endif
    }

    public func setType(type: SidebarItemType) {
        self.type = type

        if let icon = self.type.icon {
            self.icon = getIcon(name: icon)
        }
    }

    public func getName() -> String {
        return name
    }
        
    public func isSelectable() -> Bool {
        if type == .Header && project == nil {
            return false
        }

        if type == .Separator {
            return false
        }
        
        return true
    }
    
    public func isTrash() -> Bool {
        return (type == .Trash)
    }
    
    public func isGroupItem() -> Bool {
        let notesLabel = NSLocalizedString("Notes", comment: "Sidebar label")
        let trashLabel = NSLocalizedString("Trash", comment: "Sidebar label")
        if project == nil && [notesLabel, trashLabel].contains(name) {
            return true
        }
        
        return false
    }

    public func isSystem() -> Bool {
        let system: [SidebarItemType] = [.All, .Trash, .Todo, .Untagged, .Inbox]

        return system.contains(type)
    }

    public func load(type: SidebarItemType) {
        self.type = type

        if let icon = type.icon {
            self.icon = getIcon(name: icon)
        }
    }

#if os(OSX)
    public func getIcon(name: String, white: Bool = false) -> NSImage? {
        let image = NSImage(named: name)
        image?.isTemplate = true

        if UserDefaults.standard.value(forKey: "AppleAccentColor") != nil {
            return image?.tint(color: NSColor.controlAccentColor)
        } else if white && !NSAppearance.current.isDark {
            return image?.tint(color: .white)
        } else {
            return image?.tint(color: NSColor(red: 0.08, green: 0.60, blue: 0.85, alpha: 1.00))
        }
    }
#else
    public func getIcon(name: String) -> UIImage? {
        guard let image = UIImage(named: name) else { return nil }

        return image.imageWithColor(color1: UIColor.mainTheme)
    }
#endif
}
