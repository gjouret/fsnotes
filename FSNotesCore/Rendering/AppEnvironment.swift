//
//  AppEnvironment.swift
//  FSNotesCore
//
//  Central dependency container. Replaces .shared() singletons with injectable services.
//
//  Migration strategy (incremental):
//  1. AppEnvironment wraps existing singletons initially
//  2. New code receives AppEnvironment at construction
//  3. Old code gradually migrates from .shared() to injected env
//  4. Once all callers use env, .shared() methods are removed
//
//  Usage:
//    let env = AppEnvironment.shared  // transitional — eventually injected
//    let prefs = env.editorPreferences
//

import Foundation

/// Central dependency container for the application.
/// New types receive this at construction instead of calling global singletons.
public final class AppEnvironment {

    /// Transitional singleton — used during migration from .shared() pattern.
    /// Will be replaced with constructor injection as callers migrate.
    public static let shared = AppEnvironment()

    // MARK: - Services

    public let editorPreferences: EditorPreferencesProvider
    public let serializer: NoteSerializer.Type = NoteSerializer.self
    public let noteStore: NoteStore
    public let projectStore: ProjectStore

    // MARK: - Init

    /// Production initializer: uses real services backed by singletons (during migration).
    public init() {
        self.editorPreferences = EditorPreferences()
        self.noteStore = NoteStore()
        self.projectStore = ProjectStore()
    }

    /// Test initializer: inject mock services.
    public init(editorPreferences: EditorPreferencesProvider,
                noteStore: NoteStore = NoteStore(),
                projectStore: ProjectStore = ProjectStore()) {
        self.editorPreferences = editorPreferences
        self.noteStore = noteStore
        self.projectStore = projectStore
    }
}
