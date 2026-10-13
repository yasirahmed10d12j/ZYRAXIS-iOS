import XCTest
@testable import ZYRAXIS

final class MemoryModelTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let item = MemoryItem(content: "User prefers dark mode", tags: ["prefs"], importance: 0.8)
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(MemoryItem.self, from: data)
        XCTAssertEqual(item, back)
    }

    func testImportanceClamped() {
        XCTAssertEqual(MemoryItem(content: "x", importance: 5).importance, 1.0)
        XCTAssertEqual(MemoryItem(content: "x", importance: -2).importance, 0.0)
    }

    func testSaveAndSearch() async throws {
        let svc = InMemoryMemoryService()
        _ = try await svc.save(content: "ZYRAXIS backend URL is private", tags: ["backend"], importance: 0.9)
        _ = try await svc.save(content: "Unrelated note", tags: [], importance: 0.1)
        let hits = try await svc.search(query: "backend", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].content.contains("backend"))
    }

    func testEmptySaveRejected() async {
        let svc = InMemoryMemoryService()
        do {
            _ = try await svc.save(content: "   ", tags: [], importance: 0.5)
            XCTFail("expected emptyContent")
        } catch let e as MemoryError {
            XCTAssertEqual(e, .emptyContent)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testUpdateAndForget() async throws {
        let svc = InMemoryMemoryService()
        let item = try await svc.save(content: "original", tags: [], importance: 0.5)
        let updated = try await svc.update(id: item.id, content: "edited", tags: ["t"], importance: 0.7)
        XCTAssertEqual(updated.content, "edited")
        XCTAssertEqual(updated.tags, ["t"])
        try await svc.forget(id: item.id)
        let all = try await svc.listAll()
        XCTAssertTrue(all.isEmpty)
        do {
            _ = try await svc.update(id: item.id, content: "x", tags: nil, importance: nil)
            XCTFail("expected notFound")
        } catch let e as MemoryError {
            XCTAssertEqual(e, .notFound)
        }
    }
}
