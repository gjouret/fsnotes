# ADR-007: Protocol-Oriented Block Editing

## Status
Proposed

## Context
Current block editing uses massive switch statements on `Block` enum:
- Adding a block type requires editing multiple files
- No compiler enforcement of capabilities
- Hard to add custom block types

## Decision
Make blocks protocol-oriented with capability discovery.

## Implementation
```swift
protocol EditableBlock {
    static var capabilities: BlockCapabilities { get }
    var markdown: String { get }
}

protocol InsertableBlock: EditableBlock {
    func insert(_ text: String, at: BlockStorageIndex) -> EditorResult<Self>
}

// Each block type conforms to relevant protocols
struct ParagraphBlock: InsertableBlock, DeletableBlock, 
                         SplittableBlock, MergeableBlock { }
```

## Rationale

### Extensibility
- New block types just conform to protocols
- No central switch statement to modify
- Plugins can add custom blocks

### Type Safety
- `InsertableBlock` guarantees insert capability
- Compiler checks, not runtime assertions
- Generic algorithms over capabilities

## Consequences
- More types to manage
- Protocol witness tables
- But: Extensible and type-safe

## Related
- `EditableBlock.swift`
- `BlockRegistry`