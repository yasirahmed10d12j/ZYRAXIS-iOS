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
        case camera
        case telegram
        case safari
        case chrome
        case instagram
        case photos
        case settings
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
        return OpenRequest(url: url, label: "Instagram", kind: .instagram)
    }

    /// Fixed WhatsApp front page (universal link, no user input).
    public static func whatsAppHome() -> OpenRequest? {
        guard let url = URL(string: "https://www.whatsapp.com/") else { return nil }
        return OpenRequest(url: url, label: "WhatsApp", kind: .website)
    }

    /// Fixed X front page (universal link, no user input).
    public static func xHome() -> OpenRequest? {
        guard let url = URL(string: "https://x.com/") else { return nil }
        return OpenRequest(url: url, label: "X", kind: .website)
    }

    /// Fixed Facebook front page (universal link, no user input).
    public static func facebookHome() -> OpenRequest? {
        guard let url = URL(string: "https://www.facebook.com/") else { return nil }
        return OpenRequest(url: url, label: "Facebook", kind: .website)
    }

    /// Fixed Snapchat front page (universal link, no user input).
    public static func snapchatHome() -> OpenRequest? {
        guard let url = URL(string: "https://www.snapchat.com/") else { return nil }
        return OpenRequest(url: url, label: "Snapchat", kind: .website)
    }

    /// Camera via system camera app (universal link for photo capture).
    /// Uses `camera://` scheme which opens the system Camera app.
    public static func camera() -> OpenRequest? {
        guard let url = URL(string: "camera://") else { return nil }
        return OpenRequest(url: url, label: "Camera", kind: .camera)
    }

    /// Telegram universal link — opens the Telegram app if installed,
    /// falls back to web. No scheme allowlist needed for HTTPS.
    public static func telegram() -> OpenRequest? {
        guard let url = URL(string: "https://t.me/") else { return nil }
        return OpenRequest(url: url, label: "Telegram", kind: .telegram)
    }

    /// Safari via universal link — opens the default browser (Safari).
    public static func safari() -> OpenRequest? {
        guard let url = URL(string: "https://www.apple.com/safari/") else { return nil }
        return OpenRequest(url: url, label: "Safari", kind: .safari)
    }

    /// Chrome — no direct scheme available on iOS for third-party browsers.
    /// Opens a web page which will launch in the default browser (user's choice).
    public static func chrome() -> OpenRequest? {
        guard let url = URL(string: "https://www.google.com/chrome/") else { return nil }
        return OpenRequest(url: url, label: "Chrome", kind: .chrome)
    }

    /// Photos app via universal link.
    public static func photos() -> OpenRequest? {
        guard let url = URL(string: "photos-redirect://") else { return nil }
        return OpenRequest(url: url, label: "Photos", kind: .photos)
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

    /// Messages composer (no address — the user picks the recipient).
    /// Bare `sms:` is constructed, never displayed as AI output.
    /// Device behavior UNVERIFIED — needs a real iPhone (no public docs
    /// guarantee what bare `sms:` opens).
    public static func messages() -> OpenRequest? {
        guard let url = URL(string: "sms:") else { return nil }
        return OpenRequest(url: url, label: "Messages", kind: .message)
    }

    /// Mail composer (empty draft). Device behavior UNVERIFIED — needs a
    /// real iPhone.
    public static func mailComposer() -> OpenRequest? {
        guard let url = URL(string: "mailto:") else { return nil }
        return OpenRequest(url: url, label: "Mail", kind: .email)
    }

    /// FaceTime app front (no target). Device behavior UNVERIFIED — needs a
    /// real iPhone.
    public static func facetimeHome() -> OpenRequest? {
        guard let url = URL(string: "facetime://") else { return nil }
        return OpenRequest(url: url, label: "FaceTime", kind: .facetime)
    }

    private static func phoneDigits(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let plus = trimmed.hasPrefix("+") ? "+" : ""
        let digits = String(trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map { Character($0) })
        guard digits.count >= 7 else { return nil }
        return plus + digits
    }
}

/// A validated device-system action. Only things iOS lets third-party apps
/// do: screen brightness (settable, no entitlement), relative steps, and the
/// camera flashlight (AVCaptureDevice torch — needs Camera permission, asked
/// on first use).
/// Volume is deliberately absent — iOS offers no public volume-setter API
/// (only MPVolumeView UI), so volume phrases are answered, never executed.
/// The Phone keypad is likewise absent — no public scheme opens it, so
/// "open phone" is answered, never faked.
public enum SystemAction: Equatable, Sendable {
    /// Absolute brightness 0.05...1.0.
    case brightness(Double)
    case brightnessUp
    case brightnessDown
    /// Flashlight on/off (torch). Executed by the UI layer; reports failure
    /// honestly when the device has no torch or Camera is denied.
    case torch(Bool)
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
    /// Validated device-system action (handled by the UI layer).
    case system(SystemAction)
    /// Create a task reminder, optionally at a parsed due date.
    case remind(text: String, dueDate: Date?)
    /// Read back active reminders as an assistant message.
    case myReminders
    /// Save a note to memory ("remember that …"). Shown back as confirmation.
    case remember(String)
    /// Save "<name>'s phone number: <digits>" to memory for call-by-name.
    case rememberPhone(name: String, digits: String)
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
        case "my reminders", "read my reminders", "show my reminders", "my tasks", "show my tasks", "reminders":
            return .myReminders
        case "volume":
            return .answer("Volume can only be changed with the iPhone side buttons — iOS doesn't let apps set it.")
        case "phone", "open phone", "dialer", "open dialer", "keypad", "phone app":
            return .answer("I can't open the Phone keypad — iOS doesn't allow apps to do that. Say \"call\" followed by the number instead.")
        case "flashlight", "torch", "flash":
            return .answer("Say \"flashlight on\" or \"flashlight off\".")
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
        if let system = Self.systemAction(for: norm) {
            return system
        }
        if let remember = Self.rememberAction(for: norm) {
            return remember
        }
        if let remind = Self.reminderAction(for: norm) {
            return remind
        }
        return .none
    }

    /// Brightness (settable API) and the volume honesty answer (no setter API
    /// exists — answered locally so the user learns the real limit at once).
    /// Torch (flashlight) via AVCaptureDevice — executed by the UI layer,
    /// which reports camera-denied/torch-missing honestly.
    static func systemAction(for norm: String) -> FastCommandAction? {
        for phrase in ["flashlight on", "torch on", "flash on", "turn on flashlight", "turn on torch",
                       "turn the flashlight on", "turn on the flashlight", "switch on flashlight"] {
            if norm == phrase { return .system(.torch(true)) }
        }
        for phrase in ["flashlight off", "torch off", "flash off", "turn off flashlight", "turn off torch",
                       "turn the flashlight off", "turn off the flashlight", "switch off flashlight"] {
            if norm == phrase { return .system(.torch(false)) }
        }        if norm == "brightness up" || norm == "increase brightness" || norm == "brighter" {
            return .system(.brightnessUp)
        }
        if norm == "brightness down" || norm == "decrease brightness" || norm == "dim" || norm == "dimmer" {
            return .system(.brightnessDown)
        }
        for prefix in ["set brightness", "brightness"] {
            if let rest = remainder(after: [prefix], in: norm), !rest.isEmpty {
                if let level = brightnessLevel(from: rest) {
                    return .system(.brightness(level))
                }
                return nil
            }
        }
        if norm.contains("volume") && (norm.hasPrefix("set ") || norm.hasPrefix("increase ") || norm.hasPrefix("decrease ") || norm.hasPrefix("turn ") || norm == "volume up" || norm == "volume down" || norm == "mute") {
            return .answer("Volume can only be changed with the iPhone side buttons — iOS doesn't let apps set it.")
        }
        return nil
    }

    /// 0-100 percent or full/half/low/minimum words → 0.05...1.0 (never a
    /// fully black screen from a misheard command).
    static func brightnessLevel(from rest: String) -> Double? {
        let lower = rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "full", "maximum", "max": return 1.0
        case "half", "medium": return 0.5
        case "low": return 0.25
        case "minimum", "min": return 0.1
        default: break
        }
        let digits = lower.filter { $0.isNumber }
        guard let value = Double(digits), !digits.isEmpty else { return nil }
        return min(1.0, max(0.05, value / 100.0))
    }

    /// "remember …" memory commands. Narrow by construction so normal chat
    /// ("remember when…", "do you remember…") always reaches the AI:
    /// - phone-number facts match ANYWHERE — the digits are their own proof
    ///   ("Rehan's number is 03001234567", "remember mom's mobile number is…").
    /// - a named number WITHOUT digits asks for the digits, but only when
    ///   the input also carries a remember/save/note/learn verb (so plain
    ///   questions like "what is mom's number?" still reach the AI/memory).
    /// - generic notes need explicit verbs ("remember that …", "… in memory").
    static func rememberAction(for norm: String) -> FastCommandAction? {
        if let (name, digits) = contactNumberFact(in: norm) {
            return .rememberPhone(name: name, digits: digits)
        }
        if let name = contactNumberMissingDigits(in: norm) {
            let pretty = prettifyName(name)
            return .answer("I don't have \(pretty)'s number yet — say \"\(pretty)'s number is\" followed by the digits and I'll remember it.")
        }
        for prefix in ["remember that ", "remember this ", "note that ", "note down ",
                       "save that ", "don't forget that ", "don't forget to ",
                       "dont forget that ", "dont forget to ", "keep in mind that "] {
            if norm.hasPrefix(prefix) {
                let rest = String(norm.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { return .remember(rest) }
            }
        }
        for verb in ["remember ", "save ", "note "] {
            if norm.hasPrefix(verb) && norm.hasSuffix(" in memory") {
                var rest = String(norm.dropFirst(verb.count))
                for suffix in [" in memory", " to memory", " into memory"] {
                    if rest.hasSuffix(suffix) { rest = String(rest.dropLast(suffix.count)); break }
                }
                rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { return .remember(rest) }
            }
        }
        return nil
    }

    /// "<name>'s [phone|mobile|contact] number is <digits>" or
    /// "my [phone|mobile] number is <digits>". Name is 1–40 chars, digit-free.
    static func contactNumberFact(in norm: String) -> (name: String, digits: String)? {
        guard let regex = try? NSRegularExpression(
            pattern: "([a-z][a-z .'-]*?)'s (?:phone |mobile |contact )?number is (\\+?[\\d][\\d\\s\\-().]{5,}\\d|\\d{7,})"
        ) else { return nil }
        let range = NSRange(norm.startIndex..., in: norm)
        guard let m = regex.firstMatch(in: norm, range: range),
              let nameRange = Range(m.range(at: 1), in: norm),
              let digitRange = Range(m.range(at: 2), in: norm) else { return nil }
        var name = String(norm[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["this is ", "that is ", "it is "] {
            if name.hasPrefix(lead) { name = String(name.dropFirst(lead.count)); break }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = String(norm[digitRange])
        let plus = raw.hasPrefix("+") ? "+" : ""
        let digits = plus + raw.filter { $0.isNumber }
        guard !name.isEmpty, name.count <= 40, !name.contains(where: { $0.isNumber }),
              digits.filter({ $0.isNumber }).count >= 7 else { return nil }
        return (name, digits)
    }

    /// Named number mentioned without digits, gated on a memory verb.
    static func contactNumberMissingDigits(in norm: String) -> String? {
        guard norm.contains("remember") || norm.contains("save")
                || norm.contains("note") || norm.contains("learn") else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: "([a-z][a-z .'-]*?)'s (?:phone |mobile |contact )?number\\b"
        ) else { return nil }
        let range = NSRange(norm.startIndex..., in: norm)
        guard let m = regex.firstMatch(in: norm, range: range),
              let nameRange = Range(m.range(at: 1), in: norm) else { return nil }
        // A fact WITH digits is handled above — only the digit-less case lands here.
        let rest = String(norm[Range(m.range, in: norm)!.upperBound...])
        if rest.filter({ $0.isNumber }).count >= 7 { return nil }
        var name = String(norm[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["this is ", "that is ", "it is ", "this ", "that "] {
            if name.hasPrefix(lead) { name = String(name.dropFirst(lead.count)); break }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains(where: { $0.isNumber }) else { return nil }
        return name
    }

    /// "rehan" → "Rehan" for user-facing confirmations (input is lowercased).
    static func prettifyName(_ name: String) -> String {
        name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "remind me to <text>" [+ "in N minutes|hours"]. Bare "remind me" and
    /// unparseable times fall through to the AI.
    static func reminderAction(for norm: String) -> FastCommandAction? {
        guard norm.hasPrefix("remind me to ") else { return nil }
        let rest = String(norm.dropFirst("remind me to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        let words = rest.lowercased().split(separator: " ").map(String.init)
        if words.count >= 4, words[words.count - 3] == "in",
           let amount = Double(words[words.count - 2]),
           ["minute", "minutes", "hour", "hours"].contains(words[words.count - 1]),
           amount > 0, amount <= 24 * 7 {
            let seconds = words[words.count - 1].hasPrefix("hour") ? amount * 3600 : amount * 60
            let text = words.dropLast(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .remind(text: rest, dueDate: nil) }
            return .remind(text: text, dueDate: Date().addingTimeInterval(seconds))
        }
        return .remind(text: rest, dueDate: nil)
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
        if norm == "messages" || norm == "open messages" || norm == "sms" || norm == "open sms" || norm == "open texts" {
            return OpenRequest.messages()
        }
        if norm == "mail" || norm == "open mail" || norm == "open email" || norm == "email app" {
            return OpenRequest.mailComposer()
        }
        if norm == "facetime" || norm == "open facetime" {
            return OpenRequest.facetimeHome()
        }
        if norm == "open camera" || norm == "camera" || norm == "take photo" || norm == "take picture" {
            return OpenRequest.camera()
        }
        if norm == "open telegram" || norm == "telegram" {
            return OpenRequest.telegram()
        }
        if norm == "open instagram" || norm == "instagram" {
            return OpenRequest.instagram()
        }
        if norm == "open whatsapp" || norm == "whatsapp" {
            return OpenRequest.whatsAppHome()
        }
        if norm == "open safari" || norm == "safari" || norm == "open browser" || norm == "browser" {
            return OpenRequest.safari()
        }
        if norm == "open chrome" || norm == "chrome" {
            return OpenRequest.chrome()
        }
        if norm == "open photos" || norm == "photos" || norm == "gallery" || norm == "open gallery" {
            return OpenRequest.photos()
        }
        if norm == "x" || norm == "open x" || norm == "twitter" || norm == "open twitter" {
            return OpenRequest.xHome()
        }
        if norm == "facebook" || norm == "open facebook" {
            return OpenRequest.facebookHome()
        }
        if norm == "snapchat" || norm == "open snapchat" {
            return OpenRequest.snapchatHome()
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
