import XCTest
@testable import ZYRAXIS

/// Protocol-layer tests: envelope encoding, version enforcement,
/// unknown-type tolerance, payload mapping via the v1 adapter.
/// No backend required — all frames are constructed locally.
final class AIProtocolTests: XCTestCase {

    private func envelope(
        type: BackendMessageType,
        requestId: String = UUID().uuidString,
        payload: [String: JSONValue] = [:],
        version: Int = BackendProtocol.currentVersion
    ) -> ZyraxisEnvelope {
        ZyraxisEnvelope(type: type, requestId: requestId, payload: payload, version: version)
    }

    private func payload<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try XCTUnwrap(object as? [String: Any])
        var out: [String: JSONValue] = [:]
        for (k, v) in dict {
            out[k] = try XCTUnwrap(jsonValue(v), "unconvertible payload value for key \(k)")
        }
        return out
    }

    private func jsonValue(_ any: Any) -> JSONValue? {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case is NSNull: return .null
        case let a as [Any]:
            let mapped = a.compactMap { jsonValue($0) }
            guard mapped.count == a.count else { return nil }
            return .array(mapped)
        case let o as [String: Any]:
            var mapped: [String: JSONValue] = [:]
            for (k, v) in o {
                guard let jv = jsonValue(v) else { return nil }
                mapped[k] = jv
            }
            return .object(mapped)
        default: return nil
        }
    }

    // MARK: - Envelope round-trip

    func testEnvelopeEncodeDecodeRoundTrip() throws {
        let id = UUID().uuidString
        let env = envelope(
            type: .assistantDelta,
            requestId: id,
            payload: try payload(AssistantDeltaPayload(delta: "Hello", seq: 3))
        )
        let text = try env.encode()
        let back = try ZyraxisEnvelope.decode(text)
        XCTAssertEqual(back, env)
        XCTAssertEqual(back.type, .assistantDelta)
        XCTAssertEqual(back.requestId, id)
    }

    func testRequestEncoding() throws {
        let ctx = ConversationContext(
            systemPrompt: "sys",
            messages: [ConversationMessage(role: .user, text: "hi")],
            memories: [],
            assistantState: "IDLE",
            availableTools: ["clock"]
        )
        let req = AIRequest(text: "Hello ZYRAXIS", context: ctx, timeout: 30)
        let data = try JSONEncoder().encode(
            ["requestId": req.id.uuidString, "text": req.text]
        )
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(decoded["text"], "Hello ZYRAXIS")
        XCTAssertEqual(decoded["requestId"], req.id.uuidString)
    }

    // MARK: - Version + malformed handling

    func testVersionMismatchThrows() {
        let env = envelope(type: .ping, version: 999)
        guard let text = try? env.encode() else { return XCTFail("encode failed") }
        XCTAssertThrowsError(try ZyraxisEnvelope.decode(text)) { error in
            guard case BackendProtocolError.versionMismatch(let e, let r) = error as? BackendProtocolError else {
                return XCTFail("expected versionMismatch, got \(error)")
            }
            XCTAssertEqual(e, BackendProtocol.currentVersion)
            XCTAssertEqual(r, 999)
        }
    }

    func testMalformedFrameThrows() {
        XCTAssertThrowsError(try ZyraxisEnvelope.decode("this is not json")) { error in
            XCTAssertTrue(error is BackendProtocolError)
        }
    }

    func testUnknownTypeTolerated() throws {
        let id = UUID().uuidString
        let json = "{\"version\":1,\"type\":\"future_magic\",\"requestId\":\"\(id)\",\"payload\":{}}"
        let env = try ZyraxisEnvelope.decode(json)
        XCTAssertEqual(env.type, .unknown("future_magic"))
        let events = try ZyraxisV1Adapter().streamEvents(from: env)
        XCTAssertTrue(events.isEmpty, "unknown types must be ignored, not crash")
    }

    // MARK: - Adapter mapping

    func testDeltaMapsToTextDelta() throws {
        let id = UUID()
        let env = envelope(
            type: .assistantDelta,
            requestId: id.uuidString,
            payload: try payload(AssistantDeltaPayload(delta: "Hel", seq: 1))
        )
        let events = try ZyraxisV1Adapter().streamEvents(from: env)
        XCTAssertEqual(events, [.textDelta(requestId: id, delta: "Hel", seq: 1)])
    }

    func testCompleteMapsWithToolCalls() throws {
        let id = UUID()
        let call = ToolCall(toolName: "reminder.create", argumentsJSON: "{}")
        let env = envelope(
            type: .assistantComplete,
            requestId: id.uuidString,
            payload: try payload(AssistantCompletePayload(fullText: "Done", toolCalls: [call]))
        )
        let events = try ZyraxisV1Adapter().streamEvents(from: env)
        XCTAssertEqual(events.count, 1)
        if case .completed(let rid, let resp) = events[0] {
            XCTAssertEqual(rid, id)
            XCTAssertEqual(resp.text, "Done")
            XCTAssertEqual(resp.toolCalls, [call])
        } else {
            XCTFail("expected completed")
        }
    }

    func testErrorMapsToFailed() throws {
        let id = UUID()
        let env = envelope(
            type: .assistantError,
            requestId: id.uuidString,
            payload: try payload(AssistantErrorPayload(code: "MODEL_DOWN", message: "bad", retryable: true))
        )
        let events = try ZyraxisV1Adapter().streamEvents(from: env)
        XCTAssertEqual(events.count, 1)
        if case .failed(let rid, _) = events[0] {
            XCTAssertEqual(rid, id)
        } else {
            XCTFail("expected failed")
        }
    }

    func testToolCallAndResultMap() throws {
        let id = UUID()
        let callEnv = envelope(
            type: .toolCall,
            requestId: id.uuidString,
            payload: try payload(ToolCallPayload(toolCall: ToolCall(toolName: "t", argumentsJSON: "{}"), seq: 1))
        )
        let callEvents = try ZyraxisV1Adapter().streamEvents(from: callEnv)
        XCTAssertEqual(callEvents.count, 1)
        if case .toolCall(let req) = callEvents[0] {
            XCTAssertEqual(req.requestId, id)
            XCTAssertEqual(req.toolCall.toolName, "t")
        } else {
            XCTFail("expected toolCall")
        }

        let resEnv = envelope(
            type: .toolResult,
            requestId: id.uuidString,
            payload: try payload(ToolResultPayload(toolName: "t", outputJSON: "{\"ok\":true}"))
        )
        let resEvents = try ZyraxisV1Adapter().streamEvents(from: resEnv)
        if case .toolResult(let res) = resEvents[0] {
            XCTAssertTrue(res.succeeded)
        } else {
            XCTFail("expected toolResult")
        }
    }

    func testPingPongProduceNoAIEvents() throws {
        let id = UUID()
        for t in [BackendMessageType.ping, .pong] {
            let events = try ZyraxisV1Adapter().streamEvents(from: envelope(type: t, requestId: id.uuidString))
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testSessionStartMapsToConnected() throws {
        let id = UUID()
        let events = try ZyraxisV1Adapter().streamEvents(from: envelope(type: .sessionStart, requestId: id.uuidString))
        XCTAssertEqual(events, [.connected(requestId: id)])
    }

    func testNonUUIDRequestIdThrows() {
        let env = envelope(type: .assistantDelta, requestId: "not-a-uuid")
        XCTAssertThrowsError(try ZyraxisV1Adapter().streamEvents(from: env))
    }
}
