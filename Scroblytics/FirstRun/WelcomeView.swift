import SwiftUI
import AppKit

/// What a brand-new person sees: what the app is, the three things to do, and the account form. It replaces the
/// (empty) tabs until a Last.fm account is saved; saving starts the import and the app appears.
struct WelcomeView: View {
    let onSkip: () -> Void

    @State private var form = LastfmAccountForm()
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Field?
    private enum Field { case username, apiKey }

    private static let createKeyURL = URL(string: "https://www.last.fm/api/account/create")!

    var body: some View {
        VStack(spacing: 0) {
            #if DEBUG
            TestProfileStrip()
            #endif
            ScrollView {
                VStack(spacing: 28) {
                    header
                    VStack(alignment: .leading, spacing: 22) {
                        step(1, "Get a free Last.fm API key") {
                            Text("Scroblytics reads your listening history from Last.fm using a key that is yours alone. Registering one takes a minute. Any name and description will do, and Last.fm then shows you an **API key**.")
                                .foregroundStyle(.secondary)
                            Button("Open Last.fm’s API page") { NSWorkspace.shared.open(Self.createKeyURL) }
                        }
                        step(2, "Enter your username and the key") { accountForm }
                        step(3, "Import your history") {
                            Text("As soon as Last.fm confirms the details, the import starts by itself. A long history takes a while, and you can use the app while it runs. If you quit, it carries on where it stopped.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    footer
                }
                .frame(maxWidth: 560)
                .padding(.vertical, 36).padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background { WelcomeBackdrop() }
        // The backdrop is dark in either appearance, so the welcome screen is always drawn as a dark screen.
        .environment(\.colorScheme, .dark)
        .onAppear { focused = .username }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 84, height: 84)
            Text("Welcome to Scroblytics").font(.largeTitle.bold())
            Text("A private copy of your Last.fm listening history on your Mac, ready to explore: charts, trends, milestones and a library you can search by anything.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Last.fm username", text: $form.username)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .username)
                .onSubmit { focused = .apiKey }
            TextField("API key", text: $form.apiKey)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.codeInput)
                .focused($focused, equals: .apiKey)
                .onSubmit { Task { await form.testAndSave() } }
            HStack(spacing: 10) {
                Button("Test & Save") { Task { await form.testAndSave() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.canSubmit)
                if form.isChecking {
                    ProgressView().controlSize(.small)
                    Text("Checking with Last.fm…").foregroundStyle(.secondary)
                }
            }
            switch form.phase {
            case .idle, .checking:
                EmptyView()
            case .saved(let account):
                Label("Found \(account.scrobbles.formatted()) scrobbles for “\(account.username)”. Starting the import…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if Connectivity.shared.isOffline {
                Label("Offline mode is on. Switch it off (Library menu) to check your account.", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("Your history is kept only on this Mac. Scroblytics talks to Last.fm to read it, and nothing else about you is sent anywhere.")
                .font(AppTypography.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 18) {
                HelpLinkButton(articleID: "lastfm-account", title: "What the key is and where it’s stored")
                Button("Restore from a backup…") { openWindow(id: "data-management") }
                    .buttonStyle(.link).font(AppTypography.supporting)
                Button("Skip for now") { onSkip() }
                    .buttonStyle(.link).font(AppTypography.supporting)
                    .help("Opens the empty app for this session. The welcome screen returns next time until an account is added.")
            }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The picture behind the welcome screen: the image named `WelcomeBackground` in the asset catalog, dimmed so the
/// card stays readable, or a plain dark gradient when there is no such image.
private struct WelcomeBackdrop: View {
    var body: some View {
        ZStack {
            if let image = NSImage(named: "WelcomeBackground") {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                Color.black.opacity(0.35)
            } else {
                LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.accentColor.opacity(0.22), .clear], center: .top, startRadius: 40, endRadius: 520)
            }
        }
        .ignoresSafeArea()
        .clipped()
    }
}
