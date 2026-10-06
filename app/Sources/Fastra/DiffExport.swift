import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Die fertige Vergleichsbasis wird beim Öffnen des Speicherdialogs festgehalten.
/// Weder spätere Dateiänderungen noch Falt- oder Navigationszustände gehören dazu.
enum DiffExportSnapshot {
    case file(FileDiffRequest, FileDiff.Result)
    case git(GitDiffRequest, GitDiffDocument)

    var protectedSources: [URL] {
        switch self {
        case .file(let request, _):
            return [request.left, request.right].compactMap { side in
                side.url ?? side.path.map { URL(fileURLWithPath: $0) }
            }
        case .git(let request, let document):
            var paths = document.files.flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } }
            if let original = request.originalPath { paths.append(original) }
            switch request.source {
            case .workingTree(let path): if let path { paths.append(path) }
            case .staged(let path), .unstaged(let path), .untracked(let path), .commit(_, _, let path):
                paths.append(path)
            }
            let root = URL(fileURLWithPath: request.repositoryPath, isDirectory: true)
            return paths.map { root.appendingPathComponent($0) }
        }
    }

    func report() -> String {
        var lines = [L10n.string("Fastra — Differenzen-Liste"),
                     L10n.string("Bericht aus der fertigen Vergleichsbasis; gefaltete Zeilen ändern die Liste nicht."), ""]
        func quote(_ text: String) -> String { String(reflecting: text) }
        func appendRow(before: String?, after: String?, beforeNumber: Int?, afterNumber: Int?,
                       beforeMissingNewline: Bool = false, afterMissingNewline: Bool = false) {
            if let before, let beforeNumber {
                lines.append("- \(beforeNumber) | \(before)")
                if beforeMissingNewline { lines.append(L10n.string("  Linke Zeile ohne abschließenden Zeilenumbruch.")) }
            }
            if let after, let afterNumber {
                lines.append("+ \(afterNumber) | \(after)")
                if afterMissingNewline { lines.append(L10n.string("  Rechte Zeile ohne abschließenden Zeilenumbruch.")) }
            }
        }
        switch self {
        case .file(let request, let result):
            func source(_ side: FileDiffSide) -> String {
                let location = side.path.map { " (\(quote($0)))" } ?? ""
                let kind = side.text != nil ? L10n.string("Editorinhalt") : L10n.string("Datei")
                return "\(quote(side.name))\(location) — \(kind)"
            }
            lines.append(L10n.format("Links: %@", source(request.left)))
            lines.append(L10n.format("Rechts: %@", source(request.right)))
            let options = request.options.isDefault ? L10n.string("Keine Unterschiede ignoriert.")
                : FileDiffView.optionsSummary(request.options)
            lines.append(L10n.format("Vergleichsoptionen: %@", options))
            lines.append(L10n.format("Unterschiede: %ld", result.blocks.count))
            for block in result.blocks {
                lines += ["", L10n.format("Unterschied %ld von %ld", block.id + 1, result.blocks.count)
                          + ": " + FileDiffView.blockDescription(block)]
                for row in result.rows[block.firstRowID...block.lastRowID] {
                    appendRow(before: row.before, after: row.after,
                              beforeNumber: row.beforeLine, afterNumber: row.afterLine)
                }
            }
        case .git(let request, let document):
            lines.append(L10n.format("Repository: %@", quote(request.repositoryPath)))
            lines.append("git " + request.arguments.map(quote).joined(separator: " "))
            if let description = request.comparisonDescription { lines.append(description) }
            lines.append(L10n.string("Git-Vergleich: Export der angezeigten Änderungen und Grenzen; unveränderte Bereiche können fehlen."))
            let entries = GitDiffDisplay.entries(document: document)
            lines.append(L10n.format("Unterschiede: %ld", entries.count))
            if let limit = document.limitation {
                lines += ["", limit.title, limit.explanation]
            }
            let byStart = Dictionary(uniqueKeysWithValues: entries.map { ($0.firstOrdinal, $0) })
            var ordinal = 0
            for file in document.files {
                lines += ["", quote(GitDiffDisplay.fileTitle(file))]
                if let limit = file.limitation { lines += [limit.title, limit.explanation] }
                for hunk in file.hunks {
                    for row in hunk.rows {
                        if let entry = byStart[ordinal] {
                            lines += ["", L10n.format("Unterschied %ld von %ld", entry.id + 1, entries.count)
                                      + ": " + quote(entry.label)]
                        }
                        if row.kind != .context {
                            appendRow(before: row.before, after: row.after,
                                      beforeNumber: row.beforeNumber, afterNumber: row.afterNumber,
                                      beforeMissingNewline: row.beforeMissingFinalNewline,
                                      afterMissingNewline: row.afterMissingFinalNewline)
                        }
                        ordinal += 1
                    }
                }
            }
        }
        lines += ["", L10n.string("- bezeichnet die linke/vorherige Zeile; + die rechte/neue Zeile. Zeilennummern beginnen bei 1.")]
        return lines.joined(separator: "\n") + "\n"
    }
}

enum DiffExport {
    static func write(_ snapshot: DiffExportSnapshot, to destination: URL) throws {
        try protectSources(snapshot.protectedSources, from: destination)
        let data = Data(snapshot.report().utf8)
        try protectSources(snapshot.protectedSources, from: destination)
        try data.write(to: destination, options: .atomic)
    }

    private static func protectSources(_ sources: [URL], from destination: URL) throws {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        func identity(_ url: URL) -> [UInt64]? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return [device.uint64Value, inode.uint64Value]
        }
        let targetIdentity = identity(target)
        for source in sources {
            let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
            if target == resolved || (targetIdentity != nil && targetIdentity == identity(resolved)) {
                throw NSError(domain: "DiffExport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L10n.string("Der Bericht darf keine Vergleichsquelle überschreiben. Wähle eine andere Datei.")])
            }
        }
    }
}

/// Der Knopf kennt sein eigenes Fenster, auch in externen Vergleichsfenstern.
struct DiffExportButton: NSViewRepresentable {
    let snapshot: DiffExportSnapshot

    func makeCoordinator() -> Coordinator { Coordinator(snapshot: snapshot) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.export(_:)))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = L10n.string("Diff-Liste exportieren…")
        button.setAccessibilityLabel(button.toolTip)
        button.identifier = NSUserInterfaceItemIdentifier("diffExport")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.snapshot = snapshot
        button.isEnabled = !context.coordinator.isBusy
    }

    @MainActor final class Coordinator: NSObject {
        var snapshot: DiffExportSnapshot
        var isBusy = false
        init(snapshot: DiffExportSnapshot) { self.snapshot = snapshot }

        @objc func export(_ sender: NSButton) {
            guard !isBusy, let window = sender.window else { return }
            let captured = snapshot
            isBusy = true
            sender.isEnabled = false
            let panel = NSSavePanel()
            panel.title = L10n.string("Diff-Liste exportieren…")
            panel.nameFieldStringValue = "Fastra-Diff.txt"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            SelfTest.configureDiffExportPanel(panel)
            panel.beginSheetModal(for: window) { [weak window, weak sender] response in
                guard response == .OK, let url = panel.url, let window, window.isVisible else {
                    self.isBusy = false; sender?.isEnabled = true
                    return
                }
                Task { @MainActor in
                    let failure: Error? = await Task.detached(priority: .userInitiated) {
                        do { try DiffExport.write(captured, to: url); return nil as Error? }
                        catch { return error }
                    }.value
                    self.isBusy = false; sender?.isEnabled = true
                    if let failure, window.isVisible {
                        let alert = NSAlert()
                        alert.messageText = L10n.string("Diff-Liste konnte nicht exportiert werden")
                        alert.informativeText = failure.localizedDescription
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    }
                }
            }
        }
    }
}
