import Foundation

/// Checks a Last.fm username and API key against Last.fm before they are saved, and says in plain words what is wrong.
/// The check is the same `user.getInfo` call a sync starts with, so a pair that passes here will sync.
enum LastfmAccountCheck {
    struct Account: Equatable, Sendable {
        /// The name as Last.fm spells it (the typed name may differ in case).
        let username: String
        let scrobbles: Int
    }

    enum Outcome: Equatable, Sendable {
        case valid(Account)
        case invalid(String)
    }

    /// The typed values with stray spaces removed, or the reason they can't be right.
    static func normalize(username: String, apiKey: String) -> (username: String, apiKey: String, problem: String?) {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return (name, key, "Enter your Last.fm username.") }
        if name.contains("@") { return (name, key, "Enter your Last.fm username (the name in your profile address), not an email address.") }
        if name.lowercased().hasPrefix("http") { return (name, key, "Enter just your Last.fm username, not a web address.") }
        if key.isEmpty { return (name, key, "Enter your Last.fm API key.") }
        if key.lowercased().hasPrefix("http") || key.contains(where: \.isWhitespace) {
            return (name, key, "That doesn’t look like an API key. It is a single run of letters and digits, shown at last.fm/api/accounts.")
        }
        return (name, key, nil)
    }

    static func validate(username: String, apiKey: String, session: URLSession = .shared) async -> Outcome {
        let typed = normalize(username: username, apiKey: apiKey)
        if let problem = typed.problem { return .invalid(problem) }
        let client = LastfmAPIClient(apiKey: typed.apiKey, username: typed.username, session: session)
        do {
            let info = try await client.fetchUserInfo()
            return .valid(Account(username: info.name, scrobbles: info.playcount))
        } catch {
            return .invalid(message(for: error, username: typed.username))
        }
    }

    /// What to tell a person about a failed check.
    static func message(for error: Error, username: String) -> String {
        if error is OfflineError { return "Offline mode is on. Go online to check your account." }
        if ConnectivityGate.isConnectivityError(error) { return "Can’t reach Last.fm. Check your internet connection and try again." }
        if let error = error as? LastfmAPIError {
            switch error {
            case .api(let code, let text):
                switch code {
                case 10: return "Last.fm doesn’t recognise this API key. Copy it again from last.fm/api/accounts. It must be the API key, not the shared secret."
                case 26: return "Last.fm has suspended this API key. Register a new one at last.fm/api/account/create."
                case 6: return "Last.fm has no user named “\(username)”. Check the spelling: it is the name in your profile address (last.fm/user/…)."
                case 17: return "Last.fm won’t share this profile’s listening history. In your Last.fm privacy settings, turn off “Hide recent listening information”, then try again."
                case 29: return "Last.fm is limiting requests right now. Wait a minute and try again."
                case 8, 11, 16: return "Last.fm is temporarily unavailable. Try again shortly."
                default: return "Last.fm error \(code): \(text)"
                }
            case .http(let status): return "Last.fm answered with HTTP error \(status). Try again shortly."
            default: break
            }
        }
        return describeSyncError(error)
    }
}
