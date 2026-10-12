import Foundation

/// How a walk picks one of the three suggestions at each step.
enum RabbitHoleWalkRule: String, CaseIterable, Codable, Identifiable, Sendable {
    case mostSimilar, balanced, wander, leastRecent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostSimilar: "Most similar"
        case .balanced: "Balanced"
        case .wander: "Wander"
        case .leastRecent: "Least recently played"
        }
    }

    /// The steering used to draw each step's three, in place of the page's own settings.
    func knobs(base: RabbitHoleKnobs) -> RabbitHoleKnobs {
        var knobs = base
        switch self {
        case .mostSimilar: knobs.wander = 0; knobs.familiarity = 0
        case .balanced: break
        case .wander: knobs.wander = 2
        case .leastRecent: knobs.familiarity = -2
        }
        return knobs
    }
}

/// How long a walk goes on for.
enum RabbitHoleWalkLength: String, CaseIterable, Codable, Identifiable, Sendable {
    case minutes30, minutes60, minutes90, tracks10, tracks20, tracks30

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minutes30: "30 minutes"
        case .minutes60: "60 minutes"
        case .minutes90: "90 minutes"
        case .tracks10: "10 tracks"
        case .tracks20: "20 tracks"
        case .tracks30: "30 tracks"
        }
    }

    var targetSeconds: Double? {
        switch self {
        case .minutes30: 30 * 60
        case .minutes60: 60 * 60
        case .minutes90: 90 * 60
        default: nil
        }
    }

    var targetTracks: Int? {
        switch self {
        case .tracks10: 10
        case .tracks20: 20
        case .tracks30: 30
        default: nil
        }
    }
}

/// "Take steps for me": extends the current path one suggestion at a time, by a rule, until the length is reached. Every step is an
/// ordinary node (with the three options it chose from), so the tree, Back One Step and the playlist export all work on a walk.
enum RabbitHoleWalk {
    /// A walk never goes further than this many steps, whatever the length.
    static let maxSteps = 40
    /// Used for a track whose length isn't known yet (the result is then marked approximate).
    static let assumedTrackSeconds = 210.0
    /// Dead ends tolerated before the walk stops.
    static let maxDeadEnds = 3

    struct Progress: Sendable {
        var tracksAdded = 0
        var seconds = 0.0
        var approximate = false
    }

    enum Ending: Equatable, Sendable {
        case reachedLength, stoppedByUser, deadEnd, stepLimit, failed(String)
    }

    struct Result: Sendable {
        var tree: RabbitHoleTree
        var memory: RabbitHoleMemory
        var progress: Progress
        /// The nodes this walk created that are still on the path, in order (for "Remove last walk").
        var addedNodeIDs: [UUID]
        var ending: Ending
    }

    /// Which of the offered tracks the rule takes.
    static func choose(from candidates: [RabbitHoleTrack], rule: RabbitHoleWalkRule, using rng: inout some RandomNumberGenerator) -> RabbitHoleTrack? {
        guard !candidates.isEmpty else { return nil }
        switch rule {
        case .mostSimilar:
            let best = candidates.map(\.matchScore).max() ?? 0
            return candidates.filter { $0.matchScore == best }.randomElement(using: &rng)
        case .leastRecent:
            return candidates.min { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
        case .balanced, .wander:
            return candidates.randomElement(using: &rng)
        }
    }

    static func isDone(_ progress: Progress, length: RabbitHoleWalkLength) -> Bool {
        if let seconds = length.targetSeconds { return progress.seconds >= seconds }
        if let tracks = length.targetTracks { return progress.tracksAdded >= tracks }
        return true
    }

    /// Runs a walk from the tree's current node. `candidatesFor` offers the three for a node (the real one asks the engine);
    /// `seconds` gives a track's length if known. `onProgress` hears the tree after each step so the page can follow along.
    /// Cancelling the task ends the walk where it is, with a valid tree.
    @MainActor
    static func run(
        length: RabbitHoleWalkLength, rule: RabbitHoleWalkRule, tree startTree: RabbitHoleTree, memory startMemory: RabbitHoleMemory,
        candidatesFor: (RabbitHoleTree, RabbitHoleNode, RabbitHoleMemory) async throws -> [RabbitHoleTrack],
        seconds: (RabbitHoleTrack) -> Double?,
        onProgress: (RabbitHoleTree, Progress) -> Void = { _, _ in },
        using rng: inout some RandomNumberGenerator
    ) async throws -> Result {
        var tree = startTree
        var memory = startMemory
        var progress = Progress()
        var added: [UUID] = []
        var durations: [UUID: Double] = [:]
        var deadTracks = Set<String>()
        var deadEnds = 0
        var steps = 0
        var ending = Ending.reachedLength
        let startID = tree.currentID
        guard var currentID = tree.currentID, tree.nodes[currentID] != nil else {
            return Result(tree: tree, memory: memory, progress: progress, addedNodeIDs: [], ending: .deadEnd)
        }

        while !isDone(progress, length: length) {
            if Task.isCancelled { ending = .stoppedByUser; break }
            if steps >= maxSteps { ending = .stepLimit; break }
            guard let node = tree.nodes[currentID] else { break }
            var offered = node.candidates ?? []
            if offered.isEmpty {
                do { offered = try await candidatesFor(tree, node, memory) }
                catch is CancellationError { ending = .stoppedByUser; break }
                catch { ending = .failed(error.localizedDescription); break }
                tree.nodes[currentID]?.candidates = offered
                memory.noteShown(offered.map(\.id))
            }
            let usable = offered.filter { !deadTracks.contains($0.id) }
            guard let choice = choose(from: usable, rule: rule, using: &rng) else {
                // Nothing to offer from here: back up one step (the node is left in the tree as an explored dead end) and look again.
                deadEnds += 1
                // Never back up past the track the walk began from: that is the person's own position.
                guard currentID != startID, let parentID = node.parentID else { ending = .deadEnd; break }
                deadTracks.insert(node.track.id)
                if let seconds = durations.removeValue(forKey: currentID) {
                    progress.seconds -= seconds
                    progress.tracksAdded -= 1
                    added.removeAll { $0 == currentID }
                }
                currentID = parentID
                tree.currentID = parentID
                if deadEnds > maxDeadEnds { ending = .deadEnd; onProgress(tree, progress); break }
                tree.nodes[parentID]?.candidates = nil
                onProgress(tree, progress)
                continue
            }
            let id = UUID()
            tree.nodes[id] = RabbitHoleNode(id: id, track: choice, parentID: currentID, candidates: nil, childIDs: [])
            tree.nodes[currentID]?.childIDs.append(id)
            tree.currentID = id
            currentID = id
            memory.noteChosen(choice.id)
            let trackSeconds = seconds(choice)
            if trackSeconds == nil { progress.approximate = true }
            durations[id] = trackSeconds ?? assumedTrackSeconds
            progress.seconds += trackSeconds ?? assumedTrackSeconds
            progress.tracksAdded += 1
            added.append(id)
            steps += 1
            onProgress(tree, progress)
        }
        if isDone(progress, length: length) { ending = .reachedLength }
        return Result(tree: tree, memory: memory, progress: progress, addedNodeIDs: added, ending: ending)
    }

    /// Takes a walk off the path again: the nodes it added are removed and the page goes back to where the walk began.
    static func remove(walk addedNodeIDs: [UUID], from tree: RabbitHoleTree) -> RabbitHoleTree {
        guard let first = addedNodeIDs.first, let startID = tree.nodes[first]?.parentID else { return tree }
        var result = tree
        for id in addedNodeIDs {
            if let parent = result.nodes[id]?.parentID { result.nodes[parent]?.childIDs.removeAll { $0 == id } }
            result.nodes.removeValue(forKey: id)
        }
        result.nodes[startID]?.candidates = nil
        result.currentID = startID
        return result
    }
}
