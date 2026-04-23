//
//  AppEnvironment.swift
//  FSNotesCore
//
//  Central dependency container for editor preferences and storage-facing services.
//

import Foundation

/// Central dependency container for the application.
public final class AppEnvironment {

    public static let shared = AppEnvironment()

    // MARK: - Services

    public let editorPreferences: EditorPreferencesProvider
    // Phase 4.7: `serializer: NoteSerializer.Type` removed with the
    // deletion of `NoteSerializer`. No call sites referenced it.
    public let noteStore: NoteStore
    public let projectStore: ProjectStore

    // MARK: - Init

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
