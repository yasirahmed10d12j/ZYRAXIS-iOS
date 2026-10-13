import XCTest
@testable import ZYRAXIS

final class TaskModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Each test gets a virgin task store: LocalTaskService persists to
        // UserDefaults.standard on every mutation and reloads it in init, so
        // without this, tasks completed/cancelled by earlier tests (XCTest runs
        // alphabetically) leak into later ones and count-sensitive assertions
        // (e.g. testListFilters expecting exactly 1 completed) flake.
        // Key must match LocalTaskService's storage key; drift self-detects as
        // a count mismatch, never a silent pass.
        UserDefaults.standard.removeObject(forKey: "zyraxis.tasks.v1")
    }

    func testActiveByDefault() {
        let t = ZyraxisTask(title: "Test")
        XCTAssertTrue(t.isActive)
        XCTAssertFalse(t.isCompleted)
        XCTAssertFalse(t.isCancelled)
    }

    func testCompleteViaService() async throws {
        let svc = LocalTaskService(notifications: nil)
        let created = try await svc.create(title: "Buy milk", notes: nil, dueDate: nil, priority: .medium)
        let done = try await svc.complete(id: created.id)
        XCTAssertTrue(done.isCompleted)
        XCTAssertFalse(done.isActive)
    }

    func testCancelViaService() async throws {
        let svc = LocalTaskService(notifications: nil)
        let created = try await svc.create(title: "Temp", notes: nil, dueDate: nil, priority: .low)
        let cancelled = try await svc.cancel(id: created.id)
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertFalse(cancelled.isActive)
    }

    func testEmptyTitleRejected() async {
        let svc = LocalTaskService(notifications: nil)
        do {
            _ = try await svc.create(title: "   ", notes: nil, dueDate: nil, priority: .medium)
            XCTFail("expected emptyTitle")
        } catch let e as TaskError {
            XCTAssertEqual(e, .emptyTitle)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testSnoozeRequiresFutureDate() async throws {
        let svc = LocalTaskService(notifications: nil)
        let created = try await svc.create(title: "Snooze me", notes: nil, dueDate: nil, priority: .medium)
        do {
            _ = try await svc.snooze(id: created.id, until: Date(timeIntervalSinceNow: -60))
            XCTFail("expected invalidSnoozeDate")
        } catch let e as TaskError {
            XCTAssertEqual(e, .invalidSnoozeDate)
        }
        let future = Date(timeIntervalSinceNow: 3600)
        let snoozed = try await svc.snooze(id: created.id, until: future)
        XCTAssertEqual(snoozed.snoozedUntil?.timeIntervalSinceReferenceDate ?? 0,
                       future.timeIntervalSinceReferenceDate, accuracy: 1.0)
        XCTAssertEqual(snoozed.effectiveDueDate?.timeIntervalSinceReferenceDate ?? 0,
                       future.timeIntervalSinceReferenceDate, accuracy: 1.0)
    }

    func testListFilters() async throws {
        let svc = LocalTaskService(notifications: nil)
        let a = try await svc.create(title: "A", notes: nil, dueDate: nil, priority: .medium)
        _ = try await svc.create(title: "B", notes: nil, dueDate: nil, priority: .medium)
        _ = try await svc.complete(id: a.id)
        let active = try await svc.list(filter: .active)
        XCTAssertTrue(active.allSatisfy { $0.isActive })
        let completed = try await svc.list(filter: .completed)
        XCTAssertEqual(completed.count, 1)
    }

    func testCodableRoundTrip() throws {
        let t = ZyraxisTask(title: "Persist", notes: "n", priority: .high)
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(ZyraxisTask.self, from: data)
        XCTAssertEqual(t, back)
    }
}
