import Foundation
import SwiftData

/// Persists a Category A tool's own simple-UI options into the existing `ToolFilterSetting` model — the
/// same shape the backup format already round-trips (`NativeBackupEngine`), keyed by a tool
/// id (e.g. "recentmostoften").
/// `advancedGroupsJSON` has no consumer yet (no tool here returns extra conditions from Query back onto
/// its own simple UI) — written as an empty array so the stored shape matches what backup expects.
enum ToolFilterSettingsStore {
    private static func descriptor(_ toolId: String) -> FetchDescriptor<ToolFilterSetting> {
        var d = FetchDescriptor<ToolFilterSetting>(predicate: #Predicate { $0.toolId == toolId })
        d.fetchLimit = 1
        return d
    }

    static func load<Options: Codable>(_ type: Options.Type, toolId: String, context: ModelContext, default defaultValue: Options) -> Options {
        guard let existing = try? context.fetch(descriptor(toolId)).first,
              let decoded = try? JSONDecoder().decode(Options.self, from: existing.optionsJSON) else { return defaultValue }
        return decoded
    }

    static func save(_ options: some Codable, toolId: String, context: ModelContext) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        if let existing = try? context.fetch(descriptor(toolId)).first {
            existing.optionsJSON = data
        } else {
            context.insert(ToolFilterSetting(toolId: toolId, optionsJSON: data, advancedGroupsJSON: Data("[]".utf8)))
        }
    }
}
