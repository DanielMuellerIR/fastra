// GitDualPaneDiffView.swift
//
// Git-Diff auf dem GEMEINSAMEN Dual-Pane-Renderer (Etappe 2 Wunschpaket
// 2026-07c). Der Git-spezifische Unterbau (GitDiffRequest/GitDiffParser,
// Hunk-Folding, Mehr-Datei-Diffs, Commit-Metadaten, Unified-Fallback)
// bleibt vollständig erhalten — NUR die Darstellungsschicht ist mit dem
// Datei-Diff vereinheitlicht: eine Optik, eine Tastatur-Navigation, eine
// Differenzen-Liste (früher: eigener Renderer `GitSideBySideDiffView`).

import SwiftUI

/// Pure Abbildung „Git-Diff-Modell → gemeinsames Anzeige-Modell".
/// Die Zeilen-AUSRICHTUNG stammt unverändert aus `GitDiffParser`; hier wird
/// nichts neu ausgerichtet, nur 1:1 übersetzt (unit-getestet).
enum GitDiffDisplay {

    /// Position jeder Zeile in der vollen (ungefalteten) Zeilenfolge des
    /// Dokuments — Basis für Auswahl-Hervorhebung über Falt-Grenzen hinweg.
    static func rowOrdinals(document: GitDiffDocument) -> [String: Int] {
        var ordinals: [String: Int] = [:]
        var next = 0
        for hunk in document.hunks {
            for row in hunk.rows {
                ordinals[row.id] = next
                next += 1
            }
        }
        return ordinals
    }

    /// 1:1-Übersetzung einer ausgerichteten Git-Zeile (keine Neuausrichtung).
    static func displayRow(_ row: GitDiffAlignedRow, ordinal: Int) -> DiffDisplayRow {
        let kind: FileDiff.RowKind
        switch row.kind {
        case .context: kind = .unchanged
        case .added: kind = .added
        case .removed: kind = .removed
        case .changed: kind = .changed
        }
        return DiffDisplayRow(
            id: row.id, ordinal: ordinal, kind: kind,
            beforeNumber: row.beforeNumber, afterNumber: row.afterNumber,
            before: row.before, after: row.after,
            beforeHighlight: row.beforeHighlight,
            afterHighlight: row.afterHighlight,
            beforeMissingFinalNewline: row.beforeMissingFinalNewline,
            afterMissingFinalNewline: row.afterMissingFinalNewline,
            intralineWasLimited: row.intralineWasLimited
        )
    }

    /// Titel des Dateikopfs (Logik des früheren Renderers unverändert).
    static func fileTitle(_ file: GitDiffFile) -> String {
        let old = file.oldPath ?? L10n.string("leere Datei")
        let new = file.newPath ?? L10n.string("gelöschte Datei")
        if file.oldPath == nil, file.newPath == nil {
            return file.metadata.first(where: { $0.hasPrefix("diff --git ") })
                ?? L10n.string("Datei")
        }
        return old == new ? old : L10n.format("%@ → %@", old, new)
    }

    /// Baut die sichtbaren Elemente: Dateiköpfe, Datei-Hinweise, Lücken,
    /// Hunk-Köpfe und die per `GitDiffViewModel` gefalteten Zeilen — exakt
    /// die Struktur des früheren Renderers, nur im gemeinsamen Modell.
    static func items(document: GitDiffDocument,
                      expandedFolds: Set<String>) -> [DiffDisplayItem] {
        let ordinals = rowOrdinals(document: document)
        var out: [DiffDisplayItem] = []
        for file in document.files {
            out.append(.fileHeader(id: "filehead-\(file.id)", title: fileTitle(file)))
            if let limitation = file.limitation {
                out.append(.note(id: "note-\(file.id)",
                                 title: limitation.title,
                                 explanation: limitation.explanation))
            }
            for (index, hunk) in file.hunks.enumerated() {
                let gap = GitDiffViewModel.omittedLineCount(
                    previous: index > 0 ? file.hunks[index - 1] : nil,
                    current: hunk
                )
                if gap > 0 { out.append(.gap(id: "gap-\(hunk.id)", count: gap)) }
                out.append(.hunkHeader(
                    id: hunk.id, text: hunk.header,
                    accessibility: L10n.format(
                        "Änderungsblock ab vorher Zeile %ld, nachher Zeile %ld",
                        hunk.oldStart, hunk.newStart
                    )
                ))
                for item in GitDiffViewModel.visibleItems(
                    hunk: hunk, expandedFolds: expandedFolds
                ) {
                    switch item {
                    case .row(let row):
                        out.append(.row(displayRow(row, ordinal: ordinals[row.id] ?? 0)))
                    case .fold(let fold):
                        out.append(.fold(id: fold.id, count: fold.count,
                                         expanded: expandedFolds.contains(fold.id)))
                    }
                }
            }
        }
        return out
    }

    /// Differenzen-Liste: ein Eintrag je zusammenhängendem Lauf veränderter
    /// Zeilen (gleiche Semantik wie beim Datei-Diff). Läufe enden an
    /// Kontextzeilen und an Hunk-Grenzen; bei Mehr-Datei-Diffs steht der
    /// Dateiname vor der Beschreibung.
    static func entries(document: GitDiffDocument) -> [DiffListEntry] {
        let ordinals = rowOrdinals(document: document)
        let multiFile = document.files.count > 1
        var entries: [DiffListEntry] = []
        for file in document.files {
            let prefix: String? = multiFile
                ? ((file.newPath ?? file.oldPath).map {
                    ($0 as NSString).lastPathComponent
                } ?? L10n.string("Datei"))
                : nil
            for hunk in file.hunks {
                let rows = hunk.rows
                var runStart: Int? = nil

                func flush(upTo end: Int) {
                    guard let start = runStart else { return }
                    runStart = nil
                    let run = rows[start..<end]
                    let kinds = Set(run.map(\.kind))
                    let kind: FileDiff.BlockKind
                    if kinds == [.added] { kind = .onlyRight }
                    else if kinds == [.removed] { kind = .onlyLeft }
                    else { kind = .changed }
                    let beforeNumbers = run.compactMap(\.beforeNumber)
                    let afterNumbers = run.compactMap(\.afterNumber)
                    // Beschreibung über dieselbe Logik wie der Datei-Diff —
                    // der Block dient nur als Träger für Bereiche + Art.
                    let block = FileDiff.Block(
                        id: 0, firstRowID: 0, lastRowID: 0, kind: kind,
                        beforeLines: beforeNumbers.isEmpty
                            ? nil : beforeNumbers.min()!...beforeNumbers.max()!,
                        afterLines: afterNumbers.isEmpty
                            ? nil : afterNumbers.min()!...afterNumbers.max()!
                    )
                    var label = FileDiffView.blockDescription(block)
                    if let prefix { label = "\(prefix): \(label)" }
                    entries.append(DiffListEntry(
                        id: entries.count, label: label, kind: kind,
                        scrollTargetID: rows[start].id,
                        firstOrdinal: ordinals[rows[start].id] ?? 0,
                        lastOrdinal: ordinals[rows[end - 1].id] ?? 0
                    ))
                }

                for (index, row) in rows.enumerated() {
                    if row.kind == .context {
                        flush(upTo: index)
                    } else if runStart == nil {
                        runStart = index
                    }
                }
                flush(upTo: rows.count)
            }
        }
        return entries
    }
}

/// Read-only Git-Diff-Tab auf dem gemeinsamen Renderer. Lade-, Leer- und
/// Grenz-Zustände (binär, kombinierter Merge-Diff, …) verhalten sich wie
/// beim früheren Renderer.
struct GitDualPaneDiffView: View {
    let request: GitDiffRequest
    let document: GitDiffDocument?
    let fallbackText: String

    @State private var expandedFolds: Set<String> = []
    @State private var currentEntry: Int? = nil

    var body: some View {
        Group {
            if let limitation = document?.limitation {
                limitationView(limitation)
            } else if document == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Git-Diff wird geladen …")
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if document?.isEmpty == true {
                Text(fallbackText.isEmpty ? L10n.string("Keine Änderungen.") : fallbackText)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                DualPaneDiffView(
                    items: GitDiffDisplay.items(document: document,
                                                expandedFolds: expandedFolds),
                    entries: GitDiffDisplay.entries(document: document),
                    expandedFolds: $expandedFolds,
                    currentEntry: $currentEntry
                ) {
                    toolbarLeading
                }
            }
        }
        .background(Theme.surfaceRaised)
        .onChange(of: request.id) {
            expandedFolds.removeAll()
            currentEntry = nil
        }
        .onChange(of: document) { _, newDocument in
            // Nach einem Reload nur noch existierende Falt-IDs behalten
            // (Auswahl klammert der gemeinsame Renderer selbst).
            if let newDocument {
                expandedFolds = GitDiffViewModel.validExpandedFolds(
                    expandedFolds, document: newDocument
                )
            } else {
                expandedFolds.removeAll()
            }
        }
    }

    @ViewBuilder
    private var toolbarLeading: some View {
        if let comparison = request.comparisonDescription {
            Text(comparison)
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .help("Der ausgewählte Eltern-Commit ist die linke Vergleichsseite.")
        } else {
            Text("Vorher")
                .fastraFont(.small)
                .foregroundColor(Theme.diffRemovedFG)
            Image(systemName: "arrow.right")
                .fastraFont(size: 9)
                .foregroundColor(Theme.textSecondary)
            Text("Nachher")
                .fastraFont(.small)
                .foregroundColor(Theme.diffAddedFG)
        }
    }

    private func limitationView(_ limitation: GitDiffLimitation) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: limitationIcon(limitation))
                    .fastraFont(size: 24)
                    .foregroundColor(Theme.textSecondary)
                Text(limitation.title)
                    .fastraFont(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text(limitation.explanation)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 620)
                if case .combinedDiff(let unified) = limitation {
                    Text(unified)
                        .fastraFont(.monoSmall)
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.surfaceBase)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func limitationIcon(_ limitation: GitDiffLimitation) -> String {
        if case .binary = limitation { return "doc.badge.ellipsis" }
        return "exclamationmark.triangle"
    }
}
