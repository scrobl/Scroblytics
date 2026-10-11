import SwiftUI

/// Settings › Tempo: the optional GetSongBPM key and the credit its free tier requires. The key goes to the Keychain
/// only. Without one, tempos still come from Deezer.
struct TempoSettingsView: View {
    @State private var keyDraft = ""
    @State private var savedKey = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isTesting = false
    @AppStorage(BPMEngine.backgroundLookupsKey) private var backgroundLookups = true

    var body: some View {
        Form {
            Section("Tempo sources") {
                Text("A track’s tempo (BPM) is looked up on GetSongBPM first, then on Deezer. A tempo you enter on the track page always wins. GetSongBPM finds more tracks and adds time signature and key. The app includes its own GetSongBPM key; you can use your own below instead.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
                HelpLinkButton(articleID: "tempo-lookup", title: "How tempo lookup works")
            }
            Section("Background lookups") {
                Toggle("Look up tempos in the background", isOn: $backgroundLookups)
                Text("Works slowly through your most-played tracks that have no tempo yet, behind anything you open. Progress shows in the status line. Turn it off to look tempos up only when you open a track or click Resolve.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
            Section("Your own GetSongBPM key (optional)") {
                HStack {
                    SecureField("API key", text: $keyDraft, prompt: Text(savedKey ? "Saved in your Keychain" : (GetSongBPMKeychain.builtInKey != nil ? "using the built-in key" : "paste your key")))
                    Button("Save") { save() }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove", role: .destructive) {
                        GetSongBPMKeychain.removeKey()
                        BPMEngine.keyChanged()
                        refresh()
                        report(GetSongBPMKeychain.builtInKey != nil ? "Key removed. The built-in key is used again." : "Key removed. Tempos will come from Deezer alone.", error: false)
                    }
                    .disabled(!savedKey)
                }
                HStack {
                    Button("Test") { Task { await test() } }.disabled(GetSongBPMKeychain.activeKey() == nil || isTesting || ConnectivityGate.isOffline)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let status {
                        Text(status).font(AppTypography.supportingDense).foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    }
                }
                Link("Request a key at getsongbpm.com/api", destination: URL(string: "https://getsongbpm.com/api")!)
                    .font(AppTypography.supporting)
            }
            Section("Credit") {
                HStack(spacing: 4) {
                    Text("Tempo data from")
                    Link("GetSongBPM.com", destination: URL(string: "https://getsongbpm.com")!)
                    Text("and Deezer.")
                }
                .font(AppTypography.supporting)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() { savedKey = GetSongBPMKeychain.hasKey }

    private func report(_ text: String, error: Bool) { status = text; statusIsError = error }

    private func save() {
        do {
            try GetSongBPMKeychain.setKey(keyDraft)
            keyDraft = ""
            BPMEngine.keyChanged()
            refresh()
            report("Key saved to your Keychain.", error: false)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    /// One real lookup of a well-known track, so a wrong key is reported instead of silently falling back to Deezer.
    private func test() async {
        guard let key = GetSongBPMKeychain.activeKey() else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            if let found = try await GetSongBPMClient(apiKey: key).fetchFeatures(artist: "The Weeknd", track: "Blinding Lights") {
                report("The key works. Test lookup returned \(BPMEngine.format(found.bpm)) BPM.", error: false)
            } else {
                report("The key was accepted, but the test lookup found nothing.", error: false)
            }
        } catch {
            report(error.localizedDescription, error: true)
        }
    }
}
