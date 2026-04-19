# ADR-009: Centralized Effect System

## Status
Proposed

## Context
Side effects (file I/O, notifications, rendering) are scattered:
- View controllers directly call file APIs
- Rendering happens inline with editing
- Hard to coordinate and debounce

## Decision
Centralize all side effects in `EffectHandler`.

## Implementation
```swift
enum EditorEffect {
    case requestRender
    case requestSave
    case showToast(String)
    case debounced(EditorEffect, milliseconds: Int)
}

final class EffectHandler {
    func handle(_ effect: EditorEffect, store: EditorStore) {
        // Execute with proper queue/scheduler
    }
}
```

## Rationale

### Centralization
- All side effects in one place
- Easy to add logging/telemetry
- Consistent error handling

### Composability
- Effects can emit other effects
- Debouncing/throttling built-in
- Async coordination

## Consequences
- Indirection for simple operations
- EffectHandler can become large
- But: Controlled, testable side effects

## Related
- `EffectSystem.swift`
- `EditorEffect`