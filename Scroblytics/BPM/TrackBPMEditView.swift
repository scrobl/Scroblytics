import SwiftUI
import SwiftData

/// Manual "Edit tempo" control: a free-text BPM field with halve/double buttons (tempo detectors often report half or
/// double the felt tempo), Save, and "Reset to Detected" shown only when a correction currently exists.
struct TrackBPMEditView: View {
    let artist: String
    let track: String
    let detected: BPMEngine.Resolved?
    let currentOverride: Double?
    let modelContext: ModelContext
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?

    private var parsed: Double? { BPMEngine.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Tempo").font(AppTypography.sectionTitle)
            Text("\(artist) — \(track)").font(AppTypography.metadata).foregroundStyle(.secondary)

            if let detected {
                Text("Detected: \(BPMEngine.format(detected.bpm)) BPM · \(detected.source.label)")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            } else {
                Text("No detected tempo yet.").font(AppTypography.supporting).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("BPM", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { save() }
                Text("BPM").foregroundStyle(.secondary)
                Button("÷ 2") { scale(by: 0.5) }
                    .disabled(parsed == nil)
                    .help("Halve the tempo — for a track a detector reported at double speed.")
                Button("× 2") { scale(by: 2) }
                    .disabled(parsed == nil)
                    .help("Double the tempo — for a track a detector reported at half speed.")
            }

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
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            if let currentOverride { text = BPMEngine.format(currentOverride) }
            else if let detected { text = BPMEngine.format(detected.bpm) }
        }
    }

    private func scale(by factor: Double) {
        guard let parsed else { return }
        text = BPMEngine.format((parsed * factor * 100).rounded() / 100)
        errorMessage = nil
    }

    private func save() {
        guard let bpm = parsed else {
            errorMessage = "Enter a tempo between 0 and 999, like 128 or 127.5."
            return
        }
        apply(bpm, failure: "save")
    }

    private func reset() { apply(nil, failure: "reset") }

    private func apply(_ bpm: Double?, failure verb: String) {
        let key = BPMEngine.cacheKey(artist: artist, track: track)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
        descriptor.fetchLimit = 1
        do {
            guard let existing = try modelContext.fetch(descriptor).first else {
                errorMessage = "No local Track row exists yet for this track."
                return
            }
            existing.bpmOverride = bpm
            try modelContext.save()
            onSaved()
            dismiss()
        } catch {
            errorMessage = "Couldn’t \(verb): \(error.localizedDescription)"
        }
    }
}
