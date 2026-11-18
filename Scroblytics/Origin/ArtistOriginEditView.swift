import Observation
import SwiftData
import SwiftUI

/// What the edit sheet shows and does for one artist. Reads and writes through `ArtistOriginDataStore`; nothing is sent anywhere until
/// the person asks to search MusicBrainz for a different match.
@MainActor
@Observable
final class ArtistOriginEditModel {
    let artist: String
    private let container: ModelContainer?

    var city = ""
    var region = ""
    /// ISO code of the chosen country, "" for none.
    var countryCode = ""
    private(set) var state: ArtistOriginPageState?
    private(set) var loaded = false
    private(set) var isBusy = false
    private(set) var isSearching = false
    /// Candidates from a live search (the saved ones, for a best guess, are in `state`).
    private(set) var searched: [ArtistOriginCandidate]?
    private(set) var message: String?

    init(artist: String, container: ModelContainer?) {
        self.artist = artist
        self.container = container
    }

    /// A made-up state for layout snapshots; it never touches a database.
    static func sample(artist: String, state: ArtistOriginPageState, city: String, region: String, countryCode: String, searched: [ArtistOriginCandidate]? = nil, message: String? = nil) -> ArtistOriginEditModel {
        let model = ArtistOriginEditModel(artist: artist, container: nil)
        model.state = state
        model.city = city
        model.region = region
        model.countryCode = countryCode
        model.searched = searched
        model.message = message
        model.loaded = true
        return model
    }

    var hasOverride: Bool { state?.edit?.place != nil }
    var needsReview: Bool { state?.display.needsReview == true }
    var hasDetected: Bool { state?.detected != nil }
    var detectedText: String? { state?.detected?.text }
    var lookupsOn: Bool { ArtistOriginStore.shared.enabled }

    /// The saved candidates (a best guess) and any from a live search, without repeats, the current match first.
    var candidates: [ArtistOriginCandidate] {
        var seen = Set<String>()
        let all = (state?.candidates ?? []) + (searched ?? [])
        let unique = all.filter { seen.insert($0.id).inserted }
        return unique.sorted { ($0.id == state?.matchedMBID ? 0 : 1, -$0.score) < ($1.id == state?.matchedMBID ? 0 : 1, -$1.score) }
    }

    /// The place being typed, as it would be saved.
    var typedPlace: OriginPlace {
        OriginPlace(
            city: city.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, region: region.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            country: ArtistOriginCountries.name(forCode: countryCode), countryCode: countryCode.isEmpty ? nil : countryCode
        )
    }

    var canSave: Bool { !typedPlace.isEmpty && typedPlace != (state?.edit?.place ?? state?.detected) }

    func load() async {
        guard let container else { return }
        let loadedState = await ArtistOriginPageState.load(artist: artist, container: container)
        state = loadedState
        let start = loadedState?.edit?.place ?? loadedState?.detected
        city = start?.city ?? ""
        region = start?.region ?? ""
        countryCode = start?.countryCode ?? ""
        loaded = true
    }

    private func change(_ body: @escaping @Sendable (ArtistOriginDataStore) async throws -> Void) async -> Bool {
        guard let container else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await offMain { try await body(ArtistOriginDataStore(modelContainer: container)) }
            NotificationCenter.default.post(name: .artistOriginDidUpdate, object: nil)
            return true
        } catch {
            message = "Couldn’t save: \(error.localizedDescription)"
            return false
        }
    }

    func save() async -> Bool {
        let place = typedPlace, artist = artist
        return await change { try await $0.setPlace(place, for: artist) }
    }

    func reset() async -> Bool {
        let artist = artist
        return await change { try await $0.resetPlace(for: artist) }
    }

    func confirm() async -> Bool {
        let artist = artist
        return await change { try await $0.confirm(artist) }
    }

    /// Picks another MusicBrainz artist for this name and asks for its place (if lookups are on).
    func choose(_ candidate: ArtistOriginCandidate) async -> Bool {
        let artist = artist, id = candidate.id
        guard await change({ try await $0.choose(mbid: id, for: artist) }) else { return false }
        await ArtistOriginStore.shared.prioritize([artist], force: true)
        return true
    }

    /// Asks MusicBrainz for the artists with this name (the person pressed the button, so this is allowed even with lookups off).
    func search() async {
        isSearching = true
        message = nil
        defer { isSearching = false }
        do {
            searched = try await MusicBrainzAPIClient().searchArtists(name: artist)
            if searched?.isEmpty == true { message = "MusicBrainz has no artist with this name." }
        } catch is OfflineError {
            message = "Offline mode is on. Go online to search MusicBrainz."
        } catch {
            message = "MusicBrainz didn’t answer. Try again in a moment."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// "Edit where this artist is from": city, state or region and country by hand, Reset to Detected, "Looks right" for a best guess, and a way
/// to pick a different MusicBrainz artist when the automatic match was a namesake.
struct ArtistOriginEditView: View {
    @State var model: ArtistOriginEditModel
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(artist: String, container: ModelContainer, onChanged: @escaping () -> Void) {
        _model = State(initialValue: ArtistOriginEditModel(artist: artist, container: container))
        self.onChanged = onChanged
    }

    init(model: ArtistOriginEditModel, onChanged: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.onChanged = onChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where This Artist Is From").font(AppTypography.sectionTitle)
            Text(model.artist).font(AppTypography.metadata).foregroundStyle(.secondary)

            if model.loaded {
                detectedLine
                fields
                if let message = model.message {
                    Text(message).font(AppTypography.supporting).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                actions
                Divider()
                matchSection
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Spacer()
                    // Always a way out, even if reading the saved place is slow.
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await model.load() }
    }

    @ViewBuilder private var detectedLine: some View {
        if let text = model.detectedText {
            Text("Detected: \(text)").font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if model.state?.detectedStatus == ArtistOriginStatus.none {
            Text("MusicBrainz has no artist with this name.").font(AppTypography.supporting).foregroundStyle(.secondary)
        } else {
            Text(model.lookupsOn ? "Not looked up yet." : "Lookups are off, so nothing was looked up.").font(AppTypography.supporting).foregroundStyle(.secondary)
        }
        if model.needsReview {
            Label("This is a best guess: several artists share the name. Check it, or pick another below.", systemImage: "exclamationmark.circle")
                .font(AppTypography.supporting).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("City")
                TextField("City", text: $model.city).textFieldStyle(.roundedBorder).labelsHidden()
            }
            GridRow {
                Text("State / region")
                TextField("State, province or region (optional)", text: $model.region).textFieldStyle(.roundedBorder).labelsHidden()
            }
            GridRow {
                Text("Country")
                Picker("Country", selection: $model.countryCode) {
                    Text("None").tag("")
                    ForEach(ArtistOriginCountries.all) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actions: some View {
        HStack {
            if model.hasOverride {
                Button("Reset to Detected", role: .destructive) { Task { if await model.reset() { finish() } } }
            }
            if model.needsReview {
                Button("Looks Right") { Task { if await model.confirm() { finish() } } }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { Task { if await model.save() { finish() } } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave || model.isBusy)
        }
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wrong artist?").font(AppTypography.sectionTitle)
            Text("MusicBrainz can list several artists with this name. Pick the right one and its place is looked up.")
                .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.lookupsOn {
                Text("Looking up is off in Settings › Sync, so the new match is used when you turn it on.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.candidates) { candidate in
                candidateRow(candidate)
            }
            HStack {
                Button(model.isSearching ? "Searching…" : (model.searched == nil ? "Search MusicBrainz" : "Search Again")) { Task { await model.search() } }
                    .disabled(model.isSearching)
                if model.isSearching { ProgressView().controlSize(.small) }
            }
        }
    }

    private func candidateRow(_ candidate: ArtistOriginCandidate) -> some View {
        let isCurrent = candidate.id == model.state?.matchedMBID
        let place = [candidate.beginAreaName, candidate.areaName].compactMap { $0 }.reduce(into: [String]()) { if !$1.isEmpty, $0.last != $1 { $0.append($1) } }.joined(separator: ", ")
        let detail = [candidate.type, candidate.disambiguation, place.isEmpty ? nil : place].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).font(AppTypography.statValue).lineLimit(1)
                Text(detail.isEmpty ? "No details on MusicBrainz" : detail).font(AppTypography.supportingDense).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if isCurrent {
                Text("Current").font(AppTypography.supportingDense).foregroundStyle(.secondary)
            } else {
                Button("Use This One") { Task { if await model.choose(candidate) { finish() } } }.disabled(model.isBusy)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func finish() {
        onChanged()
        dismiss()
    }
}
