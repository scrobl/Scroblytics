import Foundation

/// Listening sessions, for a query that finds single plays. A session is a run of plays each started within a set number of minutes of the
/// one before it; a longer silence ends it and the next play starts a new one. Sessions are found over your whole history (not just the plays
/// a query keeps), so a play at the start of a period still knows which session it belongs to and how it began.
///
/// The gap is measured from one play's start to the next play's start, as scrobbles only record when a play began. The default is 30 minutes;
/// a different gap is a setting on the field, so two columns can use two gaps.
extension QueryFieldRegistry {
    static let sessionGap = QueryFieldParameter(
        id: "gapMinutes", label: "Gap that ends a session (minutes)",
        options: [10, 15, 20, 30, 45, 60, 90, 120].map { .number(Double($0)) }, defaultValue: .number(30), suffix: "m", showsDefaultInTitle: false,
        help: "How long after one play starts the next one must start for them to be in different sessions. A longer gap makes longer, fewer sessions."
    )

    /// One listening session of the history: the plays from `first` to `last` of the run's whole history (oldest first).
    struct ListeningSession: Sendable {
        var first: Int
        var last: Int
        /// When its first and its last play began (seconds since 1970).
        var start: Double
        var end: Double
        var artists: Int
        var tracks: Int
        /// The artist with most of its plays (the first alphabetically on a tie), and how many it has.
        var topArtist: String
        var topArtistPlays: Int
        var size: Int { last - first + 1 }
    }

    /// Every session of the history, oldest first, found with the gap. One walk, built once per run for each gap.
    static func sessionList(_ run: QueryRun, gapMinutes: Double) -> [ListeningSession] {
        run.memoized("listeningSessions.\(gapMinutes)") {
            let plays = run.allTimeScrobbles
            let gap = gapMinutes * 60
            var sessions: [ListeningSession] = []
            var index = 0
            while index < plays.count {
                var end = index
                while end + 1 < plays.count, plays[end + 1].playedAt.timeIntervalSince(plays[end].playedAt) <= gap { end += 1 }
                var artistCounts: [String: Int] = [:]
                var tracks = Set<String>()
                for play in plays[index...end] {
                    artistCounts[play.artistName, default: 0] += 1
                    tracks.insert(play.artistName + "\u{0}" + play.trackName)
                }
                let top = artistCounts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
                sessions.append(ListeningSession(
                    first: index, last: end, start: plays[index].playedAt.timeIntervalSince1970, end: plays[end].playedAt.timeIntervalSince1970,
                    artists: artistCounts.count, tracks: tracks.count, topArtist: top?.key ?? "", topArtistPlays: top?.value ?? 0
                ))
                index = end + 1
            }
            return sessions
        }
    }

    /// "182 plays · 9h 2m · 41 artists · mostly Beck": what a session was, in one line under its date.
    static func sessionSummary(_ session: ListeningSession) -> String {
        let minutes = Int(((session.end - session.start) / 60).rounded())
        let length = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        var parts = ["\(session.size.formatted()) play\(session.size == 1 ? "" : "s")"]
        if session.size > 1 { parts.append(length) }
        parts.append("\(session.artists.formatted()) artist\(session.artists == 1 ? "" : "s")")
        if session.artists > 1, session.topArtistPlays * 2 > session.size { parts.append("mostly \(session.topArtist)") }
        return parts.joined(separator: " · ")
    }

    /// One play's place in its session.
    struct SessionInfo: Sendable {
        /// When the session began, and when its last play began (seconds since 1970).
        var start: Double
        var end: Double
        /// 1-based position in the session, and how many plays it has.
        var position: Int
        var size: Int
        /// How many different artists the session has.
        var artists: Int
        /// How many plays in a row by this play's artist, within the session, the run this play is in has.
        var artistRun: Int
    }

    /// Every play of the history with its session, built once per run for each gap.
    static func sessions(_ run: QueryRun, gapMinutes: Double) -> [QueryEntityID: SessionInfo] {
        run.memoized("scrobbleSessions.\(gapMinutes)") {
            let plays = run.allTimeScrobbles
            var info: [QueryEntityID: SessionInfo] = [:]
            info.reserveCapacity(plays.count)
            for session in sessionList(run, gapMinutes: gapMinutes) {
                var runStart = session.first
                while runStart <= session.last {
                    var runEnd = runStart
                    while runEnd + 1 <= session.last, plays[runEnd + 1].artistName == plays[runStart].artistName { runEnd += 1 }
                    for position in runStart...runEnd {
                        info[run.entityID(forPlay: plays[position])] = SessionInfo(
                            start: session.start, end: session.end, position: position - session.first + 1, size: session.size,
                            artists: session.artists, artistRun: runEnd - runStart + 1
                        )
                    }
                    runStart = runEnd + 1
                }
            }
            return info
        }
    }

    private static func gapMinutes(_ parameters: [String: QueryValue]) -> Double {
        if case .number(let n)? = parameters["gapMinutes"] { return n }
        return 30
    }

    private static func sessionField(
        id: String, name: String, type: QueryValueType, column: QueryColumnSpec? = nil, help: String,
        value: @escaping @Sendable (SessionInfo, QueryEntity) -> QueryValue
    ) -> QueryField {
        playField(id: id, name: name, type: type, parameters: [sessionGap], column: column, help: help) { run, parameters, entity in
            sessions(run, gapMinutes: gapMinutes(parameters))[entity.id].map { .value(value($0, entity)) } ?? .missing
        }
    }

    static let scrobbleSessionFields: [QueryField] = [
        sessionField(
            id: "sessionStart", name: "Session started", type: .date, column: .standard(for: .date, width: 170),
            help: "When the listening session this play is in began: the start of its first play. Plays in the same session share it, so it groups a night's listening and sorts sessions by when they happened."
        ) { info, _ in .date(Date(timeIntervalSince1970: info.start)) },
        sessionField(
            id: "sessionPosition", name: "Play # in session", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 100),
            help: "Which play of its session this is: 1 for the play that began it, 2 for the next, and so on."
        ) { info, _ in .number(Double(info.position)) },
        sessionField(
            id: "sessionSize", name: "Plays in session", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 100),
            help: "How many plays the session this play is in has, counting every play of it, not only the ones the query keeps."
        ) { info, _ in .number(Double(info.size)) },
        sessionField(
            id: "sessionLength", name: "Session length", type: .numeric, column: .standard(for: .numeric, style: .listeningTime, width: 130),
            help: "How long the session lasted, from the start of its first play to the start of its last (a session of one play is 0). It does not include the length of the last song."
        ) { info, _ in .number(info.end - info.start) },
        sessionField(
            id: "sessionArtists", name: "Artists in session", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 100),
            help: "How many different artists the session this play is in has."
        ) { info, _ in .number(Double(info.artists)) },
        sessionField(
            id: "sessionId", name: "Session ID", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 110),
            help: "A number that names the session this play is in: the time it began, in seconds since 1970. Plays of the same session share it, so “Session ID equals …” lists exactly one session’s plays (this is how a row of a sessions query opens its plays)."
        ) { info, _ in .number(info.start) },
        sessionField(
            id: "startsSession", name: "Starts a session", type: .boolean,
            help: "True when this play began a session: it came after a silence longer than the gap (or is your first play ever)."
        ) { info, _ in .bool(info.position == 1) },
        sessionField(
            id: "endsSession", name: "Ends a session", type: .boolean,
            help: "True when this was the last play of its session: nothing followed it within the gap."
        ) { info, _ in .bool(info.position == info.size) },
        sessionField(
            id: "artistRun", name: "Plays in a row by this artist", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 110),
            help: "How many plays by this play's artist came one after another, within the session, in the run this play is part of. 1 when the artist before and after it were different. A run of 6 is six songs in a row by the same artist."
        ) { info, _ in .number(Double(info.artistRun)) },
    ]
}
