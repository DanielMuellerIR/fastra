// DualPaneDiffView.swift
//
// Gemeinsamer Dual-Pane-Diff-Renderer (Etappe 2 Wunschpaket 2026-07c):
// EINE Optik, EINE Tastatur-Navigation und EINE Differenzen-Liste für den
// git-losen Datei-Vergleich UND die Git-Diff-Tabs. Beide Spalten leben in
// derselben LazyVStack und damit in exakt derselben Scrollposition.
//
// Die Komponente ist bewusst „dumm": Sie rendert vorbereitete
// `DiffDisplayItem`s und `DiffListEntry`s. Wer sie einbettet (FileDiffView,
// GitDualPaneDiffView), besitzt den Falt- und Auswahlzustand und baut die
// Elemente aus seinem jeweiligen Modell — die Zeilen-AUSRICHTUNG selbst
// bleibt unangetastet in `FileDiff` bzw. `GitDiffParser`.

import SwiftUI

// MARK: - Anzeige-Modell

/// Eine ausgerichtete Anzeigezeile — gemeinsame Form für Datei- und Git-Diff.
struct DiffDisplayRow: Hashable, Identifiable {
    /// Stabile Identität (Scroll-Ziel): Git-Row-ID bzw. „row-N" im Datei-Diff.
    let id: String
    /// Position in der VOLLEN (ungefalteten) Zeilenfolge — Basis der
    /// Hervorhebung des gewählten Unterschieds.
    let ordinal: Int
    let kind: FileDiff.RowKind
    let beforeNumber: Int?
    let afterNumber: Int?
    let before: String?
    let after: String?
    let beforeHighlight: Range<Int>?
    let afterHighlight: Range<Int>?
    let beforeMissingFinalNewline: Bool
    let afterMissingFinalNewline: Bool
    let intralineWasLimited: Bool
}

/// Sichtbares Element des Renderers: Zeile, Falt-Knopf oder Git-spezifische
/// Dekoration (Dateikopf, Hunk-Kopf, ausgelassener Bereich, Hinweis).
enum DiffDisplayItem: Hashable, Identifiable {
    case row(DiffDisplayRow)
    case fold(id: String, count: Int, expanded: Bool)
    case fileHeader(id: String, title: String)
    case hunkHeader(id: String, text: String, accessibility: String)
    case gap(id: String, count: Int)
    case note(id: String, title: String, explanation: String)

    var id: String {
        switch self {
        case .row(let row): return row.id
        case .fold(let id, _, _): return id
        case .fileHeader(let id, _): return id
        case .hunkHeader(let id, _, _): return id
        case .gap(let id, _): return id
        case .note(let id, _, _): return id
        }
    }
}

/// Ein Eintrag der Differenzen-Liste unter dem Diff (BBEdit-Vorbild).
struct DiffListEntry: Hashable, Identifiable {
    /// Fortlaufender Index (= Position in der Liste).
    let id: Int
    /// Fertig formulierte Beschreibung („Zeilen 12–14 geändert" …).
    let label: String
    let kind: FileDiff.BlockKind
    /// Item-ID der ersten Zeile des Unterschieds (Scroll-Ziel).
    let scrollTargetID: String
    /// Ordinal-Bereich der zugehörigen Zeilen (Hervorhebung).
    let firstOrdinal: Int
    let lastOrdinal: Int
}

/// Meldet die Fensterpositionen der jeweils ersten Zeile jedes Unterschieds —
/// damit folgt die „Unterschied X von Y"-Anzeige dem Scrollen (gleiches
/// Muster wie die Hunk-Verfolgung des früheren Git-Renderers).
private struct DiffEntryOffsetsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat],
                       nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

// MARK: - Gemeinsamer Renderer

struct DualPaneDiffView<Leading: View>: View {
    let items: [DiffDisplayItem]
    let entries: [DiffListEntry]
    @Binding var expandedFolds: Set<String>
    /// Gewählter Unterschied (Index in `entries`) — der Einbetter besitzt
    /// den Zustand (Selbsttest-Marker, Reconciliation bei Git-Reloads).
    @Binding var currentEntry: Int?
    /// Kopfzeilen-Inhalt links (Dateinamen bzw. Commit-Beschreibung).
    @ViewBuilder let leading: () -> Leading

    /// Nach einer bewussten Auswahl (Klick/Taste) darf die Scroll-Verfolgung
    /// sie nicht sofort wieder überschreiben: Das Zentrieren des Ziels lässt
    /// den VORIGEN Eintrag „oben passieren", was die Verfolgung sonst als
    /// neuen aktuellen Eintrag deutete. Kurzes Zeitfenster statt Dauer-Flag —
    /// echtes Weiterscrollen von Hand übernimmt danach wieder.
    @State private var suppressFollowUntil: Date? = nil

    /// Schnelle Zuordnung „Zeilen-ID → Eintrag-Index" für Scroll-Verfolgung.
    private var entryIndexByTargetID: [String: Int] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.scrollTargetID, $0.id) })
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbar(proxy: proxy)
                Divider().opacity(0.6)
                HStack(spacing: 0) {
                    GeometryReader { geometry in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(items) { item in
                                    itemView(item)
                                        .id(item.id)
                                }
                            }
                            .frame(minWidth: max(geometry.size.width, 920),
                                   minHeight: geometry.size.height,
                                   alignment: .topLeading)
                        }
                        .coordinateSpace(name: "dualPaneDiffScroll")
                        .onPreferenceChange(DiffEntryOffsetsKey.self) { offsets in
                            if let until = suppressFollowUntil, Date() < until {
                                return
                            }
                            let positions = offsets.mapValues(Double.init)
                            if let visible = GitDiffViewModel.currentHunkIndex(
                                positions: positions,
                                orderedIDs: entries.map(\.scrollTargetID)
                            ) {
                                currentEntry = visible
                            }
                        }
                    }
                    .accessibilityLabel("Vergleich beider Dateien")

                    Divider().opacity(0.6)
                    overviewRuler(proxy: proxy)
                        .frame(width: 20)
                }
                Divider().opacity(0.6)
                differencesList(proxy: proxy)
            }
        }
        .onChange(of: items) {
            // Nach einem Reload (Git-Refresh) darf die Auswahl nicht auf
            // einen nicht mehr existierenden Eintrag zeigen.
            if let current = currentEntry, current >= entries.count {
                currentEntry = entries.isEmpty ? nil : entries.count - 1
            }
        }
        .onAppear {
            // Start beim ersten Unterschied — wie der frühere Git-Renderer
            // („Änderung 1 von N"); die Verfolgung übernimmt beim Scrollen.
            if currentEntry == nil, !entries.isEmpty { currentEntry = 0 }
        }
    }

    // MARK: Kopfzeile

    private func toolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            leading()
            Spacer()
            Text(L10n.format("Unterschied %ld von %ld",
                             (currentEntry ?? 0) + 1, entries.count))
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
            Button { navigate(-1, proxy: proxy) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.upArrow, modifiers: .option)
            .disabled(entries.isEmpty || currentEntry == 0)
            .help("Voriger Unterschied (⌥↑)")
            .accessibilityLabel("Voriger Unterschied")
            Button { navigate(1, proxy: proxy) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.downArrow, modifiers: .option)
            .disabled(entries.isEmpty || currentEntry == entries.count - 1)
            .help("Nächster Unterschied (⌥↓)")
            .accessibilityLabel("Nächster Unterschied")
            // Die alten Git-Diff-Shortcuts ⌥⌘[/⌥⌘] bleiben als stille
            // Zweitbelegung erhalten (eingeübte Hände brechen nicht).
            Button { navigate(-1, proxy: proxy) } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: [.command, .option])
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Button { navigate(1, proxy: proxy) } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("]", modifiers: [.command, .option])
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        // Fenster-Selbsttests beobachten hier ECHT gerenderten Zustand:
        // Anzahl der Unterschiede + aktuelle Auswahl.
        .background(SelfTestMarker(
            id: "diffState-b\(entries.count)-c\(currentEntry ?? -1)"
        ).frame(width: 0, height: 0))
    }

    /// Springt relativ zum aktuellen Unterschied (⌥↑/⌥↓, ⌥⌘[/⌥⌘]).
    private func navigate(_ direction: Int, proxy: ScrollViewProxy) {
        guard !entries.isEmpty else { return }
        let next = max(0, min(entries.count - 1, (currentEntry ?? -1) + direction))
        select(entryIndex: next, proxy: proxy)
    }

    /// Wählt einen Unterschied und scrollt beide Spalten dorthin (eine
    /// LazyVStack → ein Scroll genügt für beide Seiten).
    private func select(entryIndex: Int, proxy: ScrollViewProxy) {
        guard entries.indices.contains(entryIndex) else { return }
        currentEntry = entryIndex
        suppressFollowUntil = Date().addingTimeInterval(0.35)
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(entries[entryIndex].scrollTargetID, anchor: .center)
        }
    }

    // MARK: Differenzen-Liste (unten, BBEdit-Vorbild)

    private func differencesList(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.format("%ld Unterschiede", entries.count))
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
                        ForEach(entries) { entry in
                            entryRow(entry, proxy: proxy)
                                .id("entry-\(entry.id)")
                        }
                    }
                }
                .onChange(of: currentEntry) { _, newValue in
                    // Tastatur-Navigation hält den gewählten Eintrag sichtbar.
                    if let newValue {
                        listProxy.scrollTo("entry-\(newValue)", anchor: nil)
                    }
                }
            }
            .frame(height: 132)
        }
        .accessibilityLabel("Liste der Unterschiede")
    }

    private func entryRow(_ entry: DiffListEntry, proxy: ScrollViewProxy) -> some View {
        let selected = currentEntry == entry.id
        return Button {
            select(entryIndex: entry.id, proxy: proxy)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entryIcon(entry.kind))
                    .fastraFont(size: 10)
                    .foregroundColor(entryColor(entry.kind))
                    .frame(width: 14)
                Text(entry.label)
                    .fastraFont(.small)
                    .foregroundColor(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(selected ? Theme.accent.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Selbsttest-Anker: reale Fensterposition der Zeile für einen
        // synthetischen Klick (der 0×0-Marker sitzt in der Zeilenmitte).
        .background(SelfTestMarker(id: "diffListRow-\(entry.id)")
            .frame(width: 0, height: 0))
    }

    private func entryIcon(_ kind: FileDiff.BlockKind) -> String {
        switch kind {
        case .changed: return "pencil"
        case .onlyLeft: return "minus.circle"
        case .onlyRight: return "plus.circle"
        }
    }

    private func entryColor(_ kind: FileDiff.BlockKind) -> Color {
        switch kind {
        case .changed: return Theme.gitModified
        case .onlyLeft: return Theme.diffRemovedFG
        case .onlyRight: return Theme.diffAddedFG
        }
    }

    // MARK: Elemente

    @ViewBuilder
    private func itemView(_ item: DiffDisplayItem) -> some View {
        switch item {
        case .row(let row):
            alignedRow(row)
        case .fold(let id, let count, let expanded):
            Button {
                if expanded { expandedFolds.remove(id) }
                else { expandedFolds.insert(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.up" : "ellipsis")
                    Text(expanded
                         ? L10n.format("%ld unveränderte Zeilen wieder einklappen", count)
                         : L10n.format("%ld unveränderte Zeilen einblenden", count))
                    Spacer()
                }
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(minWidth: 920, minHeight: 23, alignment: .leading)
                .background(Theme.surfaceSand.opacity(0.22))
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded
                                ? L10n.string("ausgeklappt")
                                : L10n.string("eingeklappt"))
        case .fileHeader(_, let title):
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .fastraFont(.small)
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(minWidth: 920, minHeight: 30, alignment: .leading)
            .background(Theme.surfaceBase)
            .accessibilityElement(children: .combine)
        case .hunkHeader(_, let text, let accessibility):
            HStack {
                Text(text)
                    .fastraFont(.monoSmall)
                    .foregroundColor(Theme.tokenCharClass)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 920, minHeight: 24, alignment: .leading)
            .background(Theme.surfaceSand.opacity(0.38))
            .accessibilityLabel(accessibility)
        case .gap(_, let count):
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                Text(L10n.format("%ld weitere unveränderte Zeilen (nicht geladen)", count))
                Spacer()
            }
            .fastraFont(size: 10)
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 920, minHeight: 23, alignment: .leading)
            .background(Theme.surfaceSand.opacity(0.16))
            .help("Git hat diesen unveränderten Bereich außerhalb des kontrollierten Kontexts ausgelassen.")
            .accessibilityElement(children: .combine)
        case .note(_, let title, let explanation):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundColor(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundColor(Theme.textPrimary)
                    Text(explanation)
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .fastraFont(.small)
            .padding(10)
            .frame(minWidth: 920, alignment: .leading)
            .background(Theme.surfaceSand.opacity(0.22))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Zeilen

    /// Gehört die Zeile zum gewählten Unterschied? (Hervorhebung)
    private func isInCurrentEntry(_ row: DiffDisplayRow) -> Bool {
        guard let currentEntry, entries.indices.contains(currentEntry) else {
            return false
        }
        let entry = entries[currentEntry]
        return row.ordinal >= entry.firstOrdinal && row.ordinal <= entry.lastOrdinal
    }

    private func alignedRow(_ row: DiffDisplayRow) -> some View {
        let tallRow = row.beforeMissingFinalNewline || row.afterMissingFinalNewline
            || row.intralineWasLimited
        return HStack(spacing: 0) {
            cell(number: row.beforeNumber, text: row.before,
                 highlight: row.beforeHighlight, before: true, kind: row.kind,
                 missingFinalNewline: row.beforeMissingFinalNewline)
            Divider().opacity(0.5)
            cell(number: row.afterNumber, text: row.after,
                 highlight: row.afterHighlight, before: false, kind: row.kind,
                 missingFinalNewline: row.afterMissingFinalNewline)
        }
        .frame(minWidth: 920, minHeight: tallRow ? 38 : 22, alignment: .leading)
        .overlay(alignment: .bottom) {
            if row.intralineWasLimited {
                Text("Intra-Zeilen-Markierung wegen Zeilenlänge ausgelassen.")
                    .fastraFont(size: 9)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .overlay(alignment: .leading) {
            if isInCurrentEntry(row) {
                // Dezente Markierung des gewählten Unterschieds.
                Rectangle()
                    .fill(Theme.accentReadable)
                    .frame(width: 2)
            }
        }
        .background {
            // Nur die jeweils ERSTE Zeile eines Unterschieds meldet ihre
            // Position — die Anzeige „Unterschied X von Y" folgt dem Scrollen.
            if let entryIndex = entryIndexByTargetID[row.id] {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: DiffEntryOffsetsKey.self,
                        value: [entries[entryIndex].scrollTargetID:
                                    geometry.frame(in: .named("dualPaneDiffScroll")).minY]
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Klick auf eine veränderte Zeile wählt ihren Unterschied.
            if let index = entries.firstIndex(where: {
                row.ordinal >= $0.firstOrdinal && row.ordinal <= $0.lastOrdinal
            }) {
                currentEntry = index
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func cell(number: Int?, text: String?, highlight: Range<Int>?,
                      before: Bool, kind: FileDiff.RowKind,
                      missingFinalNewline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
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
            if missingFinalNewline {
                Text("Kein Zeilenumbruch am Dateiende")
                    .fastraFont(size: 9)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 5)
        .frame(minWidth: 459, maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
        .background(cellBackground(before: before, kind: kind))
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

    private func cellBackground(before: Bool, kind: FileDiff.RowKind) -> Color {
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

    // MARK: Übersichts-Leiste rechts

    private func overviewRuler(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            let positions = GitDiffViewModel.rulerPositions(hunkCount: entries.count)
            let markerIndices = GitDiffViewModel.rulerMarkerIndices(
                hunkCount: entries.count, currentHunk: currentEntry
            )
            ZStack(alignment: .top) {
                Theme.surfaceBase
                ForEach(markerIndices, id: \.self) { index in
                    Button {
                        select(entryIndex: index, proxy: proxy)
                    } label: {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index == currentEntry
                                  ? Theme.accentReadable : Theme.gitModified)
                            .frame(width: index == currentEntry ? 12 : 8, height: 5)
                    }
                    .buttonStyle(.plain)
                    .position(x: geometry.size.width / 2,
                              y: max(4, min(geometry.size.height - 4,
                                            CGFloat(positions[index]) * geometry.size.height)))
                    .help(L10n.format("Zu Unterschied %ld springen", index + 1))
                    .accessibilityLabel(L10n.format("Unterschied %ld von %ld",
                                                    index + 1, entries.count))
                }
            }
        }
        .help("Übersicht der Unterschiede; die hervorgehobene Markierung ist der aktuelle.")
        .accessibilityLabel("Übersicht der Unterschiede")
    }
}
