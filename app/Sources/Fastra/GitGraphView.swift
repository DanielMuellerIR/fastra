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
    @State private var expandedCommits: Set<String> = []

    private let laneWidth: CGFloat = 14
    private let rowHeight: CGFloat = 23
    private let nodeRadius: CGFloat = 4

    var body: some View {
        Group {
            if layout.rows.isEmpty {
                VStack {
                    Spacer()
                    Text("Noch keine Commits.")
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(layout.rows) { row in
                            GraphRowView(
                                row: row,
                                laneWidth: laneWidth,
                                rowHeight: rowHeight,
                                nodeRadius: nodeRadius,
                                isExpanded: expandedCommits.contains(row.id),
                                toggleExpanded: { toggle(row.id) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .clipped()
            }
        }
        .onAppear {
            recompute()
            workspace.refreshGitLog()
        }
        .onChange(of: workspace.gitLog) { recompute() }
        .onChange(of: workspace.gitRepositorySnapshot?.headOID) { recompute() }
    }

    private func recompute() {
        layout = GitGraph.layout(workspace.gitLog,
                                 headOID: workspace.gitRepositorySnapshot?.headOID)
        expandedCommits.formIntersection(Set(workspace.gitLog.map(\.hash)))
    }

    private func toggle(_ hash: String) {
        if expandedCommits.contains(hash) {
            expandedCommits.remove(hash)
        } else {
            expandedCommits.insert(hash)
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
        let isTag = ref.hasPrefix("tag: ")
        let isHead = ref.hasPrefix("HEAD")
        let label = ref
            .replacingOccurrences(of: "tag: ", with: "")
            .replacingOccurrences(of: "HEAD -> ", with: "")
        return HStack(spacing: 2) {
            if isTag { Image(systemName: "tag.fill").fastraFont(size: 7) }
            Text(label)
                .fastraFont(size: 9, weight: isHead ? .bold : .regular, design: .monospaced)
                .lineLimit(1)
        }
        .foregroundColor(Theme.accentReadable)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(Theme.surfaceSand))
        .fixedSize()
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
