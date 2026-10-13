import XCTest
@testable import ZYRAXIS

@MainActor
final class AssistantStateMachineTests: XCTestCase {

    func testInitialStateIsIdle() {
        let sm = AssistantStateMachine()
        XCTAssertEqual(sm.state, .idle)
    }

    func testValidIdleToListening() {
        let sm = AssistantStateMachine()
        XCTAssertTrue(sm.transition(to: .listening))
        XCTAssertEqual(sm.state, .listening)
    }

    func testInvalidIdleToSpeakingRejected() {
        let sm = AssistantStateMachine()
        XCTAssertFalse(sm.transition(to: .speaking))
        XCTAssertEqual(sm.state, .idle)
    }

    func testFullHappyPath() {
        let sm = AssistantStateMachine()
        XCTAssertTrue(sm.beginListening())
        XCTAssertTrue(sm.markUserSpeaking())
        XCTAssertTrue(sm.beginProcessing())
        XCTAssertTrue(sm.beginSpeaking())
        XCTAssertTrue(sm.transition(to: .idle))
    }

    func testProcessingToExecutingToIdle() {
        let sm = AssistantStateMachine()
        XCTAssertTrue(sm.transition(to: .processing))
        XCTAssertTrue(sm.beginExecuting())
        XCTAssertTrue(sm.transition(to: .idle))
    }

    func testErrorIsStickyUntilReset() {
        let sm = AssistantStateMachine()
        sm.fail(with: .ai("boom"))
        XCTAssertEqual(sm.state, .error)
        XCTAssertEqual(sm.lastError, .ai("boom"))
        XCTAssertFalse(sm.transition(to: .processing))
        XCTAssertTrue(sm.resetToIdle())
        XCTAssertEqual(sm.state, .idle)
        XCTAssertNil(sm.lastError)
    }

    func testVisionRoundTrip() {
        let sm = AssistantStateMachine()
        XCTAssertTrue(sm.beginVision())
        XCTAssertTrue(sm.beginProcessing())
        XCTAssertTrue(sm.transition(to: .idle))
    }

    func testCanTransitionMatrix() {
        XCTAssertTrue(AssistantStateMachine.canTransition(from: .idle, to: .listening))
        XCTAssertFalse(AssistantStateMachine.canTransition(from: .idle, to: .speaking))
        XCTAssertTrue(AssistantStateMachine.canTransition(from: .error, to: .idle))
        XCTAssertFalse(AssistantStateMachine.canTransition(from: .error, to: .processing))
    }
}
