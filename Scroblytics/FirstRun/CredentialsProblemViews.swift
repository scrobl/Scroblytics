import Security
import SwiftUI

/// What to tell someone when the Keychain wouldn't give up the saved Last.fm account: why (from the macOS status), and what to do.
enum CredentialsProblemText {
    static let headline = "Scroblytics can’t read your Last.fm account from the Keychain."

    /// Why, in a short sentence.
    static func reason(_ status: OSStatus) -> String {
        switch status {
        case errSecInteractionNotAllowed: "Your login keychain is locked."
        case errSecAuthFailed, errSecUserCanceled: "Access to the saved account was refused."
        case errSecDecode: "The saved account couldn’t be understood."
        case errSecNotAvailable, errSecNoSuchKeychain: "The Keychain isn’t available."
        default: "macOS reported error \(status)."
        }
    }

    /// What to try, for that reason.
    static func guidance(_ status: OSStatus) -> String {
        switch status {
        case errSecInteractionNotAllowed:
            "Unlock your login keychain (in Keychain Access, or by signing out and in again), then press Try Again."
        case errSecAuthFailed, errSecUserCanceled:
            "Press Try Again, and choose Allow or Always Allow when macOS asks."
        case errSecDecode:
            "Press Set Up Again to enter your account again. Your imported history is not affected."
        default:
            "Press Try Again. If it keeps happening, use Set Up Again to enter your account again."
        }
    }

    /// One line for the strip under the toolbar, once there is history to work with.
    static func stripText(_ status: OSStatus) -> String {
        "Can’t read your Last.fm account from the Keychain, so syncing and lookups are paused. \(reason(status))"
    }

    /// The same, for a sync that was asked for.
    static let syncError = "Scroblytics couldn’t read your Last.fm account from the Keychain. Unlock it and try again."
}

/// Shown in place of the welcome screen when there is no history and the Keychain can't be read: an account is probably saved, so
/// "welcome, set up an account" would be wrong.
struct CredentialsUnreadableView: View {
    let status: OSStatus
    let onTryAgain: () -> Void
    let onSetUpAgain: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            #if DEBUG
            TestProfileStrip()
            #endif
            VStack(spacing: 18) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(CredentialsProblemText.headline)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                VStack(spacing: 6) {
                    Text(CredentialsProblemText.reason(status)).font(.title3)
                    Text(CredentialsProblemText.guidance(status)).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Try Again", action: onTryAgain)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Set Up Again…", action: onSetUpAgain)
                }
                HStack(spacing: 16) {
                    HelpLinkButton(articleID: "lastfm-account", title: "About your saved account")
                    Button("Open the app anyway", action: onContinue).buttonStyle(.link)
                }
                .font(.callout)
                Text("Your imported history isn’t affected.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 520)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The one line under the toolbar when history is already imported but the account can't be read.
struct CredentialsProblemStrip: View {
    @Environment(HistoryStatus.self) private var history: HistoryStatus?

    var body: some View {
        if let history, let status = history.credentialsProblem, history.scrobbleCount > 0 {
            CredentialsProblemBar(status: status, onTryAgain: { history.retryCredentials() })
        }
    }
}

struct CredentialsProblemBar: View {
    let status: OSStatus
    let onTryAgain: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
            Text(CredentialsProblemText.stripText(status)).lineLimit(2)
            Spacer(minLength: 12)
            Button("Try Again", action: onTryAgain)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
