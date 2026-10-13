import XCTest
@testable import ZYRAXIS

/// Fast-command routing: exact local matches handled on-device, everything
/// else falls through to the AI. No backend required.
final class FastCommandRouterTests: XCTestCase {

    private let router = FastCommandRouter()

    func testTimeCommands() {
        for input in ["time", "What time is it?", "current time", "tell me the time"] {
            if case .answer(let text) = router.route(input) {
                XCTAssertTrue(text.lowercased().contains("current time"), "got: \(text)")
            } else {
                XCTFail("expected answer for \(input)")
            }
        }
    }

    func testDateCommands() {
        for input in ["date", "what day is it", "today's date"] {
            if case .answer(let text) = router.route(input) {
                XCTAssertTrue(text.lowercased().contains("today is"), "got: \(text)")
            } else {
                XCTFail("expected answer for \(input)")
            }
        }
    }

    func testStopCancel() {
        XCTAssertEqual(router.route("stop"), .cancelCurrent)
        XCTAssertEqual(router.route("Cancel"), .cancelCurrent)
        XCTAssertEqual(router.route("stop listening"), .cancelCurrent)
    }

    func testMicCommands() {
        XCTAssertEqual(router.route("mic off"), .mic(.disableMic))
        XCTAssertEqual(router.route("mute"), .mic(.disableMic))
        XCTAssertEqual(router.route("microphone on"), .mic(.enableMic))
        XCTAssertEqual(router.route("unmute"), .mic(.enableMic))
    }

    func testNormalConversationPassesThrough() {
        // These MUST reach the AI — the fast path must not hijack them.
        let normal = [
            "What is the weather?",
            "What time does the store open?",
            "Tell me about the date of the moon landing",
            "Stop making sense",       // starts with stop but is not the command
            "Can you mute the background noise conceptually?",
            "Hello ZYRAXIS",
            "Open that again."
        ]
        for input in normal {
            XCTAssertEqual(router.route(input), .none, "must not hijack: \(input)")
        }
    }
}
