//
//  Phase1OllamaClientTests.swift
//  FSNotesTests
//
//  Tests for OllamaClient pure helpers (URL construction + JSON decoding).
//  These run without a live Ollama instance.
//

import XCTest
@testable import FSNotes

final class Phase1OllamaClientTests: XCTestCase {

    // MARK: - URL construction

    func testTagsURL_appendsApiTags() {
        let url = OllamaClient.tagsURL(host: "http://localhost:11434")
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/api/tags")
    }

    func testTagsURL_stripsTrailingSlash() {
        let url = OllamaClient.tagsURL(host: "http://localhost:11434/")
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/api/tags")
    }

    func testTagsURL_stripsMultipleTrailingSlashes() {
        let url = OllamaClient.tagsURL(host: "http://localhost:11434///")
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/api/tags")
    }

    func testVersionURL_appendsApiVersion() {
        let url = OllamaClient.versionURL(host: "http://localhost:11434")
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/api/version")
    }

    func testChatURL_appendsApiChat() {
        let url = OllamaClient.chatURL(host: "http://localhost:11434")
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/api/chat")
    }

    func testTagsURL_remoteHost() {
        let url = OllamaClient.tagsURL(host: "https://ollama.example.com:8443")
        XCTAssertEqual(url?.absoluteString, "https://ollama.example.com:8443/api/tags")
    }

    func testTagsURL_emptyHostReturnsNil() {
        XCTAssertNil(OllamaClient.tagsURL(host: ""))
        XCTAssertNil(OllamaClient.tagsURL(host: "   "))
    }

    // MARK: - Decoding /api/tags

    func testDecodeTags_emptyModels() throws {
        let json = """
        { "models": [] }
        """.data(using: .utf8)!
        let response = try OllamaClient.decodeTags(json)
        XCTAssertEqual(response.models.count, 0)
    }

    func testDecodeTags_singleModel() throws {
        let json = """
        {
          "models": [
            {
              "name": "llama3.2:latest",
              "modified_at": "2024-09-25T18:23:00.000Z",
              "size": 2019393189,
              "digest": "f64c4fa5",
              "details": {
                "family": "llama",
                "parameter_size": "3.2B",
                "quantization_level": "Q4_K_M"
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let response = try OllamaClient.decodeTags(json)
        XCTAssertEqual(response.models.count, 1)
        let model = response.models[0]
        XCTAssertEqual(model.name, "llama3.2:latest")
        XCTAssertEqual(model.size, 2019393189)
        XCTAssertEqual(model.digest, "f64c4fa5")
        XCTAssertEqual(model.details?.family, "llama")
        XCTAssertEqual(model.details?.parameterSize, "3.2B")
        XCTAssertEqual(model.details?.quantizationLevel, "Q4_K_M")
    }

    func testDecodeTags_modelWithoutDetails() throws {
        let json = """
        {
          "models": [
            { "name": "mistral:7b" }
          ]
        }
        """.data(using: .utf8)!
        let response = try OllamaClient.decodeTags(json)
        XCTAssertEqual(response.models.count, 1)
        XCTAssertEqual(response.models[0].name, "mistral:7b")
        XCTAssertNil(response.models[0].details)
    }

    func testDecodeTags_garbageThrows() {
        let bogus = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try OllamaClient.decodeTags(bogus)) { error in
            XCTAssertEqual(error as? OllamaClientError, .decodingFailed)
        }
    }

    // MARK: - Decoding /api/version

    func testDecodeVersion() throws {
        let json = """
        { "version": "0.3.6" }
        """.data(using: .utf8)!
        let response = try OllamaClient.decodeVersion(json)
        XCTAssertEqual(response.version, "0.3.6")
    }
}
