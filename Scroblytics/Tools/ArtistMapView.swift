import SwiftUI
import SwiftData

// MARK: - Model

/// What the Artist Map screen shows and does: your top artists for a period, Last.fm's saved answers about who is similar to whom, the
/// lookups for the artists that have none, and the picture those make. The engine itself is in `ArtistMap.swift`.
@MainActor
@Observable
final class ArtistMapModel {
    struct Options: Codable, Equatable {
        enum Mode: String, Codable, CaseIterable, Identifiable {
            case top, seed
            var id: String { rawValue }
            var title: String { self == .top ? "Top artists" : "From a seed" }
        }

        var mode: Mode = .top
        var count = 100
        /// The same choices and default as the Overview's period (`DateRangePresets`): "last30" is Last 30 days.
        var periodId = "last30"
        var minMatchPercent = 40
        var showGhosts = false
        var showArtwork = true
        /// What the dots' colors mean: the group an artist is in, or the country it is from.
        enum ColorBy: String, Codable, CaseIterable, Identifiable {
            case group, country
            var id: String { rawValue }
            var title: String { self == .group ? "Group" : "Country" }
        }
        var colorBy = ColorBy.group
        /// From a seed: the artist the map is drawn from, and how many steps out it reaches (1 or 2).
        var seedArtist: String?
        var reach = 1

        init() {}

        private enum CodingKeys: String, CodingKey { case mode, count, periodId, minMatchPercent, showGhosts, showArtwork, colorBy, seedArtist, reach }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .top
            count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 100
            // An earlier version saved a different, shorter list of periods under another name; it is not carried over.
            periodId = try values.decodeIfPresent(String.self, forKey: .periodId) ?? "last30"
            minMatchPercent = try values.decodeIfPresent(Int.self, forKey: .minMatchPercent) ?? 40
            showGhosts = try values.decodeIfPresent(Bool.self, forKey: .showGhosts) ?? false
            showArtwork = try values.decodeIfPresent(Bool.self, forKey: .showArtwork) ?? true
            colorBy = try values.decodeIfPresent(ColorBy.self, forKey: .colorBy) ?? .group
            seedArtist = try values.decodeIfPresent(String.self, forKey: .seedArtist)
            reach = min(2, max(1, try values.decodeIfPresent(Int.self, forKey: .reach) ?? 1))
        }
    }

    static let countChoices = [10, 25, 50, 100, 200]
    static let minMatchRange = 30...90

    /// One line of the side panel's "closest links".
    struct Link: Identifiable {
        let key: String
        let name: String
        let isGhost: Bool
        /// How strongly the selected artist's answer lists this one, and this one's answer lists the selected artist (0 = not listed).
        let outgoing: Double
        let incoming: Double
        /// The group of this artist (-1 for none, and for a never-played artist).
        let group: Int
        var id: String { key }
        var weight: Double { max(outgoing, incoming) }
    }

    struct Selection {
        let node: ArtistMapGraph.Node
        let group: Int
        /// The group's busiest member, which gives it its name.
        let groupName: String?
        let groupSize: Int
        /// The group's biggest members other than this artist, busiest first.
        let groupMembers: [String]
        let links: [Link]
        /// Where this artist is from, when that is known.
        let origin: ArtistOriginDisplay?
        /// What the group's known origins say ("Mostly from the United Kingdom: 7 of 9 with a known origin"), when they say anything.
        let groupOrigin: String?
    }

    /// What a group's members' countries say about it: nothing unless two or more are known and more than half share one country.
    static func originSummary(countries: [String?]) -> String? {
        let known = countries.compactMap { $0 }
        guard known.count >= 2 else { return nil }
        let counts = Dictionary(grouping: known, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value * 2 > known.count else { return nil }
        let name = CountryNames.phrase(forCode: top.key)
        return top.value == known.count ? "All \(known.count) with a known origin are from \(name)" : "Mostly from \(name): \(top.value) of \(known.count) with a known origin"
    }

    /// One of the commonest countries on the map, as the legend lists it.
    struct CountryLegend: Identifiable {
        let code: String
        let name: String
        let artists: Int
        let color: Color
        var id: String { code }
    }

    /// What the panel says about an artist's group. The group is named after its busiest member, so this says who is in it rather than
    /// reading as the artist's own name.
    static func groupDescription(selected: String, leader: String?, size: Int) -> String {
        guard let leader, size > 0 else { return "Not in a group" }
        if leader == selected { return "The busiest of a group of \(size)" }
        let others = max(size - 2, 0)
        switch others {
        case 0: return "In a group with \(leader)"
        case 1: return "In a group with \(leader) and 1 other"
        default: return "In a group with \(leader) and \(others) others"
        }
    }

    var options = Options()
    var selectedKey: String?
    var hoveredKey: String?

    private(set) var shown = ArtistMapGraph()
    /// Where each artist is from (the saved lookups and your corrections), read when the map opens and whenever they change.
    private(set) var origins = QueryOriginSnapshot.empty
    /// The country (ISO code) of each artist on the map whose origin is known, by node key.
    private(set) var countryOfNode: [String: String] = [:]
    /// The commonest countries on the map, each with its own color; the rest share one.
    private(set) var countryLegend: [CountryLegend] = []
    private(set) var groups = ArtistMapGroups()
    private(set) var positions: [CGPoint] = []
    private(set) var isLoadingHistory = true
    private(set) var hasHistory = true
    private(set) var scopeCount = 0
    private(set) var answeredCount = 0
    private(set) var isLookingUp = false
    private(set) var lookupDone = 0
    private(set) var lookupTotal = 0
    private(set) var lookupMessage: String?
    /// The period choices (as on Overview), bounded by your first scrobble once the history is read.
    private(set) var rangeOptions = DateRangePresets.build(oldestScrobbleDate: nil)
    /// Artist pictures drawn on the dots, cut square and small, by artist key.
    private(set) var artwork: [String: NSImage] = [:]

    let container: ModelContainer
    private var snapshots: [ScrobbleSnapshot] = []
    private var scope: [ArtistMapEntry] = []
    private var libraryKeys = Set<String>()
    private var answers: [String: [SimilarArtist]] = [:]
    private var positionsByKey: [String: CGPoint] = [:]
    private var generation = 0
    private var rebuildTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var throttlePending = false
    /// Every artist you have played, by key, which a seed's neighbors are taken from.
    private var library: [String: ArtistMapEntry] = [:]
    /// The artists whose answer is still missing and would add to the map.
    private(set) var lookupTargets: [String] = []
    private var lookupAfterRescope = false
    /// Artists whose saved answer is older than 30 days: still drawn, and offered for a refresh.
    private var staleKeys = Set<String>()
    private(set) var hasAnswers = false
    private var imageLookup: [String: String]?
    private var artworkTried = Set<String>()
    private var artworkTask: Task<Void, Never>?
    /// The drawing area (the canvas less its margin), which the layout is worked out for.
    private(set) var canvasSize = ArtistMapLayout.defaultCanvas
    static let canvasPadding: CGFloat = 36
    /// Set by the offscreen snapshots, which show made-up data and must not read the history.
    private(set) var isSnapshotSample = false

    init(container: ModelContainer) { self.container = container }

    var missingCount: Int { lookupTargets.count }
    /// Everything waiting is an old answer to refresh, rather than an artist with no answer yet.
    var lookupIsRefresh: Bool { !lookupTargets.isEmpty && lookupTargets.allSatisfy { staleKeys.contains(ArtistMapNames.key($0)) } }
    var staleCount: Int { scope.filter { staleKeys.contains(ArtistMapNames.key($0.name)) }.count }
    /// The seed's key when the map is drawn from one.
    var seedKey: String? { options.mode == .seed ? options.seedArtist.map(ArtistMapNames.key) : nil }
    var maxPlays: Int { shown.nodes.map(\.plays).max() ?? 1 }

    /// The drawing area changed size: lay the map out again for the new shape (a small change is ignored).
    func canvasChanged(_ size: CGSize) {
        let usable = CGSize(width: size.width - Self.canvasPadding * 2, height: size.height - Self.canvasPadding * 2)
        guard usable.width > 150, usable.height > 150 else { return }
        let moved = abs(usable.width - canvasSize.width) / canvasSize.width > 0.08 || abs(usable.height - canvasSize.height) / canvasSize.height > 0.08
        guard moved else { return }
        canvasSize = usable
        if !shown.nodes.isEmpty { scheduleRebuild(delay: .milliseconds(250)) }
    }

    var statusText: String {
        guard scopeCount > 0 else { return "" }
        let shownArtists = shown.nodes.filter { !$0.isGhost }.count
        let ghosts = shown.nodes.count - shownArtists
        var parts = ["\(shownArtists) artists", "\(shown.edges.count) links"]
        if ghosts > 0 { parts.append("\(ghosts) you haven't played") }
        if options.mode == .seed {
            parts.append(options.reach == 1 ? "one step out" : "two steps out")
            if missingCount > 0 { parts.append("\(missingCount) \(missingCount == 1 ? "lookup" : "lookups") waiting") }
        } else {
            parts.append(missingCount == 0 ? "saved answers for all \(scopeCount)" : "saved answers for \(answeredCount) of \(scopeCount)")
        }
        if staleCount > 0 { parts.append("\(staleCount) older than 30 days") }
        return parts.joined(separator: " · ")
    }

    /// The dates the chosen period covers; Last 30 days if the saved choice no longer exists (a year before your first scrobble, say).
    func selectedRange() -> (from: Date?, to: Date?) {
        let option = rangeOptions.first { $0.id == options.periodId } ?? rangeOptions.first { $0.id == "last30" }
        guard let range = option?.range() else { return (nil, nil) }
        return (range.from, range.to)
    }

    // MARK: Loading

    func start() async {
        isLoadingHistory = true
        snapshots = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
        rangeOptions = DateRangePresets.build(oldestScrobbleDate: snapshots.first?.playedAt)
        hasHistory = !snapshots.isEmpty
        origins = QueryOriginSnapshot.load(context: container.mainContext)
        isLoadingHistory = false
        await rescope()
    }

    /// The artists on the map changed (another count, period, mode or seed): choose them again and read what is saved about them.
    func rescope() async {
        lookupTask?.cancel()
        imageLookup = nil
        let snaps = snapshots
        if options.mode == .seed {
            await rescopeSeed(snaps)
        } else {
            let count = options.count, range = selectedRange()
            let top = await Task.detached(priority: .userInitiated) {
                ArtistMapScope.top(snapshots: snaps, count: count, from: range.from, to: range.to)
            }.value
            scope = top.entries
            libraryKeys = top.libraryKeys
            scopeCount = scope.count
            let provider = ArtistMapSavedProvider(store: SimilarityCacheStore(modelContainer: container))
            let saved = await ArtistMapLoader.load(artists: scope.map(\.name), provider: provider, fetchMissing: false, isOffline: { false }, onUpdate: { _ in })
            answers = saved.neighbors
            staleKeys = saved.summary.staleKeys
            updateAnswered()
        }
        await rebuild()
        if lookupAfterRescope {
            lookupAfterRescope = false
            lookUpMissing()
        }
    }

    /// A map from one seed: its neighbors in your library, and (two steps) theirs. What is saved is read in two rounds, since the
    /// neighbors are only known once the seed's own answer is.
    private func rescopeSeed(_ snaps: [ScrobbleSnapshot]) async {
        let range = selectedRange()
        let everyone = await Task.detached(priority: .userInitiated) { ArtistMapScope.top(snapshots: snaps, count: Int.max, from: range.from, to: range.to) }.value
        libraryKeys = everyone.libraryKeys
        library = Dictionary(everyone.entries.map { (ArtistMapNames.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        answers = [:]
        staleKeys = []
        if let key = seedKey { selectedKey = key }
        guard options.seedArtist != nil else { updateAnswered(); return }
        let provider = ArtistMapSavedProvider(store: SimilarityCacheStore(modelContainer: container))
        for _ in 0..<2 {
            updateAnswered()
            let saved = await ArtistMapLoader.load(artists: scope.map(\.name), provider: provider, fetchMissing: false, isOffline: { false }, onUpdate: { _ in })
            answers.merge(saved.neighbors) { _, new in new }
            staleKeys.formUnion(saved.summary.staleKeys)
        }
        updateAnswered()
    }

    /// Picks `name` as the seed, switches to the seed map and, once it is drawn from what is saved, looks up what is missing (choosing a
    /// seed is the request to ask Last.fm about it).
    func chooseSeed(_ name: String) {
        lookupAfterRescope = true
        let before = options
        options.mode = .seed
        options.seedArtist = name
        if options == before { Task { await rescope() } }
    }

    func optionsChanged(from old: Options) {
        if old.count != options.count || old.periodId != options.periodId || old.mode != options.mode
            || old.seedArtist != options.seedArtist || old.reach != options.reach {
            Task { await rescope() }
        } else {
            // Only the colors changed: the layout stays as it is and the canvas just draws again.
            var recoloured = old
            recoloured.colorBy = options.colorBy
            if recoloured == options { return }
            scheduleRebuild()
        }
    }

    /// What the answers so far say is on the map and still to look up.
    private func updateAnswered() {
        if options.mode == .seed {
            guard let seed = options.seedArtist else {
                scope = []; lookupTargets = []; scopeCount = 0; answeredCount = 0
                return
            }
            let result = ArtistMapSeedScope.build(seed: seed, library: library, answers: answers, steps: options.reach, stale: staleKeys)
            scope = result.scope
            lookupTargets = result.lookups
            scopeCount = scope.count
        } else {
            lookupTargets = scope.filter {
                let key = ArtistMapNames.key($0.name)
                return answers[key] == nil || staleKeys.contains(key)
            }.map(\.name)
        }
        hasAnswers = scope.contains { answers[ArtistMapNames.key($0.name)] != nil }
        answeredCount = scope.filter {
            let key = ArtistMapNames.key($0.name)
            return answers[key] != nil && !staleKeys.contains(key)
        }.count
    }

    // MARK: Drawing

    private func scheduleRebuild(delay: Duration = .milliseconds(150)) {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await rebuild()
        }
    }

    /// While lookups arrive the picture is redrawn at most once a second.
    private func scheduleThrottled() {
        guard !throttlePending else { return }
        throttlePending = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            throttlePending = false
            await rebuild()
        }
    }

    func rebuild() async {
        generation += 1
        let mine = generation
        let graph = ArtistMapGraph.build(scope: scope, libraryKeys: libraryKeys, neighbors: answers)
        let seed = seedKey
        let filtered = graph.filtered(minMatch: Double(options.minMatchPercent) / 100, showGhosts: options.showGhosts, alwaysKeep: seed, dropUnlinked: seed != nil)
        let found = ArtistMapGroups.find(in: filtered)
        // Round a seed, the members of a group sit together.
        let ringOrder = filtered.nodes.indices.sorted { a, b in
            let ga = found.groupOfNode[a] < 0 ? Int.max : found.groupOfNode[a], gb = found.groupOfNode[b] < 0 ? Int.max : found.groupOfNode[b]
            return ga != gb ? ga < gb : a < b
        }
        let previous = positionsByKey
        let canvas = canvasSize
        let top = filtered.nodes.map(\.plays).max() ?? 1
        let dotScale = Self.dotScale(for: canvas)
        let radii = filtered.nodes.map { Double(Self.radius(of: $0, maxPlays: top, scale: dotScale)) }
        let laidOut = await Task.detached(priority: .userInitiated) {
            if let seed { return ArtistMapLayout.radial(graph: filtered, seedKey: seed, canvas: canvas, radii: radii, order: ringOrder) }
            return ArtistMapLayout.force(graph: filtered, previous: previous, canvas: canvas, radii: radii)
        }.value
        guard mine == generation else { return }
        shown = filtered
        groups = found
        positions = laidOut
        for (index, node) in filtered.nodes.enumerated() { positionsByKey[node.key] = laidOut[index] }
        if let key = selectedKey, !filtered.nodes.contains(where: { $0.key == key }) { selectedKey = nil }
        refreshCountries()
        refreshArtwork()
    }

    /// Reads the origins again (they were looked up, forgotten or corrected) and recolors the map.
    func reloadOrigins() {
        origins = QueryOriginSnapshot.load(context: container.mainContext)
        refreshCountries()
    }

    /// Which country each artist on the map is from, and a color for each of the eight commonest.
    private func refreshCountries() {
        var codes: [String: String] = [:]
        var counts: [String: Int] = [:]
        for node in shown.nodes where !node.isGhost {
            let display = origins.display(artist: node.name)
            guard display.state == .known,
                  let code = display.place.countryCode.flatMap({ CountryNames.code(for: $0) }) ?? display.place.country.flatMap({ CountryNames.code(for: $0) }) else { continue }
            codes[node.key] = code
            counts[code, default: 0] += 1
        }
        countryOfNode = codes
        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(ArtistMapPalette.countryColors.count)
        countryLegend = ranked.enumerated().map { index, entry in
            CountryLegend(code: entry.key, name: CountryNames.name(forCode: entry.key) ?? entry.key, artists: entry.value, color: ArtistMapPalette.countryColors[index])
        }
    }

    /// The color of an artist's dot, by what the map is colored by: its group, or its country (gray when it is not among the commonest
    /// countries, lighter gray when its country is not known).
    func color(forKey key: String, group: Int) -> Color {
        guard options.colorBy == .country else { return ArtistMapPalette.color(group: group) }
        guard let code = countryOfNode[key] else { return ArtistMapPalette.unknownCountry }
        return countryLegend.first { $0.code == code }?.color ?? ArtistMapPalette.otherCountry
    }

    // MARK: Artwork

    /// Loads the pictures for the artists now on the map that have one saved (or reachable, when online). The map draws at once with
    /// colored dots and the pictures come in as they load; an artist with no picture keeps its colored dot, and is not asked for again.
    func refreshArtwork() {
        guard options.showArtwork else { return }
        let wanted = shown.nodes.filter { !$0.isGhost && artwork[$0.key] == nil && !artworkTried.contains($0.key) }
        guard !wanted.isEmpty else { return }
        artworkTask?.cancel()
        let container = self.container
        let known = imageLookup
        artworkTask = Task { [weak self] in
            let lookup: [String: String]
            if let known { lookup = known } else {
                lookup = await Task.detached(priority: .utility) { (try? ImageResolutionEngine.imageLookup(context: ModelContext(container))) ?? [:] }.value
                self?.imageLookup = lookup
            }
            var urls: [String: String] = [:]
            for node in wanted {
                let target = ImageTarget(kind: .artist, artist: node.name, album: nil, track: nil)
                if let url = ImageResolutionEngine.effectiveImageURL(for: target, lookup: lookup) { urls[node.key] = url }
            }
            let loaded = await ShareArtwork.load(Array(urls.values))
            guard !Task.isCancelled, let self else { return }
            for node in wanted {
                artworkTried.insert(node.key)
                if let url = urls[node.key], let image = loaded[url] { artwork[node.key] = ArtistMapArtwork.thumbnail(image) }
            }
        }
    }

    // MARK: Lookups

    func lookUpMissing() {
        guard !isLookingUp, !lookupTargets.isEmpty else { return }
        guard let credentials = LastfmCredentialsStore.load() else {
            lookupMessage = "Connect Last.fm in Settings to look up similar artists."
            return
        }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let provider = LastfmSimilarityProvider(client: client, store: SimilarityCacheStore(modelContainer: container))
        isLookingUp = true
        lookupMessage = nil
        lookupDone = 0
        lookupTotal = lookupTargets.count
        lookupTask = Task { [weak self] in
            var combined = ArtistMapLoader.Summary()
            // A map from a seed learns its neighbors from the seed's answer, so it looks up in rounds: the seed, then its neighbors.
            for _ in 0..<3 {
                guard let self else { return }
                let names = self.lookupTargets
                if names.isEmpty { break }
                self.lookupDone = 0
                self.lookupTotal = names.count
                let (stream, continuation) = AsyncStream.makeStream(of: ArtistMapLoader.Update.self)
                let consumer = Task { @MainActor in
                    for await update in stream { self.apply(update) }
                }
                let result = await ArtistMapLoader.load(
                    artists: names, provider: provider, fetchMissing: true,
                    isOffline: { ConnectivityGate.isOffline }, onUpdate: { continuation.yield($0) }
                )
                continuation.finish()
                await consumer.value
                combined.fetched += result.summary.fetched
                combined.failed += result.summary.failed
                if let stopped = result.summary.stopped { combined.stopped = stopped; break }
                if result.summary.fetched == 0 || self.options.mode == .top { break }
            }
            await self?.finishLookup(combined)
        }
    }

    func stopLookup() { lookupTask?.cancel() }

    private func apply(_ update: ArtistMapLoader.Update) {
        answers[update.key] = update.neighbors
        if !update.fromSaved { staleKeys.remove(update.key) }
        lookupDone = update.done
        lookupTotal = update.total
        updateAnswered()
        if !update.fromSaved { scheduleThrottled() }
    }

    private func finishLookup(_ summary: ArtistMapLoader.Summary) async {
        isLookingUp = false
        updateAnswered()
        switch summary.stopped {
        case .offline: lookupMessage = "Offline mode is on, so the rest wait until you go online."
        case .tooManyFailures: lookupMessage = "Last.fm isn't answering right now. Try again in a moment."
        case .cancelled: lookupMessage = nil
        case nil: lookupMessage = summary.failed > 0 ? "\(summary.failed) artists couldn't be looked up. Try again to fill them in." : nil
        }
        await rebuild()
    }

    // MARK: Selection

    func radius(of node: ArtistMapGraph.Node) -> CGFloat { Self.radius(of: node, maxPlays: maxPlays, scale: dotScale) }

    /// A bigger window gets bigger dots (up to half as big again), so a map on a large display isn't a few specks on a wide field.
    var dotScale: CGFloat { Self.dotScale(for: canvasSize) }

    static func dotScale(for canvas: CGSize) -> CGFloat {
        let area = max(canvas.width * canvas.height, 1)
        return min(1.5, max(1, (area / (700 * 450)).squareRoot()))
    }

    static func radius(of node: ArtistMapGraph.Node, maxPlays: Int, scale: CGFloat = 1) -> CGFloat {
        if node.isGhost { return 8 * scale }
        let share = (Double(node.plays) / Double(max(maxPlays, 1))).squareRoot()
        return (6 + 14 * CGFloat(share)) * scale
    }

    func index(ofKey key: String?) -> Int? {
        guard let key else { return nil }
        return shown.nodes.firstIndex { $0.key == key }
    }

    /// The keys of the artists joined to `key` by a line on screen.
    func neighborKeys(of key: String) -> Set<String> {
        guard let i = index(ofKey: key) else { return [] }
        var out = Set<String>()
        for edge in shown.edges {
            if edge.a == i { out.insert(shown.nodes[edge.b].key) } else if edge.b == i { out.insert(shown.nodes[edge.a].key) }
        }
        return out
    }

    var selection: Selection? {
        guard let i = index(ofKey: selectedKey) else { return nil }
        func group(of node: Int) -> Int {
            guard node < groups.groupOfNode.count, !shown.nodes[node].isGhost else { return -1 }
            return groups.groupOfNode[node]
        }
        var links: [Link] = []
        for edge in shown.edges {
            if edge.a == i {
                let other = shown.nodes[edge.b]
                links.append(Link(key: other.key, name: other.name, isGhost: other.isGhost, outgoing: edge.aToB, incoming: edge.bToA, group: group(of: edge.b)))
            } else if edge.b == i {
                let other = shown.nodes[edge.a]
                links.append(Link(key: other.key, name: other.name, isGhost: other.isGhost, outgoing: edge.bToA, incoming: edge.aToB, group: group(of: edge.a)))
            }
        }
        links.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.name < $1.name }
        let mine = group(of: i)
        // Nodes are in play order, so the members come out busiest first.
        let members = mine >= 0 ? shown.nodes.indices.filter { $0 != i && group(of: $0) == mine }.map { shown.nodes[$0].name } : []
        let node = shown.nodes[i]
        let groupCountries: [String?] = mine >= 0 ? shown.nodes.indices.filter { group(of: $0) == mine }.map { countryOfNode[shown.nodes[$0].key] } : []
        return Selection(
            node: node, group: mine, groupName: mine >= 0 ? groups.names[mine] : nil,
            groupSize: mine >= 0 ? groups.sizes[mine] : 0, groupMembers: Array(members.prefix(6)), links: links,
            origin: node.isGhost ? nil : origins.display(artist: node.name), groupOrigin: Self.originSummary(countries: groupCountries)
        )
    }
}

// MARK: - Artwork

enum ArtistMapArtwork {
    /// A square, centered crop of `image`, `side` points across: dots are small, so a full-size picture would only cost memory.
    @MainActor
    static func thumbnail(_ image: NSImage, side: CGFloat = 96) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let short = min(size.width, size.height)
        let source = NSRect(x: (size.width - short) / 2, y: (size.height - short) / 2, width: short, height: short)
        let result = NSImage(size: NSSize(width: side, height: side))
        result.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: source, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }
}

// MARK: - Colors

enum ArtistMapPalette {
    private static let colors: [Color] = [.purple, .teal, .orange, .pink, .indigo, .mint, .brown, .cyan]

    static func color(group: Int) -> Color { group < 0 ? .gray : colors[group % colors.count] }

    /// One color for each of the eight commonest countries on the map; every other country shares `otherCountry`.
    static let countryColors: [Color] = [.blue, .orange, .green, .pink, .purple, .yellow, .red, .teal]
    static let otherCountry = Color.gray
    static let unknownCountry = Color.gray.opacity(0.35)
}

// MARK: - View

struct ArtistMapView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    let openQuery: (QuerySpec, String, String?) -> Void

    private static let toolId = "artistMap"

    @Environment(\.modelContext) private var modelContext
    @State private var model: ArtistMapModel
    @State private var showingSeedSearch = false
    /// The heights of what sits above and below the map, measured, so the map can take all the rest of the window.
    @State private var headerHeight: CGFloat = 120
    @State private var stripHeight: CGFloat = 30
    @State private var legendHeight: CGFloat = 20
    /// The map is never shorter than this; a window shorter than the page scrolls.
    private static let mapMinHeight: CGFloat = 520
    private static let pageSpacing: CGFloat = 14
    private static let pagePadding: CGFloat = 16

    init(
        modelContainer: ModelContainer, navigation: DetailNavigationCoordinator, openQuery: @escaping (QuerySpec, String, String?) -> Void,
        sample: ArtistMapModel? = nil
    ) {
        self.modelContainer = modelContainer
        self.navigation = navigation
        self.openQuery = openQuery
        _model = State(initialValue: sample ?? ArtistMapModel(container: modelContainer))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.pageSpacing) {
                PageSettingsHeader("Artist Map") { controls }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                if model.isLoadingHistory {
                    ProgressView("Reading your history…").frame(maxWidth: .infinity, minHeight: 240)
                } else if !model.hasHistory {
                    ContentUnavailableView("No scrobbles yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Once your history is imported, your artists appear here, joined by how similar Last.fm says they are."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if model.options.mode == .seed && model.options.seedArtist == nil {
                    ContentUnavailableView {
                        Label("Pick an artist to map from", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("The map puts that artist in the middle and draws the artists in your library that Last.fm says are most similar around it, the closest ones nearest.")
                    } actions: {
                        Button("Choose artist…") { showingSeedSearch = true }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    statusStrip
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }
                    HStack(alignment: .top, spacing: 12) {
                        ArtistMapCanvas(model: model, onOpen: openArtist, onQuery: query)
                            .frame(minWidth: 360, maxHeight: .infinity)
                        ArtistMapPanel(model: model, onOpen: openArtist, onQuery: query, onSeed: { model.chooseSeed($0) })
                            .frame(width: 250)
                            .frame(maxHeight: .infinity)
                    }
                    // The map and its panel take whatever height the window has left, down to a minimum.
                    .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                        let chrome = headerHeight + stripHeight + legendHeight + Self.pageSpacing * 3 + Self.pagePadding * 2
                        return max(Self.mapMinHeight, length - chrome)
                    }
                    legend
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { legendHeight = $0 }
                }
            }
            .padding(Self.pagePadding)
        }
        .navigationTitle("Artist Map")
        .overlay {
            if showingSeedSearch {
                GlobalSearchOverlay(
                    isPresented: $showingSeedSearch,
                    onSelect: { result in if let name = result.artist?.name { model.chooseSeed(name) } },
                    allowedKinds: [.artist]
                )
            }
        }
        .task {
            guard !model.isSnapshotSample else { return }
            model.options = ToolFilterSettingsStore.load(ArtistMapModel.Options.self, toolId: Self.toolId, context: modelContext, default: ArtistMapModel.Options())
            await model.start()
            #if DEBUG
            if Tour.minutes != nil { await model.runTourScript() }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .artistOriginDidUpdate)) { _ in
            guard !model.isSnapshotSample else { return }
            model.reloadOrigins()
        }
        .onChange(of: model.options) { old, new in
            guard !model.isSnapshotSample else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
            model.optionsChanged(from: old)
        }
    }

    // MARK: Controls

    private var controls: some View {
        ToolControlsFlow {
            Picker("Map", selection: $model.options.mode) {
                ForEach(ArtistMapModel.Options.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Your top artists together, or the neighborhood of one artist.")
            if model.options.mode == .top {
                Picker("Artists", selection: $model.options.count) {
                    ForEach(ArtistMapModel.countChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .help("How many of your most played artists are on the map.")
            } else {
                Button { showingSeedSearch = true } label: {
                    Label(model.options.seedArtist ?? "Choose artist…", systemImage: "person.crop.circle.badge.plus").lineLimit(1)
                }
                .help("Search your library for the artist to draw the map from.")
                Picker("Reach", selection: $model.options.reach) {
                    Text("1 step").tag(1)
                    Text("2 steps").tag(2)
                }
                .help("One step shows the artists most similar to the seed. Two steps also shows the closest few of each of those.")
            }
            Picker("Period", selection: $model.options.periodId) {
                ForEach(model.rangeOptions) { Text($0.label).tag($0.id) }
            }
            .help(model.options.mode == .top
                  ? "The period that ranks your artists and sizes the dots."
                  : "Only artists you played in this period are on the map, and it sizes the dots.")
            HStack(spacing: 8) {
                Text("Minimum match").font(AppTypography.metadata)
                Slider(value: minMatchBinding, in: Double(ArtistMapModel.minMatchRange.lowerBound)...Double(ArtistMapModel.minMatchRange.upperBound), step: 5)
                    .frame(width: 140)
                Text("\(model.options.minMatchPercent)%").font(AppTypography.metadata).monospacedDigit().frame(width: 36, alignment: .leading)
            }
            .help("Show only links at least this strong. Last.fm scores similarity from 0 to 100%.")
            Picker("Color by", selection: $model.options.colorBy) {
                ForEach(ArtistMapModel.Options.ColorBy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Color each dot by the group of artists it belongs to, or by the country the artist is from (the eight commonest get a color each; where artists are from comes from Settings › Sync › Artist origins).")
            Toggle("Artwork", isOn: $model.options.showArtwork)
                .toggleStyle(.checkbox)
                .help("Draw each artist's picture on its dot. The colored ring still shows its group, or its country.")
            Toggle("Show artists I haven't played", isOn: $model.options.showGhosts)
                .toggleStyle(.checkbox)
                .help("Also draw the artists Last.fm says are most similar to yours that you've never played, as dashed dots.")
        }
    }

    private var minMatchBinding: Binding<Double> {
        Binding(get: { Double(model.options.minMatchPercent) }, set: { model.options.minMatchPercent = Int($0.rounded()) })
    }

    // MARK: Status

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(model.statusText).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(2)
                if model.isLookingUp {
                    ProgressView(value: Double(model.lookupDone), total: Double(max(model.lookupTotal, 1))).frame(width: 140)
                    Text("\(model.lookupDone) of \(model.lookupTotal)").font(AppTypography.compactMetadata).monospacedDigit().foregroundStyle(.secondary)
                    Button("Stop") { model.stopLookup() }.controlSize(.small)
                } else if model.missingCount > 0 {
                    let noun = model.missingCount == 1 ? "artist" : "artists"
                    Button { model.lookUpMissing() } label: {
                        Label("\(model.lookupIsRefresh ? "Refresh" : "Look up") \(model.missingCount) \(noun)", systemImage: "arrow.triangle.2.circlepath")
                    }
                        .controlSize(.small)
                        .disabled(Connectivity.shared.isOffline)
                        .help(Connectivity.shared.isOffline
                              ? "Offline mode is on. Go online to look up similar artists."
                              : (model.lookupIsRefresh
                                 ? "These answers are more than 30 days old. They still draw the map; this asks Last.fm again."
                                 : "Asks Last.fm which artists are similar to each of these, a few at a time (about 40 seconds for 100). The answers are saved for 30 days, after which they are offered for a refresh."))
                }
                Spacer(minLength: 0)
            }
            if let message = model.lookupMessage {
                Text(message).font(AppTypography.compactMetadata).foregroundStyle(.orange)
            } else if !model.hasAnswers && model.scopeCount > 0 && !model.isLookingUp {
                Text("No similar-artist answers are saved for these artists yet. Look them up to draw the links.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.orange)
            }
        }
    }

    private var legend: some View {
        AskFlowLayout(spacing: 16) {
            Text("Dot size = plays").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            Text("Line thickness = match").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            if model.options.mode == .seed {
                Text("Closer to the seed = stronger match").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
            if model.options.colorBy == .country {
                if model.countryLegend.isEmpty {
                    Text("Color = the artist's country (none known yet)").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                } else {
                    Text("Color = country:").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    ForEach(model.countryLegend) { item in
                        HStack(spacing: 4) {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                            Text("\(item.name) (\(item.artists))").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Circle().fill(ArtistMapPalette.otherCountry).frame(width: 8, height: 8)
                        Text("others").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(ArtistMapPalette.unknownCountry).frame(width: 8, height: 8)
                        Text("not known").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Color = a group of artists that point at each other").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
            if model.options.showGhosts {
                Text("Dashed = not played").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func openArtist(_ name: String) { navigation.goToArtist(ArtistIdentity(name: name)) }

    private func query(_ name: String) {
        openQuery(ArtistMapLinks.querySpec(artist: name), "Artist Map · \(name)", "Tracks by \(name)")
    }
}

// MARK: - Canvas

private struct ArtistMapCanvas: View {
    @Bindable var model: ArtistMapModel
    let onOpen: (String) -> Void
    let onQuery: (String) -> Void

    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private let padding = ArtistMapModel.canvasPadding

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in draw(&context, size: size) }
                ForEach(Array(model.shown.nodes.enumerated()), id: \.element.key) { index, node in
                    hitArea(index: index, node: node, size: geo.size)
                }
                zoomControls
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.canvasChanged($0) }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in offset = CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height) }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(5, max(0.6, pinchBase * value.magnification)) }
                    .onEnded { _ in pinchBase = scale }
            )
            .onTapGesture { model.selectedKey = nil }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Artist map with \(model.shown.nodes.count) artists")
    }

    private func screenPoint(_ index: Int, size: CGSize) -> CGPoint {
        guard index < model.positions.count else { return .zero }
        let p = model.positions[index]
        let usableW = max(size.width - padding * 2, 1), usableH = max(size.height - padding * 2, 1)
        return CGPoint(
            x: size.width / 2 + (p.x - 0.5) * usableW * scale + offset.width + drag.width,
            y: size.height / 2 + (p.y - 0.5) * usableH * scale + offset.height + drag.height
        )
    }

    private func displayRadius(_ node: ArtistMapGraph.Node) -> CGFloat { model.radius(of: node) * min(max(scale, 0.8).squareRoot(), 1.6) }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let nodes = model.shown.nodes
        guard nodes.count == model.positions.count else { return }
        let selected = model.selectedKey
        let selectedIndex = model.index(ofKey: selected)
        let linked = selected.map { model.neighborKeys(of: $0) } ?? []
        for edge in model.shown.edges {
            let a = screenPoint(edge.a, size: size), b = screenPoint(edge.b, size: size)
            let hot = selectedIndex == edge.a || selectedIndex == edge.b
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let ghostLine = nodes[edge.a].isGhost || nodes[edge.b].isGhost
            let strength = edge.weight
            let color: Color = hot ? .accentColor : Color.secondary
            let opacity = hot ? 0.9 : (selected == nil ? 0.2 + strength * 0.4 : 0.08)
            context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: 0.6 + strength * 4.2, lineCap: .round, dash: ghostLine ? [4, 4] : []))
        }
        var labelled: [(index: Int, priority: Int)] = []
        let byPlays = nodes.indices.sorted { nodes[$0].plays != nodes[$1].plays ? nodes[$0].plays > nodes[$1].plays : $0 < $1 }
        let topLinked = Set(model.selection?.links.prefix(8).map(\.key) ?? [])
        let everyone = scale >= 2.5
        for (index, node) in nodes.enumerated() {
            var priority = 99
            if node.key == selected || node.key == model.seedKey { priority = 0 }
            else if node.key == model.hoveredKey { priority = 1 }
            else if topLinked.contains(node.key) { priority = 2 }
            else if everyone { priority = 4 }
            else if let rank = byPlays.firstIndex(of: index), rank < 14, !node.isGhost { priority = 3 + rank }
            if priority < 99 { labelled.append((index, priority)) }
        }
        labelled.sort { $0.priority != $1.priority ? $0.priority < $1.priority : $0.index < $1.index }
        var placed: [CGRect] = []
        var labelAt: [Int: CGPoint] = [:]
        for item in labelled {
            let node = nodes[item.index]
            let p = screenPoint(item.index, size: size)
            let r = displayRadius(node)
            let text = Self.shortName(node.name)
            let width = Self.estimatedWidth(text) + 6
            let frame = CGRect(x: p.x - width / 2, y: p.y + r + 2, width: width, height: 14)
            if item.priority > 1, placed.contains(where: { $0.intersects(frame) }) { continue }
            placed.append(frame)
            labelAt[item.index] = CGPoint(x: p.x, y: frame.midY)
        }
        for (index, node) in nodes.enumerated() {
            let p = screenPoint(index, size: size)
            let r = displayRadius(node)
            let isSelected = node.key == selected
            let dim = selected != nil && !isSelected && !linked.contains(node.key)
            let color = model.color(forKey: node.key, group: index < model.groups.groupOfNode.count ? model.groups.groupOfNode[index] : -1)
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if node.isGhost {
                context.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(circle, with: .color(.secondary.opacity(dim ? 0.4 : 0.9)), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
            } else {
                let ring: Color = isSelected ? Color.primary : (node.key == model.seedKey ? Color.accentColor : color)
                if model.options.showArtwork, let image = model.artwork[node.key] {
                    var layer = context
                    layer.clip(to: circle)
                    layer.opacity = dim ? 0.35 : 1
                    layer.draw(Image(nsImage: image), in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    context.stroke(circle, with: .color(ring.opacity(dim ? 0.5 : 1)), lineWidth: isSelected ? 3 : (node.key == model.seedKey ? 3.5 : 2.2))
                    // The outer ring marks the selection (or the seed), so the group's color goes just inside it.
                    if (isSelected || node.key == model.seedKey), r > 7 {
                        let inset = r - 3.6
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - inset, y: p.y - inset, width: inset * 2, height: inset * 2)), with: .color(color), lineWidth: 2.4)
                    }
                } else {
                    context.fill(circle, with: .color(color.opacity(dim ? 0.3 : 0.85)))
                    context.stroke(circle, with: .color(ring), lineWidth: isSelected ? 2.5 : (node.key == model.seedKey ? 3 : 1))
                }
            }
        }
        for (index, point) in labelAt {
            let node = nodes[index]
            let isSelected = node.key == selected
            let dim = selected != nil && !isSelected && !linked.contains(node.key)
            let label = Text(Self.shortName(node.name)).font(.system(size: 11, weight: isSelected ? .semibold : .regular)).foregroundColor(dim ? .secondary : .primary)
            context.draw(context.resolve(label), at: point, anchor: .center)
        }
    }

    /// Long names are cut for the map; the side panel and the tooltip carry the whole name.
    private static func shortName(_ name: String) -> String { name.count > 26 ? String(name.prefix(25)) + "…" : name }

    /// About how wide a label is in 11-point type (characters in other scripts are wider).
    private static func estimatedWidth(_ text: String) -> CGFloat {
        text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 11.5 : 6.2) }
    }

    @ViewBuilder
    private func hitArea(index: Int, node: ArtistMapGraph.Node, size: CGSize) -> some View {
        let r = max(displayRadius(node), 12)
        let base = Color.clear
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            .position(screenPoint(index, size: size))
            .onTapGesture { model.selectedKey = node.key }
            .onHover { inside in
                if inside { model.hoveredKey = node.key } else if model.hoveredKey == node.key { model.hoveredKey = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(node.isGhost ? "\(node.name), not played" : "\(node.name), \(node.plays) plays")
            .accessibilityAddTraits(.isButton)
        if node.isGhost {
            base.contextMenu {
                Button("View on Last.fm") { if let url = ArtistMapLinks.lastfmURL(artist: node.name) { NSWorkspace.shared.open(url) } }
            }
        } else {
            base.entityContextMenu(target: ImageTarget(kind: .artist, artist: node.name, album: nil, track: nil), onOpen: { onOpen(node.name) })
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 4) {
            Button { zoom(by: 1.3) } label: { Image(systemName: "plus") }.help("Zoom in")
            Button { zoom(by: 1 / 1.3) } label: { Image(systemName: "minus") }.help("Zoom out")
            Button { scale = 1; pinchBase = 1; offset = .zero } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit the whole map")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
    }

    private func zoom(by factor: CGFloat) {
        scale = min(5, max(0.6, scale * factor))
        pinchBase = scale
    }
}

// MARK: - Panel

private struct ArtistMapPanel: View {
    let model: ArtistMapModel
    let onOpen: (String) -> Void
    let onQuery: (String) -> Void
    let onSeed: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selection = model.selection {
                header(selection)
                Divider()
                links(selection)
                actions(selection)
            } else {
                Text("Select an artist to see who it is closest to.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(_ s: ArtistMapModel.Selection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.node.name).font(AppTypography.sectionTitle).lineLimit(2)
            if s.node.isGhost {
                Text("You haven't played this artist.").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            } else {
                if let origin = s.origin, origin.state == .known {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        Text("\(origin.label) \(origin.text)").font(AppTypography.compactMetadata).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(ArtistMapPalette.color(group: s.group)).frame(width: 10, height: 10)
                    Text(ArtistMapModel.groupDescription(selected: s.node.name, leader: s.groupName, size: s.groupSize)).font(AppTypography.compactMetadata)
                }
                .help(s.groupMembers.isEmpty ? "Not in a group of at least three artists that point at each other."
                      : "Its group's other biggest members: " + s.groupMembers.joined(separator: ", ") + (s.groupSize - 1 > s.groupMembers.count ? ", and more." : "."))
                if let groupOrigin = s.groupOrigin {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "globe").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        Text(groupOrigin).font(AppTypography.compactMetadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(s.node.key == model.seedKey ? "The seed · \(s.node.plays.formatted()) plays" : "\(s.node.plays.formatted()) plays in this period")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func links(_ s: ArtistMapModel.Selection) -> some View {
        Text("Closest links").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        if s.links.isEmpty {
            Text("No links at this minimum match.").font(AppTypography.supporting).foregroundStyle(.secondary)
        } else {
            ForEach(s.links.prefix(6)) { link in
                Button { model.selectedKey = link.key } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if !link.isGhost, link.group != s.group {
                                Circle().fill(model.color(forKey: link.key, group: link.group)).frame(width: 8, height: 8)
                            }
                            Text(link.name).font(AppTypography.supporting).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int((link.weight * 100).rounded()))%").font(AppTypography.compactMetadata).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: link.weight).progressViewStyle(.linear).controlSize(.mini)
                    }
                }
                .buttonStyle(.plain)
                .help(Self.directionText(selected: s.node.name, link: link) + (!link.isGhost && link.group != s.group
                      ? (link.group >= 0 ? " It is in another group (the colored dot)." : " It is not in a group (the gray dot).") : ""))
            }
            if s.links.prefix(6).contains(where: { !$0.isGhost && $0.group != s.group }) {
                Text("A colored dot marks a link that is in a different group from \(s.node.name).")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
            if let top = s.links.first, top.outgoing > 0, top.incoming > 0, abs(top.outgoing - top.incoming) >= 0.05 {
                Text("The line uses the higher of the two directions. \(Self.directionText(selected: s.node.name, link: top))")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ s: ArtistMapModel.Selection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if s.node.isGhost {
                Button { if let url = ArtistMapLinks.lastfmURL(artist: s.node.name) { NSWorkspace.shared.open(url) } } label: {
                    Label("View on Last.fm", systemImage: "safari").frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button { onOpen(s.node.name) } label: { Label("Open artist page", systemImage: "person.crop.circle").frame(maxWidth: .infinity, alignment: .leading) }
                Button { onQuery(s.node.name) } label: { Label("Open in Query", systemImage: "tablecells").frame(maxWidth: .infinity, alignment: .leading) }
                if s.node.key != model.seedKey {
                    Button { onSeed(s.node.name) } label: { Label("Map from this artist", systemImage: "scope").frame(maxWidth: .infinity, alignment: .leading) }
                        .help("Draw a map with this artist in the middle.")
                }
            }
        }
        .controlSize(.small)
    }

    private static func directionText(selected: String, link: ArtistMapModel.Link) -> String {
        func pct(_ v: Double) -> String { v > 0 ? "\(Int((v * 100).rounded()))%" : "not listed" }
        return "\(selected) lists \(link.name) at \(pct(link.outgoing)); \(link.name) lists \(selected) at \(pct(link.incoming))."
    }
}

#if DEBUG
extension ArtistMapModel {
    /// Made-up artists for the offscreen snapshots: three clusters, a few bridges between them, some never-played artists and some awkward
    /// names (very long, another script).
    private static func sampleData(artists: Int) -> (scope: [ArtistMapEntry], answers: [String: [SimilarArtist]]) {
        var rng = SeededRandom(seed: 7)
        var scope: [ArtistMapEntry] = []
        var answers: [String: [SimilarArtist]] = [:]
        var firstOfCluster: [String] = []
        let clusters = ["Alpha", "Bravo", "Charlie"]
        for (c, cluster) in clusters.enumerated() {
            let names = (1...max(artists / 3, 4)).map { i -> String in
                switch i {
                case 3: "\(cluster) Band With A Very Long Name That Keeps Going"
                case 5: "日本のバンド \(cluster)"
                default: "\(cluster) \(i)"
                }
            }
            firstOfCluster.append(names[0])
            for (i, name) in names.enumerated() { scope.append(ArtistMapEntry(name: name, plays: max(20, 4000 / (i + 1) - c * 150))) }
            for (i, name) in names.enumerated() {
                var list: [SimilarArtist] = []
                for j in names.indices where j != i {
                    let r = Double(rng.next() % 1000) / 1000
                    if r < 0.28 { list.append(SimilarArtist(name: names[j], match: 0.35 + r * 2)) }
                }
                if i % 6 == 0 { list.append(SimilarArtist(name: "Never Played \(c)-\(i % 5)", match: 0.5 + Double(i % 4) * 0.1)) }
                answers[ArtistMapNames.key(name), default: []] += list
            }
        }
        for c in clusters.indices {
            let from = ArtistMapNames.key(firstOfCluster[c]), to = firstOfCluster[(c + 1) % clusters.count]
            answers[from, default: []].append(SimilarArtist(name: to, match: 0.45))
        }
        return (scope, answers)
    }

    /// Marks some artists as waiting for a lookup (and, if `stale`, as old answers to refresh), so a snapshot shows the status strip's button.
    func installSampleWaiting(count: Int, stale: Bool) {
        let names = shown.nodes.filter { !$0.isGhost }.prefix(count).map(\.name)
        lookupTargets = names
        if stale { staleKeys = Set(names.map { ArtistMapNames.key($0) }) }
        answeredCount = max(0, scopeCount - names.count)
    }

    /// Pictures for two artists in three, made up (a color block with a stripe), so the snapshots show how artwork sits on a dot.
    func installSampleArtwork() {
        for (index, node) in shown.nodes.enumerated() where !node.isGhost && index % 3 != 1 {
            let image = NSImage(size: NSSize(width: 120, height: 120))
            image.lockFocus()
            NSColor(hue: CGFloat((index * 37) % 100) / 100, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 120, height: 120).fill()
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSRect(x: 0, y: 50, width: 120, height: 22).fill()
            image.unlockFocus()
            artwork[node.key] = image
        }
    }

    private func install(scope: [ArtistMapEntry], answers: [String: [SimilarArtist]], graph: ArtistMapGraph, positions: [CGPoint]) {
        self.scope = scope
        libraryKeys = Set(scope.map { ArtistMapNames.key($0.name) })
        self.answers = answers
        scopeCount = scope.count
        answeredCount = scope.count
        hasAnswers = true
        shown = graph
        groups = ArtistMapGroups.find(in: graph)
        self.positions = positions
        isLoadingHistory = false
        hasHistory = true
        isSnapshotSample = true
    }

    /// A made-up map for the offscreen snapshots.
    static func sample(container: ModelContainer, artists: Int = 60, showGhosts: Bool = true, minMatch: Int = 40, canvas: CGSize = ArtistMapLayout.defaultCanvas) -> ArtistMapModel {
        let model = ArtistMapModel(container: container)
        model.canvasSize = canvas
        let data = sampleData(artists: artists)
        model.options.showGhosts = showGhosts
        model.options.minMatchPercent = minMatch
        let keys = Set(data.scope.map { ArtistMapNames.key($0.name) })
        let graph = ArtistMapGraph.build(scope: data.scope, libraryKeys: keys, neighbors: data.answers).filtered(minMatch: Double(minMatch) / 100, showGhosts: showGhosts)
        let top = graph.nodes.map(\.plays).max() ?? 1
        let positions = ArtistMapLayout.force(graph: graph, canvas: canvas, radii: graph.nodes.map { Double(radius(of: $0, maxPlays: top, scale: dotScale(for: canvas))) })
        model.install(scope: data.scope, answers: data.answers, graph: graph, positions: positions)
        model.installSampleArtwork()
        // An artist that has a picture, so a snapshot shows the selection ring over artwork.
        model.selectedKey = graph.nodes.first { $0.name.hasPrefix("Bravo") && model.artwork[$0.key] != nil }?.key ?? graph.nodes.first?.key
        return model
    }

    /// Gives the artists of a made-up map origins (three clusters, each mostly from one country, some artists with none) and colors it by country.
    func installSampleOrigins() {
        var snapshot = QueryOriginSnapshot(lookupsOn: true)
        func place(_ city: String, _ country: String, _ code: String) -> OriginPlace { OriginPlace(city: city, region: nil, country: country, countryCode: code) }
        let pools: [[OriginPlace]] = [
            [place("City A", "United Kingdom", "GB"), place("City A", "United Kingdom", "GB"), place("City B", "United Kingdom", "GB"), place("City C", "Ireland", "IE")],
            [place("City D", "United States", "US"), place("City E", "United States", "US"), place("City F", "United States", "US"), place("City G", "Canada", "CA")],
            [place("City H", "Sweden", "SE"), place("City I", "Germany", "DE"), place("City J", "Japan", "JP"), place("City K", "Sweden", "SE")],
        ]
        for node in shown.nodes where !node.isGhost {
            let cluster = node.name.contains("Alpha") ? 0 : node.name.contains("Bravo") ? 1 : 2
            let spread = node.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            if spread % 9 == 0 { continue }
            snapshot.entries[TextNormalization.artistIdentityKey(node.name)] = OriginEntrySnapshot(
                status: .found, mbid: "m", matchedName: nil, kind: .group, place: pools[cluster][spread % pools[cluster].count], candidates: [], resolvedAt: Date()
            )
        }
        origins = snapshot
        options.colorBy = .country
        refreshCountries()
    }

    /// A made-up map drawn from a seed, for the offscreen snapshots.
    static func sampleSeed(container: ModelContainer, steps: Int = 2, showGhosts: Bool = true, minMatch: Int = 30, canvas: CGSize = ArtistMapLayout.defaultCanvas) -> ArtistMapModel {
        let model = ArtistMapModel(container: container)
        model.canvasSize = canvas
        let data = sampleData(artists: 90)
        var answers = data.answers
        let seed = "Bravo 2"
        // The seed's own answer is long and strong, as a real one is; only the seed and its neighbors have answers, like a real lookup.
        let library = Dictionary(data.scope.map { (ArtistMapNames.key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        var seedList = (answers[ArtistMapNames.key(seed)] ?? []).filter { library[ArtistMapNames.key($0.name)] != nil }
        for (i, entry) in data.scope.filter({ $0.name.hasPrefix("Alpha") || $0.name.hasPrefix("Charlie") }).prefix(6).enumerated() {
            seedList.append(SimilarArtist(name: entry.name, match: 0.32 + Double(i) * 0.03))
        }
        seedList.append(SimilarArtist(name: "Never Played Seed", match: 0.62))
        answers[ArtistMapNames.key(seed)] = seedList
        let ringKeys = Set(ArtistMapSeedScope.build(seed: seed, library: library, answers: answers, steps: 1).scope.map { ArtistMapNames.key($0.name) })
        answers = answers.filter { ringKeys.contains($0.key) }
        let result = ArtistMapSeedScope.build(seed: seed, library: library, answers: answers, steps: steps)
        model.options.mode = .seed
        model.options.seedArtist = seed
        model.options.reach = steps
        model.options.showGhosts = showGhosts
        model.options.minMatchPercent = minMatch
        model.library = library
        let graph = ArtistMapGraph.build(scope: result.scope, libraryKeys: Set(library.keys), neighbors: answers)
            .filtered(minMatch: Double(minMatch) / 100, showGhosts: showGhosts, alwaysKeep: ArtistMapNames.key(seed))
        let groups = ArtistMapGroups.find(in: graph)
        let order = graph.nodes.indices.sorted { a, b in
            let ga = groups.groupOfNode[a] < 0 ? Int.max : groups.groupOfNode[a], gb = groups.groupOfNode[b] < 0 ? Int.max : groups.groupOfNode[b]
            return ga != gb ? ga < gb : a < b
        }
        let top = graph.nodes.map(\.plays).max() ?? 1
        let positions = ArtistMapLayout.radial(graph: graph, seedKey: ArtistMapNames.key(seed), canvas: canvas, radii: graph.nodes.map { Double(radius(of: $0, maxPlays: top)) }, order: order)
        model.install(scope: result.scope, answers: answers, graph: graph, positions: positions)
        model.lookupTargets = result.lookups
        model.installSampleArtwork()
        model.selectedKey = ArtistMapNames.key(seed)
        return model
    }
}
#endif

#if DEBUG
extension ArtistMapModel {
    /// Removes the map's saved answers (in the copy of a library the test runs on), so a run starts with real lookups to make.
    func clearSavedAnswers() async {
        let container = self.container
        await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let entries = (try? context.fetch(FetchDescriptor<SimilarityLookupCacheEntry>())) ?? []
            for entry in entries where entry.cacheKey.hasPrefix("artistmap") { context.delete(entry) }
            try? context.save()
        }.value
    }

    /// What the self-driving tour (`Tour`) does on this screen, the way a person would use it, against a stand-in Last.fm server: look up
    /// a whole map, drag the slider, select artists, change the count (stopping and restarting lookups on the way), switch to a seed and
    /// back. Logs what it did, so a crash or a stall shows up in the tour's log.
    func runTourScript() async {
        func log(_ line: String) { Tour.log("ARTISTMAP \(line)") }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func waitForLookups(_ limit: Double) async {
            let end = Date().addingTimeInterval(limit)
            while isLookingUp, Date() < end { await pause(0.4) }
        }
        log("script start")
        await clearSavedAnswers()
        options.mode = .top
        options.periodId = "alltime"
        options.count = 100
        options.minMatchPercent = 40
        // Read the (now empty) saved answers again even if no setting changed, so there are real lookups to make.
        await rescope()
        await pause(2)
        log("top \(scopeCount) artists, \(lookupTargets.count) to look up")
        lookUpMissing()
        await waitForLookups(120)
        log("lookups done: \(answeredCount) answered, \(shown.edges.count) links, lookingUp=\(isLookingUp)")
        for percent in [30, 50, 70, 90, 60, 40] {
            options.minMatchPercent = percent
            await pause(0.7)
        }
        for node in shown.nodes.prefix(6) { selectedKey = node.key; await pause(0.3) }
        options.showGhosts = true; await pause(1.5)
        options.showArtwork = false; await pause(1)
        options.showArtwork = true; await pause(1)
        options.showGhosts = false; await pause(1)
        // A bigger map: stop its lookups part-way, then carry on.
        options.count = 200
        await pause(2.5)
        lookUpMissing()
        await pause(4)
        stopLookup()
        await pause(1.5)
        log("stopped part-way: \(answeredCount) answered, lookingUp=\(isLookingUp)")
        lookUpMissing()
        await waitForLookups(180)
        log("200 map: \(answeredCount) answered, \(shown.edges.count) links")
        for count in [25, 10, 100] { options.count = count; await pause(2) }
        // From a seed.
        let artists = shown.nodes.filter { !$0.isGhost }.map(\.name)
        if let first = artists.first {
            chooseSeed(first)
            await pause(3)
            await waitForLookups(90)
            log("seed \(first): \(shown.nodes.count) artists, \(shown.edges.count) links")
            options.reach = 2; await pause(3)
            for percent in [30, 60, 45] { options.minMatchPercent = percent; await pause(0.7) }
            options.showGhosts = true; await pause(1.5)
            if artists.count > 1 { chooseSeed(artists[1]); await pause(3); await waitForLookups(90) }
            options.reach = 1; await pause(2)
        }
        options.mode = .top
        await pause(3)
        log("script done")
    }
}
#endif
