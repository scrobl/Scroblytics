import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A Share button for any screen: `ShareButton { card }`, where the closure builds the card from what the screen already holds. It opens
/// one popover (the same for every card) with a live preview, the options that suit the card, and the ways to send it on.
struct ShareButton: View {
    var title = "Share"
    /// Just the icon, for a small spot on a card in a list (each one names what it shares, for VoiceOver and the tooltip).
    var iconOnly = false
    /// Builds the card when the button is pressed; nil (nothing to share yet) disables the button.
    let card: @MainActor () -> ShareCard?
    var isEnabled = true

    @State private var presented: ShareCard?

    var body: some View {
        Button {
            presented = card()
        } label: {
            if iconOnly {
                Image(systemName: "square.and.arrow.up")
            } else {
                Label(title, systemImage: "square.and.arrow.up")
            }
        }
        .accessibilityLabel(iconOnly ? "Share \(title)" : "Share")
        .disabled(!isEnabled)
        .help(iconOnly ? "Share \(title)" : "Make an image or text of this to share")
        .popover(item: Binding(get: { presented.map(PresentedCard.init) }, set: { presented = $0?.card }), arrowEdge: .bottom) { item in
            SharePopover(card: item.card)
        }
    }

    private struct PresentedCard: Identifiable {
        let card: ShareCard
        var id: String { card.kindID + "|" + card.title + "|" + card.period }
    }
}

/// The card as something the system Share menu can take: rendered when the person picks a target, not before.
struct ShareCardImage: Transferable {
    let render: @MainActor @Sendable () -> Data?

    enum Failure: Error { case notRendered }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = await item.render() else { throw Failure.notRendered }
            return data
        }
    }
}

private struct SharePopover: View {
    let card: ShareCard

    @Environment(\.modelContext) private var modelContext
    @AppStorage(ShareSettings.showsNameKey) private var showsName = false
    @AppStorage(ShareSettings.showsFooterKey) private var showsFooter = false
    @AppStorage(ShareSettings.logoKey) private var logoRaw = LastfmLogoStyle.circle.rawValue
    @State private var options = ShareOptions()
    @State private var images: [String: NSImage] = [:]
    @State private var imagesLoaded = false
    @State private var preview: NSImage?
    @State private var accountName: String?
    @State private var status: String?
    @State private var renderTask: Task<Void, Never>?

    private var identity: ShareIdentity {
        ShareIdentity(name: showsName ? accountName : nil, showsFooter: showsFooter, logo: LastfmLogoStyle(rawValue: logoRaw) ?? .circle)
    }

    /// Rows whose picture exists but could not be loaded (Offline mode, or the picture is not saved on this Mac).
    private var missingPictures: Int {
        guard imagesLoaded else { return 0 }
        return card.pictureURLs(for: options).compactMap { $0 }.filter { images[$0] == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewView
            controls
            if missingPictures > 0 {
                Text(Connectivity.shared.isOffline
                     ? "Offline mode is on: \(missingPictures) picture\(missingPictures == 1 ? "" : "s") not saved on this Mac left out."
                     : "\(missingPictures) picture\(missingPictures == 1 ? "" : "s") couldn’t be loaded.")
                    .font(AppTypography.supportingDense).foregroundStyle(.orange)
            }
            Divider()
            actions
            if let status {
                Text(status).font(AppTypography.supportingDense).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 440)
        .task {
            options = ShareSettings.options(for: card.kindID, fallback: card.defaultOptions)
            accountName = ShareSettings.accountName(context: modelContext)
            images = await ShareArtwork.load(ShareRenderer.imageURLs(card: card, options: ShareOptions(rowCount: ShareOptions.rowCounts.max() ?? 20)))
            imagesLoaded = true
            renderPreview()
        }
        .onChange(of: options) { _, new in
            ShareSettings.save(new, for: card.kindID)
            scheduleRender()
        }
        .onChange(of: showsName) { scheduleRender() }
        .onChange(of: showsFooter) { scheduleRender() }
        .onChange(of: logoRaw) { scheduleRender() }
        .onDisappear { renderTask?.cancel() }
    }

    // MARK: Preview

    @ViewBuilder
    private var previewView: some View {
        let ratio = options.size.points.width / options.size.points.height
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25))
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.6), lineWidth: 1) }
    }

    /// Draws the preview a moment after the last change, so typing a title (one change per key) draws it once, not once per letter.
    @MainActor
    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            renderPreview()
        }
    }

    @MainActor
    private func renderPreview() {
        guard imagesLoaded else { return }
        preview = ShareRenderer.nsImage(card: card, options: options, identity: identity, images: images, scale: 0.8)
    }

    // MARK: Options

    /// 5, 10, 15 and 20 where the card has that many rows, and all of them when it has fewer.
    private var rowChoices: [Int] {
        let available = card.rows.count
        var choices = ShareOptions.rowCounts.filter { $0 <= available }
        if available <= (ShareOptions.rowCounts.max() ?? 20), !choices.contains(available) { choices.append(available) }
        return choices.isEmpty ? [max(available, 1)] : choices.sorted()
    }

    /// What the picker shows: a remembered count the card can't fill (10 remembered, 4 rows on this chart) reads as the nearest choice, without
    /// changing what is remembered.
    private var shownRowCount: Int {
        let choices = rowChoices
        return choices.contains(options.rowCount) ? options.rowCount : (choices.last { $0 <= options.rowCount } ?? choices[0])
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Size", selection: $options.size) {
                ForEach(ShareSize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if card.isList {
                HStack {
                    Picker("Rows", selection: Binding(get: { shownRowCount }, set: { options.rowCount = $0 })) {
                        ForEach(rowChoices, id: \.self) { Text("\($0) \($0 == 1 ? "row" : "rows")").tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                }
            }
            if card.tree != nil {
                Picker("Layout", selection: $options.layout) {
                    ForEach(ShareLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if card.isList {
                TextField("Title", text: $options.customTitle, prompt: Text(card.title))
                    .textFieldStyle(.roundedBorder)
            }
            if card.iconChoice {
                HStack {
                    Text("Picture for the total")
                    Picker("Picture for the total", selection: $options.icon) {
                        ForEach(ShareIcon.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if card.isList && !card.drawsTree(for: options) {
                if card.valueColumns.isEmpty {
                    Toggle("Show \(card.valueLabel.lowercased())", isOn: $options.showValues)
                } else {
                    // Which column the image shows, or none of them.
                    HStack {
                        Text("Show")
                        Picker("Show", selection: Binding(
                            get: { options.showValues ? card.valueColumnIndex(for: options) : -1 },
                            set: { choice in
                                options.showValues = choice >= 0
                                if choice >= 0 { options.valueColumn = choice }
                            }
                        )) {
                            ForEach(Array(card.valueColumns.enumerated()), id: \.offset) { Text($1).tag($0) }
                            Divider()
                            Text("None").tag(-1)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            if card.hasNotes && !card.drawsTree(for: options) {
                Toggle("Show why each track was chosen", isOn: $options.showNotes)
            }
            Toggle("Show today’s date", isOn: $options.showDate)
            if card.hasMovement {
                Toggle("Show movement", isOn: $options.showMovement)
            }
            Toggle(isOn: $showsName) {
                Text(accountName.map { "Show my Last.fm name (\($0))" } ?? "Show my Last.fm name")
            }
            .disabled(accountName == nil)
            Toggle("Show “Scroblytics” on the card", isOn: $showsFooter)
        }
        .toggleStyle(.checkbox)
        .font(AppTypography.supporting)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Copy Image") { copyImage() }
                .buttonStyle(.borderedProminent)
                .disabled(!imagesLoaded)
            Button("Save PNG…") { savePNG() }
                .disabled(!imagesLoaded)
            ShareLink(item: ShareCardImage(render: { [card, options, identity, images] in
                ShareRenderer.png(card: card, options: options, identity: identity, images: images)
            }), preview: SharePreview(card.title)) {
                Text("Share…")
            }
            .disabled(!imagesLoaded)
            // A chart is a picture; it has no text form.
            if card.snapshot == nil {
                Menu("Copy Text") {
                    Button("Markdown table (for Reddit)") { copyText(ShareText.markdownTable(card, options: options, identity: identity), "Markdown table") }
                    Button("Markdown list") { copyText(ShareText.markdownList(card, options: options, identity: identity), "Markdown list") }
                    Button("Plain text") { copyText(ShareText.plain(card, options: options, identity: identity), "Text") }
                }
                .fixedSize()
            }
        }
    }

    @MainActor
    private func fullPNG() -> Data? {
        ShareRenderer.png(card: card, options: options, identity: identity, images: images)
    }

    @MainActor
    private func copyImage() {
        guard let data = fullPNG() else { status = "The image couldn’t be made."; return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        if let image = NSImage(data: data) { pasteboard.writeObjects([image]) }
        status = "Image copied. Paste it into your post or message."
    }

    @MainActor
    private func savePNG() {
        guard let data = fullPNG() else { status = "The image couldn’t be made."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Scroblytics \(card.title).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            status = "Saved."
        } catch {
            status = error.localizedDescription
        }
    }

    @MainActor
    private func copyText(_ text: String, _ label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        status = "\(label) copied."
    }
}

#if DEBUG
/// The popover's content on its own, for the offscreen layout snapshot (`SCROBLYTICS_SHARE_SNAPSHOT_POPOVER`).
enum SharePopoverPreview {
    @MainActor
    static func view(card: ShareCard) -> some View { SharePopover(card: card) }
}
#endif
