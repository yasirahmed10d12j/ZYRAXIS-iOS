import Foundation

/// Mic actions a fast command can request. Executed by the UI layer
/// (which owns VoiceManager) — the router itself touches no hardware.
public enum FastCommandMicAction: Equatable, Sendable {
    case enableMic
    case disableMic
}

/// A validated request to open an external destination. Only Apple-supported
/// URL schemes and universal (https) links can be constructed — anything else
/// is nil. In particular there is NO way to open iOS Settings or arbitrary
/// third-party apps by name (sandbox; `prefs:root` is private API and
/// `canOpenURL` needs declared schemes), so those inputs stay `.none` and
/// fall through to the AI.
public struct OpenRequest: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case website
        case call
        case message
        case email
        case maps
        case facetime
        case appStore
        case youTube
        case whatsApp
    }

    public var url: URL
    public var label: String
    public var kind: Kind

    /// https://host — host must be a bare dotted hostname (no spaces).
    public static func website(_ rawHost: String) -> OpenRequest? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("https://") { host = String(host.dropFirst("https://".count)) }
        else if host.hasPrefix("http://") { host = String(host.dropFirst("http://".count)) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, host.count <= 253, host.contains("."),
              !host.contains(" "), host.first != ".", host.last != ".", host.first != "-",
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        guard let url = URL(string: "https://\(host)") else { return nil }
        return OpenRequest(url: url, label: "website \(host)", kind: .website)
    }

    /// tel: digits (7+ digits; leading + kept).
    public static func call(_ raw: String) -> OpenRequest? {
        guard let digits = phoneDigits(from: raw) else { return nil }
        guard let url = URL(string: "tel:\(digits)") else { return nil }
        return OpenRequest(url: url, label: "call \(digits)", kind: .call)
    }

    /// sms: digits.
    public static func message(_ raw: String) -> OpenRequest? {
        guard let digits = phoneDigits(from: raw) else { return nil }
        guard let url = URL(string: "sms:\(digits)") else { return nil }
        return OpenRequest(url: url, label: "text \(digits)", kind: .message)
    }

    /// mailto: basic user@host.tld shape.
    public static func email(_ raw: String) -> OpenRequest? {
        let addr = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !addr.isEmpty,
              addr.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil,
              let url = URL(string: "mailto:\(addr)") else { return nil }
        return OpenRequest(url: url, label: "email \(addr)", kind: .email)
    }

    /// Apple Maps universal link for a place query.
    public static func maps(query rawQuery: String) -> OpenRequest? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://maps.apple.com/?q=\(encoded)") else { return nil }
        return OpenRequest(url: url, label: "map search", kind: .maps)
    }

    /// facetime: digits or email.
    public static func facetime(_ raw: String) -> OpenRequest? {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        if let digits = phoneDigits(from: target) {
            guard let url = URL(string: "facetime://\(digits)") else { return nil }
            return OpenRequest(url: url, label: "FaceTime call", kind: .facetime)
        }
        guard target.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil,
              let url = URL(string: "facetime://\(target)") else { return nil }
        return OpenRequest(url: url, label: "FaceTime call", kind: .facetime)
    }

    /// Fixed App Store front (no user input — nothing to validate).
    public static func appStore() -> OpenRequest? {
        guard let url = URL(string: "itms-apps://apps.apple.com") else { return nil }
        return OpenRequest(url: url, label: "App Store", kind: .appStore)
    }

    /// WhatsApp chat as a universal link (`wa.me/<digits>` — digits only, no
    /// `+`/spaces). Opens the chat in WhatsApp when installed, else the web
    /// fallback. The message itself is still typed and sent by the user —
    /// iOS never sends messages without confirmation.
    public static func whatsApp(_ rawDigits: String) -> OpenRequest? {
        let digits = rawDigits.filter { $0.isNumber }
        guard digits.count >= 7,
              let url = URL(string: "https://wa.me/\(digits)") else { return nil }
        return OpenRequest(url: url, label: "WhatsApp chat", kind: .whatsApp)
    }

    /// Fixed Instagram front page (universal link, no user input).
    public static func instagram() -> OpenRequest? {
        guard let url = URL(string: "https://www.instagram.com/") else { return nil }
        return OpenRequest(url: url, label: "Instagram", kind: .website)
    }

    /// Fixed WhatsApp front page (universal link, no user input).
    public static func whatsAppHome() -> OpenRequest? {
        guard let url = URL(string: "https://www.whatsapp.com/") else { return nil }
        return OpenRequest(url: url, label: "WhatsApp", kind: .website)
    }

    /// YouTube via HTTPS universal links ONLY — deliberately never the
    /// `youtube://` custom scheme. A universal link opens the YouTube app
    /// when installed and falls back to Safari otherwise, so there is no
    /// launch-failure mode for a missing app and no scheme allowlist entry
    /// is required. That is the whole fix for the "Open YouTube" failure:
    /// the old path let the AI emit an unvalidatable `youtube://` link.
    public static func youTubeHome() -> OpenRequest? {
        guard let url = URL(string: "https://www.youtube.com/") else { return nil }
        return OpenRequest(url: url, label: "YouTube", kind: .youTube)
    }

    /// YouTube search as a universal link (`results?search_query=`).
    public static func youTubeSearch(_ rawQuery: String) -> OpenRequest? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") else { return nil }
        return OpenRequest(url: url, label: "YouTube search", kind: .youTube)
    }

    private static func phoneDigits(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let plus = trimmed.hasPrefix("+") ? "+" : ""
        let digits = String(trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map { Character($0) })
        guard digits.count >= 7 else { return nil }
        return plus + digits
    }
}

/// Result of fast-path routing: either a locally-handled outcome or
/// `.none`, meaning "send to the AI backend normally".
public enum FastCommandAction: Equatable, Sendable {
    /// Answer computed on-device (clock facts). Never presented as AI output.
    case answer(String)
    case cancelCurrent
    case mic(FastCommandMicAction)
    /// Open a validated external destination (handled by the UI layer, which
    /// owns UIApplication). Never fabricated: nil validation stays `.none`.
    case open(OpenRequest)
    /// Call/text/WhatsApp a contact by name (resolved against iOS contacts
    /// by the engine; unresolvable names report an error, never dial).
    case callContact(String)
    case messageContact(String)
    case whatsAppContact(String)
    case none
}

/// Low-latency local command path. Safe, read-only device facts and session
/// controls bypass AI processing entirely:
///
/// time, date, stop/cancel, mic on/off, and validated open-URL commands.
///
/// Matching is deliberately EXACT for facts/controls (normalized whole input)
/// so normal conversation ("what time does the store open?") always reaches
/// the AI; open commands use explicit verb prefixes below. Anything
/// unvalidated (including "open settings" — no public scheme exists) falls
/// through as `.none`. No unsafe device actions exist here.
public struct FastCommandRouter: Sendable {

    public init() {}

    public func route(_ text: String) -> FastCommandAction {
        let norm = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[?!.,]+$", with: "", options: .regularExpression)

        switch norm {
        case "stop", "cancel", "stop listening", "cancel request", "abort":
            return .cancelCurrent
        case "mic on", "microphone on", "unmute", "start listening", "enable mic":
            return .mic(.enableMic)
        case "mic off", "microphone off", "mute", "stop mic", "disable mic":
            return .mic(.disableMic)
        case "time", "what time is it", "current time", "tell me the time", "what's the time":
            return .answer("The current time is \(Self.timeString()).")
        case "date", "what date is it", "current date", "today's date", "what is today's date", "what day is it":
            return .answer("Today is \(Self.dateString()).")
        default:
            break
        }
        if let open = Self.openRequest(for: norm) {
            return .open(open)
        }
        // Contact names (digits handled as direct opens above): resolved
        // against iOS contacts by the engine with honest failure feedback.
        if let contact = Self.contactAction(for: norm) {
            return contact
        }
        return .none
    }

    /// Contact-name fallback for call/text/whatsapp. Bare verbs yield nil
    /// (fall through to the AI, as before).
    static func contactAction(for norm: String) -> FastCommandAction? {
        if let rest = remainder(after: ["call"], in: norm), !rest.isEmpty {
            return .callContact(rest)
        }
        if let rest = remainder(after: ["text", "message"], in: norm), !rest.isEmpty {
            return .messageContact(rest)
        }
        if let rest = remainder(after: ["whatsapp"], in: norm), !rest.isEmpty {
            if let direct = OpenRequest.whatsApp(rest) {
                return .open(direct)
            }
            return .whatsAppContact(rest)
        }
        return nil
    }

    /// Prefix-intent open commands. Specific fixed phrases first, generic
    /// `open <host>` last (its validation rejects non-hosts like "settings").
    static func openRequest(for norm: String) -> OpenRequest? {
        if norm == "open app store" || norm == "app store" {
            return OpenRequest.appStore()
        }
        if norm == "instagram" || norm == "open instagram" {
            return OpenRequest.instagram()
        }
        if norm == "whatsapp" || norm == "open whatsapp" {
            return OpenRequest.whatsAppHome()
        }
        if norm == "youtube" || norm == "open youtube" {
            return OpenRequest.youTubeHome()
        }
        if let rest = remainder(after: ["search youtube for", "open youtube", "youtube"], in: norm) {
            return OpenRequest.youTubeSearch(rest)
        }
        if let rest = remainder(after: ["directions to", "navigate to", "show map of", "map of", "maps"], in: norm) {
            return OpenRequest.maps(query: rest)
        }
        if let rest = remainder(after: ["facetime"], in: norm) {
            return OpenRequest.facetime(rest)
        }
        if let rest = remainder(after: ["call"], in: norm) {
            return OpenRequest.call(rest)
        }
        if let rest = remainder(after: ["text", "message"], in: norm) {
            return OpenRequest.message(rest)
        }
        if let rest = remainder(after: ["email"], in: norm) {
            return OpenRequest.email(rest)
        }
        if let rest = remainder(after: ["open website", "open site", "open", "go to"], in: norm) {
            return OpenRequest.website(rest)
        }
        return nil
    }

    /// Remainder after a whole-word verb prefix, or nil when absent.
    /// A bare verb with no argument yields "" (validation then rejects it).
    private static func remainder(after prefixes: [String], in norm: String) -> String? {
        for prefix in prefixes {
            if norm == prefix { return "" }
            if norm.hasPrefix(prefix + " ") {
                return String(norm.dropFirst(prefix.count + 1))
            }
        }
        return nil
    }

    // MARK: - Formatters (real device clock)

    private static func timeString(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    private static func dateString(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.timeStyle = .none
        f.dateStyle = .full
        return f.string(from: date)
    }
}
