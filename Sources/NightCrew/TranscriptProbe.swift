import Foundation
import NightCrewCore

/// SPEC §5.3 signal 1: newest transcript mtimes on disk.
struct TranscriptProbe {
    private let claudeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let codexRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    /// Codex files a rollout under the session's start date, so a long session writes to an older folder.
    private let codexLookbackDays = 7

    /// Only the Claude project folders of live sessions are listed; other projects are irrelevant.
    func snapshot(claudeFolders: Set<String>, now: Date) -> TranscriptSnapshot {
        let fileManager = FileManager.default
        var claudeProjects: [String: Date]?
        if fileManager.fileExists(atPath: claudeRoot.path) {
            var found: [String: Date] = [:]
            for folder in claudeFolders {
                found[folder] = newest(in: claudeRoot.appendingPathComponent(folder)) { $0.hasSuffix(".jsonl") }
            }
            claudeProjects = found
        }

        let codexRootExists = fileManager.fileExists(atPath: codexRoot.path)
        var codexNewest: Date?
        if codexRootExists {
            let calendar = Calendar.current
            for daysBack in 0..<codexLookbackDays {
                guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let folder = codexRoot.appendingPathComponent(
                    String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
                if let date = newest(in: folder, where: { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }) {
                    codexNewest = max(codexNewest ?? date, date)
                }
            }
        }
        return TranscriptSnapshot(claudeProjects: claudeProjects, codexRootExists: codexRootExists, codexNewest: codexNewest)
    }

    private func newest(in folder: URL, where matches: (String) -> Bool) -> Date? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return files.filter { matches($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
