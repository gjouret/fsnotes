//
//  OllamaClient.swift
//  FSNotes
//
//  Pure URL-construction + decoding helpers for the Ollama HTTP API.
//  Network calls are delegated to a caller-supplied URLSession (defaults to .shared)
//  so the tests can inject a mock session without spinning up a real Ollama instance.
//

import Foundation

/// Errors surfaced by the Ollama client.
enum OllamaClientError: LocalizedError, Equatable {
    case invalidHost(String)
    case unreachable
    case httpError(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidHost(let host):
            return "Invalid Ollama host URL: \(host)"
        case .unreachable:
            return "Ollama is not reachable. Make sure `ollama serve` is running."
        case .httpError(let code):
            return "Ollama returned HTTP \(code)."
        case .decodingFailed:
            return "Could not decode Ollama API response."
        }
    }
}

/// Stateless helper around the Ollama HTTP API.
///
/// All methods are static; callers pass the host URL explicitly so the same helper
/// can be used for testing different endpoints without touching UserDefaults.
enum OllamaClient {

    // MARK: - URL construction (pure, side-effect free)

    /// Build the URL for the `/api/tags` (model list) endpoint.
    /// Returns `nil` if `host` cannot be combined with the path into a valid URL.
    static func tagsURL(host: String) -> URL? {
        guard let base = sanitizedBaseURL(host: host) else { return nil }
        return base.appendingPathComponent("api").appendingPathComponent("tags")
    }

    /// Build the URL for the `/api/version` endpoint (used for reachability checks).
    static func versionURL(host: String) -> URL? {
        guard let base = sanitizedBaseURL(host: host) else { return nil }
        return base.appendingPathComponent("api").appendingPathComponent("version")
    }

    /// Build the URL for the `/api/chat` endpoint (used by the streaming provider).
    static func chatURL(host: String) -> URL? {
        guard let base = sanitizedBaseURL(host: host) else { return nil }
        return base.appendingPathComponent("api").appendingPathComponent("chat")
    }

    /// Strip a trailing slash from `host` and return it as a URL.
    /// Exposed for tests so they can verify the normalization rule directly.
    static func sanitizedBaseURL(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return URL(string: normalized)
    }

    // MARK: - Decoding (pure)

    /// Decode an `/api/tags` JSON payload. Public for testing.
    static func decodeTags(_ data: Data) throws -> OllamaTagsResponse {
        do {
            return try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        } catch {
            throw OllamaClientError.decodingFailed
        }
    }

    /// Decode an `/api/version` JSON payload. Public for testing.
    static func decodeVersion(_ data: Data) throws -> OllamaVersionResponse {
        do {
            return try JSONDecoder().decode(OllamaVersionResponse.self, from: data)
        } catch {
            throw OllamaClientError.decodingFailed
        }
    }

    // MARK: - Network helpers

    /// List models available on the given Ollama host.
    /// - Parameters:
    ///   - host: Base URL of the Ollama server (e.g. `http://localhost:11434`).
    ///   - session: URLSession to use. Defaults to `.shared`; tests inject a mock.
    static func listModels(host: String,
                           session: URLSession = .shared,
                           completion: @escaping (Result<[OllamaModel], Error>) -> Void) {
        guard let url = tagsURL(host: host) else {
            completion(.failure(OllamaClientError.invalidHost(host)))
            return
        }

        let task = session.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(OllamaClientError.httpError(http.statusCode)))
                return
            }
            guard let data = data else {
                completion(.failure(OllamaClientError.decodingFailed))
                return
            }
            do {
                let decoded = try decodeTags(data)
                completion(.success(decoded.models))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Check whether the Ollama server is reachable. Returns `false` on any error
    /// or non-200 status — callers only care about the boolean.
    static func checkReachability(host: String,
                                  session: URLSession = .shared,
                                  completion: @escaping (Bool) -> Void) {
        guard let url = versionURL(host: host) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let task = session.dataTask(with: request) { _, response, error in
            if error != nil {
                completion(false)
                return
            }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completion(ok)
        }
        task.resume()
    }
}
