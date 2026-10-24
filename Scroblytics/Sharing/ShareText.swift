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

    /// "Ranked by scrobbles" reads on mid-sentence as "ranked by scrobbles"; "1K milestones" keeps its K.
    private static func lowercasingFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
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
        var line = "**\(escape(card.displayTitle(for: options)))**"
        if !card.period.isEmpty { line += " · \(escape(card.period))" }
        if !card.measure.isEmpty { line += " · \(escape(lowercasingFirst(card.measure)))" }
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
        let subtitle = card.displaySubtitle(for: options)
        var line = markdown ? "**\(text(card.displayTitle(for: options)))**" : card.displayTitle(for: options)
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
        if let headline = card.profile?.headline { lines.append(markdown ? "\(bullet)**Milestone:** \(text(headline))" : "\(bullet)Milestone: \(headline)") }
        for stat in profileStats(card, options: options) {
            lines.append(markdown ? "\(bullet)**\(text(stat.label)):** \(text(stat.value))" : "\(bullet)\(stat.label): \(stat.value)")
        }
        for pick in card.profile?.highlights ?? [] {
            let by = pick.subtitle.map { " — \(text($0))" } ?? ""
            lines.append(markdown ? "\(bullet)**\(text(pick.role)):** \(text(pick.title))\(by) (\(text(pick.value)))" : "\(bullet)\(pick.role): \(pick.title)\(pick.subtitle.map { " — \($0)" } ?? "") (\(pick.value))")
        }
        let chips = chipLines(card)
        if let ranks = chips.ranks { lines.append(markdown ? "\(bullet)**Top ranks:** \(text(ranks))" : "\(bullet)Top ranks: \(ranks)") }
        if let milestones = chips.milestones { lines.append(markdown ? "\(bullet)**Milestones:** \(text(milestones))" : "\(bullet)Milestones: \(milestones)") }
        if identity.showsFooter { lines += ["", markdown ? "^(made with Scroblytics)" : "Made with Scroblytics"] }
        return lines.joined(separator: "\n")
    }

    private static func profileTable(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity) -> String {
        var lines = [profileHeader(card, options: options, identity: identity, markdown: true), "", "| Stat | Value |", "|---|---|"]
        if let headline = card.profile?.headline { lines.append("| Milestone | \(escape(headline)) |") }
        for stat in profileStats(card, options: options) { lines.append("| \(escape(stat.label)) | \(escape(stat.value)) |") }
        for pick in card.profile?.highlights ?? [] {
            let by = pick.subtitle.map { " — \(escape($0))" } ?? ""
            lines.append("| \(escape(pick.role)) | \(escape(pick.title))\(by) (\(escape(pick.value))) |")
        }
        let chips = chipLines(card)
        if let ranks = chips.ranks { lines.append("| Top ranks | \(escape(ranks)) |") }
        if let milestones = chips.milestones { lines.append("| Milestones | \(escape(milestones)) |") }
        if identity.showsFooter { lines += ["", "^(made with Scroblytics)"] }
        return lines.joined(separator: "\n")
    }

    /// A row's values for the list and plain forms: a query's every column as "Column: value", otherwise the one value and its label.
    private static func valueParts(_ row: ShareRow, card: ShareCard) -> [String] {
        if !card.valueColumns.isEmpty {
            return zip(card.valueColumns, row.values).map { "\($0): \($1)" }
        }
        return [row.milestone == nil ? "\(row.value) \(card.valueLabel.lowercased())" : row.value]
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
        var text = "\(card.numbered ? "\(row.rank). " : "- ")**\(escape(row.title))**"
        if let subtitle = card.detailLine(row, options: options) { text += " — \(escape(subtitle))" }
        var tail: [String] = []
        if options.showValues { tail += valueParts(row, card: card) }
        let change = changeText(row.change)
        if options.showMovement, card.hasMovement, !change.isEmpty { tail.append(change) }
        if !tail.isEmpty { text += " (" + tail.joined(separator: ", ") + ")" }
        return text
    }

    /// A chart drawn for the card: its title and period, the sentence about it (unless left off) and its lines (the rows it shows).
    private static func nativeText(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity, markdown: Bool) -> String {
        guard let native = card.native else { return "" }
        let text: (String) -> String = { markdown ? escape($0) : $0 }
        var head = markdown ? "**\(text(card.displayTitle(for: options)))**" : card.displayTitle(for: options)
        let subtitle = card.displaySubtitle(for: options)
        if !subtitle.isEmpty { head += " — \(text(subtitle))" }
        if !card.period.isEmpty { head += " · \(text(card.period))" }
        if options.showDate { head += " · \(text(dateText(card)))" }
        if let name = identity.name, !name.isEmpty { head += " · \(text(name))" }
        var lines = [head]
        let caption = native.displayCaption(for: options)
        if options.showsCaption, !caption.isEmpty { lines += ["", text(caption)] }
        if !native.textLines.isEmpty { lines.append("") }
        lines += native.textLines.map { (markdown ? "- " : "• ") + text($0) }
        if options.showsFootnote, let footnote = native.footnote { lines += ["", text(footnote)] }
        if identity.showsFooter { lines += ["", markdown ? "^(made with Scroblytics)" : "Made with Scroblytics"] }
        return lines.joined(separator: "\n")
    }

    /// A numbered Markdown list, one row per line.
    static func markdownList(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity = .anonymous) -> String {
        if card.native != nil { return nativeText(card, options: options, identity: identity, markdown: true) }
        if card.profile != nil { return profileList(card, options: options, identity: identity, markdown: true) }
        var lines = header(card, options: options, identity: identity) + [""]
        lines += card.visibleRows(for: options).map { line($0, options: options, card: card) }
        if identity.showsFooter { lines += ["", "^(made with Scroblytics)"] }
        return lines.joined(separator: "\n")
    }

    /// A Markdown table, which Reddit renders as a table.
    static func markdownTable(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity = .anonymous) -> String {
        if card.native != nil { return nativeText(card, options: options, identity: identity, markdown: true) }
        if card.profile != nil { return profileTable(card, options: options, identity: identity) }
        let hasSubtitle = card.rows.contains { $0.subtitle?.isEmpty == false }
        let showsMovement = options.showMovement && card.hasMovement
        var headers = card.numbered ? ["#", "Name"] : ["Name"]
        if hasSubtitle { headers.append("Artist") }
        if options.showValues { headers += card.valueColumns.isEmpty ? [card.valueLabel] : card.valueColumns }
        if showsMovement { headers.append("Move") }
        let showsNotes = options.showNotes && card.hasNotes
        if showsNotes { headers.append("Why") }
        var lines = header(card, options: options, identity: identity) + ["", "| " + headers.joined(separator: " | ") + " |", "|" + headers.map { _ in "---" }.joined(separator: "|") + "|"]
        for row in card.visibleRows(for: options) {
            var cells = card.numbered ? ["\(row.rank)", escape(row.title)] : [escape(row.title)]
            if hasSubtitle { cells.append(escape(row.subtitle ?? "")) }
            if options.showValues {
                if card.valueColumns.isEmpty { cells.append(row.value) } else { cells += card.valueColumns.indices.map { row.values.indices.contains($0) ? escape(row.values[$0]) : "—" } }
            }
            if showsMovement { cells.append(changeText(row.change)) }
            if showsNotes { cells.append(escape(row.note ?? "")) }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        if identity.showsFooter { lines += ["", "^(made with Scroblytics)"] }
        return lines.joined(separator: "\n")
    }

    /// Plain text with no formatting characters.
    static func plain(_ card: ShareCard, options: ShareOptions, identity: ShareIdentity = .anonymous) -> String {
        if card.native != nil { return nativeText(card, options: options, identity: identity, markdown: false) }
        if card.profile != nil { return profileList(card, options: options, identity: identity, markdown: false) }
        var title = card.displayTitle(for: options)
        if !card.period.isEmpty { title += " — \(card.period)" }
        if !card.measure.isEmpty { title += ", \(lowercasingFirst(card.measure))" }
        if options.showDate { title += ", \(dateText(card))" }
        if let name = identity.name, !name.isEmpty { title += " (\(name))" }
        var lines = [title]
        if let note = movementNote(card, options: options) { lines.append(note) }
        lines.append("")
        for row in card.visibleRows(for: options) {
            var text = "\(card.numbered ? "\(row.rank). " : "• ")\(row.title)"
            if let subtitle = card.detailLine(row, options: options) { text += " — \(subtitle)" }
            var tail: [String] = []
            if options.showValues { tail += valueParts(row, card: card) }
            let change = changeText(row.change)
            if options.showMovement, card.hasMovement, !change.isEmpty { tail.append(change) }
            if !tail.isEmpty { text += " (" + tail.joined(separator: ", ") + ")" }
            lines.append(text)
        }
        if identity.showsFooter { lines += ["", "Made with Scroblytics"] }
        return lines.joined(separator: "\n")
    }
}
