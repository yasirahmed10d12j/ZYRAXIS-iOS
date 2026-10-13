import XCTest
@testable import ZYRAXIS

/// Reconnect backoff: deterministic growth, cap, attempt budget.
/// Uses the jitter-free variant so assertions are exact.
final class ReconnectPolicyTests: XCTestCase {

    func testExponentialGrowth() {
        let p = ReconnectPolicy.deterministic
        XCTAssertEqual(p.delay(forAttempt: 1), 1.0, accuracy: 0.001)
        XCTAssertEqual(p.delay(forAttempt: 2), 2.0, accuracy: 0.001)
        XCTAssertEqual(p.delay(forAttempt: 3), 4.0, accuracy: 0.001)
        XCTAssertEqual(p.delay(forAttempt: 4), 8.0, accuracy: 0.001)
    }

    func testDelayCappedAtMax() {
        let p = ReconnectPolicy.deterministic
        XCTAssertEqual(p.delay(forAttempt: 10), 30.0, accuracy: 0.001)
        XCTAssertEqual(p.delay(forAttempt: 100), 30.0, accuracy: 0.001)
    }

    func testZeroOrNegativeAttemptIsZero() {
        let p = ReconnectPolicy.deterministic
        XCTAssertEqual(p.delay(forAttempt: 0), 0)
        XCTAssertEqual(p.delay(forAttempt: -1), 0)
    }

    func testJitterStaysWithinCap() {
        let p = ReconnectPolicy(maxAttempts: 8, baseDelay: 1.0, maxDelay: 30.0, jitter: true)
        for attempt in 1...12 {
            let d = p.delay(forAttempt: attempt)
            XCTAssertGreaterThan(d, 0)
            XCTAssertLessThanOrEqual(d, 30.0)
        }
    }

    func testCustomPolicyRespected() {
        let p = ReconnectPolicy(maxAttempts: 3, baseDelay: 2.0, maxDelay: 5.0, jitter: false)
        XCTAssertEqual(p.maxAttempts, 3)
        XCTAssertEqual(p.delay(forAttempt: 1), 2.0, accuracy: 0.001)
        XCTAssertEqual(p.delay(forAttempt: 2), 4.0, accuracy: 0.001)
        XCTAssertEqual(p.delay(forAttempt: 3), 5.0, accuracy: 0.001) // capped
    }
}
