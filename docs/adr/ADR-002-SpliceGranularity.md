# ADR-002: Character-Granular Splices, Not Block-Granular

## Status
Accepted

## Context
When editing a block, we need to update the view. Two approaches:

1. **Block-granular**: Replace the entire block's rendered output
2. **Character-granular**: Calculate the minimal changed substring and only replace that

## Decision
Use character-granular splices for all in-block edits.

## Rationale

### Performance
- Block-granular: A 1-char edit in a 7000-char block replaces all 7000 chars
- Character-granular: Same edit replaces 1 char
- This matters for syntax highlighting, which is expensive

### Correctness
- Block-granular loses cursor position context
- Character-granular preserves NSTextStorage's internal state better
- Minimizes layout recalculation

### Implementation
- `EditResult.spliceRange` and `spliceReplacement` define minimal change
- `assertSpliceInvariant` test verifies correctness
- EditingOps.calculateSplice() computes diff

## Consequences
- More complex splice calculation
- Must handle inline formatting boundaries
- Must handle atomic elements (images, tables)
- But: Dramatically better performance for large documents

## Related
- `EditingOps.swift` - splice calculation
- `EditResult` struct
- Tests: `assertSpliceInvariant`