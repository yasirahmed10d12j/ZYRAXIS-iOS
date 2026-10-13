import SwiftUI

/// ZYRAXIS application entry point. SwiftUI App lifecycle, iOS 17+.
///
/// Explicitly `@MainActor`: the dependency graph is MainActor-isolated, so the
/// entry point must be too — otherwise `makeDefault()` is unreachable from the
/// property initializer under strict (Swift 6) concurrency checking.
@main @MainActor
public struct ZYRAXISApp: App {

    @StateObject private var dependencies = AppDependencies.makeDefault()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainAssistantView()
                .environmentObject(dependencies)
                .preferredColorScheme(colorScheme(for: dependencies.settings.appearance))
        }
    }

    private func colorScheme(for appearance: SettingsStore.Appearance) -> ColorScheme? {
        switch appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
