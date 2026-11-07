import Foundation

/// Submitting the plays Unscrobbled Plays found to Last.fm, timestamped with Music's last-played date.
///
/// This WRITES to the person's Last.fm account (a public profile), so it only ever happens after the person has seen the exact list in
/// a confirmation and pressed the button. Everything here that decides what would be sent is pure and checked on made-up data; the
/// sending itself goes through `LastfmWriteClient`, tested only against the stand-in server.
enum UnscrobbledPlaysScrobbling {
    /// Last.fm accepts a scrobble only for a play from about the last 14 days. Plays within this much of the edge are left out
    /// rather than risk an ignored one.
    nonisolated static let windowDays = 14
    nonisolated static let windowSafety: TimeInterval = 3600
    nonisolated static var maxAge: TimeInterval { Double(windowDays) * 86_400 - windowSafety }
    /// How long a submitted play is remembered, so it isn't offered again before the history has caught up.
    nonisolated static let ledgerRetention: TimeInterval = 30 * 86_400

    /// One play that could be submitted: the song as Music names it, and when Music last played it.
    struct Play: Identifiable, Sendable, Equatable {
        let id: String
        let artist: String
        let track: String
        let album: String
        let playedAt: Date
        let neverScrobbled: Bool
        var timestamp: Int { Int(playedAt.timeIntervalSince1970) }
    }

    // MARK: What can be submitted

    /// The plays of `rows` (Not scrobbled rows) that can be submitted now, oldest first: within the 14-day window and not in the future,
    /// and not already covered by a scrobble under another spelling.
    nonisolated static func eligible(_ rows: [UnscrobbledPlaysEngine.Row], now: Date = Date()) -> [Play] {
        rows.compactMap { row -> Play? in
            guard row.shiftHours == nil, !row.coveredByVariant,
                  row.musicLastPlayed <= now, now.timeIntervalSince(row.musicLastPlayed) <= maxAge else { return nil }
            return Play(
                id: "\(row.id)\u{241F}\(Int(row.musicLastPlayed.timeIntervalSince1970))", artist: row.artist, track: row.track,
                album: row.album, playedAt: row.musicLastPlayed, neverScrobbled: row.kind == .neverScrobbled
            )
        }
        .sorted { ($0.playedAt, $0.id) < ($1.playedAt, $1.id) }
    }

    /// `artist | title | timestamp`, the identity of one submitted play (the names as Music has them, case and spacing ignored).
    nonisolated static func ledgerKey(artist: String, track: String, timestamp: Int) -> String {
        UnscrobbledPlaysEngine.exactKey(artist: artist, track: track) + "\u{241F}\(timestamp)"
    }

    /// The plays as Last.fm wants them: no repeats of the same song at the same moment, oldest first.
    nonisolated static func submissions(_ plays: [Play]) -> [LastfmWriteClient.ScrobbleSubmission] {
        var seen = Set<String>()
        return plays.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }.compactMap { play in
            guard !play.artist.isEmpty, !play.track.isEmpty,
                  seen.insert(ledgerKey(artist: play.artist, track: play.track, timestamp: play.timestamp)).inserted else { return nil }
            return LastfmWriteClient.ScrobbleSubmission(artist: play.artist, track: play.track, album: play.album.isEmpty ? nil : play.album, timestamp: play.timestamp)
        }
    }

    // MARK: Submitting

    struct Ignored: Sendable, Equatable {
        let play: Play
        let code: Int
        let message: String
    }

    struct Report: Sendable {
        /// Plays Last.fm took, plays it ignored (with its reason), and plays that were never sent because the run stopped.
        var accepted: [Play] = []
        var ignored: [Ignored] = []
        var notSent: [Play] = []
        /// Why the run stopped early, in plain words.
        var failure: String?
        /// The call that failed may nevertheless have been taken by Last.fm (the connection dropped before an answer came).
        var outcomeUnknownFor: [Play] = []
    }

    typealias Sender = @Sendable ([LastfmWriteClient.ScrobbleSubmission]) async throws -> [LastfmWriteClient.ScrobbleOutcome]

    /// The real sender: Last.fm, signed with the person's Track Actions session.
    nonisolated static func sender(apiKey: String, secret: String, sessionKey: String) -> Sender {
        { plays in try await LastfmWriteClient.scrobble(apiKey: apiKey, secret: secret, sessionKey: sessionKey, plays: plays) }
    }

    /// Sends `plays` in batches of 50, oldest first, and reports what happened to each. A batch Last.fm answers is recorded through
    /// `recordAccepted` at once, so a later failure never loses track of what already went through. The first batch that fails stops
    /// the run: the rest are reported as not sent, and if the failure is one where Last.fm may have taken the batch anyway (a dropped
    /// connection), that batch is reported as unknown.
    static func submit(
        _ plays: [Play], send: Sender, pause: Duration = .milliseconds(250), recordAccepted: @Sendable ([Play]) -> Void = { _ in }
    ) async -> Report {
        var report = Report()
        // One play per song and moment; keep Music's own order of names for display.
        var seen = Set<String>()
        let ordered = plays.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }.filter {
            seen.insert(ledgerKey(artist: $0.artist, track: $0.track, timestamp: $0.timestamp)).inserted && !$0.artist.isEmpty && !$0.track.isEmpty
        }
        let batches = stride(from: 0, to: ordered.count, by: LastfmWriteClient.maxScrobblesPerCall).map {
            Array(ordered[$0..<min($0 + LastfmWriteClient.maxScrobblesPerCall, ordered.count)])
        }
        for (index, batch) in batches.enumerated() {
            do {
                let outcomes = try await send(submissions(batch))
                guard outcomes.count == batch.count else { throw LastfmAPIError.malformedField("scrobble count") }
                var taken: [Play] = []
                for (play, outcome) in zip(batch, outcomes) {
                    if outcome.accepted { taken.append(play) } else { report.ignored.append(Ignored(play: play, code: outcome.ignoredCode ?? 0, message: outcome.message)) }
                }
                report.accepted += taken
                recordAccepted(taken)
            } catch {
                report.failure = describe(error)
                if mayHaveBeenTaken(error) { report.outcomeUnknownFor = batch }
                report.notSent = report.outcomeUnknownFor.isEmpty ? batches[index...].flatMap { $0 } : batches[(index + 1)...].flatMap { $0 }
                return report
            }
            if index < batches.count - 1 { try? await Task.sleep(for: pause) }
        }
        return report
    }

    /// True when Last.fm may have processed a call although no usable answer came back.
    nonisolated static func mayHaveBeenTaken(_ error: Error) -> Bool {
        guard let api = error as? LastfmAPIError else { return false }
        switch api {
        case .api: return false            // Last.fm answered with an error: it did not take the plays
        case .network, .http, .decoding, .invalidResponse, .malformedField: return true
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let gate = error as? LocalizedError, let text = gate.errorDescription { return text }
        return error.localizedDescription
    }

    /// What Last.fm's ignore codes mean, in plain words.
    nonisolated static func ignoredReason(code: Int, message: String) -> String {
        switch code {
        case 1: "Last.fm ignored the artist name."
        case 2: "Last.fm ignored the song title."
        case 3: "Too old: Last.fm only takes plays from about the last 14 days."
        case 4: "Dated in the future."
        case 5: "Last.fm’s daily scrobble limit was reached."
        default: message.isEmpty ? "Last.fm ignored it (code \(code))." : message
        }
    }
}

/// Which plays this tool has submitted, remembered on this Mac for a while so that a play isn't offered again in the moment before
/// the next sync brings it into the history. Kept in the app's preferences, not the database: it is a convenience, not your data,
/// and nothing here leaves the Mac.
enum UnscrobbledPlaysLedger {
    nonisolated static let defaultsKey = "unscrobbledPlays.submitted.v1"

    nonisolated static func load(now: Date = Date(), defaults: UserDefaults = .standard) -> Set<String> {
        let stored = (defaults.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
        let cutoff = now.addingTimeInterval(-UnscrobbledPlaysScrobbling.ledgerRetention).timeIntervalSince1970
        return Set(stored.filter { $0.value >= cutoff }.keys)
    }

    nonisolated static func record(_ plays: [UnscrobbledPlaysScrobbling.Play], now: Date = Date(), defaults: UserDefaults = .standard) {
        guard !plays.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-UnscrobbledPlaysScrobbling.ledgerRetention).timeIntervalSince1970
        var stored = ((defaults.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]).filter { $0.value >= cutoff }
        for play in plays {
            stored[UnscrobbledPlaysScrobbling.ledgerKey(artist: play.artist, track: play.track, timestamp: play.timestamp)] = now.timeIntervalSince1970
        }
        defaults.set(stored, forKey: defaultsKey)
    }
}
