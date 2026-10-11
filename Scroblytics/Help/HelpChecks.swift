import Foundation

#if DEBUG
/// `SCROBLYTICS_HELP_CHECK=1`: verifies the Help content (field coverage, links, ids, forbidden text) and quits with a
/// non-zero status on any failure. `SCROBLYTICS_HELP_DUMP=1` instead prints every registry field, for writing definitions.
enum HelpChecks {
    static func runHeadlessIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if environment["SCROBLYTICS_HELP_DUMP"] != nil {
            for field in QueryFieldRegistry.similarSounds.fields {
                let targets = [QueryTarget.artist, .album, .track].filter { field.targets.contains($0) }.map(\.rawValue).joined(separator: ",")
                print("\(field.group.title) | \(field.id) | \(field.name) | \(targets) | \(field.type.rawValue) | \(field.help)")
            }
            exit(0)
        }
        guard environment["SCROBLYTICS_HELP_CHECK"] != nil else { return }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail().isEmpty ? "" : " — " + detail())")
            if !ok { failures += 1 }
        }

        let articles = HelpContent.allArticles
        let ids = articles.map(\.id)
        check("article ids are unique", Set(ids).count == ids.count, "duplicates: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
        check("article ids are lowercase letters, digits and hyphens", ids.allSatisfy { $0.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } && !$0.isEmpty })
        check("every article has blocks", articles.allSatisfy { !$0.blocks.isEmpty })

        let registryIDs = Set(QueryFieldRegistry.similarSounds.fields.map(\.id))
        let definedIDs = Set(HelpFieldDefinitions.text.keys)
        check("every registry field has a definition", registryIDs.isSubset(of: definedIDs), "missing: \(registryIDs.subtracting(definedIDs).sorted())")
        check("every definition has a registry field", definedIDs.isSubset(of: registryIDs), "orphans: \(definedIDs.subtracting(registryIDs).sorted())")
        let groupsShown = Set(articles.flatMap(\.blocks).compactMap { block -> QueryFieldGroup? in
            if case .fieldGroup(let group) = block { return group } else { return nil }
        })
        check("every field group has a reference article", groupsShown == Set(QueryFieldGroup.allCases), "missing: \(Set(QueryFieldGroup.allCases).subtracting(groupsShown).map(\.title))")

        // Links: every help:// target must exist.
        let linkPattern = try! NSRegularExpression(pattern: #"help://([a-z0-9-]+)"#)
        var broken: [String] = []
        for article in articles {
            let text = article.searchText
            for match in linkPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text), !ids.contains(String(text[range])) { broken.append("\(article.id) → \(text[range])") }
            }
        }
        check("every help:// link resolves", broken.isEmpty, broken.joined(separator: ", "))

        // Repo privacy rules: nothing identifying, nothing about the app this one grew out of, no stale claims.
        // The words that must never appear are kept out of the repository: they are read from the git-ignored
        // `Config/forbidden-terms.local` (one regular expression, alternatives separated by "|") when it exists.
        var forbidden = ["the reference app", "not yet tracked"]
        let localTerms = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Config/forbidden-terms.local")
        if let text = try? String(contentsOf: localTerms, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            forbidden += line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        let hits = articles.flatMap { article in forbidden.filter { article.searchText.contains($0) }.map { "\(article.id): \($0)" } }
        check("no forbidden text", hits.isEmpty, hits.joined(separator: ", "))

        // The privacy policy link: one URL, shown in Help, and a well-formed https address to the published policy.
        let policy = AppIdentity.privacyPolicyURLString
        check("the privacy policy URL is https and points at PRIVACY.md", URL(string: policy)?.scheme == "https" && policy.hasSuffix("/PRIVACY.md"), policy)
        for id in ["what-leaves-your-mac", "welcome"] {
            check("the \(id) article links the privacy policy", articles.first { $0.id == id }?.searchText.contains(policy.lowercased()) == true)
        }

        print("\(HelpContent.sections.count) sections, \(articles.count) articles, \(HelpFieldDefinitions.text.count) field definitions")
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
