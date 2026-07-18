// FileDiffView.swift
//
// Datei-Vergleichs-Tab (Etappe 1 Wunschpaket 2026-07c) auf dem gemeinsamen
// Dual-Pane-Renderer (`DualPaneDiffView`, Etappe 2): Diese View besitzt nur
// noch die Zustände des Datei-Vergleichs (Laden, Grenzen, „identisch",
// Kopfzeile mit Dateinamen + Optionen) und übersetzt das `FileDiff`-Modell
// in das gemeinsame Anzeige-Modell.

import SwiftUI

struct FileDiffView: View {
    let request: FileDiffRequest
    /// `nil` = Berechnung läuft noch.
    let document: FileDiffDocument?

    @State private var expandedFolds: Set<String> = []
    /// Index des gewählten Unterschieds in `result.blocks`.
    @State private var currentBlock: Int? = nil

    private var result: FileDiff.Result? { document?.result }
    private var blocks: [FileDiff.Block] { result?.blocks ?? [] }

    var body: some View {
        Group {
            if let limitation = document?.limitation {
                limitationView(limitation)
            } else if document == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Vergleich wird berechnet …")
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result, result.isIdentical {
                identicalView(result)
            } else {
                DualPaneDiffView(
                    items: displayItems,
                    entries: listEntries,
                    expandedFolds: $expandedFolds,
                    currentEntry: $currentBlock
                ) {
                    toolbarLeading
                }
            }
        }
        .background(Theme.surfaceRaised)
        .onChange(of: request.id) {
            expandedFolds.removeAll()
            currentBlock = nil
        }
    }

    // MARK: - Abbildung auf das gemeinsame Anzeige-Modell

    /// `FileDiff.Row` → gemeinsame Anzeigezeile. Die `id`s („row-N") sind
    /// die Scroll-Ziele; das Ordinal ist die Zeilenposition selbst.
    private static func displayRow(_ row: FileDiff.Row) -> DiffDisplayRow {
        DiffDisplayRow(
            id: "row-\(row.id)", ordinal: row.id, kind: row.kind,
            beforeNumber: row.beforeLine, afterNumber: row.afterLine,
            before: row.before, after: row.after,
            beforeHighlight: row.beforeHighlight,
            afterHighlight: row.afterHighlight,
            beforeMissingFinalNewline: false,
            afterMissingFinalNewline: false,
            intralineWasLimited: row.intralineWasLimited
        )
    }

    private var displayItems: [DiffDisplayItem] {
        FileDiff.visibleItems(rows: result?.rows ?? [],
                              expandedFolds: expandedFolds).map { item in
            switch item {
            case .row(let row):
                return .row(Self.displayRow(row))
            case .fold(let fold):
                return .fold(id: fold.id, count: fold.count,
                             expanded: expandedFolds.contains(fold.id))
            }
        }
    }

    private var listEntries: [DiffListEntry] {
        blocks.map { block in
            DiffListEntry(
                id: block.id,
                label: Self.blockDescription(block),
                kind: block.kind,
                scrollTargetID: "row-\(block.firstRowID)",
                firstOrdinal: block.firstRowID,
                lastOrdinal: block.lastRowID
            )
        }
    }

    // MARK: - Kopfzeile

    @ViewBuilder
    private var toolbarLeading: some View {
        Text(request.left.name)
            .fastraFont(.small)
            .foregroundColor(Theme.diffRemovedFG)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(request.left.path ?? request.left.name)
        Image(systemName: "arrow.left.arrow.right")
            .fastraFont(size: 9)
            .foregroundColor(Theme.textSecondary)
        Text(request.right.name)
            .fastraFont(.small)
            .foregroundColor(Theme.diffAddedFG)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(request.right.path ?? request.right.name)
        if !request.options.isDefault {
            Text(L10n.format("Ignoriert: %@", Self.optionsSummary(request.options)))
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .help("Diese Vergleichsoptionen waren beim Erstellen des Diffs aktiv.")
        }
    }

    /// Menschlich lesbare Beschreibung eines Unterschieds („Zeilen 12–14
    /// geändert", „Zeile 30 nur links"). Statisch → unit-testbar; auch der
    /// Git-Diff nutzt sie für seine Differenzen-Liste.
    static func blockDescription(_ block: FileDiff.Block) -> String {
        func text(_ range: ClosedRange<Int>) -> String {
            range.lowerBound == range.upperBound
                ? String(range.lowerBound)
                : "\(range.lowerBound)–\(range.upperBound)"
        }
        func isSingle(_ range: ClosedRange<Int>?) -> Bool {
            guard let range else { return true }
            return range.lowerBound == range.upperBound
        }
        switch block.kind {
        case .onlyLeft:
            guard let lines = block.beforeLines else { return "" }
            return isSingle(lines)
                ? L10n.format("Zeile %@ nur links", text(lines))
                : L10n.format("Zeilen %@ nur links", text(lines))
        case .onlyRight:
            guard let lines = block.afterLines else { return "" }
            return isSingle(lines)
                ? L10n.format("Zeile %@ nur rechts", text(lines))
                : L10n.format("Zeilen %@ nur rechts", text(lines))
        case .changed:
            let before = block.beforeLines
            let after = block.afterLines
            if let before, let after, before != after {
                return L10n.format("Zeilen %@ ↔ %@ geändert",
                                   text(before), text(after))
            }
            guard let lines = before ?? after else { return "" }
            return isSingle(lines)
                ? L10n.format("Zeile %@ geändert", text(lines))
                : L10n.format("Zeilen %@ geändert", text(lines))
        }
    }

    // MARK: - Sonderzustände

    /// Identische Dateien werden AUSDRÜCKLICH gemeldet — inklusive der
    /// aktiven Optionen, damit „identisch unter diesen Regeln" nie wie
    /// „byte-identisch" wirkt.
    private func identicalView(_ result: FileDiff.Result) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .fastraFont(size: 24)
                .foregroundColor(Theme.diffAddedFG)
            Text(result.leftLineCount == result.rightLineCount
                 ? L10n.format("Keine Unterschiede — %ld Zeilen identisch.",
                               result.leftLineCount)
                 : L10n.format("Keine Unterschiede — links %ld, rechts %ld Zeilen.",
                               result.leftLineCount, result.rightLineCount))
                .fastraFont(.headline)
                .foregroundColor(Theme.textPrimary)
            Text(L10n.format("%@ und %@", request.left.name, request.right.name))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
            if !request.options.isDefault {
                Text(L10n.format("Ignoriert: %@", Self.optionsSummary(request.options)))
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Zusammenfassung der aktiven Optionen („Leerzeilen, Groß-/Klein-
    /// schreibung"). Statisch → unit-testbar.
    static func optionsSummary(_ options: FileDiffOptions) -> String {
        var parts: [String] = []
        if options.ignoreAllWhitespace {
            parts.append(L10n.string("alle Leerraum-Unterschiede"))
        } else if options.ignoreTrailingWhitespace {
            parts.append(L10n.string("Leerraum am Zeilenende"))
        }
        if options.ignoreBlankLines { parts.append(L10n.string("Leerzeilen")) }
        if options.ignoreCase { parts.append(L10n.string("Groß-/Kleinschreibung")) }
        return parts.joined(separator: ", ")
    }

    private func limitationView(_ limitation: FileDiffLimitation) -> some View {
        VStack(spacing: 10) {
            Image(systemName: limitationIcon(limitation))
                .fastraFont(size: 24)
                .foregroundColor(Theme.textSecondary)
            Text(limitationTitle(limitation))
                .fastraFont(.headline)
                .foregroundColor(Theme.textPrimary)
            Text(limitationExplanation(limitation))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 620)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func limitationIcon(_ limitation: FileDiffLimitation) -> String {
        if case .binary = limitation { return "doc.badge.ellipsis" }
        return "exclamationmark.triangle"
    }

    /// Name der betroffenen Seite für Fehlermeldungen.
    private func sideName(_ side: FileDiffSideRole) -> String {
        side == .left ? request.left.name : request.right.name
    }

    private func limitationTitle(_ limitation: FileDiffLimitation) -> String {
        switch limitation {
        case .unreadable(let side):
            return L10n.format("„%@“ konnte nicht gelesen werden", sideName(side))
        case .binary(let side):
            return L10n.format("„%@“ ist eine Binärdatei", sideName(side))
        case .tooLarge(let side):
            return L10n.format("„%@“ ist zu groß für den Vergleich", sideName(side))
        case .tooManyLines(let side, _):
            return L10n.format("„%@“ hat zu viele Zeilen für den Vergleich", sideName(side))
        case .tooDifferent:
            return L10n.string("Die Dateien unterscheiden sich zu stark")
        }
    }

    private func limitationExplanation(_ limitation: FileDiffLimitation) -> String {
        switch limitation {
        case .unreadable:
            return L10n.string("Die Datei fehlt, ist nicht lesbar oder hat eine unbekannte Kodierung. Prüfe Pfad und Zugriffsrechte und vergleiche erneut.")
        case .binary:
            return L10n.string("Ein zeilenweiser Vergleich wäre bei Binärdaten irreführend. Öffne die Datei in der Hex-Ansicht, um ihren Inhalt zu prüfen.")
        case .tooLarge:
            return L10n.string("Fastra lädt so große Dateien nicht vollständig in den Speicher — ein vollständiger, ehrlicher Vergleich ist damit nicht möglich.")
        case .tooManyLines(_, let limit):
            return L10n.format("Der Vergleich verarbeitet bis zu %ld Zeilen je Datei. Teile die Datei auf oder vergleiche Ausschnitte.", limit)
        case .tooDifferent(let limit):
            return L10n.format("Nach Abzug gleicher Anfangs- und Endzeilen bleiben mehr als %ld unterschiedliche Zeilen — das übersteigt das Rechenbudget des zeilengenauen Vergleichs. Ein Ergebnis würde Minuten dauern oder unvollständig sein.", limit)
        }
    }
}
