import SwiftUI

/// Settings › Ask: which engine answers, and how to reach it. Keys go to the Keychain only; everything else (the
/// choice, model names, server addresses) is ordinary settings.
struct AskSettingsView: View {
    @State private var settings = AskSettingsStore.load()
    @State private var keyDraft = ""
    @State private var savedKey = false
    @State private var models: [String] = []
    @State private var isBusy = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testChips: [String] = []

    private var engine: AskEngineID { settings.selected }

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Answer questions with", selection: $settings.selected) {
                    ForEach(AskEngineID.allCases) { Text($0.label).tag($0) }
                }
                Text(engine.privacyNote).font(AppTypography.supportingDense).foregroundStyle(.secondary)
                HelpLinkButton(articleID: "ask-keys", title: "Engines, keys and what is sent")
                if engine == .onDevice {
                    Text("The on-device model is private and free but often reads requests wrongly. A larger model through your own key, or one you run yourself, is usually far more accurate.")
                        .font(AppTypography.supportingDense).foregroundStyle(.secondary)
                }
            }

            if engine != .onDevice {
                Section(engine.label) {
                    if let measured = engine.measuredNote {
                        Text(measured).font(AppTypography.supportingDense).foregroundStyle(.secondary)
                    }
                    if engine.usesKey { keyRows }
                    if engine.usesBaseURL {
                        TextField("Server address", text: baseURLBinding, prompt: Text(engine.defaultBaseURL))
                            .autocorrectionDisabled()
                    }
                    HStack {
                        TextField("Model", text: modelBinding, prompt: Text(engine.defaultModel.isEmpty ? "choose a model" : engine.defaultModel))
                            .autocorrectionDisabled()
                        Menu("Choose…") {
                            if models.isEmpty { Text("Fetch the list first") }
                            ForEach(models, id: \.self) { name in Button(name) { modelBinding.wrappedValue = name } }
                        }
                        .fixedSize()
                        Button("Fetch models") { Task { await fetchModels() } }.disabled(isBusy || (Connectivity.shared.isOffline && engine.isCloud))
                    }
                    HStack {
                        Button("Test") { Task { await test() } }.disabled(isBusy || (Connectivity.shared.isOffline && engine.isCloud))
                        if isBusy { ProgressView().controlSize(.small) }
                    }
                    if let status {
                        Text(status).font(AppTypography.supportingDense).foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    }
                    if !testChips.isEmpty {
                        Text("“artists I’ve played more than 100 times” was read as: " + testChips.joined(separator: " · "))
                            .font(AppTypography.supportingDense).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, new in
            AskSettingsStore.save(new)
            refreshKeyState()
            models = []; status = nil; testChips = []
        }
        .onAppear { refreshKeyState() }
    }

    @ViewBuilder
    private var keyRows: some View {
        HStack {
            SecureField("API key", text: $keyDraft, prompt: Text(savedKey ? "Saved in your Keychain" : (engine.keyIsOptional ? "optional" : "paste your key")))
            Button("Save") { saveKey() }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Remove", role: .destructive) { AskKeychain.removeKey(for: engine); refreshKeyState() }.disabled(!savedKey)
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.providers[engine.rawValue]?.model ?? "" }, set: { new in
            var config = settings.providers[engine.rawValue] ?? AskProviderConfig(model: "", baseURL: "")
            config.model = new
            settings.set(config, for: engine)
        })
    }

    private var baseURLBinding: Binding<String> {
        Binding(get: { settings.providers[engine.rawValue]?.baseURL ?? "" }, set: { new in
            var config = settings.providers[engine.rawValue] ?? AskProviderConfig(model: "", baseURL: "")
            config.baseURL = new
            settings.set(config, for: engine)
        })
    }

    private func refreshKeyState() { savedKey = AskKeychain.hasKey(for: engine) }

    private func saveKey() {
        do {
            try AskKeychain.setKey(keyDraft, for: engine)
            keyDraft = ""
            refreshKeyState()
            report("Key saved to your Keychain.", error: false)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    private func report(_ text: String, error: Bool) { status = text; statusIsError = error }

    private func client() -> AskLLMClient {
        AskLLMClients.make(engine, config: settings.config(for: engine), key: AskKeychain.key(for: engine))
    }

    private func fetchModels() async {
        isBusy = true
        defer { isBusy = false }
        do {
            models = try await client().listModels()
            report(models.isEmpty ? "The provider returned no models." : "\(models.count) models available.", error: models.isEmpty)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    /// A real round trip: the same prompt, schema and validation Ask uses, on a sentence with one right answer.
    private func test() async {
        isBusy = true
        testChips = []
        defer { isBusy = false }
        let registry = QueryFieldRegistry.standard
        let (resolved, availability) = AskEngines.resolve(registry: registry, settings: settings)
        guard let resolved else {
            if case .unavailable(let why) = availability { report(why, error: true) }
            return
        }
        do {
            let t = try await resolved.translate("artists I've played more than 100 times", context: .none, now: Date())
            testChips = AskChips.describe(t.interpretation.spec, registry: registry).map(\.text)
            var detail = "Works — answered in \(t.usage?.seconds.formatted(.number.precision(.fractionLength(1))) ?? "?") s"
            if let input = t.usage?.inputTokens { detail += ", \(input.formatted()) tokens in" }
            if let cached = t.usage?.cachedTokens, cached > 0 { detail += " (\(cached.formatted()) cached)" }
            report(detail + ".", error: false)
        } catch {
            report(error.localizedDescription, error: true)
        }
    }
}
