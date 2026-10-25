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

    /// Every play of the history, oldest first, with its session. One walk, built once per run for each gap.
    static func sessions(_ run: QueryRun, gapMinutes: Double) -> [QueryEntityID: SessionInfo] {
        run.memoized("scrobbleSessions.\(gapMinutes)") {
            let plays = run.allTimeScrobbles
            var info: [QueryEntityID: SessionInfo] = [:]
            info.reserveCapacity(plays.count)
            let gap = gapMinutes * 60
            var index = 0
            while index < plays.count {
                // The session: from `index` while each play starts within the gap of the one before.
                var end = index
                while end + 1 < plays.count, plays[end + 1].playedAt.timeIntervalSince(plays[end].playedAt) <= gap { end += 1 }
                let members = plays[index...end]
                let artists = Set(members.map(\.artistName)).count
                let start = plays[index].playedAt.timeIntervalSince1970, last = plays[end].playedAt.timeIntervalSince1970
                // Runs of the same artist, in order.
                var runStart = index
                while runStart <= end {
                    var runEnd = runStart
                    while runEnd + 1 <= end, plays[runEnd + 1].artistName == plays[runStart].artistName { runEnd += 1 }
                    for position in runStart...runEnd {
                        if let id = run.entityID(for: plays[position]) {
                            info[id] = SessionInfo(start: start, end: last, position: position - index + 1, size: end - index + 1, artists: artists, artistRun: runEnd - runStart + 1)
                        }
                    }
                    runStart = runEnd + 1
                }
                index = end + 1
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
