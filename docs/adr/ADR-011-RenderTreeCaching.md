# ADR-011: Structural Sharing in Render Trees

## Status
Proposed

## Context
Re-rendering entire document on every edit is expensive:
- 10,000 char document re-renders for 1 char change
- No way to reuse previous render work
- GC pressure from temporary objects

## Decision
Implement immutable render tree with structural sharing.

## Implementation
```swift
struct RenderTree {
    let version: UInt64
    let nodes: [RenderNode]  // Persistent data structure
    
    func patch(_ delta: RenderDelta) -> RenderTree {
        // Reuse unchanged nodes, only rebuild changed paths
    }
}

struct RenderNode: Equatable {
    let id: UUID
    let block: Block
    let renderCache: RenderCache?
}
```

## Rationale

### Performance
- O(log n) updates vs O(n) re-render
- Unchanged nodes shared (reference equality)
- Cache-friendly for repeated renders

### Correctness
- Immutable nodes
- Version monotonic
- Diff-friendly for view updates

## Consequences
- More memory for node storage
- Version management complexity
- But: Scales to large documents

## Related
- `RenderTree.swift`
- `RenderNode`
- `RenderDelta`
