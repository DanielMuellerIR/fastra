import SwiftUI

/// Reduzierter read-only Git-Diff: beide Seiten leben in derselben LazyVStack
/// und damit in exakt derselben vertikalen Scrollposition. Es werden bewusst
/// keine zwei Source-Editoren synchronisiert.
struct GitSideBySideDiffView: View {
    let request: GitDiffRequest
    let document: GitDiffDocument?
    let fallbackText: String

    @State private var expandedFolds: Set<String> = []
    @State private var currentHunk: Int? = nil

    private var hunks: [GitDiffHunk] { document?.hunks ?? [] }

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
            } else {
                diffBody
            }
        }
        .background(Theme.surfaceRaised)
        .onChange(of: request.id) {
            expandedFolds.removeAll()
            currentHunk = nil
        }
        .onChange(of: document) { oldDocument, newDocument in
            let oldHunks = oldDocument?.hunks ?? []
            let previousID = currentHunk.flatMap {
                oldHunks.indices.contains($0) ? oldHunks[$0].id : nil
            }
            let newHunks = newDocument?.hunks ?? []
            currentHunk = GitDiffViewModel.reconciledHunkIndex(
                previousID: previousID, previousIndex: currentHunk, hunks: newHunks
            )
            if let newDocument {
                expandedFolds = GitDiffViewModel.validExpandedFolds(
                    expandedFolds, document: newDocument
                )
            } else {
                expandedFolds.removeAll()
            }
        }
    }

    private var diffBody: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                toolbar(proxy: proxy)
                Divider().opacity(0.6)
                HStack(spacing: 0) {
                    GeometryReader { geometry in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(document?.files ?? []) { file in
                                    fileHeader(file)
                                    if let limitation = file.limitation {
                                        inlineLimitation(limitation)
                                    }
                                    ForEach(Array(file.hunks.enumerated()), id: \.element.id) {
                                        index, hunk in
                                        let gap = GitDiffViewModel.omittedLineCount(
                                            previous: index > 0 ? file.hunks[index - 1] : nil,
                                            current: hunk
                                        )
                                        if gap > 0 { omittedGap(gap) }
                                        hunkHeader(hunk)
                                        ForEach(GitDiffViewModel.visibleItems(
                                            hunk: hunk, expandedFolds: expandedFolds
                                        )) { item in
                                            itemView(item)
                                        }
                                    }
                                }
                            }
                            .frame(minWidth: max(geometry.size.width, 920),
                                   minHeight: geometry.size.height,
                                   alignment: .topLeading)
                        }
                        .coordinateSpace(name: "gitDiffScroll")
                        .onPreferenceChange(GitDiffHunkOffsetsKey.self) { offsets in
                            let positions = offsets.mapValues(Double.init)
                            if let visible = GitDiffViewModel.currentHunkIndex(
                                positions: positions, orderedIDs: hunks.map(\.id)
                            ) {
                                currentHunk = visible
                            }
                        }
                    }
                    .accessibilityLabel("Vorher-Nachher-Diff")

                    Divider().opacity(0.6)
                    overviewRuler(proxy: proxy)
                        .frame(width: 20)
                }
            }
            .onAppear {
                if currentHunk == nil, !hunks.isEmpty { currentHunk = 0 }
            }
        }
    }

    private func toolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
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
            Spacer()
            Text(hunks.isEmpty
                 ? L10n.string("Keine Änderungen")
                 : L10n.format("Änderung %ld von %ld", (currentHunk ?? 0) + 1, hunks.count))
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
            Button { navigate(-1, proxy: proxy) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(hunks.isEmpty || currentHunk == 0)
            .help("Vorige Änderung (⌥⌘[)")
            .accessibilityLabel("Vorige Änderung")
            Button { navigate(1, proxy: proxy) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(hunks.isEmpty || currentHunk == hunks.count - 1)
            .help("Nächste Änderung (⌥⌘])")
            .accessibilityLabel("Nächste Änderung")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func navigate(_ direction: Int, proxy: ScrollViewProxy) {
        guard let next = GitDiffViewModel.adjacentHunk(
            current: currentHunk, count: hunks.count, direction: direction
        ) else { return }
        currentHunk = next
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(hunks[next].id, anchor: .top)
        }
    }

    private func fileHeader(_ file: GitDiffFile) -> some View {
        let old = file.oldPath ?? L10n.string("leere Datei")
        let new = file.newPath ?? L10n.string("gelöschte Datei")
        let title: String
        if file.oldPath == nil, file.newPath == nil {
            title = file.metadata.first(where: { $0.hasPrefix("diff --git ") })
                ?? L10n.string("Datei")
        } else {
            title = old == new ? old : L10n.format("%@ → %@", old, new)
        }
        return HStack(spacing: 8) {
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
    }

    private func hunkHeader(_ hunk: GitDiffHunk) -> some View {
        HStack {
            Text(hunk.header)
                .fastraFont(.monoSmall)
                .foregroundColor(Theme.tokenCharClass)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 920, minHeight: 24, alignment: .leading)
        .background(Theme.surfaceSand.opacity(0.38))
        .id(hunk.id)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: GitDiffHunkOffsetsKey.self,
                    value: [hunk.id: geometry.frame(in: .named("gitDiffScroll")).minY]
                )
            }
        }
        .onTapGesture {
            currentHunk = hunks.firstIndex(where: { $0.id == hunk.id })
        }
        .accessibilityLabel(L10n.format("Änderungsblock ab vorher Zeile %ld, nachher Zeile %ld",
                                       hunk.oldStart, hunk.newStart))
    }

    private func inlineLimitation(_ limitation: GitDiffLimitation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.badge.ellipsis")
                .foregroundColor(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(limitation.title)
                    .foregroundColor(Theme.textPrimary)
                Text(limitation.explanation)
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

    private func omittedGap(_ count: Int) -> some View {
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
    }

    @ViewBuilder
    private func itemView(_ item: GitDiffVisibleItem) -> some View {
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

    private func alignedRow(_ row: GitDiffAlignedRow) -> some View {
        HStack(spacing: 0) {
            cell(number: row.beforeNumber, text: row.before,
                 highlight: row.beforeHighlight, before: true, kind: row.kind,
                 missingFinalNewline: row.beforeMissingFinalNewline)
            Divider().opacity(0.5)
            cell(number: row.afterNumber, text: row.after,
                 highlight: row.afterHighlight, before: false, kind: row.kind,
                 missingFinalNewline: row.afterMissingFinalNewline)
        }
        .frame(minWidth: 920,
               minHeight: row.beforeMissingFinalNewline
                    || row.afterMissingFinalNewline || row.intralineWasLimited ? 38 : 22,
               alignment: .leading)
        .overlay(alignment: .bottom) {
            if row.intralineWasLimited {
                Text("Intra-Zeilen-Markierung wegen Zeilenlänge ausgelassen.")
                    .fastraFont(size: 9)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            currentHunk = hunks.firstIndex(where: { $0.id == row.hunkID })
        }
        .accessibilityElement(children: .contain)
    }

    private func cell(number: Int?, text: String?, highlight: Range<Int>?,
                      before: Bool, kind: GitDiffRowKind,
                      missingFinalNewline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 6) {
                Text(number.map(String.init) ?? "")
                    .fastraFont(size: 9, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityHidden(true)
                highlightedText(text ?? " ", range: highlight,
                                color: before ? Theme.diffRemovedFG : Theme.diffAddedFG)
                    .fastraFont(.monoSmall)
                    .foregroundColor(textColor(before: before, kind: kind))
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

    private func textColor(before: Bool, kind: GitDiffRowKind) -> Color {
        switch kind {
        case .context: return Theme.textSecondary
        case .added: return before ? Theme.textSecondary : Theme.diffAddedFG
        case .removed: return before ? Theme.diffRemovedFG : Theme.textSecondary
        case .changed: return before ? Theme.diffRemovedFG : Theme.diffAddedFG
        }
    }

    private func cellBackground(before: Bool, kind: GitDiffRowKind) -> Color {
        switch kind {
        case .context: return .clear
        case .added: return before ? Theme.surfaceSand.opacity(0.15) : Theme.diffAddedBG.opacity(0.7)
        case .removed: return before ? Theme.diffRemovedBG.opacity(0.7) : Theme.surfaceSand.opacity(0.15)
        case .changed: return before ? Theme.diffRemovedBG.opacity(0.7) : Theme.diffAddedBG.opacity(0.7)
        }
    }

    private func overviewRuler(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            let positions = GitDiffViewModel.rulerPositions(hunkCount: hunks.count)
            let markerIndices = GitDiffViewModel.rulerMarkerIndices(
                hunkCount: hunks.count, currentHunk: currentHunk
            )
            ZStack(alignment: .top) {
                Theme.surfaceBase
                ForEach(markerIndices, id: \.self) { index in
                    let hunk = hunks[index]
                    Button {
                        currentHunk = index
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(hunk.id, anchor: .top)
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index == currentHunk ? Theme.accentReadable : Theme.gitModified)
                            .frame(width: index == currentHunk ? 12 : 8, height: 5)
                    }
                    .buttonStyle(.plain)
                    .position(x: geometry.size.width / 2,
                              y: max(4, min(geometry.size.height - 4,
                                            CGFloat(positions[index]) * geometry.size.height)))
                    .help(L10n.format("Zu Änderung %ld springen", index + 1))
                    .accessibilityLabel(L10n.format("Änderung %ld von %ld", index + 1, hunks.count))
                }
            }
        }
        .help("Übersicht der Änderungen; die hervorgehobene Markierung ist der aktuelle Block.")
        .accessibilityLabel("Übersicht der Änderungsblöcke")
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

private struct GitDiffHunkOffsetsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat],
                       nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}
