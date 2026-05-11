import Testing
import Foundation
@testable import FroggyKit

// MARK: - FroggyRequest round-trip

@Test func froggyRequest_codableRoundTrip_minimal() throws {
    let req     = FroggyRequest(cmd: "status")
    let data    = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(FroggyRequest.self, from: data)
    #expect(decoded.cmd == "status")
    #expect(decoded.prompt == nil)
    #expect(decoded.maxTokens == nil)
    #expect(decoded.accessor == nil)
}

@Test func froggyRequest_codableRoundTrip_allFields() throws {
    let req = FroggyRequest(
        cmd: "generate",
        prompt: "hello",
        maxTokens: 1024,
        maxChars: 4096,
        useContext: true,
        path: "/tmp/foo",
        accessor: "ocr"
    )
    let data    = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(FroggyRequest.self, from: data)
    #expect(decoded.cmd == "generate")
    #expect(decoded.prompt == "hello")
    #expect(decoded.maxTokens == 1024)
    #expect(decoded.maxChars == 4096)
    #expect(decoded.useContext == true)
    #expect(decoded.path == "/tmp/foo")
    #expect(decoded.accessor == "ocr")
}

// MARK: - FroggyResponse round-trip

@Test func froggyResponse_codableRoundTrip_textChunk() throws {
    var res = FroggyResponse()
    res.ok = true
    res.text = "hello"
    res.final = false
    let data    = try JSONEncoder().encode(res)
    let decoded = try JSONDecoder().decode(FroggyResponse.self, from: data)
    #expect(decoded.ok == true)
    #expect(decoded.text == "hello")
    #expect(decoded.final == false)
    #expect(decoded.error == nil)
}

@Test func froggyResponse_codableRoundTrip_pressureSnapshot() throws {
    var res = FroggyResponse()
    res.ok = true
    res.pressureLevel = "warning"
    res.tier1Frozen = [1234, 5678]
    res.tier2Frozen = []
    res.secondsInLevel = 42
    res.final = true
    let data    = try JSONEncoder().encode(res)
    let decoded = try JSONDecoder().decode(FroggyResponse.self, from: data)
    #expect(decoded.pressureLevel == "warning")
    #expect(decoded.tier1Frozen == [1234, 5678])
    #expect(decoded.tier2Frozen == [])
    #expect(decoded.secondsInLevel == 42)
    #expect(decoded.final == true)
}

// MARK: - Forward-compat: unknown fields are silently ignored

@Test func froggyResponse_decodingIgnoresUnknownFields() throws {
    // A newer daemon adds a field that this client doesn't know yet.
    let json = #"""
    {
        "ok": true,
        "text": "hi",
        "final": true,
        "futureField": {"experimental": "metadata", "n": 42},
        "anotherNewKey": [1, 2, 3]
    }
    """#
    let decoded = try JSONDecoder().decode(FroggyResponse.self, from: Data(json.utf8))
    #expect(decoded.ok == true)
    #expect(decoded.text == "hi")
    #expect(decoded.final == true)
}

@Test func froggyRequest_decodingIgnoresUnknownFields() throws {
    // A future caller might add new optional request fields.
    let json = #"""
    {
        "cmd": "generate",
        "prompt": "p",
        "newOptionalField": "ignored",
        "anotherFutureKey": 99
    }
    """#
    let decoded = try JSONDecoder().decode(FroggyRequest.self, from: Data(json.utf8))
    #expect(decoded.cmd == "generate")
    #expect(decoded.prompt == "p")
}

// MARK: - Backward-compat: missing optional fields don't break decoding

@Test func froggyResponse_decodesMinimalJSON_singleField() throws {
    // The earliest possible response — every field optional except none.
    let json    = #"{}"#
    let decoded = try JSONDecoder().decode(FroggyResponse.self, from: Data(json.utf8))
    #expect(decoded.ok == nil)
    #expect(decoded.text == nil)
    #expect(decoded.final == nil)
}

@Test func froggyRequest_decodesMinimalJSON_onlyCmd() throws {
    let json    = #"{"cmd": "status"}"#
    let decoded = try JSONDecoder().decode(FroggyRequest.self, from: Data(json.utf8))
    #expect(decoded.cmd == "status")
    #expect(decoded.prompt == nil)
}

@Test func froggyResponse_decodesLegacyShape_v01_singleTextChunk() throws {
    // Snapshot of a response shape from before pressure fields existed.
    let legacy = #"""
    {
        "ok": true,
        "text": "generated text",
        "final": true
    }
    """#
    let decoded = try JSONDecoder().decode(FroggyResponse.self, from: Data(legacy.utf8))
    #expect(decoded.ok == true)
    #expect(decoded.text == "generated text")
    #expect(decoded.final == true)
    #expect(decoded.pressureLevel == nil)
    #expect(decoded.tier1Frozen == nil)
}

// MARK: - Wire shape sanity (JSON-line semantics)

@Test func froggyRequest_encoding_isSingleJSONObject() throws {
    let req     = FroggyRequest(cmd: "ping")
    let data    = try JSONEncoder().encode(req)
    let string  = String(decoding: data, as: UTF8.self)
    // Must be a single JSON object (no newlines added by encoder — the
    // caller is responsible for appending \n).
    #expect(!string.contains("\n"))
    #expect(string.hasPrefix("{"))
    #expect(string.hasSuffix("}"))
}
