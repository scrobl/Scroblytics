import SwiftUI

#if DEBUG
/// Debug › Test Profiles…: start the app as a brand-new user would meet it, in a separate copy with its own empty
/// database, preferences and Keychain items, so your real data is never touched.
struct TestProfilesView: View {
    @State private var launcher = TestProfileLauncher.shared
    @State private var newName = "first-run"
    @State private var scenario: String?
    @State private var seedAccount = true
    @State private var errorMessage: String?
    @State private var resetCandidate: String?

    private var nameIsValid: Bool { TestProfile.isValid(name: newName) }
    private var scenarioDetail: String {
        launcher.scenarios.first { $0.name == scenario }?.detail ?? "Talks to the real Last.fm. You enter your own username and API key in the profile."
    }

    var body: some View {
        Form {
            Section {
                Text("Opens a separate copy of Scroblytics with its own empty database, preferences and Keychain items. Your real library and settings are never touched. The copy has a yellow “TEST PROFILE” strip across the top.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Start") {
                TextField("Profile name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { launch(newName) }
                if !nameIsValid && !newName.isEmpty {
                    Text("Use lowercase letters, digits and hyphens.").font(.caption).foregroundStyle(.red)
                }
                Picker("Last.fm", selection: $scenario) {
                    Text("Real Last.fm (enter your own key)").tag(String?.none)
                    Divider()
                    ForEach(launcher.scenarios) { Text("Stand-in: \($0.name)").tag(Optional($0.name)) }
                }
                Text(scenarioDetail).font(.caption).foregroundStyle(.secondary)
                Toggle("Pre-fill a made-up account", isOn: $seedAccount)
                    .disabled(scenario == nil)
                    .help("Saves made-up credentials in the profile so it starts syncing straight away. Leave it off to try typing them in yourself.")
                Button("Start Profile") { launch(newName) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!nameIsValid || launcher.isWorking || launcher.running.contains(newName))
            }

            if !launcher.profiles.isEmpty {
                Section("Existing profiles") {
                    ForEach(launcher.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.body.weight(.medium))
                                if launcher.running.contains(profile.name) {
                                    Text("Running").font(.caption).foregroundStyle(.green)
                                } else if let modified = profile.modified {
                                    Text("Last used \(modified.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Start") { launch(profile.name) }
                                .disabled(launcher.isWorking || launcher.running.contains(profile.name))
                            Button("Reset…", role: .destructive) { resetCandidate = profile.name }
                                .disabled(launcher.running.contains(profile.name))
                        }
                    }
                }
            }

            Section {
                if launcher.isWorking { ProgressView().controlSize(.small) }
                if !launcher.status.isEmpty { Text(launcher.status).font(.callout) }
                if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 440)
        .task {
            launcher.refresh()
            await launcher.loadScenarios()
        }
        .confirmationDialog(
            "Reset “\(resetCandidate ?? "")”?", isPresented: Binding(get: { resetCandidate != nil }, set: { if !$0 { resetCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset Profile", role: .destructive) {
                if let name = resetCandidate {
                    do { try launcher.reset(name: name); errorMessage = nil } catch { errorMessage = error.localizedDescription }
                }
                resetCandidate = nil
            }
            Button("Cancel", role: .cancel) { resetCandidate = nil }
        } message: {
            Text("Deletes this profile’s database, images and preferences, and the Keychain items it made. Your real data isn’t affected.")
        }
    }

    private func launch(_ name: String) {
        guard TestProfile.isValid(name: name), !launcher.isWorking else { return }
        errorMessage = nil
        Task {
            do { try await launcher.launch(name: name, scenario: scenario, seedAccount: seedAccount && scenario != nil) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

/// The Debug menu. It is left out of a test profile's own menu bar (a profile already has the yellow strip).
struct DebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Debug") {
            if TestProfile.name == nil {
                Button("Test Profiles…") { openWindow(id: "test-profiles") }
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
        }
    }
}

/// Opens the Test Profiles window by itself when Option was held while the app started. Placed once in the main
/// window (next to `TestProfileStrip`); it draws nothing.
struct TestProfilesLaunchTrigger: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                if TestProfile.name == nil, TestProfileLauncher.shared.consumeOptionRequest() { openWindow(id: "test-profiles") }
            }
    }
}
#endif
