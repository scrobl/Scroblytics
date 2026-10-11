import Foundation

/// Registry fields that WRAP `BPMEngine`. Precedence (your correction > cached lookup > confirmed miss > unresolved)
/// is `BPMEngine.Snapshot.resolution`, the one function every screen reads.
extension QueryFieldRegistry {
    private static func tempoField(
        id: String, name: String, type: QueryValueType, help: String, column: QueryColumnSpec? = nil,
        value: @escaping @Sendable (BPMEngine.Resolved) -> QueryValue?
    ) -> QueryField {
        QueryField(
            id: id, name: name, group: .tempo, type: type, targets: [.track], column: column, help: help,
            isBackgroundResolved: true, resolver: .bpm
        ) { run, _, entities in
            let snapshot = run.snapshots.bpm
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                switch snapshot.resolution(forKey: BPMEngine.cacheKey(artist: entity.artist, track: entity.name)) {
                case .value(let resolved): return (entity.id, value(resolved).map { .value($0) } ?? .missing)
                case .noMatch: return (entity.id, .missing)
                case .pending: return (entity.id, .pending)
                }
            })
        }
    }

    static let bpmFields: [QueryField] = {
        var bucket = tempoField(
            id: "tempoBucket", name: "Tempo range", type: .text,
            help: "The track’s tempo as a preset range: Slow (under 90 BPM), Moderate (90–120), Upbeat (120–140), Fast (140–160) or Very fast (160+). Use BPM for an exact span. “Missing” means no tempo could be found; a value still being looked up matches neither.",
            column: .standard(for: .text, width: 170)
        ) { .text(TempoBucket.bucket(for: $0.bpm).rawValue) }
        bucket.choices = TempoBucket.allCases.map(\.rawValue)
        var source = tempoField(
            id: "bpmSource", name: "Tempo source", type: .text,
            help: "Where the track’s tempo came from: GetSongBPM, Deezer, or entered by you. A track with no tempo never matches.",
            column: .standard(for: .text, width: 130)
        ) { .text($0.source.label) }
        source.choices = BPMSource.allCases.map(\.label)
        return [
            tempoField(
                id: "bpm", name: "BPM", type: .numeric,
                help: "The track’s tempo in beats per minute. A tempo you entered wins over the one found online. “Missing” means no tempo could be found; a value still being looked up matches neither.",
                column: .standard(for: .numeric, style: .tempo, width: 90)
            ) { .number($0.bpm) },
            bucket,
            source,
            tempoField(
                id: "timeSignature", name: "Time signature", type: .text,
                help: "The track’s time signature as GetSongBPM reports it, such as 4/4 or 3/4. Only tempos found by GetSongBPM carry one; the rest are missing.",
                column: .standard(for: .text, width: 110)
            ) { $0.timeSignature.map(QueryValue.text) },
            tempoField(
                id: "musicalKey", name: "Musical key", type: .text,
                help: "The track’s key as GetSongBPM reports it, such as Cm or F#. Only tempos found by GetSongBPM carry one; the rest are missing.",
                column: .standard(for: .text, width: 110)
            ) { $0.musicalKey.map(QueryValue.text) },
        ]
    }()
}
