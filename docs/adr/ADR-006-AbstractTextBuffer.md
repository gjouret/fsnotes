# ADR-006: Abstract TextBuffer for Testability

## Status
Proposed

## Context
Current code directly uses `NSTextStorage`, making it:
- Impossible to unit test without AppKit
- Hard to mock for edge cases
- Difficult to reason about in isolation

## Decision
Abstract text storage behind `TextBuffer` protocol.

## Implementation
```swift
protocol TextBuffer {
    var content: String { get }
    func replace(range: StorageRange, with: String)
    func addChangeObserver(...) -> ObserverToken
    // ... etc
}

// Production
final class NSTextStorageBuffer: TextBuffer { }

// Tests
final class InMemoryTextBuffer: TextBuffer { }
```

## Rationale

### Testability
- Unit tests use `InMemoryTextBuffer`
- No AppKit dependencies in core logic
- Fast, deterministic tests

### Flexibility
- Could implement `CloudKitTextBuffer`
- Could add caching layers
- Swap implementations without changing logic

## Consequences
- Protocol overhead
- Need adapter layer
- But: Test coverage can reach core logic

## Related
- `TextBuffer.swift`
- `InMemoryTextBuffer` (test helper)