import Foundation

/// How Rabbit Hole leans when it picks its three suggestions from a pool. Saved with the tool's settings; every field has a default so
/// settings saved by an earlier version still load.
struct RabbitHoleKnobs: Codable, Equatable, Sendable {
    /// -2 (mostly forgotten tracks) … +2 (mostly familiar ones).
    var familiarity = 0
    /// 0 stay close (the best matches), 1 balanced, 2 wander (many kinds of match are in play).
    var wander = 1
    /// Lower the chance of offering a track again that was shown or chosen in the last week.
    var avoidRepeats = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        familiarity = min(2, max(-2, try c.decodeIfPresent(Int.self, forKey: .familiarity) ?? 0))
        wander = min(2, max(0, try c.decodeIfPresent(Int.self, forKey: .wander) ?? 1))
        avoidRepeats = try c.decodeIfPresent(Bool.self, forKey: .avoidRepeats) ?? true
    }
}

/// What the tool showed and what you chose recently, so a new suggestion doesn't repeat the last ones. Entries fade after a week and
/// the list is kept short.
struct RabbitHoleMemory: Codable, Equatable, Sendable {
    var shown: [String: Date] = [:]
    var chosen: [String: Date] = [:]

    static let window: TimeInterval = 7 * 24 * 60 * 60
    static let capacity = 500

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shown = try c.decodeIfPresent([String: Date].self, forKey: .shown) ?? [:]
        chosen = try c.decodeIfPresent([String: Date].self, forKey: .chosen) ?? [:]
    }

    mutating func noteShown(_ keys: [String], now: Date = Date()) {
        for key in keys { shown[key] = now }
        prune(now: now)
    }

    mutating func noteChosen(_ key: String, now: Date = Date()) {
        chosen[key] = now
        prune(now: now)
    }

    /// 1 for something not seen lately, down to 0.35 (shown) or 0.5 (chosen) just after, rising back to 1 over the week.
    func penalty(for key: String, now: Date = Date()) -> Double {
        func factor(_ date: Date?, floor: Double) -> Double {
            guard let date else { return 1 }
            let age = max(0, now.timeIntervalSince(date))
            guard age < Self.window else { return 1 }
            return floor + (1 - floor) * (age / Self.window)
        }
        return min(factor(shown[key], floor: 0.35), factor(chosen[key], floor: 0.5))
    }

    mutating func prune(now: Date = Date()) {
        Self.trim(&shown, now: now)
        Self.trim(&chosen, now: now)
    }

    private static func trim(_ entries: inout [String: Date], now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value) < window }
        let overflow = entries.count - capacity
        if overflow > 0 {
            for key in entries.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) { entries.removeValue(forKey: key) }
        }
    }
}

enum RabbitHoleSelector {
    struct Item: Sendable {
        let key: String
        let artistKey: String
        let albumKey: String
        /// The artist's first community tag, so three suggestions don't all sound like the same genre.
        let topTag: String?
        /// 0-100.
        let score: Double
        let plays: Int
        let lastPlayed: Date
        let loved: Bool
    }

    /// How likely this item is to be picked, before spreading the three picks apart.
    static func weight(_ item: Item, knobs: RabbitHoleKnobs, memory: RabbitHoleMemory, now: Date = Date()) -> Double {
        let alpha = [2.0, 1.0, 0.35][min(2, max(0, knobs.wander))]
        var weight = pow(max(item.score, 1) / 100, alpha)
        let lean = Double(knobs.familiarity)
        if lean > 0 {
            let familiar = (item.loved ? 0.5 : 0) + min(0.5, log10(Double(item.plays) + 1) / 4)
            weight *= 1 + lean * familiar * 1.5
        } else if lean < 0 {
            let forgotten = min(1, max(0, now.timeIntervalSince(item.lastPlayed) / (365 * 86400)))
            weight *= 1 + abs(lean) * forgotten * 1.5
        }
        if knobs.avoidRepeats { weight *= memory.penalty(for: item.key, now: now) }
        return weight
    }

    /// Up to `count` items, chosen at random in proportion to their weight, one at a time. After each pick, a candidate by the same artist
    /// (or in the same genre) is much less likely, so the choices differ. Per-artist and per-album limits count what is already on the path.
    static func pick(
        _ items: [Item], count: Int, knobs: RabbitHoleKnobs, memory: RabbitHoleMemory,
        pathArtistCounts: [String: Int], pathAlbumCounts: [String: Int], perArtist: Int, perAlbum: Int,
        now: Date = Date(), using rng: inout some RandomNumberGenerator
    ) -> [Item] {
        var remaining = items
        var picked: [Item] = []
        var artistCounts = pathArtistCounts
        var albumCounts = pathAlbumCounts
        while picked.count < count, !remaining.isEmpty {
            remaining.removeAll { item in
                (perArtist > 0 && artistCounts[item.artistKey, default: 0] >= perArtist)
                    || (perAlbum > 0 && albumCounts[item.albumKey, default: 0] >= perAlbum)
            }
            guard !remaining.isEmpty else { break }
            let weights: [Double] = remaining.map { item in
                var w = weight(item, knobs: knobs, memory: memory, now: now)
                for earlier in picked {
                    if earlier.artistKey == item.artistKey { w *= 0.3 }
                    else if let tag = item.topTag, tag == earlier.topTag { w *= 0.6 }
                }
                return w
            }
            let total = weights.reduce(0, +)
            guard total > 0 else { break }
            var target = Double.random(in: 0..<total, using: &rng)
            var chosenIndex = weights.count - 1
            for (i, w) in weights.enumerated() {
                if target < w { chosenIndex = i; break }
                target -= w
            }
            let chosen = remaining.remove(at: chosenIndex)
            artistCounts[chosen.artistKey, default: 0] += 1
            albumCounts[chosen.albumKey, default: 0] += 1
            picked.append(chosen)
        }
        return picked
    }
}
