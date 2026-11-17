import SwiftUI

/// Settings › Sync › Artist origins: the switch for looking up where artists are from, how far it has got, and a way to forget what was
/// looked up (your own corrections stay).
struct ArtistOriginSettingsSection: View {
    var store = ArtistOriginStore.shared
    @State private var confirmingForget = false

    var body: some View {
        Section("Artist origins") {
            Toggle("Look up where artists are from", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
            Text(store.statusText)
                .font(AppTypography.supporting)
                .foregroundStyle(store.lastError == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if store.knownCount > 0 {
                Button("Forget Looked-Up Places…", role: .destructive) { confirmingForget = true }
            }
            Text("Asks MusicBrainz once for each artist where they were born or formed (city, state or region, and country), starting with the artists you play most, and keeps the answer on this Mac. Only artist names are sent. A large library takes a few hours, quietly in the background; places you correct yourself are never replaced.")
                .font(AppTypography.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Forget the places that were looked up?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Task { await store.forget() } }
        } message: {
            Text("They are looked up again if the switch is on. Places you entered or corrected yourself are kept.")
        }
    }
}
