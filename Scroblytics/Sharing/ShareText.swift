import Foundation

/// The text forms of a card, for Reddit posts and messages. Pure, so the escaping can be checked.
enum ShareText {
    /// Escapes what Markdown would read as formatting in an artist or track name.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\", "`", "*", "_", "[", "]", "|", "<", ">", "~", "#":
                out.append("\\")
                out.append(character)
            case "\n", "\r":
                out.append(" ")
            default:
                out.append(character)
            }
        }
        return out
    }

    /// The card's date as the image shows it.
    static func dateText(_ card: ShareCard) -> String {
        card.generatedAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// What the movement arrows are measured against, when they are shown.
    private static func movementNote(_ card: ShareCard, options: ShareOptions) -> String? {
        guard options.showMovement, card.hasMovement, let note = card.movementNote else { return nil }
        return "Movement (▲▼) \(note)"
    }

    private static func header(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity) -> [String] {
        var line = "**\(escape(card.title))** · \(escape(card.period)) · \(escape(card.measure.lowercased()))"
        if options.showDate { line += " · \(escape(dateText(card)))" }
        if let name = identity.name, !name.isEmpty { line += " · \(escape(name))" }
        var lines = [line]
        if let note = movementNote(card, options: options) { lines.append(escape(note)) }
        return lines
    }

    // MARK: Profile cards (one artist, album or track)

    /// The tiles the text shows: the same as the image's.
    private static func profileStats(_ card: ShareCard, options: ShareOptions) -> [ShareStat] {
        card.visibleStats(for: options)
    }

    private static func chipLines(_ card: ShareCard) -> (ranks: String?, milestones: String?) {
        let chips = card.profile?.chips ?? []
        let ranks = chips.filter { $0.kind == .rank }.map(\.text)
        let milestones = chips.filter { $0.kind == .milestone }.map(\.text)
        return (ranks.isEmpty ? nil : ranks.joined(separator: ", "), milestones.isEmpty ? nil : milestones.joined(separator: "; "))
    }

    private static func profileHeader(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity, markdown: Bool) -> String {
        let text: (String) -> String = { markdown ? escape($0) : $0 }
        let subtitle = card.profile?.subtitle ?? ""
        var line = markdown ? "**\(text(card.title))**" : card.title
        if !subtitle.isEmpty { line += " — \(text(subtitle))" }
        line += " · \(text(card.period))"
        if options.showDate { line += " · \(text(dateText(card)))" }
        if let name = identity.name, !name.isEmpty { line += " · \(text(name))" }
        return line
    }

    private static func profileList(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity, markdown: Bool) -> String {
        let text: (String) -> String = { markdown ? escape($0) : $0 }
        let bullet = markdown ? "- " : "• "
        var lines = [profileHeader(card, options: options, identity: identity, markdown: markdown), ""]
        for stat in profileStats(card, options: options) {
            lines.append(markdown ? "\(bullet)**\(text(stat.label)):** \(text(stat.value))" : "\(bullet)\(stat.label): \(stat.value)")
        }
        let chips = chipLines(card)
        if let ranks = chips.ranks { lines.append(markdown ? "\(bullet)**Top ranks:** \(text(ranks))" : "\(bullet)Top ranks: \(ranks)") }
        if let milestones = chips.milestones { lines.append(markdown ? "\(bullet)**Milestones:** \(text(milestones))" : "\(bullet)Milestones: \(milestones)") }
        if identity.showsFooter { lines += ["", markdown ? "^(made with Scroblytics)" : "Made with Scroblytics"] }
        return lines.joined(separator: "\n")
    }

    private static func profileTable(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity) -> String {
        var lines = [profileHeader(card, options: options, identity: identity, markdown: true), "", "| Stat | Value |", "|---|---|"]
        for stat in profileStats(card, options: options) { lines.append("| \(escape(stat.label)) | \(escape(stat.value)) |") }
        let chips = chipLines(card)
        if let ranks = chips.ranks { lines.append("| Top ranks | \(escape(ranks)) |") }
        if let milestones = chips.milestones { lines.append("| Milestones | \(escape(milestones)) |") }
        if identity.showsFooter { lines += ["", "^(made with Scroblytics)"] }
        return lines.joined(separator: "\n")
    }

    private static func changeText(_ change: ShareChange) -> String {
        switch change {
        case .none, .same: ""
        case .up(let n): "▲\(n)"
        case .down(let n): "▼\(n)"
        case .new: "NEW"
        }
    }

    private static func line(_ row: ShareRow, options: ShareOptions, card: ShareCard) -> String {
        var text = "\(row.rank). **\(escape(row.title))**"
        if let subtitle = row.subtitle, !subtitle.isEmpty { text += " — \(escape(subtitle))" }
        var tail: [String] = []
        if options.showValues { tail.append("\(row.value) \(card.valueLabel.lowercased())") }
        let change = changeText(row.change)
        if options.showMovement, card.hasMovement, !change.isEmpty { tail.append(change) }
        if !tail.isEmpty { text += " (" + tail.joined(separator: ", ") + ")" }
        return text
    }

    /// A numbered Markdown list, one row per line.
    static func markdownList(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity = .anonymous) -> String {
        if card.profile != nil { return profileList(card, options: options, identity: identity, markdown: true) }
        var lines = header(card, options: options, identity: identity) + [""]
        lines += card.visibleRows(for: options).map { line($0, options: options, card: card) }
        if identity.showsFooter { lines += ["", "^(made with Scroblytics)"] }
        return lines.joined(separator: "\n")
    }

    /// A Markdown table, which Reddit renders as a table.
    static func markdownTable(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity = .anonymous) -> String {
        if card.profile != nil { return profileTable(card, options: options, identity: identity) }
        let hasSubtitle = card.rows.contains { $0.subtitle?.isEmpty == false }
        let showsMovement = options.showMovement && card.hasMovement
        var headers = ["#", "Name"]
        if hasSubtitle { headers.append("Artist") }
        if options.showValues { headers.append(card.valueLabel) }
        if showsMovement { headers.append("Move") }
        var lines = header(card, options: options, identity: identity) + ["", "| " + headers.joined(separator: " | ") + " |", "|" + headers.map { _ in "---" }.joined(separator: "|") + "|"]
        for row in card.visibleRows(for: options) {
            var cells = ["\(row.rank)", escape(row.title)]
            if hasSubtitle { cells.append(escape(row.subtitle ?? "")) }
            if options.showValues { cells.append(row.value) }
            if showsMovement { cells.append(changeText(row.change)) }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        if identity.showsFooter { lines += ["", "^(made with Scroblytics)"] }
        return lines.joined(separator: "\n")
    }

    /// Plain text with no formatting characters.
    static func plain(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity = .anonymous) -> String {
        if card.profile != nil { return profileList(card, options: options, identity: identity, markdown: false) }
        var title = "\(card.title) — \(card.period), \(card.measure.lowercased())"
        if options.showDate { title += ", \(dateText(card))" }
        if let name = identity.name, !name.isEmpty { title += " (\(name))" }
        var lines = [title]
        if let note = movementNote(card, options: options) { lines.append(note) }
        lines.append("")
        for row in card.visibleRows(for: options) {
            var text = "\(row.rank). \(row.title)"
            if let subtitle = row.subtitle, !subtitle.isEmpty { text += " — \(subtitle)" }
            var tail: [String] = []
            if options.showValues { tail.append("\(row.value) \(card.valueLabel.lowercased())") }
            let change = changeText(row.change)
            if options.showMovement, card.hasMovement, !change.isEmpty { tail.append(change) }
            if !tail.isEmpty { text += " (" + tail.joined(separator: ", ") + ")" }
            lines.append(text)
        }
        if identity.showsFooter { lines += ["", "Made with Scroblytics"] }
        return lines.joined(separator: "\n")
    }
}
