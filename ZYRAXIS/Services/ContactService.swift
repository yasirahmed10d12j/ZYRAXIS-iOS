import Foundation
import Contacts

/// Contact lookup for call/text/WhatsApp-by-name commands.
///
/// - Lookup runs only when the user issues such a command; nothing is
///   preloaded, synced, or stored. Names/numbers stay on device except inside
///   the `tel:`/`sms:`/`wa.me` URL the user explicitly requested.
/// - `requestPermission()` must be granted first (drives the iOS Contacts
///   prompt; requires `NSContactsUsageDescription` in Info.plist — the app
///   crashes without it, so the key ships with the target).
/// - First match with a usable phone number wins; multiples are a documented
///   limitation (use a more specific name).
///
/// Concurrency note: intentionally NOT `Sendable`-constrained (mirrors
/// `AIService`/`STTProvider`); the concrete type is `@MainActor`-bound.
public protocol ContactService {
    func requestPermission() async -> Bool
    func phoneNumber(for name: String) async -> String?
}

/// System-contacts implementation. `CNContactStore` calls stay on MainActor.
@MainActor
public final class SystemContactService: ContactService {

    private let store = CNContactStore()

    public init() {}

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    public func phoneNumber(for name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
        ] as [CNKeyDescriptor]
        guard let matches = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: trimmed),
            keysToFetch: keys
        ) else { return nil }
        for contact in matches {
            guard let raw = contact.phoneNumbers.first?.value.stringValue,
                  let digits = Self.normalizedDigits(raw) else { continue }
            return digits
        }
        return nil
    }

    /// Digits-only phone number (no spaces, dashes, or `+`), 7+ digits.
    /// Pure function of its arguments (no actor state), so `nonisolated`:
    /// callable from nonisolated test contexts. Unit-testable without contacts access.
    public nonisolated static func normalizedDigits(_ raw: String) -> String? {
        let digits = String(
            raw.unicodeScalars
                .filter { CharacterSet.decimalDigits.contains($0) }
                .map { Character($0) }
        )
        return digits.count >= 7 ? digits : nil
    }
}
