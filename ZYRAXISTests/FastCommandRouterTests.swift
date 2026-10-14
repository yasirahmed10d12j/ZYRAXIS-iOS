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

    func testOpenWebsiteCommands() {
        if case .open(let req) = router.route("open example.com") {
            XCTAssertEqual(req.url.absoluteString, "https://example.com")
            XCTAssertEqual(req.kind, .website)
        } else {
            XCTFail("expected open website")
        }
        // "open settings" has no public scheme — must fall through to the AI.
        XCTAssertEqual(router.route("open settings"), .none)
        XCTAssertEqual(router.route("open"), .none)
        XCTAssertEqual(router.route("open foo bar"), .none)
    }

    func testCallTextEmailCommands() {
        if case .open(let req) = router.route("call 5551234567") {
            XCTAssertEqual(req.url.absoluteString, "tel:5551234567")
            XCTAssertEqual(req.kind, .call)
        } else {
            XCTFail("expected open call")
        }
        if case .open(let req) = router.route("text 5551234567") {
            XCTAssertEqual(req.url.absoluteString, "sms:5551234567")
            XCTAssertEqual(req.kind, .message)
        } else {
            XCTFail("expected open text")
        }
        if case .open(let req) = router.route("email a@b.com") {
            XCTAssertEqual(req.url.absoluteString, "mailto:a@b.com")
            XCTAssertEqual(req.kind, .email)
        } else {
            XCTFail("expected open email")
        }
        // Unvalidated direct targets become contact lookups (resolved with
        // honest failure feedback), never blind dials.
        XCTAssertEqual(router.route("call abc"), .callContact("abc"))
        XCTAssertEqual(router.route("call 123"), .callContact("123"))
        XCTAssertEqual(router.route("email nodomain"), .none)
        XCTAssertEqual(router.route("launch safari"), .none)
    }

    func testCallTextWhatsAppContactRouting() {
        XCTAssertEqual(router.route("call mom"), .callContact("mom"))
        XCTAssertEqual(router.route("text mom"), .messageContact("mom"))
        XCTAssertEqual(router.route("message dad"), .messageContact("dad"))
        XCTAssertEqual(router.route("whatsapp mom"), .whatsAppContact("mom"))
        XCTAssertEqual(router.route("call"), .none)
        XCTAssertEqual(router.route("text"), .none)
        // Pure digits still open directly without a contact lookup.
        if case .open(let req) = router.route("call 5551234567") {
            XCTAssertEqual(req.kind, .call)
        } else {
            XCTFail("expected direct call open")
        }
        if case .open(let req) = router.route("whatsapp 15551234567") {
            XCTAssertEqual(req.url.absoluteString, "https://wa.me/15551234567")
            XCTAssertEqual(req.kind, .whatsApp)
        } else {
            XCTFail("expected direct whatsapp open")
        }
    }

    func testInstagramWhatsAppFrontPages() {
        if case .open(let req) = router.route("open instagram") {
            XCTAssertEqual(req.url.absoluteString, "https://www.instagram.com/")
        } else {
            XCTFail("expected instagram")
        }
        if case .open(let req) = router.route("open whatsapp") {
            XCTAssertEqual(req.url.absoluteString, "https://www.whatsapp.com/")
        } else {
            XCTFail("expected whatsapp home")
        }
    }

    func testMapsFaceTimeAppStoreCommands() {
        if case .open(let req) = router.route("directions to paris") {
            XCTAssertEqual(req.url.host ?? "", "maps.apple.com")
            XCTAssertEqual(req.kind, .maps)
        } else {
            XCTFail("expected open maps")
        }
        if case .open(let req) = router.route("facetime 5551234567") {
            XCTAssertTrue(req.url.absoluteString.hasPrefix("facetime://"))
            XCTAssertEqual(req.kind, .facetime)
        } else {
            XCTFail("expected open facetime")
        }
        if case .open(let req) = router.route("open app store") {
            XCTAssertEqual(req.url.scheme ?? "", "itms-apps")
            XCTAssertEqual(req.kind, .appStore)
        } else {
            XCTFail("expected open app store")
        }
    }

    func testYouTubeUsesHTTPSUniversalLinks() {
        // The observed failure: no youtube:// custom scheme anywhere — the
        // universal link opens the app when installed, Safari otherwise.
        if case .open(let req) = router.route("open youtube") {
            XCTAssertEqual(req.url.absoluteString, "https://www.youtube.com/")
            XCTAssertEqual(req.kind, .youTube)
        } else {
            XCTFail("expected open youtube")
        }
        if case .open(let req) = router.route("youtube") {
            XCTAssertEqual(req.url.absoluteString, "https://www.youtube.com/")
            XCTAssertEqual(req.kind, .youTube)
        } else {
            XCTFail("expected bare youtube")
        }
        if case .open(let req) = router.route("youtube cats") {
            XCTAssertEqual(req.url.host ?? "", "www.youtube.com")
            XCTAssertTrue(req.url.absoluteString.contains("search_query=cats"))
            XCTAssertEqual(req.kind, .youTube)
        } else {
            XCTFail("expected youtube search")
        }
        // Misspellings and empty queries stay out of the allowlist.
        XCTAssertEqual(router.route("open youtub"), .none)
        XCTAssertEqual(router.route("youtube"), .open(OpenRequest.youTubeHome()!))
    }

    func testContactServiceNormalizedDigits() {
        XCTAssertEqual(SystemContactService.normalizedDigits("+1 (555) 123-4567"), "15551234567")
        XCTAssertEqual(SystemContactService.normalizedDigits("5551234567"), "5551234567")
        XCTAssertNil(SystemContactService.normalizedDigits("123"))
        XCTAssertNil(SystemContactService.normalizedDigits("mom"))
        XCTAssertNil(SystemContactService.normalizedDigits(""))
    }
}

/// Contact lookup tests use a spy (no address-book access in unit tests).
/// Shared across test files in this target.
final class SpyContactService: ContactService {
    var permissionGranted = true
    var numbersByName: [String: String] = [:]
    var requestedPermission = false

    func requestPermission() async -> Bool {
        requestedPermission = true
        return permissionGranted
    }

    func phoneNumber(for name: String) async -> String? {
        numbersByName[name.lowercased()]
    }
}
