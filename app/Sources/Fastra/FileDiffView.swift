// FileDiffView.swift
//
// Dual-Pane-Differenzansicht für den git-losen Datei-Vergleich (Etappe 1
// Wunschpaket 2026-07c). Muster wie `GitSideBySideDiffView`: beide Spalten
// leben in EINER LazyVStack und damit in exakt derselben Scrollposition.
// Unten sitzt — nach BBEdit-Vorbild („Differences" -Liste) — die Liste aller
// Unterschiede; ein Klick springt im Diff dorthin, ⌥↑/⌥↓ navigieren.

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
                diffBody
            }
        }
        .background(Theme.surfaceRaised)
        .onChange(of: request.id) {
            expandedFolds.removeAll()
            currentBlock = nil
        }
    }

    // MARK: - Diff-Ansicht

    private var diffBody: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbar(proxy: proxy)
                Divider().opacity(0.6)
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(FileDiff.visibleItems(
                                rows: result?.rows ?? [],
                                expandedFolds: expandedFolds
                            )) { item in
                                itemView(item)
                                    .id(item.id)
                            }
                        }
                        .frame(minWidth: max(geometry.size.width, 920),
                               minHeight: geometry.size.height,
                               alignment: .topLeading)
                    }
                }
                .accessibilityLabel("Vergleich beider Dateien")
                Divider().opacity(0.6)
                differencesList(proxy: proxy)
            }
        }
    }

    private func toolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
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
            Spacer()
            Text(L10n.format("Unterschied %ld von %ld",
                             (currentBlock ?? 0) + 1, blocks.count))
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
            Button { navigate(-1, proxy: proxy) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.upArrow, modifiers: .option)
            .disabled(blocks.isEmpty || currentBlock == 0)
            .help("Voriger Unterschied (⌥↑)")
            .accessibilityLabel("Voriger Unterschied")
            Button { navigate(1, proxy: proxy) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.downArrow, modifiers: .option)
            .disabled(blocks.isEmpty || currentBlock == blocks.count - 1)
            .help("Nächster Unterschied (⌥↓)")
            .accessibilityLabel("Nächster Unterschied")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        // Fenster-Selbsttest `filediff`: Der Marker trägt Blockzahl und
        // gewählten Unterschied — so beobachtet der Test ECHT gerenderten
        // Zustand statt nur das Modell (Muster `sidebarheader`).
        .background(SelfTestMarker(
            id: "fileDiffState-b\(blocks.count)-c\(currentBlock ?? -1)"
        ).frame(width: 0, height: 0))
    }

    /// Springt relativ zum aktuellen Unterschied (⌥↑/⌥↓ und Pfeil-Buttons).
    private func navigate(_ direction: Int, proxy: ScrollViewProxy) {
        guard !blocks.isEmpty else { return }
        let next = max(0, min(blocks.count - 1, (currentBlock ?? -1) + direction))
        select(blockIndex: next, proxy: proxy)
    }

    /// Wählt einen Unterschied und scrollt beide Spalten dorthin (eine
    /// LazyVStack → ein Scroll genügt für beide Seiten).
    private func select(blockIndex: Int, proxy: ScrollViewProxy) {
        guard blocks.indices.contains(blockIndex) else { return }
        currentBlock = blockIndex
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo("row-\(blocks[blockIndex].firstRowID)", anchor: .center)
        }
    }

    // MARK: - Differenzen-Liste (unten, BBEdit-Vorbild)

    private func differencesList(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.format("%ld Unterschiede", blocks.count))
                    .fastraFont(size: 10)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(Theme.surfaceBase)
            Divider().opacity(0.4)
            ScrollViewReader { listProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(blocks) { block in
                            blockRow(block, proxy: proxy)
                                .id("block-\(block.id)")
                        }
                    }
                }
                .onChange(of: currentBlock) { _, newValue in
                    // Tastatur-Navigation hält den gewählten Eintrag sichtbar.
                    if let newValue {
                        listProxy.scrollTo("block-\(newValue)", anchor: nil)
                    }
                }
            }
            .frame(height: 132)
        }
        .accessibilityLabel("Liste der Unterschiede")
    }

    private func blockRow(_ block: FileDiff.Block, proxy: ScrollViewProxy) -> some View {
        let selected = currentBlock == block.id
        return Button {
            select(blockIndex: block.id, proxy: proxy)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: blockIcon(block.kind))
                    .fastraFont(size: 10)
                    .foregroundColor(blockColor(block.kind))
                    .frame(width: 14)
                Text(Self.blockDescription(block))
                    .fastraFont(.small)
                    .foregroundColor(selected ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(selected ? Theme.accent.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.blockDescription(block))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Selbsttest-Anker: liefert die reale Fensterposition der Zeile für
        // einen synthetischen Klick (der 0×0-Marker sitzt in der Zeilenmitte).
        .background(SelfTestMarker(id: "fileDiffListRow-\(block.id)")
            .frame(width: 0, height: 0))
    }

    private func blockIcon(_ kind: FileDiff.BlockKind) -> String {
        switch kind {
        case .changed: return "pencil"
        case .onlyLeft: return "minus.circle"
        case .onlyRight: return "plus.circle"
        }
    }

    private func blockColor(_ kind: FileDiff.BlockKind) -> Color {
        switch kind {
        case .changed: return Theme.gitModified
        case .onlyLeft: return Theme.diffRemovedFG
        case .onlyRight: return Theme.diffAddedFG
        }
    }

    /// Menschlich lesbare Beschreibung eines Unterschieds („Zeilen 12–14
    /// geändert", „Zeile 30 nur links"). Statisch → unit-testbar.
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

    // MARK: - Zeilen

    @ViewBuilder
    private func itemView(_ item: FileDiff.VisibleItem) -> some View {
        switch item {
        case .row(let row):
            alignedRow(row)
        case .fold(let fold):
            let expanded = expandedFolds.contains(fold.id)
            Button {
                if expanded { expandedFolds.remove(fold.id) }
                else { expandedFolds.insert(fold.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.up" : "ellipsis")
                    Text(expanded
                         ? L10n.format("%ld unveränderte Zeilen wieder einklappen", fold.count)
                         : L10n.format("%ld unveränderte Zeilen einblenden", fold.count))
                    Spacer()
                }
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(minWidth: 920, minHeight: 23, alignment: .leading)
                .background(Theme.surfaceSand.opacity(0.22))
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? L10n.string("ausgeklappt") : L10n.string("eingeklappt"))
        }
    }

    /// Gehört die Zeile zum gewählten Unterschied? (Hervorhebung)
    private func isInCurrentBlock(_ row: FileDiff.Row) -> Bool {
        guard let currentBlock, blocks.indices.contains(currentBlock) else { return false }
        let block = blocks[currentBlock]
        return row.id >= block.firstRowID && row.id <= block.lastRowID
    }

    private func alignedRow(_ row: FileDiff.Row) -> some View {
        HStack(spacing: 0) {
            cell(number: row.beforeLine, text: row.before,
                 highlight: row.beforeHighlight, before: true, kind: row.kind)
            Divider().opacity(0.5)
            cell(number: row.afterLine, text: row.after,
                 highlight: row.afterHighlight, before: false, kind: row.kind)
        }
        .frame(minWidth: 920,
               minHeight: row.intralineWasLimited ? 38 : 22,
               alignment: .leading)
        .overlay(alignment: .bottom) {
            if row.intralineWasLimited {
                Text("Intra-Zeilen-Markierung wegen Zeilenlänge ausgelassen.")
                    .fastraFont(size: 9)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .overlay(alignment: .leading) {
            if isInCurrentBlock(row) {
                // Dezente Markierung des gewählten Unterschieds.
                Rectangle()
                    .fill(Theme.accentReadable)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Klick auf eine veränderte Zeile wählt ihren Unterschied.
            if let index = blocks.firstIndex(where: {
                row.id >= $0.firstRowID && row.id <= $0.lastRowID
            }) {
                currentBlock = index
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func cell(number: Int?, text: String?, highlight: Range<Int>?,
                      before: Bool, kind: FileDiff.RowKind) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .fastraFont(size: 9, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
            highlightedText(text ?? " ", range: highlight,
                            color: before ? Theme.diffRemovedFG : Theme.diffAddedFG)
                .fastraFont(.monoSmall)
                .foregroundColor(textColor(before: before, kind: kind,
                                           sideEmpty: text == nil))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 5)
        .frame(minWidth: 459, maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
        .background(cellBackground(before: before, kind: kind, sideEmpty: text == nil))
        .accessibilityLabel(L10n.format("%@ Zeile %@: %@",
                                       before ? L10n.string("Vorher") : L10n.string("Nachher"),
                                       number.map(String.init) ?? L10n.string("leer"), text ?? ""))
    }

    private func highlightedText(_ value: String, range: Range<Int>?, color: Color) -> Text {
        guard let range else { return Text(value) }
        let chars = Array(value)
        let lower = min(max(0, range.lowerBound), chars.count)
        let upper = min(max(lower, range.upperBound), chars.count)
        return Text(String(chars[..<lower]))
            + Text(String(chars[lower..<upper])).foregroundColor(color).bold()
            + Text(String(chars[upper...]))
    }

    private func textColor(before: Bool, kind: FileDiff.RowKind,
                           sideEmpty: Bool) -> Color {
        guard !sideEmpty else { return Theme.textSecondary }
        switch kind {
        case .unchanged: return Theme.textSecondary
        case .added: return before ? Theme.textSecondary : Theme.diffAddedFG
        case .removed: return before ? Theme.diffRemovedFG : Theme.textSecondary
        case .changed: return before ? Theme.diffRemovedFG : Theme.diffAddedFG
        }
    }

    private func cellBackground(before: Bool, kind: FileDiff.RowKind,
                                sideEmpty: Bool) -> Color {
        switch kind {
        case .unchanged: return .clear
        case .added:
            return before ? Theme.surfaceSand.opacity(0.15) : Theme.diffAddedBG.opacity(0.7)
        case .removed:
            return before ? Theme.diffRemovedBG.opacity(0.7) : Theme.surfaceSand.opacity(0.15)
        case .changed:
            return before ? Theme.diffRemovedBG.opacity(0.7) : Theme.diffAddedBG.opacity(0.7)
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
