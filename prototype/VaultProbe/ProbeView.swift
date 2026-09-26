import SwiftUI

struct LogLine: Identifiable {
    let id = UUID()
    let at = Date()
    let text: String
}

struct ProbeView: View {
    @State private var picking = false
    @State private var vault: URL?
    @State private var log: [LogLine] = []
    @State private var filename = "probe-target.md"
    @State private var burstCount = 20
    @State private var mode: WriteMode = .coordinated

    var body: some View {
        NavigationStack {
            List {
                Section("Vault") {
                    Button("Pick vault folder") { picking = true }
                    Button("Resolve stored bookmark") { resolveBookmark() }
                    Button("Clear bookmark") {
                        VaultBookmark.clear()
                        vault = nil
                        append("bookmark cleared")
                    }
                    LabeledContent("Resolved", value: vault?.path ?? "none")
                    LabeledContent("Stored at", value: VaultBookmark.storedAt?.formatted() ?? "never")
                }

                Section("Write") {
                    TextField("Target filename", text: $filename)
                        .autocorrectionDisabled()
                    Picker("Mode", selection: $mode) {
                        ForEach(WriteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Burst of \(burstCount)", value: $burstCount, in: 1...200)
                    Button("Run write burst") { runBurst() }
                }

                Section("Conflicts") {
                    Button("Scan vault") { scan() }
                }

                Section("Log") {
                    ForEach(log.reversed()) { line in
                        Text("\(line.at.formatted(date: .omitted, time: .standard))  \(line.text)")
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Vault Probe")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        try VaultBookmark.store(url)
                        vault = url
                        append("picked and stored: \(url.path)")
                    } catch {
                        append("store FAILED: \(error.localizedDescription)")
                    }
                case .failure(let error):
                    append("pick FAILED: \(error.localizedDescription)")
                }
            }
        }
    }

    private func resolveBookmark() {
        do {
            let (url, isStale) = try VaultBookmark.resolve()
            vault = url
            append("resolved\(isStale ? " STALE" : "") -> \(url.path)")
            if isStale {
                try? VaultBookmark.store(url)
                append("stale bookmark re-stored")
            }
        } catch {
            append("resolve FAILED: \(error)")
        }
    }

    private func runBurst() {
        withAccess { vault in
            let target = vault.appendingPathComponent(filename)
            var samples: [Double] = []
            var failures = 0

            for i in 1...burstCount {
                let body = "probe write \(i) of \(burstCount) at \(Date().ISO8601Format())\n"
                let (ms, failure) = CoordinatedWriter.write(body, to: target, mode: mode)
                samples.append(ms)
                if let failure {
                    failures += 1
                    append("write \(i) FAILED: \(failure)")
                }
            }

            let sorted = samples.sorted()
            append(String(format: "%@ x%d  failures %d  min %.1fms  med %.1fms  max %.1fms",
                          mode.rawValue,
                          burstCount,
                          failures,
                          sorted.first ?? 0,
                          sorted[sorted.count / 2],
                          sorted.last ?? 0))
        }
    }

    private func scan() {
        withAccess { vault in
            let report = ConflictScanner.scan(vault: vault)
            append("scanned \(report.filesSeen) files")
            append("suspect names: \(list(report.suspectFilenames))")
            append("NSFileVersion conflicts: \(report.unresolvedVersionCounts.isEmpty ? "none" : String(describing: report.unresolvedVersionCounts))")
            append("resource-value flagged: \(list(report.flaggedByResourceValue))")
        }
    }

    private func withAccess(_ body: (URL) -> Void) {
        guard let vault else {
            append("no vault resolved")
            return
        }
        guard vault.startAccessingSecurityScopedResource() else {
            append("startAccessingSecurityScopedResource returned false")
            return
        }
        defer { vault.stopAccessingSecurityScopedResource() }
        body(vault)
    }

    private func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: ", ")
    }

    private func append(_ text: String) {
        log.append(LogLine(text: text))
    }
}
