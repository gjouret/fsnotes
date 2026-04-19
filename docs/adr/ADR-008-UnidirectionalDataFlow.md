# ADR-008: Unidirectional Data Flow Architecture

## Status
Proposed

## Context
Current architecture has bidirectional flow:
- User types → View updates → Model updates → View updates
- Circular dependencies between ViewController and EditTextView
- Hard to trace state changes

## Decision
Implement unidirectional flow: Action → Store → Reducer → State → View

## Implementation
```swift
final class EditorStore: ObservableObject {
    @Published private(set) var state: EditorState
    
    func dispatch(_ action: EditorAction) {
        let result = reducer.reduce(state: state, action: action)
        state = result.newState
        result.effects.forEach { handle($0) }
    }
}

enum EditorAction {
    case insert(String, at: GlobalStorageIndex)
    case delete(range: StorageRange)
    // ... etc
}
```

## Rationale

### Predictability
- Single source of truth (Store)
- State changes only through actions
- Time-travel debugging possible

### Testability
- Reducers are pure functions
- Test: (State, Action) → (State, Effects)
- No UI dependencies

## Consequences
- Learning curve for new developers
- More boilerplate for simple actions
- But: Predictable, debuggable, testable

## Related
- `EditorStore.swift`
- `EditorAction`
- `EditorReducer`