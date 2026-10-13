import XCTest
@testable import ZYRAXIS

/// Error mapping: friendly user strings, structured app errors, and the
/// guarantee that no stack traces or secrets reach the transcript.
final class AssistantErrorMapperTests: XCTestCase {

    func testNoConnectionFriendly() {
        let msg = AssistantErrorMapper.userMessage(for: NetworkError.noConnection)
        XCTAssertTrue(msg.lowercased().contains("no network connection"))
    }

    func testTimeoutFriendly() {
        let msg = AssistantErrorMapper.userMessage(for: NetworkError.timeout)
        XCTAssertTrue(msg.lowercased().contains("took too long"))
    }

    func testUnauthorizedPointsToSettings() {
        let msg = AssistantErrorMapper.userMessage(for: NetworkError.unauthorized)
        XCTAssertTrue(msg.contains("Settings"))
    }

    func testBackendNotConfiguredPointsToSettings() {
        let msg = AssistantErrorMapper.userMessage(
            for: NetworkError.transport("Backend not configured. Set the backend URL in Settings.")
        )
        XCTAssertTrue(msg.contains("Settings"))
    }

    func testVersionMismatchExplains() {
        let msg = AssistantErrorMapper.userMessage(
            for: BackendProtocolError.versionMismatch(expected: 1, received: 7)
        )
        XCTAssertTrue(msg.contains("v1"))
        XCTAssertTrue(msg.contains("v7"))
    }

    func testCancellationFriendly() {
        XCTAssertEqual(AssistantErrorMapper.userMessage(for: CancellationError()), "Request cancelled.")
        XCTAssertEqual(AssistantErrorMapper.userMessage(for: NetworkError.cancelled), "Request cancelled.")
    }

    func testNoStackTraceLeaks() {
        let errors: [Error] = [
            NetworkError.server(statusCode: 500, message: "Traceback (most recent call last): File \"/srv/app.py\""),
            NetworkError.transport("dial tcp 10.0.0.5:443: connect: refused"),
            BackendProtocolError.malformedMessage("field 'payload' missing at line 1 column 40"),
            AppError.ai("inner failure")
        ]
        for error in errors {
            let msg = AssistantErrorMapper.userMessage(for: error)
            XCTAssertFalse(msg.contains("Traceback"), "leak in: \(msg)")
            XCTAssertFalse(msg.contains("10.0.0.5"), "leak in: \(msg)")
            XCTAssertFalse(msg.contains("column 40"), "leak in: \(msg)")
        }
    }

    func testAppErrorMapping() {
        XCTAssertEqual(
            AssistantErrorMapper.appError(for: NetworkError.timeout),
            .network(NetworkError.timeout.localizedDescription)
        )
        XCTAssertEqual(
            AssistantErrorMapper.appError(for: CancellationError()),
            .ai("Request cancelled.")
        )
    }

    func testLogRedaction() {
        let dirty = "POST chat Authorization: Bearer sk-live-SECRET123 api_key= hunter2 token: abc password= p@ss"
        let clean = ZyraxisLogger.redacted(dirty)
        XCTAssertFalse(clean.contains("sk-live-SECRET123"))
        XCTAssertFalse(clean.contains("hunter2"))
        XCTAssertFalse(clean.contains("p@ss"))
        XCTAssertTrue(clean.contains("[REDACTED]"))
    }
}
