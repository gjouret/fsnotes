# ADR-001: Block Spans Instead of NSTextStorage for Model

## Status
Accepted

## Context
The editor needs to track which parts of the text correspond to which blocks in the document model. Two approaches were considered:

1. **NSTextStorage as source of truth**: Use the text storage's structure directly
2. **Block spans in DocumentProjection**: Maintain separate span metadata alongside the model

## Decision
We use block spans stored in `DocumentProjection` rather than relying on NSTextStorage structure.

## Rationale

### Why Not NSTextStorage
- NSTextStorage is mutable and can change outside our control (paste, undo, etc.)
- Attribute-based metadata is fragile and hard to debug
- No type safety - ranges are just `NSRange` values
- Difficult to reconcile when model and view diverge

### Why Block Spans
- Immutable metadata tied to document version
- Type-safe with phantom types (`StorageIndex<Context>`)
- Clear separation between model and view
- Enables efficient incremental updates
- Easier to test - spans are pure data

## Consequences
- Must maintain span cache consistency with document
- Need to rebuild spans when document changes
- Slight memory overhead for span storage
- But: Enables O(log n) block lookup via binary search

## Related
- `DocumentProjection.blockSpans`
- `StorageIndex.swift` (ADR-004)