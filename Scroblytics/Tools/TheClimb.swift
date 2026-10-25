import Foundation
import SwiftData

/// One qualifying track: currently ranked inside the "Top N" tier and wasn't there at the start of the
/// comparison window — a genuine break-in, not just movement within a tier it was already in, and not
/// long-tail noise (a single play swinging rank by hundreds of places somewhere no one's really
/// competing). Read through the Field Registry's own `playRank`/`playsInLast`/`rankWindowAgo`
/// (`QueryCoreFields.swift`/`QueryClimbingFields.swift`) — this never re-derives what a rank or a play
/// count is; only the shape of the climb (below) is this tool's own.
struct TheClimbRow: Identifiable, Sendable {
    let id: QueryEntityID
    let artist: String
    let title: String
    /// Plays within the comparison window only (`playsInLast`).
    let recentPlays: Int
    /// nil if it had no plays before the window started at all (a fresh discovery, not just outside the tier).
    let previousRank: Int?
    let currentRank: Int
    /// This row's all-time rank at each of several checkpoints from the window's start through now — the
    /// first entry is `previousRank` (nil if unplayed then), the last is `currentRank`. What the
    /// sparkline draws, and what the qualitative tag and sort order below are both derived from.
    let trajectory: [Int?]
    /// True when most of the climb happened in the recent part of the window rather than spread evenly
    /// or front-loaded and since plateaued — a distinct signal from the raw rank-change number.
    let isBreakout: Bool
    /// Not shown to the user — the sort key: rank gained per segment, weighted toward the recent end of
    /// the window, so a climb that's still accelerating outranks one of the same total size that already
    /// leveled off.
    let shapeScore: Double

    var rankChange: Int? { previousRank.map { $0 - currentRank } }
}

struct TheClimb: Sendable {
    let rows: [TheClimbRow]
    let windowDays: Int
    let minPlaysNow: Int
    let topN: Int
    /// The #1 row by shape score — the headline reads this directly, so it can never disagree with the
    /// list shown right below it.
    var headline: TheClimbRow? { rows.first }
}

enum TheClimbEngine {
    /// The nearest of the Field Registry's own allowed climbing windows (30/60/90/180/365 —
    /// `ClimbingEngine.allowedWindows`, identical to `playsInLast`'s own `recentWindow` options) to an
    /// arbitrary day count. Reconciles the app-wide Chart comparison control (whose presets — 1/7/30/90/
    /// 365 days, or a custom date — don't all land on one of these) with the Field Registry's fields,
    /// whose `windowDays` parameter `QueryFieldRegistry.resolve` hard-rejects any other value for. This
    /// never changes the comparison control itself, only how this one tool reads it.
    static func snappedWindow(forDays days: Int) -> Int {
        ClimbingEngine.allowedWindows.min(by: { abs($0 - days) < abs($1 - days) }) ?? 90
    }

    /// Checkpoints for the trajectory: evenly spaced from the window's start through now.
    private static let trajectoryPoints = 6
    /// A climb counts as a "breakout" when the recency-weighted center of its gains falls in the back
    /// ~30% of the window's segments — most of the movement happened recently, not spread evenly across
    /// the whole period.
    private static let breakoutThreshold = Double(trajectoryPoints - 1) * 0.7

    /// `scrobbles` must have canonical artist names.
    static func compute(
        scrobbles: [ScrobbleSnapshot], compareDays: Int, minPlaysNow: Int, topN: Int, now: Date = Date()
    ) -> TheClimb? {
        let windowDays = snappedWindow(forDays: compareDays)
        let windowStart = now.addingTimeInterval(-Double(windowDays) * 86400)
        let span = now.timeIntervalSince(windowStart)
        let checkpoints = (0..<trajectoryPoints).map { i in
            windowStart.addingTimeInterval(span * Double(i) / Double(trajectoryPoints - 1))
        }

        // One whole-library rank pass per checkpoint — the SAME cost regardless of how many tracks end
        // up qualifying (measured against the real store: ~0.16s/pass, ~1s total for 6 points). Doing
        // this per row instead would cost tens of seconds to minutes at a realistic result-set size — the
        // N+1 shape this was checked against before committing to it. Every entity's rank is kept at
        // every checkpoint (not just a "wanted" subset) because who qualifies isn't known until all the
        // checkpoints — specifically the first and last — have been seen.
        var rankSpec = QuerySpec(target: .track)
        rankSpec.columns = [QueryFieldRef("playRank")]
        rankSpec.asOf = now
        guard let validatedRank = try? rankSpec.validate(against: .standard) else { return nil }
        var ranksByCheckpoint: [[QueryEntityID: Int]] = []
        for checkpoint in checkpoints {
            let truncated = scrobbles.filter { $0.playedAt <= checkpoint }
            let run = QueryRun(target: .track, asOf: now, scrobbles: truncated, allTimeScrobbles: scrobbles)
            let result = QueryEngine.evaluate(validatedRank, run: run)
            guard let rankKey = result.columns.first(where: { $0.field.id == "playRank" })?.cacheKey else { return nil }
            var ranks: [QueryEntityID: Int] = [:]
            for row in result.rows {
                if case .value(.number(let n))? = row.cells[rankKey] { ranks[row.entity.id] = Int(n) }
            }
            ranksByCheckpoint.append(ranks)
        }

        // The gate: currently inside the top tier, and wasn't at the window's start — a genuine
        // break-in. Excludes both a track that was already in the tier and just moved within it, and one
        // that climbed a huge raw distance without ever reaching anywhere competitive.
        let currentRanks = ranksByCheckpoint[trajectoryPoints - 1]
        let startRanks = ranksByCheckpoint[0]
        var qualifyingIDs: [QueryEntityID] = []
        for (id, rank) in currentRanks where rank <= topN {
            let previous = startRanks[id]
            if previous == nil || previous! > topN { qualifyingIDs.append(id) }
        }
        guard !qualifyingIDs.isEmpty else { return nil }

        // Recent plays (the noise floor, and what's shown per row) — read from the registry field over
        // the full history; it reads its own trailing window independently of everything above.
        var playsSpec = QuerySpec(target: .track)
        let windowParam: [String: QueryValue] = ["windowDays": .number(Double(windowDays))]
        playsSpec.columns = [QueryFieldRef("playsInLast", parameters: windowParam)]
        playsSpec.asOf = now
        guard let validatedPlays = try? playsSpec.validate(against: .standard) else { return nil }
        let playsRun = QueryRun(target: .track, asOf: now, scrobbles: scrobbles, allTimeScrobbles: scrobbles)
        let playsResult = QueryEngine.evaluate(validatedPlays, run: playsRun)
        guard let playsKey = playsResult.columns.first(where: { $0.field.id == "playsInLast" })?.cacheKey else { return nil }
        var recentPlaysByID: [QueryEntityID: Int] = [:]
        for row in playsResult.rows {
            if case .value(.number(let n))? = row.cells[playsKey] { recentPlaysByID[row.entity.id] = Int(n) }
        }

        var rows: [TheClimbRow] = []
        for id in qualifyingIDs {
            let plays = recentPlaysByID[id] ?? 0
            guard plays >= minPlaysNow else { continue }
            let trajectory = ranksByCheckpoint.map { $0[id] }
            let (shapeScore, isBreakout) = shape(of: trajectory)
            rows.append(TheClimbRow(
                id: id, artist: id.artist, title: id.name, recentPlays: plays,
                previousRank: trajectory.first ?? nil, currentRank: currentRanks[id] ?? 0,
                trajectory: trajectory, isBreakout: isBreakout, shapeScore: shapeScore
            ))
        }
        guard !rows.isEmpty else { return nil }

        // Sort by shape score — rewards both the size of the climb and how recently it happened, so a
        // climb that's still accelerating outranks one of the same total size that already leveled off.
        rows.sort { $0.shapeScore != $1.shapeScore ? $0.shapeScore > $1.shapeScore : $0.title < $1.title }
        return TheClimb(rows: rows, windowDays: windowDays, minPlaysNow: minPlaysNow, topN: topN)
    }

    /// Weights each segment's rank gain by how recent it is (a gain in the last segment counts most), so
    /// identical total movement scores higher when it's still accelerating than when it's already leveled
    /// off. Also reports whether the climb reads as a "breakout" — most of it concentrated in the back of
    /// the window — for the row's own qualitative tag.
    private static func shape(of trajectory: [Int?]) -> (score: Double, isBreakout: Bool) {
        var weightedGain = 0.0
        var totalGain = 0.0
        for end in 1..<trajectory.count {
            guard let before = trajectory[end - 1], let after = trajectory[end] else { continue }
            let gain = Double(before - after)
            guard gain > 0 else { continue }
            weightedGain += gain * Double(end)
            totalGain += gain
        }
        guard totalGain > 0 else { return (0, false) }
        let centerOfMass = weightedGain / totalGain
        return (weightedGain, centerOfMass >= breakoutThreshold)
    }

    /// The equivalent condition set for "Advanced" — the same break-in gate, handed to Query as an
    /// ordinary, further-editable spec.
    static func spec(compareDays: Int, minPlaysNow: Int, topN: Int) -> QuerySpec {
        let windowDays = snappedWindow(forDays: compareDays)
        let windowParam: [String: QueryValue] = ["windowDays": .number(Double(windowDays))]
        var spec = QuerySpec(target: .track)
        let current = QueryCondition(QueryFieldRef("playRank"), .lessThanOrEqual, [.number(Double(topN))])
        let wasOutside = QueryCondition(QueryFieldRef("rankWindowAgo", parameters: windowParam), .greaterThan, [.number(Double(topN))])
        let wasAbsent = QueryCondition(QueryFieldRef("rankWindowAgo", parameters: windowParam), .isMissing)
        var groups = [[current, wasOutside], [current, wasAbsent]]
        if minPlaysNow > 0 {
            let plays = QueryCondition(QueryFieldRef("playsInLast", parameters: windowParam), .greaterThanOrEqual, [.number(Double(minPlaysNow))])
            groups = groups.map { $0 + [plays] }
        }
        spec.groups = groups
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("playRank")), direction: .ascending)]
        spec.columns = [QueryFieldRef("playRank"), QueryFieldRef("rankWindowAgo", parameters: windowParam), QueryFieldRef("playsInLast", parameters: windowParam)]
        return spec
    }
}

#if DEBUG
/// Verification hook: with `SCROBLYTICS_CLIMB_DUMP=/path/out.tsv` set (and optionally
/// `SCROBLYTICS_CLIMB_WINDOW`/`SCROBLYTICS_CLIMB_MINPLAYS`/`SCROBLYTICS_CLIMB_TOPN`), computes The Climb
/// against the real store at launch, writes it, and quits — so it can be diffed against an independent
/// read of the same store.
enum TheClimbDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_CLIMB_DUMP"] else { return }
        HeadlessTask.run("TheClimbDebugEval") {
            let context = container.mainContext
            let raw = try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let scrobbles = QueryIdentity.canonicalizingArtists(raw)
            let compareDays = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_CLIMB_WINDOW"] ?? "") ?? 90
            let minPlaysNow = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_CLIMB_MINPLAYS"] ?? "") ?? 5
            let topN = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_CLIMB_TOPN"] ?? "") ?? 500
            let result = TheClimbEngine.compute(scrobbles: scrobbles, compareDays: compareDays, minPlaysNow: minPlaysNow, topN: topN)
            let lines = (result?.rows ?? []).map { r in
                "\(r.artist)\t\(r.title)\t\(r.recentPlays)\t\(r.rankChange.map(String.init) ?? "debut")\t\(r.previousRank.map(String.init) ?? "-")\t\(r.currentRank)\t\(r.shapeScore)\t\(r.isBreakout)\t\(r.trajectory.map { $0.map(String.init) ?? "-" }.joined(separator: ","))"
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
