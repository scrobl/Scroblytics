import SwiftUI
import SwiftData

extension Notification.Name {
    static let scrobbleSyncDidComplete = Notification.Name("ScrobbleSyncDidComplete")
    /// Posted every ~30 s while a full-history sync is landing scrobbles — the library is bigger than it was.
    static let scrobbleSyncDidProgress = Notification.Name("ScrobbleSyncDidProgress")
    static let targetedSyncDidStart = Notification.Name("TargetedSyncDidStart")
    static let targetedSyncDidFinish = Notification.Name("TargetedSyncDidFinish")
    /// Posted when the Last.fm credentials are saved or removed, so screens and background polling that depend on
    /// them (Now Playing, Overview's Last.fm-backed cards) pick the change up straight away.
    static let lastfmCredentialsDidChange = Notification.Name("LastfmCredentialsDidChange")
}

/// Settings › Sync: the Last.fm account (username and API key) and the optional write access ("Track Actions").
/// Syncing itself lives in the toolbar and the Library menu.
struct SyncSetupView: View {
    @State private var form = LastfmAccountForm()
    @State private var hasSavedCredentials = false
    /// Set when an account is probably saved but the Keychain wouldn't give it up (see `CredentialsProblemText`).
    @State private var readProblem: OSStatus?

    // MARK: - Track Actions (write access)

    @State private var hasSecret = false
    @State private var isConnected = false
    @State private var secretInput = ""
    @State private var pendingAuthToken: String?
    @State private var isSavingSecret = false
    @State private var isConnecting = false
    @State private var isFinishingConnect = false
    @State private var isDisconnectingWrite = false
    @State private var trackActionsError: String?
    @State private var showRemoveAccountConfirmation = false

    var body: some View {
        Form {
            Section("Last.fm Account") {
                TextField("Username", text: $form.username)
                    .textFieldStyle(.roundedBorder)
                TextField("API Key", text: $form.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.codeInput)
                Text("Get a free API key at last.fm/api/account/create — the sync layer has no bundled key of its own.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
                HelpLinkButton(articleID: "lastfm-account", title: "What these are and where they’re stored")
                if let readProblem, !hasSavedCredentials {
                    Label("\(CredentialsProblemText.headline) \(CredentialsProblemText.reason(readProblem)) \(CredentialsProblemText.guidance(readProblem))", systemImage: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                        .font(AppTypography.supporting)
                    Button("Try Again") {
                        LastfmCredentialsStore.dropCache()
                        loadCredentials()
                    }
                }
                HStack {
                    Button("Test & Save") { Task { await testAndSave() } }
                        .disabled(!form.canSubmit)
                    if form.isChecking { ProgressView().controlSize(.small) }
                }
                switch form.phase {
                case .idle, .checking:
                    EmptyView()
                case .saved(let account):
                    Label("Found \(account.scrobbles.formatted()) scrobbles for “\(account.username)”. Saved; importing now.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(AppTypography.supporting)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(AppTypography.supporting)
                        .textSelection(.enabled)
                }
                if hasSavedCredentials {
                    if form.phase == .idle {
                        Label("Credentials saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(AppTypography.supporting)
                    }
                    Button("Remove Account…", role: .destructive) { showRemoveAccountConfirmation = true }
                }
            }

            if hasSavedCredentials {
                Section("Track Actions") {
                    trackActionsContent
                    HelpLinkButton(articleID: "track-actions", title: "What Track Actions changes on Last.fm")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { loadCredentials() }
        .confirmationDialog("Remove your Last.fm account from this Mac?", isPresented: $showRemoveAccountConfirmation, titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) { removeAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scroblytics forgets your username, API key and write access. Your synced history, loved tracks, edits and everything else on this Mac are kept, and the authorization you gave Last.fm is not revoked (you can do that in your Last.fm account settings). You can add the account again at any time.")
        }
    }

    /// Forgets the credentials only; nothing in the local database is touched.
    private func removeAccount() {
        LastfmCredentialsStore.clear()
        form.reset()
        hasSavedCredentials = false
        hasSecret = false
        isConnected = false
        secretInput = ""
        pendingAuthToken = nil
        trackActionsError = nil
        NotificationCenter.default.post(name: .lastfmCredentialsDidChange, object: nil)
    }

    private func loadCredentials() {
        let saved = LastfmCredentialsStore.load()
        readProblem = saved == nil ? LastfmCredentialsStore.lastProblem : nil
        if let saved {
            form.loadSaved()
            hasSavedCredentials = true
            hasSecret = saved.apiSecret != nil
            isConnected = saved.sessionKey != nil
        }
    }

    /// Checks the username and key with Last.fm first; only a working pair is saved, and saving starts the import.
    private func testAndSave() async {
        guard await form.testAndSave() else { return }
        let saved = LastfmCredentialsStore.load()
        hasSavedCredentials = true
        hasSecret = saved?.apiSecret != nil
        isConnected = saved?.sessionKey != nil
    }

    // MARK: - Track Actions (write access)

    /// Optional "Connect" action, separate from the base read-only account
    /// above: love/unlove and tag
    /// writes need a signed session key on top of the plain API key, obtained
    /// through Last.fm's own desktop auth flow (getToken -> browser approval
    /// -> getSession), never a pasted password. Three states, one at a time:
    /// no secret saved yet, secret saved but not yet connected, or connected.
    @ViewBuilder
    private var trackActionsContent: some View {
        if isConnected {
            Label("Track actions are enabled — you can add or remove your tags on artists, albums, and tracks.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(AppTypography.supporting)
            Button("Disconnect Track Actions") { Task { await disconnectTrackActions() } }
                .disabled(isDisconnectingWrite)
        } else if !hasSecret {
            Text("Connect write access to add or remove your own tags on artists, albums, and tracks. Your ALREADY-REGISTERED API account's page also shows a \"Shared secret\" for the key above — copy that below.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            Button("View my API accounts") { openAPIKeyPage() }
            SecureField("API Secret", text: $secretInput)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.codeInput)
            Button("Save Secret") { Task { await saveSecret() } }
                .disabled(isSavingSecret || secretInput.trimmingCharacters(in: .whitespaces).isEmpty)
        } else if let pendingAuthToken {
            Text("Approve access in the browser tab that just opened, then come back and click below.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("I've approved access") { Task { await finishConnect(token: pendingAuthToken) } }
                    .disabled(isFinishingConnect)
                Button("Cancel") { self.pendingAuthToken = nil }
            }
        } else {
            Button("Connect") { Task { await startConnect() } }
                .disabled(isConnecting || Connectivity.shared.isOffline)
                .help(Connectivity.shared.isOffline ? "Offline mode is on. Go online to connect." : "")
        }

        if let trackActionsError {
            Text(trackActionsError)
                .font(AppTypography.supporting)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// Deliberately NOT `.../api/account/create` — that page registers a brand-NEW key+secret pair,
    /// which would orphan the key already saved above rather than surface
    /// its existing secret. `.../api/accounts` lists already-registered
    /// applications, which is what an account that already has a key (this
    /// app's only path — see `testAndSave`) actually needs.
    private func openAPIKeyPage() {
        if let url = URL(string: "https://www.last.fm/api/accounts") {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveSecret() async {
        let secret = secretInput.trimmingCharacters(in: .whitespaces)
        guard !secret.isEmpty, var credentials = LastfmCredentialsStore.load() else { return }
        isSavingSecret = true
        trackActionsError = nil
        credentials.apiSecret = secret
        do {
            try LastfmCredentialsStore.save(credentials)
            secretInput = ""
            hasSecret = true
        } catch {
            trackActionsError = "Failed to save secret: \(describeSyncError(error))"
        }
        isSavingSecret = false
    }

    /// Step 1-2 of the desktop auth flow: request a token, then open the
    /// Last.fm page the user must approve in a browser before `finishConnect`
    /// (step 3) can exchange it for a session key.
    private func startConnect() async {
        guard let credentials = LastfmCredentialsStore.load(), let secret = credentials.apiSecret else {
            trackActionsError = "Save your Last.fm API secret first."
            return
        }
        isConnecting = true
        trackActionsError = nil
        do {
            let token = try await LastfmWriteClient.getAuthToken(apiKey: credentials.apiKey, secret: secret)
            NSWorkspace.shared.open(LastfmWriteClient.authURL(apiKey: credentials.apiKey, token: token))
            pendingAuthToken = token
        } catch {
            trackActionsError = "Failed to start connect: \(describeSyncError(error))"
        }
        isConnecting = false
    }

    /// Step 3: exchange the now-approved token for a permanent session key.
    private func finishConnect(token: String) async {
        guard var credentials = LastfmCredentialsStore.load(), let secret = credentials.apiSecret else {
            trackActionsError = "Save your Last.fm API secret first."
            return
        }
        isFinishingConnect = true
        trackActionsError = nil
        do {
            let sessionKey = try await LastfmWriteClient.getAuthSession(apiKey: credentials.apiKey, secret: secret, token: token)
            credentials.sessionKey = sessionKey
            try LastfmCredentialsStore.save(credentials)
            pendingAuthToken = nil
            isConnected = true
        } catch {
            trackActionsError = "Failed to finish connect: \(describeSyncError(error))"
        }
        isFinishingConnect = false
    }

    /// Clears write access (secret + session key) without disconnecting the
    /// base read-only account, so reconnecting
    /// later requires re-entering the secret rather than silently keeping a
    /// stale one around.
    private func disconnectTrackActions() async {
        guard var credentials = LastfmCredentialsStore.load() else { return }
        isDisconnectingWrite = true
        credentials.apiSecret = nil
        credentials.sessionKey = nil
        do {
            try LastfmCredentialsStore.save(credentials)
            hasSecret = false
            isConnected = false
            pendingAuthToken = nil
        } catch {
            trackActionsError = "Failed to disconnect: \(describeSyncError(error))"
        }
        isDisconnectingWrite = false
    }
}
