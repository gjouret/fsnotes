# ADR-010: Transaction Boundaries

## Status
Proposed

## Context
Batch operations (find/replace all, paste) mutate state incrementally:
- Each step creates undo entry
- Partial failures leave document in broken state
- No way to cancel in-flight operations

## Decision
Implement explicit transactions with savepoints and rollback.

## Implementation
```swift
let tx = try store.beginTransaction(name: "Find/Replace")
for match in matches {
    try store.dispatch(.replace(...))
    if shouldCancel { try store.rollback(tx) }
}
try store.commit(tx)
```

## Rationale

### Atomicity
- All-or-nothing operations
- Consistent state even on failure
- Nested transactions supported

### Undo/Redo
- Single undo entry for transaction
- Not per-operation
- Better user experience

## Consequences
- Transaction management overhead
- Potential for long-lived transactions
- But: Data integrity guaranteed

## Related
- `TransactionSystem.swift`
- `TransactionManager`