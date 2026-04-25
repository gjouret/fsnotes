//
//  ToolOutput.swift
//  FSNotes
//
//  Result value type produced by MCP tools. All tools return
//  `ToolOutput.success(payload)` or `ToolOutput.error(message)`. The
//  MCPServer wraps any uncaught throw in `.error` before passing the
//  result back to the LLM (see docs/AI.md, "Error Handling").
//

import Foundation

/// A successful tool result carries a JSON-serialisable payload that
/// will be encoded into the `tool` message returned to the LLM. An
/// error result carries a human-readable message; the LLM may retry
/// with corrected arguments.
public enum ToolOutput {
    case success([String: Any])
    case error(String)

    /// Convenience for the common shape `{"status": "...", ...}`.
    public static func status(_ value: String, extra: [String: Any] = [:]) -> ToolOutput {
        var payload: [String: Any] = ["status": value]
        for (k, v) in extra { payload[k] = v }
        return .success(payload)
    }

    /// Encode to a JSON string suitable for the `tool` message
    /// `content` field. Errors are encoded as `{"error": "..."}` so
    /// the wire format stays uniform.
    public func encodeAsJSONString() -> String {
        let object: Any
        switch self {
        case .success(let payload):
            object = jsonSafe(payload)
        case .error(let message):
            object = ["error": message]
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            // Fall back to a minimal error envelope; never crash the
            // tool pipeline because of an unencodable payload.
            return "{\"error\":\"tool result not JSON-serialisable\"}"
        }
        return string
    }

    /// True for `.success`. Useful in tests.
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// The payload, or nil for `.error`.
    public var payload: [String: Any]? {
        if case .success(let p) = self { return p }
        return nil
    }

    /// The error message, or nil for `.success`.
    public var errorMessage: String? {
        if case .error(let m) = self { return m }
        return nil
    }
}

/// Recursively coerce a payload into JSON-serialisable types. `Date`
/// becomes ISO-8601 string; `URL` becomes its `path`; everything else
/// is passed through if `JSONSerialization` accepts it.
private func jsonSafe(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out[k] = jsonSafe(v) }
        return out
    }
    if let array = value as? [Any] {
        return array.map { jsonSafe($0) }
    }
    if let date = value as? Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    if let url = value as? URL {
        return url.path
    }
    return value
}
