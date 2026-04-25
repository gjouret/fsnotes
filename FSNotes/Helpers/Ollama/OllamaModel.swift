//
//  OllamaModel.swift
//  FSNotes
//
//  Codable value types for Ollama HTTP API responses (`/api/tags`, `/api/version`).
//  Pure value-type layer with no AppKit / URLSession imports — testable in isolation.
//

import Foundation

/// One entry in the Ollama `/api/tags` response.
///
/// Example JSON:
/// ```json
/// {
///   "name": "llama3.2:latest",
///   "modified_at": "2024-09-25T18:23:00.000Z",
///   "size": 2019393189,
///   "digest": "f64c4fa5...",
///   "details": { "family": "llama", "parameter_size": "3.2B", "quantization_level": "Q4_K_M" }
/// }
/// ```
struct OllamaModel: Codable, Equatable {
    let name: String
    let modifiedAt: String?
    let size: Int64?
    let digest: String?
    let details: Details?

    struct Details: Codable, Equatable {
        let family: String?
        let parameterSize: String?
        let quantizationLevel: String?

        enum CodingKeys: String, CodingKey {
            case family
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
        case digest
        case details
    }
}

/// Top-level payload returned by Ollama's `/api/tags` endpoint.
struct OllamaTagsResponse: Codable, Equatable {
    let models: [OllamaModel]
}

/// Top-level payload returned by Ollama's `/api/version` endpoint.
struct OllamaVersionResponse: Codable, Equatable {
    let version: String
}
