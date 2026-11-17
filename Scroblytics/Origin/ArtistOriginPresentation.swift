import Foundation
import SwiftData

/// What the Artist page knows about where the artist is from: what to show, and what the edit sheet starts from.
struct ArtistOriginPageState: Sendable, Equatable {
    var display: ArtistOriginDisplay
    /// The place as looked up, before any edit of the person's (shown as "Detected" in the editor).
    var detected: OriginPlace?
    var detectedKind: ArtistOriginKind?
    var detectedStatus: ArtistOriginStatus?
    var matchedMBID: String?
    /// The other artists that shared the name (only for a best guess).
    var candidates: [ArtistOriginCandidate]
    var edit: OriginEditSnapshot?

    static func make(entry: OriginEntrySnapshot?, edit: OriginEditSnapshot?) -> ArtistOriginPageState {
        ArtistOriginPageState(
            display: ArtistOriginResolver.display(entry: entry, edit: edit),
            detected: entry.flatMap { $0.status == .none || $0.place.isEmpty ? nil : $0.place },
            detectedKind: entry?.kind, detectedStatus: entry?.status, matchedMBID: entry?.mbid,
            candidates: entry?.candidates ?? [], edit: edit
        )
    }

    /// Reads one artist's saved lookup and the person's decisions, off the main actor.
    static func load(artist: String, container: ModelContainer) async -> ArtistOriginPageState? {
        let key = TextNormalization.artistIdentityKey(artist)
        guard !key.isEmpty, let saved = try? await offMain({ try await ArtistOriginDataStore(modelContainer: container).snapshots(for: [artist]) }) else { return nil }
        return make(entry: saved[key]?.entry, edit: saved[key]?.edit)
    }
}

enum ArtistOriginFact {
    /// The Artist page's tile: "Born in" or "Formed in" and the place, a pencil to correct it, a flag on a best guess nobody has checked.
    /// Before anything is known it says "Checking…", or "Unknown" when looking up is switched off.
    @MainActor
    static func tile(_ state: ArtistOriginPageState?, lookupsOn: Bool, onEdit: @escaping () -> Void) -> DetailFact {
        let display = state?.display ?? ArtistOriginDisplay(state: .pending, place: OriginPlace(), kind: nil, corrected: false, needsReview: false)
        var fact = DetailFact(
            id: "origin", label: display.label, value: .loading, mayHaveDetail: true,
            systemImage: "mappin.and.ellipse", help: "Where this artist was born or formed, from MusicBrainz. Use the pencil to correct it.",
            onEdit: onEdit, editHelp: "Edit where this artist is from"
        )
        fact.allowsTwoLines = true
        switch display.state {
        case .pending:
            if lookupsOn {
                fact.value = .loading
            } else {
                fact.value = .unknown
                fact.detail = "Lookups are off"
            }
        case .unknown:
            fact.value = .unknown
            fact.detail = "Not found on MusicBrainz"
        case .known:
            fact.value = .text(display.text)
            fact.help = display.text
            fact.corrected = display.corrected
            if display.needsReview {
                fact.detail = "Best guess: check"
                fact.attention = true
                fact.editHelp = "Check this match, or correct where this artist is from"
            }
        }
        return fact
    }
}

/// The countries the editor offers, by name, so the same country is always spelled the same way.
enum ArtistOriginCountries {
    struct Country: Identifiable, Hashable, Sendable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let all: [Country] = {
        let english = Locale(identifier: "en_US")
        return Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .compactMap { code in english.localizedString(forRegionCode: code).map { Country(code: code, name: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func name(forCode code: String) -> String? {
        all.first { $0.code == code.uppercased() }?.name
    }
}
