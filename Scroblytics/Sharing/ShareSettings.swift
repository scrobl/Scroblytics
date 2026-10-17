import Foundation
import SwiftData

/// What the Share popover remembers: the options per kind of card, and the two identity switches for all cards (both off until the
/// person turns one on). Stored in the app's preferences.
enum ShareSettings {
    static let showsNameKey = "share.showsName"
    static let showsFooterKey = "share.showsFooter"
    static let logoKey = "share.lastfmLogo"
    private static func optionsKey(_ kindID: String) -> String { "share.options.\(kindID)" }

    /// What was last chosen for this kind of card, or `fallback` when nothing has been.
    static func options(for kindID: String, fallback: ShareOptions = ShareOptions(), defaults: UserDefaults = .standard) -> ShareOptions {
        guard let data = defaults.data(forKey: optionsKey(kindID)),
              let options = try? JSONDecoder().decode(ShareOptions.self, from: data) else { return fallback }
        return options
    }

    static func save(_ options: ShareOptions, for kindID: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: optionsKey(kindID)) }
    }

    static func showsName(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: showsNameKey) }
    static func showsFooter(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: showsFooterKey) }
    static func logo(defaults: UserDefaults = .standard) -> LastfmLogoStyle {
        defaults.string(forKey: logoKey).flatMap(LastfmLogoStyle.init(rawValue:)) ?? .circle
    }

    /// The identity a card carries: the saved account's name only when the person chose to show it (read from the database, never the
    /// Keychain), the footer only when chosen.
    @MainActor
    static func identity(context: ModelContext, defaults: UserDefaults = .standard) -> ShareIdentity {
        var name: String?
        if showsName(defaults: defaults) {
            name = (try? context.fetch(FetchDescriptor<SyncState>()).first?.username).flatMap { $0.isEmpty ? nil : $0 }
        }
        return ShareIdentity(name: name, showsFooter: showsFooter(defaults: defaults), logo: logo(defaults: defaults))
    }

    /// The saved account's name, for the popover to say whether the switch has anything to show.
    @MainActor
    static func accountName(context: ModelContext) -> String? {
        (try? context.fetch(FetchDescriptor<SyncState>()).first?.username).flatMap { $0.isEmpty ? nil : $0 }
    }
}
