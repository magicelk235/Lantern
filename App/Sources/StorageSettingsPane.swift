import IDEModel
import SwiftUI

/// Settings › Storage: what omp and omp IDE keep on disk and could let go of, and the free
/// space. ompd reports omp's side with `omp gc --json` (a dry run) and cleans it with `omp gc --apply --blobs --wal`;
/// it never archives sessions (`--archive` moves session files that ompd or Open Session… may still resume). Loads
/// when the pane shows and while ompd is reachable.
struct StorageSettingsPane: View {
    let app: AppState
    @State private var report: StorageReport?
    /// Hot-exit temp files interrupted writes left (the app's own; ompd does not touch the editors' data).
    @State private var mirrorLeftovers = Leftovers()
    @State private var loading = false
    @State private var failure: String?
    @State private var cleaning = false
    /// What the last Clean Up did.
    @State private var outcome: String?

    private var connection: DaemonConnection { app.connection }

    private struct Leftovers: Equatable {
        var count = 0
        var bytes: Int64 = 0
    }

    var body: some View {
        Form {
            if let report {
                ForEach(report.omp, id: \.agentDir) { omp in
                    Section {
                        LabeledContent("Unreferenced blobs", value: Self.files(omp.blobs, bytes: omp.blobBytes))
                        LabeledContent("Database logs", value: omp.walBytes == 0 ? "None" : Self.size(omp.walBytes))
                    } header: {
                        Text(report.omp.count > 1 ? "omp in \(omp.agentDir)" : "omp")
                    } footer: {
                        if let archivable = omp.archiveCandidates, archivable > 0 {
                            Text("\(archivable) older sessions could be archived with omp gc --archive. omp IDE never archives them: ompd and Open Session… may still resume them.")
                        }
                    }
                }
                Section("omp IDE") {
                    LabeledContent("Data", value: Self.size(report.ide.totalBytes))
                    LabeledContent(
                        "Leftovers",
                        value: Self.files(
                            report.ide.unreferencedSnapshots + mirrorLeftovers.count,
                            bytes: report.ide.unreferencedSnapshotBytes + mirrorLeftovers.bytes))
                }
                Section {
                    LabeledContent("Free disk space", value: "\(Self.size(report.freeBytes)) of \(Self.size(report.volumeBytes))")
                }
                Section {
                    HStack(spacing: 8) {
                        Button("Clean Up", action: cleanUp)
                            .disabled(cleaning || loading || !connection.isConnected)
                        if cleaning { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let outcome {
                        Text(outcome).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(footer(report))
                }
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else if connection.isConnected {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            } else {
                Text("Available while ompd is running.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: connection.isConnected) { await load() }
    }

    private func footer(_ report: StorageReport) -> String {
        let problems = report.failures.isEmpty ? "" : " " + report.failures.joined(separator: " ")
        return "Clean Up deletes the files no omp session refers to, folds omp's database logs back into its databases and removes leftovers of omp IDE: old terminal screens and unfinished backup writes. Sessions are never archived or deleted.\(problems)"
    }

    private func load() async {
        guard connection.isConnected else {
            report = nil
            failure = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            report = try await connection.storageReport()
            mirrorLeftovers = Self.leftovers(app.persistence.abandonedMirrorWrites())
            failure = nil
        } catch {
            report = nil
            failure = "Could not read the storage: \(error.userMessage)"
        }
    }

    private func cleanUp() {
        cleaning = true
        outcome = nil
        Task {
            defer { cleaning = false }
            do {
                let result = try await connection.cleanStorage()
                let mirrors = Self.leftovers(app.persistence.removeAbandonedMirrorWrites())
                outcome = Self.describe(result, before: report, mirrors: mirrors)
                await load()
            } catch {
                outcome = "Could not clean up: \(error.userMessage)"
            }
        }
    }

    private static func leftovers(_ found: (count: Int, bytes: Int64)) -> Leftovers {
        Leftovers(count: found.count, bytes: found.bytes)
    }

    /// "Deleted 12 unused files (1.3 MB) and 2 leftovers (40 KB). Folded 48 KB of database logs back." or "Nothing to
    /// clean up." The logs folded back are what `before` (the report on screen) counted for each checkpointed agent
    /// directory less what is left: omp reports a clean-up's log size after the checkpoint.
    private static func describe(_ result: StorageClean.Result, before: StorageReport?, mirrors: Leftovers) -> String {
        let blobs = result.omp.reduce(0) { $0 + $1.blobs }
        let blobBytes = result.omp.reduce(Int64(0)) { $0 + $1.blobBytes }
        let leftovers = result.removedSnapshots + mirrors.count
        let leftoverBytes = result.removedSnapshotBytes + mirrors.bytes
        let logs = result.omp.filter(\.walCheckpointed).reduce(Int64(0)) { sum, omp in
            let reported = before?.omp.first { $0.agentDir == omp.agentDir }?.walBytes ?? 0
            return sum + max(0, reported - omp.walBytes)
        }
        var deleted: [String] = []
        if blobs > 0 { deleted.append("\(files(blobs, bytes: blobBytes, noun: "unused file"))") }
        if leftovers > 0 { deleted.append("\(files(leftovers, bytes: leftoverBytes, noun: "leftover"))") }
        var sentences: [String] = []
        if !deleted.isEmpty { sentences.append("Deleted \(deleted.joined(separator: " and ")).") }
        if logs > 0 { sentences.append("Folded \(size(logs)) of database logs back.") }
        let errors = result.omp.flatMap(\.errors) + result.failures
        if !errors.isEmpty { sentences.append(errors.joined(separator: " ")) }
        return sentences.isEmpty ? "Nothing to clean up." : sentences.joined(separator: " ")
    }

    /// "12 files, 1.3 MB"; "None" for none. With `noun`: "12 unused files (1.3 MB)".
    private static func files(_ count: Int, bytes: Int64, noun: String? = nil) -> String {
        guard let noun else { return count == 0 ? "None" : "\(count) \(count == 1 ? "file" : "files"), \(size(bytes))" }
        return "\(count) \(noun)\(count == 1 ? "" : "s") (\(size(bytes)))"
    }

    private static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
