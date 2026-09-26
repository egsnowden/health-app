import Foundation

struct ConflictReport {
    var suspectFilenames: [String] = []
    var unresolvedVersionCounts: [String: Int] = [:]
    var flaggedByResourceValue: [String] = []
    var filesSeen = 0
}

struct ConflictScanner {
    static func scan(vault: URL) -> ConflictReport {
        var report = ConflictReport()
        let keys: [URLResourceKey] = [.ubiquitousItemHasUnresolvedConflictsKey, .isRegularFileKey]

        guard let walker = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: keys) else {
            return report
        }

        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            report.filesSeen += 1

            let base = url.deletingPathExtension().lastPathComponent
            if base.range(of: #" \d+$"#, options: .regularExpression) != nil {
                report.suspectFilenames.append(url.lastPathComponent)
            }

            if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty {
                report.unresolvedVersionCounts[url.lastPathComponent] = conflicts.count
            }

            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]),
               values.ubiquitousItemHasUnresolvedConflicts == true {
                report.flaggedByResourceValue.append(url.lastPathComponent)
            }
        }

        return report
    }
}
