import SwiftUI

/// The confirmation, and then the result, of submitting missed plays to Last.fm. Nothing is sent until the person presses the button
/// here, with the exact list in front of them; each play can be unticked.
struct UnscrobbledPlaysScrobbleSheet: View {
    typealias Play = UnscrobbledPlaysScrobbling.Play

    let plays: [Play]
    /// Called with the plays Last.fm accepted once the run has ended (also when it stopped early), so the screen can refresh.
    let onFinished: ([Play]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var credentials: LastfmCredentials?
    @State private var credentialsLoaded = false
    @State private var phase = Phase.confirm
    @State private var report: UnscrobbledPlaysScrobbling.Report?

    private enum Phase { case confirm, sending, done }

    init(plays: [Play], onFinished: @escaping ([Play]) -> Void) {
        self.plays = plays
        self.onFinished = onFinished
        _selected = State(initialValue: Set(plays.map(\.id)))
    }

    private var canWrite: Bool { credentials?.apiSecret != nil && credentials?.sessionKey != nil }
    private var chosen: [Play] { plays.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .confirm: confirmation
            case .sending: ProgressView("Sending \(chosen.count.formatted()) \(chosen.count == 1 ? "play" : "plays") to Last.fm…").frame(maxWidth: .infinity, minHeight: 160)
            case .done: result
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(phase == .sending)
        .task {
            credentials = LastfmCredentialsStore.load()
            credentialsLoaded = true
        }
    }

    // MARK: Confirm

    @ViewBuilder
    private var confirmation: some View {
        Text("Scrobble \(chosen.count.formatted()) missed \(chosen.count == 1 ? "play" : "plays") to Last.fm")
            .font(AppTypography.sectionTitle)
        VStack(alignment: .leading, spacing: 6) {
            Text("Each play below is added to \(credentials.map { "the Last.fm account **\($0.username)**" } ?? "your Last.fm account"), timestamped with the time Music says it last played the song. This changes your public Last.fm profile, and Scroblytics can’t undo it: a scrobble can only be deleted on Last.fm’s own website.")
            Text("Music keeps only a song’s last play, so a song you played several times since its last scrobble is sent once. Last.fm takes plays from about the last 14 days; these are all inside that.")
                .foregroundStyle(.secondary)
        }
        .font(AppTypography.supporting)
        .fixedSize(horizontal: false, vertical: true)

        if credentialsLoaded, !canWrite {
            Label("Connect Track Actions in Settings › Sync to scrobble.", systemImage: "exclamationmark.triangle.fill")
                .font(AppTypography.supporting).foregroundStyle(.orange)
        } else if ConnectivityGate.isOffline {
            Label("Offline mode is on, so nothing can be sent.", systemImage: "wifi.slash")
                .font(AppTypography.supporting).foregroundStyle(.orange)
        }

        HStack {
            Button("Select All") { selected = Set(plays.map(\.id)) }.disabled(selected.count == plays.count)
            Button("Select None") { selected = [] }.disabled(selected.isEmpty)
            Spacer()
            Text("\(chosen.count.formatted()) of \(plays.count.formatted()) selected").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        .buttonStyle(.link)

        List(plays) { play in
            Toggle(isOn: Binding(get: { selected.contains(play.id) }, set: { on in if on { selected.insert(play.id) } else { selected.remove(play.id) } })) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(play.track).lineLimit(1)
                        Text(play.album.isEmpty ? play.artist : "\(play.artist) · \(play.album)")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(play.playedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .frame(minHeight: 200, maxHeight: 340)
        .listStyle(.bordered)

        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Scrobble \(chosen.count.formatted()) \(chosen.count == 1 ? "Play" : "Plays")") { send() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || !canWrite || ConnectivityGate.isOffline)
        }
    }

    // MARK: Result

    @ViewBuilder
    private var result: some View {
        let report = report ?? UnscrobbledPlaysScrobbling.Report()
        Text(report.accepted.isEmpty ? "Nothing was scrobbled" : "Scrobbled \(report.accepted.count.formatted()) \(report.accepted.count == 1 ? "play" : "plays")")
            .font(AppTypography.sectionTitle)
        VStack(alignment: .leading, spacing: 8) {
            if !report.accepted.isEmpty {
                Label("Last.fm took \(report.accepted.count.formatted()) \(report.accepted.count == 1 ? "play" : "plays"). A sync follows so they appear in your history.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if !report.ignored.isEmpty {
                Label("Last.fm ignored \(report.ignored.count.formatted()):", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                ForEach(report.ignored.prefix(8), id: \.play.id) { item in
                    Text("\(item.play.artist) — \(item.play.track): \(UnscrobbledPlaysScrobbling.ignoredReason(code: item.code, message: item.message))")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary).padding(.leading, 22)
                }
                if report.ignored.count > 8 { Text("and \(report.ignored.count - 8) more").font(AppTypography.compactMetadata).foregroundStyle(.secondary).padding(.leading, 22) }
            }
            if let failure = report.failure {
                Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if !report.outcomeUnknownFor.isEmpty {
                    Text("The connection failed before Last.fm answered, so it isn’t known whether it took the last \(report.outcomeUnknownFor.count.formatted()) \(report.outcomeUnknownFor.count == 1 ? "play" : "plays"). Run a sync and read Music again: plays Last.fm received no longer appear in the list. Don’t send them again before then.")
                        .font(AppTypography.supporting)
                }
                if !report.notSent.isEmpty {
                    Text("\(report.notSent.count.formatted()) \(report.notSent.count == 1 ? "play was" : "plays were") not sent and are still listed.")
                        .font(AppTypography.supporting).foregroundStyle(.secondary)
                }
            }
        }
        .font(AppTypography.supporting)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Send

    private func send() {
        guard let credentials, let secret = credentials.apiSecret, let sessionKey = credentials.sessionKey, !chosen.isEmpty else { return }
        let toSend = chosen
        let sender = UnscrobbledPlaysScrobbling.sender(apiKey: credentials.apiKey, secret: secret, sessionKey: sessionKey)
        phase = .sending
        Task {
            let finished = await UnscrobbledPlaysScrobbling.submit(toSend, send: sender, recordAccepted: { UnscrobbledPlaysLedger.record($0) })
            report = finished
            phase = .done
            onFinished(finished.accepted)
        }
    }
}
