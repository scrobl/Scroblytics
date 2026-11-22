import SwiftUI
import SwiftData

/// The name a "Correct Name…" sheet is about, as it is shown now.
struct NameCorrectionSubject: Identifiable, Equatable {
    let kind: NameCorrectionKind
    /// The artist as shown (for an artist, its own name). An album or track is found by this artist.
    let artist: String
    /// The album or track title as shown; the artist's own name for an artist.
    let name: String
    var id: String { "\(kind.rawValue)\u{241F}\(artist)\u{241F}\(name)" }

    init(kind: NameCorrectionKind, artist: String, name: String) {
        self.kind = kind
        self.artist = artist
        self.name = kind == .artist ? artist : name
    }
}

/// What the sheet needs: Last.fm's spellings of the name (with their plays), whether a correction exists, and the save and reset.
@MainActor
@Observable
final class NameCorrectionModel {
    let subject: NameCorrectionSubject
    var text: String
    /// Last.fm's spellings of this name in the library, most played first, with their play counts.
    private(set) var spellings: [(name: String, plays: Int)] = []
    /// The artist as Last.fm most often spells it for these plays (for an album or track), used to file the correction.
    private(set) var rawArtist: String
    private(set) var hasCorrection = false
    private(set) var isLoaded = false
    private(set) var isWorking = false
    var errorMessage: String?

    init(subject: NameCorrectionSubject) {
        self.subject = subject
        self.text = subject.name
        self.rawArtist = subject.artist
    }

    #if DEBUG
    /// Layout snapshots only: a model that is already loaded with made-up spellings and never reads the library.
    private(set) var isSample = false
    static func sample(subject: NameCorrectionSubject, text: String, spellings: [(name: String, plays: Int)], hasCorrection: Bool) -> NameCorrectionModel {
        let model = NameCorrectionModel(subject: subject)
        model.text = text
        model.spellings = spellings
        model.hasCorrection = hasCorrection
        model.isLoaded = true
        model.isSample = true
        return model
    }
    #endif

    /// The spelling Last.fm uses most; what a reset goes back to.
    var original: String { spellings.first?.name ?? subject.name }

    func load(container: ModelContainer) async {
        #if DEBUG
        if isSample { return }
        #endif
        let plays = (try? await ScrobbleHistoryCache.shared.snapshots(container: container)) ?? []
        let subject = subject
        let counted: ([String: Int], [String: Int]) = await Task.detached(priority: .userInitiated) {
            var names: [String: Int] = [:]
            var artists: [String: Int] = [:]
            let artistKey = NameKeys.fold(subject.artist)
            let nameKey = NameKeys.fold(subject.name)
            for play in plays {
                switch subject.kind {
                case .artist:
                    if NameKeys.fold(play.artistName) == nameKey { names[play.artistName, default: 0] += 1 }
                case .album:
                    guard !play.albumName.isEmpty, NameKeys.fold(play.albumName) == nameKey,
                          TextNormalization.trackMatchesArtistContext(trackArtist: play.artistName, context: subject.artist) else { continue }
                    names[play.albumName, default: 0] += 1
                    artists[play.artistName, default: 0] += 1
                case .track:
                    guard NameKeys.fold(play.artistName) == artistKey, NameKeys.fold(play.trackName) == nameKey else { continue }
                    names[play.trackName, default: 0] += 1
                    artists[play.artistName, default: 0] += 1
                }
            }
            return (names, artists)
        }.value
        spellings = counted.0.map { (name: $0.key, plays: $0.value) }.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
        if let top = counted.1.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key { rawArtist = top }
        let book = NameCorrections.current
        switch subject.kind {
        case .artist: hasCorrection = book.artist(subject.artist) != nil
        case .album: hasCorrection = book.album(artist: rawArtist, album: original) != nil
        case .track: hasCorrection = book.track(artist: rawArtist, title: original) != nil
        }
        isLoaded = true
    }

    var verdict: NameCorrectionRules.Verdict { NameCorrectionRules.validate(original: original, proposed: text) }

    /// Nothing to save: the text is the name as it is shown now.
    var isUnchangedFromShown: Bool { NameKeys.tidy(text) == NameKeys.tidy(subject.name) }

    var canSave: Bool {
        guard isLoaded, !isWorking, !isUnchangedFromShown else { return false }
        if case .rejected = verdict { return false }
        return true
    }

    var rejection: String? {
        if case .rejected(let message) = verdict, !NameKeys.tidy(text).isEmpty || !text.isEmpty { return message }
        return nil
    }

    /// Saves, then returns the name to show from now on (the corrected spelling, or Last.fm's when the text is Last.fm's own).
    func save(container: ModelContainer) async -> String? {
        isWorking = true
        defer { isWorking = false }
        do {
            let shown: String
            switch verdict {
            case .ok(let tidied): shown = tidied
            case .unchanged: shown = original
            case .rejected(let message): errorMessage = message; return nil
            }
            try await NameCorrections.save(container: container, kind: subject.kind, artist: rawArtist, original: original, display: shown)
            return shown
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func reset(container: ModelContainer) async -> String? {
        isWorking = true
        defer { isWorking = false }
        do {
            try await NameCorrections.reset(container: container, kind: subject.kind, artist: rawArtist, original: original)
            return original
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

/// "Correct Name…": changes how one artist, album or track name is shown on this Mac (capitalization and spacing only). Nothing is
/// changed on Last.fm or in the saved plays, and the correction is part of a backup.
struct NameCorrectionSheet: View {
    @State private var model: NameCorrectionModel
    /// Called after a save or reset with the name to show from now on.
    let onChanged: (String) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(subject: NameCorrectionSubject, onChanged: @escaping (String) -> Void = { _ in }) {
        _model = State(initialValue: NameCorrectionModel(subject: subject))
        self.onChanged = onChanged
    }

    #if DEBUG
    init(model: NameCorrectionModel) {
        _model = State(initialValue: model)
        self.onChanged = { _ in }
    }
    #endif

    private var kindWord: String { model.subject.kind.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correct \(kindWord) name").font(.title3.bold())
            Text("Change how this \(kindWord)’s name is shown in Scroblytics: capitalization and spacing only. Last.fm and your saved plays keep their spelling; this stays on this Mac and is part of a backup.")
                .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Show as").font(AppTypography.metadata).foregroundStyle(.secondary)
                TextField("Name", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if model.canSave { save() } }
                if let rejection = model.rejection {
                    Label(rejection, systemImage: "exclamationmark.triangle.fill")
                        .font(AppTypography.supporting).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.isLoaded, !model.spellings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.spellings.count == 1 ? "Last.fm spells it" : "Last.fm spells it \(model.spellings.count) ways (counted together under the name you choose)")
                        .font(AppTypography.metadata).foregroundStyle(.secondary)
                    ForEach(model.spellings, id: \.name) { spelling in
                        HStack {
                            Text(spelling.name).lineLimit(2)
                            Spacer(minLength: 12)
                            Text("\(spelling.plays.formatted()) \(spelling.plays == 1 ? "play" : "plays")").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(AppTypography.supporting)
                    }
                }
            }

            if let error = model.errorMessage {
                Text(error).font(AppTypography.supporting).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.hasCorrection {
                    Button("Reset to Last.fm’s spelling", role: .destructive) { reset() }.disabled(model.isWorking)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await model.load(container: modelContext.container) }
    }

    private func save() {
        Task {
            if let shown = await model.save(container: modelContext.container) {
                onChanged(shown)
                dismiss()
            }
        }
    }

    private func reset() {
        Task {
            if let shown = await model.reset(container: modelContext.container) {
                onChanged(shown)
                dismiss()
            }
        }
    }
}
