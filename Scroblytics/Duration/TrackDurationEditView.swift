import SwiftUI
import SwiftData

/// Manual "Edit track duration" control: a free-text `m:ss`/`h:mm:ss` field, an Apple Music
/// library prefill, Save, and "Reset to detected duration" shown only when an override
/// currently exists.
struct TrackDurationEditView: View {
    let artist: String
    let track: String
    let album: String?
    let detectedSeconds: Int?
    let currentOverrideSeconds: Int?
    let modelContext: ModelContext
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var errorMessage: String?
    @State private var isImportingFromAppleMusic = false

    private var parsedSeconds: Int? { DurationEngine.parseDuration(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Track Duration").font(AppTypography.sectionTitle)
            Text("\(artist) — \(track)").font(AppTypography.metadata).foregroundStyle(.secondary)

            if let detectedSeconds {
                Text("Detected: \(DurationEngine.formatDuration(detectedSeconds))")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            } else {
                Text("No detected duration yet.").font(AppTypography.supporting).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("m:ss or h:mm:ss", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { save() }

                Button {
                    Task { await importFromAppleMusic() }
                } label: {
                    if isImportingFromAppleMusic {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Import from Apple Music", systemImage: "music.note")
                    }
                }
                .disabled(isImportingFromAppleMusic)
            }

            if let errorMessage {
                Text(errorMessage).font(AppTypography.supporting).foregroundStyle(.red)
            }

            HStack {
                if currentOverrideSeconds != nil {
                    Button("Reset to Detected", role: .destructive) { reset() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedSeconds == nil)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            if let currentOverrideSeconds {
                text = DurationEngine.formatDuration(currentOverrideSeconds)
            } else if let detectedSeconds {
                text = DurationEngine.formatDuration(detectedSeconds)
            }
        }
    }

    private func importFromAppleMusic() async {
        guard !isImportingFromAppleMusic else { return }
        isImportingFromAppleMusic = true
        errorMessage = nil
        defer { isImportingFromAppleMusic = false }

        do {
            guard let seconds = try await AppleMusicMatcher.findTrackDuration(
                artist: artist,
                track: track,
                album: album
            ) else {
                errorMessage = "No matching track with a duration was found in your Apple Music library."
                return
            }
            text = DurationEngine.formatDuration(seconds)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let seconds = parsedSeconds else {
            errorMessage = "Enter a duration like 3:45 or 1:03:45."
            return
        }
        do {
            try applyOverride(seconds)
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

    private func applyOverride(_ seconds: Int?) throws {
        let key = DurationEngine.cacheKey(artist: artist, track: track)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
        descriptor.fetchLimit = 1
        guard let existing = try modelContext.fetch(descriptor).first else {
            throw DurationEditError.trackNotFound
        }
        existing.durationOverrideSeconds = seconds
        try modelContext.save()
    }

    private enum DurationEditError: Error, LocalizedError {
        case trackNotFound
        var errorDescription: String? { "No local Track row exists yet for this track." }
    }
}
