import SwiftUI
import SwiftData

/// Manual "Edit release date" control, mirroring `TrackDurationEditView`'s
/// exact shape — free-text date field, Save, "Reset to Detected" shown only
/// when an override currently exists. Generalized over both granularities
/// this feature has overrides for: an `.album` target writes
/// `Album.releaseDateOverride`, a `.track` target writes
/// `Track.releaseDateOverride` — always the track's own override, never the
/// album's (a track override corrects
/// just that one song, independent of its album default).
struct ReleaseDateEditView: View {
    enum Target {
        case album(artist: String, album: String)
        case track(artist: String, track: String)
    }

    let target: Target
    let detectedDate: String?
    let currentOverride: String?
    let modelContext: ModelContext
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var errorMessage: String?

    private var parsedDate: String? { ReleaseDateEngine.parseDate(text) }

    private var subtitle: String {
        switch target {
        case .album(let artist, let album): return "\(artist) — \(album)"
        case .track(let artist, let track): return "\(artist) — \(track)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Release Date").font(AppTypography.sectionTitle)
            Text(subtitle).font(AppTypography.metadata).foregroundStyle(.secondary)

            if let detectedDate {
                Text("Detected: \(ReleaseDateEngine.formatDate(detectedDate))")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            } else {
                Text("No detected release date yet.").font(AppTypography.supporting).foregroundStyle(.secondary)
            }

            TextField("YYYY, YYYY-MM, or YYYY-MM-DD", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { save() }

            if let errorMessage {
                Text(errorMessage).font(AppTypography.supporting).foregroundStyle(.red)
            }

            HStack {
                if currentOverride != nil {
                    Button("Reset to Detected", role: .destructive) { reset() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedDate == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            text = currentOverride ?? detectedDate ?? ""
        }
    }

    private func save() {
        guard let date = parsedDate else {
            errorMessage = "Enter a date like 2011, 2011-09, or 2011-09-19."
            return
        }
        do {
            try applyOverride(date)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func reset() {
        do {
            try applyOverride(nil)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "Couldn't reset: \(error.localizedDescription)"
        }
    }

    private func applyOverride(_ date: String?) throws {
        switch target {
        case .album(let artist, let album):
            guard let existing = ReleaseDateEngine.albumRow(context: modelContext, artist: artist, album: album) else {
                throw ReleaseDateEditError.entityNotFound
            }
            existing.releaseDateOverride = date
        case .track(let artist, let track):
            let key = TextNormalization.lovedKey(artist: artist, track: track)
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
            descriptor.fetchLimit = 1
            guard let existing = try modelContext.fetch(descriptor).first else {
                throw ReleaseDateEditError.entityNotFound
            }
            existing.releaseDateOverride = date
        }
        try modelContext.save()
    }

    private enum ReleaseDateEditError: Error, LocalizedError {
        case entityNotFound
        var errorDescription: String? { "No local row exists yet for this entity." }
    }
}
