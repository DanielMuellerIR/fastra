import SwiftUI

enum GitGraphActionAvailability {
    static func mutationEnabled(isBusy: Bool) -> Bool { !isBusy }
}

// GitGraphView.swift
//
// Kompakter Git-Graph nach dem VS-Code/Codium-Modell: Die Graphbreite richtet
// sich pro Zeile nach den tatsächlich sichtbaren Lanes, der Autor hängt direkt
// am Betreff und Detaildaten wandern in den Tooltip. Commits lassen sich inline
// aufklappen; ein Doppelklick auf einen Commit beziehungsweise ein Klick auf
// eine seiner Dateien öffnet den jeweiligen Diff im Editor.

struct GitGraphView: View {
    @EnvironmentObject var workspace: Workspace
    @State private var layout = GraphLayout(rows: [], laneCount: 1)

    private let laneWidth: CGFloat = 14
    private let rowHeight: CGFloat = 23
    private let nodeRadius: CGFloat = 4

    /// Eingeschränkt auf eine Datei? Dann kommen Kopfzeile, Commits und
    /// Leertext aus dem Dateiverlauf statt aus der ganzen Historie.
    private var historyFile: GitHistoryFile? { workspace.gitHistoryFile }

    /// Eigener Schlüssel je Ansicht: Die Scrollposition der ganzen Historie
    /// passt nicht auf eine kurze Dateiliste — und umgekehrt.
    private var scrollKey: String {
        historyFile.map { "gitGraph:" + $0.relativePath } ?? "gitGraph"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let historyFile {
                historyHeader(historyFile)
                Divider().opacity(0.3)
            }
            content
        }
        .onAppear {
            recompute()
            workspace.refreshGitLog()
        }
        .onChange(of: workspace.gitLog) { recompute() }
        .onChange(of: workspace.gitFileHistory) { recompute() }
        .onChange(of: workspace.gitFileHistoryState) { recompute() }
        .onChange(of: workspace.gitHistoryFile) { recompute() }
        .onChange(of: workspace.gitRepositorySnapshot?.headOID) { recompute() }
    }

    @ViewBuilder
    private var content: some View {
        if layout.rows.isEmpty {
            VStack {
                Spacer()
                Text(emptyText)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            .background(SelfTestMarker(id: "gitGraphEmpty").frame(width: 0, height: 0))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(layout.rows) { row in
                        GraphRowView(
                            row: row,
                            laneWidth: laneWidth,
                            rowHeight: rowHeight,
                            nodeRadius: nodeRadius,
                            isExpanded: workspace.gitGraphExpandedCommits.contains(row.id),
                            toggleExpanded: { toggle(row.id) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .sidebarScrollRetention(key: scrollKey,
                                        memory: workspace.sidebarScrollMemory)
                // Selbsttests lesen hier ab, wie viele Zeilen WIRKLICH
                // gerendert sind — nicht bloß, was im Modell steht.
                .background(SelfTestMarker(id: "gitGraphRows-\(layout.rows.count)")
                    .frame(width: 0, height: 0))
            }
            // Die Identität hängt am Schlüssel: Der Wechsel zwischen ganzer
            // Historie und Dateiverlauf zeigt eine ANDERE Liste und darf die
            // Position der vorigen nicht erben.
            .id(scrollKey)
            .clipped()
        }
    }

    /// Kopfzeile der eingeschränkten Ansicht: Welche Datei, wie viele Commits,
    /// und der Weg zurück zur ganzen Historie.
    private func historyHeader(_ file: GitHistoryFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .fastraFont(size: 10)
                .foregroundColor(Theme.accentReadable)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(historySubtitle)
                    .fastraFont(size: 9)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                workspace.clearGitHistoryFile()
            } label: {
                Label(L10n.string("Ganze Historie"), systemImage: "arrow.uturn.backward")
                    .fastraFont(size: 10)
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Zurück zum Verlauf des ganzen Projekts")
            .accessibilityLabel("Ganze Historie anzeigen")
            // Ohne eigene Größe übernimmt der Hintergrund die Fläche des
            // Knopfes — der Selbsttest klickt so auf dessen echte Mitte.
            .background { SelfTestMarker(id: "gitHistoryFullButton") }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help(L10n.format("Verlauf von %@", file.relativePath))
        .background(SelfTestMarker(id: "gitHistoryFile-" + file.relativePath)
            .frame(width: 0, height: 0))
    }

    private var historySubtitle: String {
        switch workspace.gitFileHistoryState {
        case .loading:
            return L10n.string("Wird geladen …")
        case .failed:
            return L10n.string("git-Aufruf fehlgeschlagen.")
        case .idle:
            let count = workspace.gitFileHistory.count
            return count == 1
                ? L10n.string("1 Commit")
                : L10n.format("%ld Commits", count)
        }
    }

    /// Leertext, der den Grund benennt statt nur „nichts da" zu melden.
    private var emptyText: String {
        guard historyFile != nil else { return L10n.string("Noch keine Commits.") }
        switch workspace.gitFileHistoryState {
        case .loading:
            return L10n.string("Wird geladen …")
        case .failed(let message):
            return message
        case .idle:
            return L10n.string("Für diese Datei gibt es noch keine Commits.")
        }
    }

    private func recompute() {
        let headOID = workspace.gitRepositorySnapshot?.headOID
        let commits: [GitCommit]
        if workspace.gitHistoryFile != nil {
            commits = GitFileHistory.commitsForDisplay(
                workspace.gitFileHistory,
                state: workspace.gitFileHistoryState
            )
            layout = GitFileHistory.layout(commits, headOID: headOID)
            workspace.gitGraphExpandedCommits = GitFileHistory.reconciledExpandedCommits(
                workspace.gitGraphExpandedCommits,
                commits: workspace.gitFileHistory,
                state: workspace.gitFileHistoryState
            )
        } else {
            commits = workspace.gitLog
            layout = GitGraph.layout(commits, headOID: headOID)
            workspace.gitGraphExpandedCommits.formIntersection(Set(commits.map(\.hash)))
        }
    }

    private func toggle(_ hash: String) {
        if workspace.gitGraphExpandedCommits.contains(hash) {
            workspace.gitGraphExpandedCommits.remove(hash)
        } else {
            workspace.gitGraphExpandedCommits.insert(hash)
        }
    }
}

private struct GraphRowView: View {
    let row: GraphRow
    let laneWidth: CGFloat
    let rowHeight: CGFloat
    let nodeRadius: CGFloat
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    @EnvironmentObject var workspace: Workspace
    @State private var hovering = false

    // Blau ist wie in VS Code die Hauptlinie; neue Nebenäste wechseln zuerst
    // auf Orange und danach auf weitere klar unterscheidbare Farben.
    private static let laneColors: [Color] = [
        Color(red: 0.20, green: 0.58, blue: 0.85),
        Color(red: 1.00, green: 0.67, blue: 0.05),
        Color(red: 0.55, green: 0.40, blue: 0.85),
        Color(red: 0.22, green: 0.68, blue: 0.45),
        Color(red: 0.85, green: 0.35, blue: 0.48),
        Color(red: 0.30, green: 0.72, blue: 0.72),
    ]

    fileprivate static func color(_ index: Int) -> Color {
        laneColors[((index % laneColors.count) + laneColors.count) % laneColors.count]
    }

    /// Anders als die alte globale Maximalbreite reserviert jede Zeile nur die
    /// Spalten, die sie wirklich berührt. Das lässt deutlich mehr Commit-Text
    /// sichtbar und entspricht der kompakten Codium-Darstellung.
    private var visibleLaneCount: Int {
        let columns = row.lines.flatMap { [$0.fromColumn, $0.toColumn] } + [row.column]
        return max(1, (columns.max() ?? 0) + 1)
    }
    private var graphWidth: CGFloat { CGFloat(visibleLaneCount) * laneWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, !row.commit.files.isEmpty {
                ForEach(row.commit.files) { file in
                    GraphCommitFileRow(
                        file: file,
                        author: row.commit.author,
                        hash: row.commit.hash,
                        graphWidth: graphWidth,
                        laneWidth: laneWidth,
                        continuationLanes: continuationLanes
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            graphCell
            info
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight,
               alignment: .leading)
        .clipped()
        .background(row.isHEAD
                    ? Theme.accentReadable.opacity(hovering ? 0.17 : 0.10)
                    : (hovering ? Theme.surfaceRaised : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Einzel- und Doppelklick werden exklusiv ausgewertet. Sonst würde ein
        // Doppelklick zuerst den Commit aufklappen und erst danach den Diff
        // öffnen, was als sichtbares Flackern und Zustandswechsel auffällt.
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        workspace.openGitCommit(hash: row.commit.hash)
                    case .second:
                        if row.commit.files.isEmpty {
                            workspace.openGitCommit(hash: row.commit.hash)
                        } else {
                            toggleExpanded()
                        }
                    }
                }
        )
        .help(tooltip)
        .contextMenu {
            Button("Neuen Branch ab diesem Commit…") {
                workspace.gitCreateBranch(at: row.commit.hash)
            }
            .disabled(!GitGraphActionAvailability.mutationEnabled(
                isBusy: workspace.gitOperationsAreBusy
            ))
            Button("Cherry-pick dieses Commits…") {
                workspace.gitCherryPick(commitHash: row.commit.hash)
            }
            .disabled(!GitGraphActionAvailability.mutationEnabled(
                isBusy: workspace.gitOperationsAreBusy
            ))
            Button("Diesen Commit reverten…") {
                workspace.gitRevert(commitHash: row.commit.hash)
            }
            .disabled(!GitGraphActionAvailability.mutationEnabled(
                isBusy: workspace.gitOperationsAreBusy
            ))
            Divider()
            Button("Commit-Hash kopieren") {
                workspace.copyGitCommitHash(row.commit.hash)
            }
            Button("Commitdetails kopieren") {
                workspace.copyGitCommitDetails(row.commit.hash)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(row.commit.files.isEmpty ? "" : (isExpanded
                            ? L10n.string("ausgeklappt") : L10n.string("eingeklappt")))
        .accessibilityHint(GitGraphAccessibility.commitHint(
            isHEAD: row.isHEAD, hasFiles: !row.commit.files.isEmpty,
            isExpanded: isExpanded
        ))
        .accessibilityAction(named: Text("Commit-Diff öffnen")) {
            workspace.openGitCommit(hash: row.commit.hash)
        }
        .accessibilityAction(named: Text(isExpanded
                                         ? "Dateien einklappen" : "Dateien ausklappen")) {
            if !row.commit.files.isEmpty { toggleExpanded() }
        }
    }

    private var graphCell: some View {
        Canvas { context, size in
            let midY = size.height / 2
            func x(_ column: Int) -> CGFloat {
                CGFloat(column) * laneWidth + laneWidth / 2
            }

            for line in row.lines {
                var path = Path()
                switch line.kind {
                case .through:
                    path.move(to: CGPoint(x: x(line.fromColumn), y: 0))
                    path.addLine(to: CGPoint(x: x(line.fromColumn), y: size.height))
                case .incoming:
                    let targetX: CGFloat
                    if line.fromColumn < line.toColumn {
                        targetX = x(line.toColumn) - nodeRadius
                    } else if line.fromColumn > line.toColumn {
                        targetX = x(line.toColumn) + nodeRadius
                    } else {
                        targetX = x(line.toColumn)
                    }
                    addBend(&path,
                            from: CGPoint(x: x(line.fromColumn), y: 0),
                            to: CGPoint(x: targetX, y: midY))
                case .outgoing:
                    let sourceX: CGFloat
                    if line.toColumn < line.fromColumn {
                        sourceX = x(line.fromColumn) - nodeRadius
                    } else if line.toColumn > line.fromColumn {
                        sourceX = x(line.fromColumn) + nodeRadius
                    } else {
                        sourceX = x(line.fromColumn)
                    }
                    addBend(&path,
                            from: CGPoint(x: sourceX, y: midY),
                            to: CGPoint(x: x(line.toColumn), y: size.height))
                }
                context.stroke(path, with: .color(Self.color(line.colorIndex)), lineWidth: 1.7)
            }

            let center = CGPoint(x: x(row.column), y: midY)
            let rect = CGRect(x: center.x - nodeRadius, y: center.y - nodeRadius,
                              width: nodeRadius * 2, height: nodeRadius * 2)
            if row.isHEAD {
                // Äußerer Halo ist immer die HEAD-Markierung. Der innere
                // Merge-Ring bleibt dadurch als eigener Formcode erkennbar.
                let haloRadius = nodeRadius + 4
                let halo = CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                                  width: haloRadius * 2, height: haloRadius * 2)
                context.fill(Path(ellipseIn: halo),
                             with: .color(Theme.accentReadable.opacity(0.18)))
                context.stroke(Path(ellipseIn: halo),
                               with: .color(Theme.accentReadable), lineWidth: 1.8)
            }
            if row.commit.parents.count > 1 {
                // Merge-Knoten als Ring: Die Abzweigung ist dadurch schon vor
                // dem Lesen des Betreffs erkennbar (VS-Code-Konvention).
                context.fill(Path(ellipseIn: rect), with: .color(Theme.surfaceBase))
                context.stroke(Path(ellipseIn: rect),
                               with: .color(Self.color(row.colorIndex)), lineWidth: 2.2)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(Self.color(row.colorIndex)))
            }
        }
        .frame(width: graphWidth, height: rowHeight)
    }

    private func addBend(_ path: inout Path, from start: CGPoint, to end: CGPoint) {
        path.move(to: start)
        guard start.x != end.x else {
            path.addLine(to: end)
            return
        }
        // Senkrechte Tangenten an beiden Enden erzeugen die kompakte S-Kurve,
        // mit der VS Code Merge-Äste eindeutig an den Knoten bindet.
        let middleY = (start.y + end.y) / 2
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x, y: middleY),
                      control2: CGPoint(x: end.x, y: middleY))
    }

    private var info: some View {
        HStack(spacing: 5) {
            if row.isHEAD { headPill }
            ForEach(row.commit.refs.filter {
                $0 != "HEAD" && !$0.hasPrefix("HEAD -> ")
            }, id: \.self) { ref in
                refPill(ref)
            }
            (Text(row.commit.subject).foregroundColor(Theme.textPrimary)
             + Text("  \(row.commit.author)").foregroundColor(Theme.textSecondary))
                .fastraFont(.small)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if !row.commit.files.isEmpty {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .fastraFont(size: 9, weight: .semibold)
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var headPill: some View {
        Text(headLabel)
            .fastraFont(size: 9, weight: .bold, design: .monospaced)
            .lineLimit(1)
            .foregroundColor(Theme.surfaceBase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.accentReadable))
            .fixedSize()
            .help(headTooltip)
            .accessibilityLabel(headLabel)
            .accessibilityHint(headTooltip)
    }

    private var headLabel: String {
        GitHeadPresentation.make(row: row, branch: workspace.gitStatus?.branch)?.label ?? "HEAD"
    }

    private var headTooltip: String {
        GitHeadPresentation.make(row: row, branch: workspace.gitStatus?.branch)?.tooltip
            ?? L10n.string("HEAD bezeichnet den aktuell ausgecheckten Commit.")
    }

    private func refPill(_ ref: String) -> some View {
        let presentation = GitGraphRefPresentation.make(
            ref: ref,
            remoteTracking: workspace.gitRepositorySnapshot?.remoteTracking ?? []
        )
        let remoteColor = presentation.kind == .remoteBranch
            ? colorForRemoteRef(presentation.label)
            : Theme.accentReadable
        return HStack(spacing: 2) {
            if presentation.kind == .tag {
                Image(systemName: "tag.fill").fastraFont(size: 7)
            } else if presentation.kind == .remoteBranch {
                Image(systemName: "network").fastraFont(size: 7)
            }
            Text(presentation.label)
                .fastraFont(
                    size: 9,
                    weight: presentation.kind == .head ? .bold : .regular,
                    design: .monospaced
                )
                .lineLimit(1)
            if let tracking = presentation.tracking {
                Text(tracking.compactCounts)
                    .fastraFont(size: 8, weight: .semibold, design: .monospaced)
            }
        }
        .foregroundColor(
            presentation.kind == .remoteBranch ? Theme.textPrimary : Theme.accentReadable
        )
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(
            presentation.kind == .remoteBranch
                ? remoteColor.opacity(0.22)
                : Theme.surfaceSand
        ))
        .overlay(Capsule().stroke(
            presentation.kind == .remoteBranch
                ? remoteColor.opacity(0.65)
                : Color.clear,
            lineWidth: 0.7
        ))
        .fixedSize()
        .help(presentation.tracking.map {
            L10n.format(
                "%@: lokal %@",
                $0.shortName,
                $0.compactCounts
            )
        } ?? "")
    }

    private func colorForRemoteRef(_ label: String) -> Color {
        let remote = label.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? label
        return Theme.groupColors[GitRemoteColorIndex.index(
            for: remote,
            colorCount: Theme.groupColors.count
        )]
    }

    /// Lanes, die an der Unterkante der Commit-Zeile weiterlaufen. Beim
    /// Aufklappen werden sie durch die Dateizeilen verlängert, sonst entstünde
    /// mitten im Graph eine optische Lücke.
    private var continuationLanes: [(column: Int, colorIndex: Int)] {
        var seen: Set<Int> = []
        return row.lines.compactMap { line in
            guard line.kind == .through || line.kind == .outgoing,
                  seen.insert(line.toColumn).inserted else { return nil }
            return (line.toColumn, line.colorIndex)
        }
    }

    private var tooltip: String {
        let exactDate: String
        let relativeDate: String
        if row.commit.timestamp > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(row.commit.timestamp))
            let exact = DateFormatter()
            exact.dateStyle = .long
            exact.timeStyle = .short
            exactDate = exact.string(from: date)
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            relativeDate = relative.localizedString(for: date, relativeTo: Date())
        } else {
            exactDate = row.commit.date
            relativeDate = row.commit.date
        }
        let head = row.isHEAD ? headTooltip + "\n\n" : ""
        return head + "\(row.commit.author) · \(relativeDate) (\(exactDate))\n"
            + "\(row.commit.subject)\n\n"
            + L10n.format("%lld Dateien geändert, %lld Einfügungen(+), %lld Löschungen(-)",
                          Int64(row.commit.files.count), Int64(row.commit.additions),
                          Int64(row.commit.deletions))
            + "\n\(row.commit.shortHash)"
    }

    private var accessibilityLabel: String {
        let kind = row.commit.parents.count > 1
            ? L10n.string("Merge-Commit") : L10n.string("Commit")
        let head = row.isHEAD ? headLabel + ", " : ""
        return head + L10n.format("%@ %@: %@, von %@", kind,
                                  row.commit.shortHash, row.commit.subject,
                                  row.commit.author)
    }
}

private struct GraphCommitFileRow: View {
    let file: GitCommitFile
    let author: String
    let hash: String
    let graphWidth: CGFloat
    let laneWidth: CGFloat
    let continuationLanes: [(column: Int, colorIndex: Int)]

    @EnvironmentObject var workspace: Workspace
    @State private var hovering = false

    private let height: CGFloat = 25

    var body: some View {
        HStack(spacing: 6) {
            continuationGraph
            Image(systemName: "doc.text")
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
            Text(file.name)
                .fastraFont(.small)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                // Der Dateiname erhält Vorrang und wird nicht mehr zugunsten
                // eines langen Verzeichnispfads in der Mitte verstümmelt.
                .layoutPriority(2)
            Text(author)
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 3)
            Text(file.status)
                .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(hovering ? Theme.surfaceRaised : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(file.isPathActionable ? 1 : 0.55)
        .onTapGesture {
            if file.isPathActionable {
                workspace.openGitCommitFile(hash: hash, file: file)
            }
        }
        .disabled(!file.isPathActionable)
        .help(file.isPathActionable
              ? L10n.format("Klick: Diff für %@ öffnen", file.path)
              : GitGraphAccessibility.fileHint(actionable: false))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L10n.format("%@, Status %@", file.path, file.status))
        .accessibilityHint(GitGraphAccessibility.fileHint(actionable: file.isPathActionable))
        .accessibilityAction(named: Text("Datei-Diff öffnen")) {
            if file.isPathActionable {
                workspace.openGitCommitFile(hash: hash, file: file)
            }
        }
    }

    private var continuationGraph: some View {
        Canvas { context, size in
            for lane in continuationLanes {
                let x = CGFloat(lane.column) * laneWidth + laneWidth / 2
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(GraphRowView.color(lane.colorIndex)), lineWidth: 1.7)
            }
        }
        .frame(width: graphWidth, height: height)
    }

    private var statusColor: Color {
        switch file.status {
        case "A": return Theme.diffAddedFG
        case "D": return Theme.diffRemovedFG
        case "R", "M": return Theme.gitModified
        default: return Theme.textSecondary
        }
    }
}
