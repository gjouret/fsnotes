//
//  UIPreferences.swift
//  FSNotesCore
//
//  Focused façade for UI/appearance preferences.
//

import Foundation
#if os(macOS)
import AppKit
#endif

public struct UIPreferences {
    public init() {}

    public var sidebarTableWidth: CGFloat { UserDefaultsManagement.sidebarTableWidth }
    public var horizontalOrientation: Bool { UserDefaultsManagement.horizontalOrientation }
    public var hidePreviewImages: Bool { UserDefaultsManagement.hidePreviewImages }
    public var hidePreview: Bool { UserDefaultsManagement.hidePreview }
    public var hideSidebar: Bool { UserDefaultsManagement.hideSidebar }
    public var hideSidebarTable: Bool { UserDefaultsManagement.hideSidebarTable }
    public var inlineTags: Bool { UserDefaultsManagement.inlineTags }
}
