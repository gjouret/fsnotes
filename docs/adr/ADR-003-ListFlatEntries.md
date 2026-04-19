# ADR-003: Flat Entries + Tree Paths for List Navigation

## Status
Accepted

## Context
Lists have hierarchical structure (items with children), but the rendered output is flat. We need to:
- Map storage offsets to specific items
- Support editing operations at any level
- Reconstruct the tree after modifications

## Decision
Flatten list to array of `FlatListEntry` values, each carrying its tree path.

## Structure
```swift
struct FlatListEntry {
    let item: ListItem
    let depth: Int
    let prefixLength: Int
    let inlineLength: Int
    let startOffset: Int    // In rendered output
    let path: [Int]         // Tree path for reconstruction
}
```

## Rationale

### Why Not Keep Tree
- Tree navigation is O(depth) per lookup
- Flat array enables binary search
- Easier to calculate offsets

### Why Carry Path
- Path enables O(1) reconstruction via `replaceItemAtPath`
- No parent pointers needed
- Immutable - paths don't change during navigation

## Consequences
- Must keep flat structure in sync with tree
- Path reconstruction on every edit
- But: O(log n) offset lookup vs O(n) tree walk

## Related
- `ListEditing.flattenList`
- `ListEditing.FlatListEntry`
- `replaceItemAtPath`