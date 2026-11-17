import Foundation
import SwiftData

/// The SwiftData side of artist origins, on its own background context so a sweep over thousands of artists and its saves never touch
/// the main actor. Holds the looked-up places (`ArtistOriginEntry`, `OriginAreaCacheEntry`) and the person's decisions (`ArtistOriginEdit`).
@ModelActor
actor ArtistOriginDataStore: OriginAreaProviding {
    // MARK: Reading

    /// The saved lookup and the person's decisions for each of `artists`, keyed by `TextNormalization.artistIdentityKey`.
    func snapshots(for artists: [String]) throws -> [String: (entry: OriginEntrySnapshot?, edit: OriginEditSnapshot?)] {
        let wanted = Set(artists.map(TextNormalization.artistIdentityKey))
        var entries: [String: OriginEntrySnapshot] = [:]
        for row in try modelContext.fetch(FetchDescriptor<ArtistOriginEntry>()) where wanted.contains(row.normalizedName) {
            entries[row.normalizedName] = OriginEntrySnapshot(row: row)
        }
        var edits: [String: OriginEditSnapshot] = [:]
        for row in try modelContext.fetch(FetchDescriptor<ArtistOriginEdit>()) where wanted.contains(row.normalizedName) {
            edits[row.normalizedName] = OriginEditSnapshot(row: row)
        }
        return Dictionary(uniqueKeysWithValues: wanted.map { ($0, (entries[$0], edits[$0])) })
    }

    /// Every saved lookup and decision (what a Query run and Missing Data read).
    func allSnapshots() throws -> (entries: [String: OriginEntrySnapshot], edits: [String: OriginEditSnapshot]) {
        var entries: [String: OriginEntrySnapshot] = [:]
        for row in try modelContext.fetch(FetchDescriptor<ArtistOriginEntry>()) { entries[row.normalizedName] = OriginEntrySnapshot(row: row) }
        var edits: [String: OriginEditSnapshot] = [:]
        for row in try modelContext.fetch(FetchDescriptor<ArtistOriginEdit>()) { edits[row.normalizedName] = OriginEditSnapshot(row: row) }
        return (entries, edits)
    }

    // MARK: Saving a lookup

    /// Records answers (found, guess or a genuine miss), replacing the earlier ones; the sweep saves every few lookups. A failed lookup never gets here.
    func save(_ results: [(artist: String, outcome: ArtistOriginLookup.Outcome)], at date: Date = Date()) throws {
        for result in results {
            let key = TextNormalization.artistIdentityKey(result.artist)
            guard !key.isEmpty else { continue }
            var descriptor = FetchDescriptor<ArtistOriginEntry>(predicate: #Predicate { $0.normalizedName == key })
            descriptor.fetchLimit = 1
            let row: ArtistOriginEntry
            if let existing = try modelContext.fetch(descriptor).first {
                row = existing
            } else {
                row = ArtistOriginEntry(normalizedName: key, status: result.outcome.status.rawValue, resolvedAt: date)
                modelContext.insert(row)
            }
            row.status = result.outcome.status.rawValue
            row.mbid = result.outcome.mbid
            row.matchedName = result.outcome.matchedName
            row.kind = result.outcome.kind?.rawValue
            row.cityName = result.outcome.place.city
            row.regionName = result.outcome.place.region
            row.countryName = result.outcome.place.country
            row.countryCode = result.outcome.place.countryCode
            row.candidatesJSON = result.outcome.candidates.isEmpty ? nil : try? JSONEncoder().encode(result.outcome.candidates)
            row.resolvedAt = date
        }
        try modelContext.save()
    }

    /// Deletes every looked-up place and area (the person's own edits stay). Forgetting makes the next sweep ask again.
    func forgetLookups() throws {
        for row in try modelContext.fetch(FetchDescriptor<ArtistOriginEntry>()) { modelContext.delete(row) }
        for row in try modelContext.fetch(FetchDescriptor<OriginAreaCacheEntry>()) { modelContext.delete(row) }
        try modelContext.save()
    }

    // MARK: Areas (OriginAreaProviding)

    func cached(_ id: String) async -> MBAreaInfo? {
        var descriptor = FetchDescriptor<OriginAreaCacheEntry>(predicate: #Predicate { $0.areaMBID == id })
        descriptor.fetchLimit = 1
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        return MBAreaInfo(id: row.areaMBID, name: row.name, type: row.type, iso31661: row.iso31661, iso31662: row.iso31662, parentID: row.parentMBID)
    }

    func save(_ area: MBAreaInfo) async {
        let id = area.id
        var descriptor = FetchDescriptor<OriginAreaCacheEntry>(predicate: #Predicate { $0.areaMBID == id })
        descriptor.fetchLimit = 1
        if let row = try? modelContext.fetch(descriptor).first {
            row.name = area.name; row.type = area.type; row.iso31661 = area.iso31661; row.iso31662 = area.iso31662
            row.parentMBID = area.parentID; row.cachedAt = Date()
        } else {
            modelContext.insert(OriginAreaCacheEntry(
                areaMBID: id, name: area.name, type: area.type, iso31661: area.iso31661, iso31662: area.iso31662,
                parentMBID: area.parentID, cachedAt: Date()
            ))
        }
        try? modelContext.save()
    }

    // MARK: The person's decisions

    private func editRow(for artist: String, create: Bool) throws -> ArtistOriginEdit? {
        let key = TextNormalization.artistIdentityKey(artist)
        guard !key.isEmpty else { return nil }
        var descriptor = FetchDescriptor<ArtistOriginEdit>(predicate: #Predicate { $0.normalizedName == key })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first { return existing }
        guard create else { return nil }
        let row = ArtistOriginEdit(normalizedName: key, artist: artist)
        modelContext.insert(row)
        return row
    }

    /// Drops an edit row that no longer decides anything, so a reset leaves nothing behind.
    private func pruneIfEmpty(_ row: ArtistOriginEdit) {
        if !row.hasPlaceOverride, row.chosenMBID == nil, !row.confirmed { modelContext.delete(row) }
    }

    /// The person's own place. Blank fields are left out; if all three are blank this is a reset.
    func setPlace(_ place: OriginPlace, for artist: String) throws {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let row = try editRow(for: artist, create: true) else { return }
        row.overrideCity = clean(place.city)
        row.overrideRegion = clean(place.region)
        row.overrideCountry = clean(place.country)
        row.overrideCountryCode = row.overrideCountry == nil ? nil : clean(place.countryCode)?.uppercased()
        row.confirmed = row.hasPlaceOverride ? false : row.confirmed
        pruneIfEmpty(row)
        try modelContext.save()
    }

    /// "Reset to Detected": removes the person's place and keeps their other decisions.
    func resetPlace(for artist: String) throws {
        guard let row = try editRow(for: artist, create: false) else { return }
        row.overrideCity = nil; row.overrideRegion = nil; row.overrideCountry = nil; row.overrideCountryCode = nil
        pruneIfEmpty(row)
        try modelContext.save()
    }

    /// "Looks right": a best guess the person checked.
    func confirm(_ artist: String, confirmed: Bool = true) throws {
        guard let row = try editRow(for: artist, create: confirmed) else { return }
        row.confirmed = confirmed
        pruneIfEmpty(row)
        try modelContext.save()
    }

    /// The MusicBrainz artist the person picked for this name (`nil` goes back to matching by name). The saved lookup is kept until the
    /// next lookup replaces it, and picking one counts as reviewing the match.
    func choose(mbid: String?, for artist: String) throws {
        guard let row = try editRow(for: artist, create: mbid != nil) else { return }
        row.chosenMBID = mbid
        if mbid != nil { row.confirmed = true }
        pruneIfEmpty(row)
        try modelContext.save()
    }
}
