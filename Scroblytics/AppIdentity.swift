import Foundation

/// The app's identity strings, in one place: the bundle identifier, and the label every Keychain item and
/// log subsystem is filed under.
enum AppIdentity {
    static let bundleID = "app.scroblytics.Scroblytics"

    /// Where the privacy policy is published (the repository's `PRIVACY.md`). One definition, used by Help, Settings and the
    /// Help menu, so moving it later (a website, say) is a one-line change.
    static let privacyPolicyURLString = "https://github.com/scrobl/Scroblytics/blob/main/PRIVACY.md"
    static let privacyPolicyURL = URL(string: privacyPolicyURLString)!

    /// A Keychain "service" name for one kind of stored secret (e.g. `keychainService("lastfm")`).
    /// A DEBUG run under a test profile (`TestProfile`) files its items under a profile-specific name, so a first-run
    /// test never reads or writes the real ones.
    static func keychainService(_ kind: String) -> String {
        #if DEBUG
        if let profile = TestProfile.name { return "\(bundleID).\(kind).profile.\(profile)" }
        #endif
        return "\(bundleID).\(kind)"
    }
}
