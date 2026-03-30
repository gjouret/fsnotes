//
//  EditorPreferences.swift
//  FSNotesCore
//
//  Focused façade for editor-related preferences. Reads from UserDefaultsManagement
//  but provides a clean, testable, single-responsibility interface.
//
//  New code should use EditorPreferences instead of UserDefaultsManagement directly.
//  Over time, callers migrate and the static properties in UserDefaultsManagement
//  get deprecated.
//
//  This is injectable (protocol-based) for testing: create a mock that doesn't
//  touch UserDefaults.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Read-only interface for editor preferences. Testable via mock implementation.
public protocol EditorPreferencesProvider {
    var fontSize: CGFloat { get }
    var noteFont: PlatformFont { get }
    var codeFont: PlatformFont { get }
    var lineWidth: CGFloat { get }
    var marginSize: CGFloat { get }
    var editorLineSpacing: CGFloat { get }
    var imagesWidth: CGFloat { get }
    var codeBlockHighlight: Bool { get }
    var searchHighlight: Bool { get }
    var wysiwygMode: Bool { get }
    var boldMarker: String { get }
    var italicMarker: String { get }
}

/// Production implementation: reads from UserDefaultsManagement.
public struct EditorPreferences: EditorPreferencesProvider {
    public init() {}

    public var fontSize: CGFloat { CGFloat(UserDefaultsManagement.fontSize) }
    public var noteFont: PlatformFont { UserDefaultsManagement.noteFont }
    public var codeFont: PlatformFont { UserDefaultsManagement.codeFont }
    public var lineWidth: CGFloat { CGFloat(UserDefaultsManagement.lineWidth) }
    public var marginSize: CGFloat { CGFloat(UserDefaultsManagement.marginSize) }
    public var editorLineSpacing: CGFloat { CGFloat(UserDefaultsManagement.editorLineSpacing) }
    public var imagesWidth: CGFloat { CGFloat(UserDefaultsManagement.imagesWidth) }
    public var codeBlockHighlight: Bool { UserDefaultsManagement.codeBlockHighlight }
    public var searchHighlight: Bool { UserDefaultsManagement.searchHighlight }
    public var wysiwygMode: Bool { UserDefaultsManagement.wysiwygMode }
    public var boldMarker: String { UserDefaultsManagement.bold }
    public var italicMarker: String { UserDefaultsManagement.italic }
}
