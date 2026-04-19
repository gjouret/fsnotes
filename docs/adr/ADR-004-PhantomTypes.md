# ADR-004: Phantom Types for Storage Index Safety

## Status
Proposed

## Context
Storage indices are frequently confused:
- Global indices (entire document)
- Block-local indices (within a block)
- Inline offsets (within inline content)

These are all `Int` values, leading to bugs when mixing them.

## Decision
Use phantom types to distinguish index contexts at compile time.

## Implementation
```swift
struct StorageIndex<Context> {
    let value: Int
}

enum StorageContext {
    enum Global {}
    enum BlockLocal {}
    enum InlineLocal {}
}

typealias GlobalStorageIndex = StorageIndex<StorageContext.Global>
typealias BlockStorageIndex = StorageIndex<StorageContext.BlockLocal>
```

## Rationale

### Type Safety
- `GlobalStorageIndex` + `BlockStorageIndex` = Compile error
- Explicit conversion functions required
- Context shifts are visible in code

### Self-Documenting
- `insert(at: BlockStorageIndex)` is clear
- No ambiguity about what offset means

## Consequences
- More verbose type signatures
- Need `.value` to extract raw Int
- But: Catches offset bugs at compile time

## Migration Path
- Gradual adoption alongside existing Int-based APIs
- Conversion functions for interop
- Eventually deprecate raw Int offsets