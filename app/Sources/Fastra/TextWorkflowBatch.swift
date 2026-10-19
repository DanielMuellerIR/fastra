import Foundation

enum TextWorkflowScope: String, CaseIterable, Identifiable {
    case document, openDocuments, folder, project
    var id: String { rawValue }
    var isDisk: Bool { self == .folder || self == .project }
    var title: String {
        switch self {
        case .document: return L10n.string("Aktives Dokument")
        case .openDocuments: return L10n.string("Offene Dokumente dieses Fensters")
        case .folder: return L10n.string("Dateien aus Ordnern")
        case .project: return L10n.string("Dateien aus dem Projekt")
        }
    }
}

/// Hält jede Eingabe sichtbar, auch wenn eine andere nicht verarbeitet werden
/// kann. Nur ein vollständig geprüfter Satz besitzt einen schreibbaren Plan.
struct TextWorkflowBatch: Sendable {
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let preview: TextWorkflowEngine.Preview?
        let issue: String?
    }
    let entries: [Entry]
    let filePlan: TextWorkflowFilePlan?
    let openPlan: TextWorkflowOpenDocumentsPlan?
    var changedCount: Int { entries.filter { $0.preview?.changed == true }.count }
    var isComplete: Bool { !entries.isEmpty && entries.allSatisfy { $0.issue == nil && $0.preview != nil } }

    struct FileSource: Sendable, Equatable {
        let roots: [URL]
        let filter: FileTypeFilter
        let exclusions: [String]
        let projectRoot: URL?

        func enumerate(seconds: TimeInterval = TextWorkflowFilePlan.Limits.standard.seconds,
                       shouldCancel: @escaping @Sendable () -> Bool) throws -> [TextWorkflowFilePlan.Input] {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(seconds, TextWorkflowFilePlan.Limits.standard.seconds))
            func check() throws {
                if shouldCancel() { throw TextWorkflowFilePlan.Failure.cancelled }
                if ProcessInfo.processInfo.systemUptime >= deadline { throw TextWorkflowFilePlan.Failure.timeout }
            }
            let shouldStop: @Sendable () -> Bool = { shouldCancel() || ProcessInfo.processInfo.systemUptime >= deadline }
            let matcher = PathExclusion.Matcher(patterns: exclusions, relativeTo: projectRoot)
            var seen = Set<URL>(), inputs: [TextWorkflowFilePlan.Input] = []
            for root in roots {
                try check()
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) else {
                    throw TextWorkflowFilePlan.Failure.unreadable(root)
                }
                let candidates: [URL]
                do {
                    candidates = directory.boolValue ? try RipgrepFileEnumerator.files(in: root,
                        timeout: min(30, max(0, deadline - ProcessInfo.processInfo.systemUptime)),
                        outputLimit: GitOutputLimit(stdoutBytes: 8 * 1024 * 1024, stderrBytes: 1024 * 1024),
                        excludedPatterns: exclusions, shouldCancel: shouldStop) : [root]
                } catch { try check(); throw error }
                var packages = FolderSearch.PackageMembershipCache(root: root)
                for url in candidates {
                    try check()
                    guard !matcher.matches(url), FolderSearch.passesFilter(url: url, filter: filter),
                          !directory.boolValue || !packages.contains(url) else { continue }
                    // Überlappende Wurzeln deduplizieren; verschiedene Aliase
                    // bleiben Eingaben und werden vom gemeinsamen Plan abgelehnt.
                    guard seen.insert(url.standardizedFileURL).inserted else { continue }
                    guard inputs.count < TextWorkflowFilePlan.Limits.standard.files else { throw TextWorkflowFilePlan.Failure.sizeLimit }
                    inputs.append(.init(url: url))
                }
            }
            try check()
            guard !inputs.isEmpty else { throw TextWorkflowFilePlan.Failure.empty }
            return inputs.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }
    }

    static func files(_ workflow: TextWorkflow, inputs: [TextWorkflowFilePlan.Input],
                      limits: TextWorkflowFilePlan.Limits = .standard,
                      openTabs: [Workspace.TextWorkflowDiskMutation.TabState] = [],
                      shouldCancel: @escaping @Sendable () -> Bool = { false },
                      progress: (ApplyTransaction.Progress) -> Void = { _ in }) throws -> Self {
        guard !inputs.isEmpty else { throw TextWorkflowFilePlan.Failure.empty }
        guard inputs.count <= min(limits.files, TextWorkflowFilePlan.Limits.standard.files) else { throw TextWorkflowFilePlan.Failure.sizeLimit }
        var budget = Budget(limits), plans: [TextWorkflowFilePlan] = [], entries: [Entry] = []
        let deadline = budget.deadline
        let shouldStop: @Sendable () -> Bool = { shouldCancel() || ProcessInfo.processInfo.systemUptime > deadline }
        var paths = Set<URL>(), identities = Set<FileIdentity>()
        let blocked = openTabs.filter(\.blocked).map { ($0.url.canonicalFileURL, FileIdentity(url: $0.url.canonicalFileURL)) }
        for (index, input) in inputs.enumerated() {
            try budget.check(shouldCancel)
            do {
                let plan = try TextWorkflowFilePlan.build(workflow, inputs: [input], limits: budget.remaining,
                                                         shouldCancel: shouldStop)
                let file = plan.files[0]
                guard paths.insert(file.url).inserted,
                      file.snapshot.identity.map({ identities.insert($0).inserted }) ?? true else {
                    throw TextWorkflowFilePlan.Failure.duplicateInput(input.url)
                }
                try budget.consume(original: file.originalBytes.count, output: file.newBytes.count, preview: file.preview,
                                   shouldCancel: shouldStop)
                plans.append(plan)
                let issue = blocked.contains { url, identity in
                    url == file.url || identity != nil && identity == file.snapshot.identity
                } ? L10n.string("In einem Fenster ungespeichert oder noch nicht vollständig geladen. Speichere oder schließe die Datei und berechne die Vorschau erneut.") : nil
                entries.append(Entry(id: input.url.path, title: input.url.lastPathComponent,
                    detail: input.url.path + " · " + String.localizedName(of: file.encoding), preview: file.preview, issue: issue))
            } catch {
                try budget.check(shouldCancel)
                entries.append(Entry(id: input.url.path, title: input.url.lastPathComponent, detail: input.url.path,
                                     preview: nil, issue: TextWorkflowFailure.message(error)))
            }
            progress(.init(phase: .planned, completedFiles: index + 1, totalFiles: inputs.count, fileName: input.url.lastPathComponent))
        }
        try budget.check(shouldCancel)
        let complete = entries.allSatisfy { $0.issue == nil }
        return Self(entries: entries, filePlan: complete ? try TextWorkflowFilePlan.combining(plans) : nil, openPlan: nil)
    }

    static func documents(_ workflow: TextWorkflow, source: TextWorkflowOpenDocumentsPlan.Source,
                          limits: TextWorkflowFilePlan.Limits = .standard,
                          shouldCancel: @escaping @Sendable () -> Bool = { false },
                          progress: (ApplyTransaction.Progress) -> Void = { _ in }) throws -> Self {
        guard !source.inputs.isEmpty else { throw TextWorkflowOpenDocumentsPlan.Failure.empty }
        guard source.inputs.count <= min(limits.files, TextWorkflowFilePlan.Limits.standard.files) else { throw TextWorkflowOpenDocumentsPlan.Failure.sizeLimit }
        var budget = Budget(limits), plans: [TextWorkflowOpenDocumentsPlan] = [], entries: [Entry] = []
        let deadline = budget.deadline
        let shouldStop: @Sendable () -> Bool = { shouldCancel() || ProcessInfo.processInfo.systemUptime > deadline }
        for (index, input) in source.inputs.enumerated() {
            try budget.check(shouldCancel)
            do {
                let single = try source.selecting(input.tabID)
                let plan = try TextWorkflowOpenDocumentsPlan.build(workflow, source: single, limits: budget.remaining, shouldCancel: shouldStop)
                let document = plan.documents[0]
                try budget.consume(original: input.source.utf8.count, output: document.preview.output.utf8.count,
                                   preview: document.preview, shouldCancel: shouldStop)
                plans.append(plan)
                entries.append(Entry(id: input.tabID.uuidString, title: input.title, detail: input.url?.path ?? L10n.string("Ungespeichertes Dokument"),
                                     preview: document.preview, issue: nil))
            } catch {
                try budget.check(shouldCancel)
                entries.append(Entry(id: input.tabID.uuidString, title: input.title, detail: input.url?.path ?? "",
                                     preview: nil, issue: TextWorkflowFailure.message(error)))
            }
            progress(.init(phase: .planned, completedFiles: index + 1, totalFiles: source.inputs.count, fileName: input.title))
        }
        try budget.check(shouldCancel)
        return Self(entries: entries, filePlan: nil, openPlan: entries.allSatisfy { $0.issue == nil }
            ? try TextWorkflowOpenDocumentsPlan.combining(plans, source: source) : nil)
    }

    private struct Budget {
        var remaining: TextWorkflowFilePlan.Limits
        let deadline: TimeInterval
        init(_ limits: TextWorkflowFilePlan.Limits) {
            let standard = TextWorkflowFilePlan.Limits.standard
            remaining = limits
            remaining.originalBytes = min(limits.originalBytes, standard.originalBytes)
            remaining.outputBytes = min(limits.outputBytes, standard.outputBytes)
            remaining.previewBytes = min(limits.previewBytes, standard.previewBytes)
            deadline = ProcessInfo.processInfo.systemUptime + min(limits.seconds, standard.seconds)
        }
        func check(_ shouldCancel: () -> Bool) throws {
            if shouldCancel() { throw TextWorkflowFilePlan.Failure.cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { throw TextWorkflowFilePlan.Failure.timeout }
        }
        mutating func consume(original: Int, output: Int, preview: TextWorkflowEngine.Preview, shouldCancel: () -> Bool) throws {
            guard let bytes = preview.retainedUTF8Bytes, original <= remaining.originalBytes,
                  output <= remaining.outputBytes, bytes <= remaining.previewBytes else { throw TextWorkflowError.sizeLimit }
            remaining.originalBytes -= original; remaining.outputBytes -= output; remaining.previewBytes -= bytes
            // Auch noch nicht ausgewählte Schritt-Diffs müssen darstellbar
            // sein. Sonst könnte Apply eine unsichtbare Änderung freigeben.
            let pairs = [(preview.source, preview.output)] + preview.steps.map { ($0.before, $0.after) }
            for (before, after) in pairs {
                try check(shouldCancel)
                let result = try TextWorkflowDiff.build(before: before, after: after, isCancelled: shouldCancel)
                guard result.document.result != nil else { throw TextWorkflowError.sizeLimit }
            }
        }
    }
}
