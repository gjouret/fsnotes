# ADR-005: Typed Error Handling Strategy

## Status
Proposed

## Context
Current error handling uses `EditingError` with string reasons:
- Hard to programmatically handle specific errors
- Inconsistent error contexts
- Recovery suggestions not structured

## Decision
Use comprehensive typed errors with structured context.

## Implementation
```swift
enum EditorError {
    case outOfBounds(StorageBoundsError)
    case crossBlockViolation(CrossBlockError)
    case modelDesync(DesyncError)
    // ... etc
}

struct StorageBoundsError {
    let index: StorageIndex
    let validRange: StorageRange
    let operation: String
}
```

## Rationale

### Rich Context
- Every error carries complete context
- Structured data for telemetry
- Specific recovery strategies per error type

### Pattern Matching
```swift
case .outOfBounds(let error):
    showToast("Invalid position \(error.index)")
case .crossBlockViolation:
    // Handle cross-block case
```

## Consequences
- More verbose error definitions
- Larger error types
- But: Better debugging and recovery

## Related
- `EditorError.swift`
- `EditorResult<T>` type alias