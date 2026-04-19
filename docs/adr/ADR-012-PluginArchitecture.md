# ADR-012: Plugin Architecture

## Status
Proposed

## Context
Features like MathJax, Mermaid, and tables are hardcoded:
- Core codebase grows with each feature
- Can't add features without modifying core
- Users can't customize behavior

## Decision
Implement plugin system with capability discovery.

## Implementation
```swift
protocol EditorPlugin {
    var capabilities: PluginCapabilities { get }
    func activate(context: PluginContext)
}

protocol BlockRenderingPlugin: EditorPlugin {
    func canRender(block: Block) -> Bool
    func render(block: Block, style: RenderStyle) -> NSAttributedString
}

final class PluginManager {
    func register(_ plugin: EditorPlugin)
}
```

## Rationale

### Extensibility
- Third-party plugins possible
- Core stays lean
- Feature parity via plugins

### Isolation
- Plugins can't break core
- Sandboxed capabilities
- Graceful degradation

## Consequences
- Plugin API stability commitment
- Version compatibility matrix
- But: Sustainable growth model

## Related
- `PluginArchitecture.swift`
- `PluginManager`
- Example plugins in `Plugins/`