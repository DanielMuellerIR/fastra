import SwiftUI

// GitGraphView.swift
//
// VS-Code-artiger Git-Graph als dritter Seitenleisten-Modus (Phase 3). Zeigt die
// Commit-Historie mit echten Multi-Lane-Verzweigungslinien. Die Algorithmik liegt
// rein in `GitGraph` (getestet); diese View macht daraus nur Striche, Kreise und
// Text. Klick auf eine Zeile öffnet den Commit als Diff-Tab (bestehende Funktion).

struct GitGraphView: View {
    @EnvironmentObject var workspace: Workspace

    /// Vorberechnetes Layout — nur bei geänderter Historie neu gerechnet, nicht
    /// bei jedem Tastendruck (Workspace publiziert viele andere Änderungen).
    @State private var layout = GraphLayout(rows: [], laneCount: 1)

    // --- Maße (ein Ort, damit Zelle und Linien fluchten) ---
    private let laneWidth: CGFloat = 16
    private let rowHeight: CGFloat = 24
    private let nodeRadius: CGFloat = 4

    var body: some View {
        Group {
            if layout.rows.isEmpty {
                VStack {
                    Spacer()
                    Text("Noch keine Commits.")
                        .font(Theme.uiSmall)
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(layout.rows) { row in
                            GraphRowView(row: row, laneCount: layout.laneCount,
                                         laneWidth: laneWidth, rowHeight: rowHeight,
                                         nodeRadius: nodeRadius)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear {
            recompute()
            workspace.refreshGitLog()   // beim Erscheinen frische Daten holen
        }
        // Historie neu geladen → Layout einmalig neu rechnen.
        .onChange(of: workspace.gitLog) { recompute() }
    }

    private func recompute() {
        layout = GitGraph.layout(workspace.gitLog)
    }
}

/// Eine Zeile: links die gezeichnete Graph-Zelle, rechts die Commit-Infos.
private struct GraphRowView: View {
    let row: GraphRow
    let laneCount: Int
    let laneWidth: CGFloat
    let rowHeight: CGFloat
    let nodeRadius: CGFloat

    @EnvironmentObject var workspace: Workspace
    @State private var hovering = false

    /// Farbpalette der Lanes — kräftige Mitteltöne, auf hellem Sand UND dunkel
    /// gut sichtbar. Index kommt aus dem Layout, wird zyklisch abgebildet.
    private static let laneColors: [Color] = [
        Color(red: 0.90, green: 0.60, blue: 0.10),   // orange
        Color(red: 0.20, green: 0.58, blue: 0.85),   // blau
        Color(red: 0.55, green: 0.40, blue: 0.85),   // violett
        Color(red: 0.22, green: 0.68, blue: 0.45),   // grün
        Color(red: 0.85, green: 0.35, blue: 0.48),   // pink/rot
        Color(red: 0.30, green: 0.72, blue: 0.72),   // türkis
        Color(red: 0.72, green: 0.55, blue: 0.20),   // ocker
    ]
    private static func color(_ i: Int) -> Color {
        laneColors[((i % laneColors.count) + laneColors.count) % laneColors.count]
    }

    private var cellWidth: CGFloat { CGFloat(laneCount) * laneWidth }

    var body: some View {
        HStack(spacing: 8) {
            graphCell
            info
        }
        .frame(height: rowHeight)
        .padding(.horizontal, 8)
        .background(hovering ? Theme.surfaceRaised : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workspace.openGitCommit(hash: row.commit.hash) }
        .help("\(row.commit.shortHash) — \(row.commit.subject)")
    }

    /// Die gezeichnete Graph-Spalte für genau diese Zeile.
    private var graphCell: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            func x(_ col: Int) -> CGFloat { CGFloat(col) * laneWidth + laneWidth / 2 }

            // 1. Durchlaufende + verbindende Linien (Knoten zuletzt, damit obenauf).
            for line in row.lines {
                var path = Path()
                let stroke = Self.color(line.colorIndex)
                switch line.kind {
                case .through:
                    // Senkrecht durch die ganze Zelle.
                    path.move(to: CGPoint(x: x(line.fromColumn), y: 0))
                    path.addLine(to: CGPoint(x: x(line.fromColumn), y: size.height))
                case .incoming:
                    // Von oben (Kante) sanft zum Knoten (Mitte).
                    addBend(&path,
                            from: CGPoint(x: x(line.fromColumn), y: 0),
                            to:   CGPoint(x: x(line.toColumn),   y: midY))
                case .outgoing:
                    // Vom Knoten (Mitte) sanft zur Kante unten.
                    addBend(&path,
                            from: CGPoint(x: x(line.fromColumn), y: midY),
                            to:   CGPoint(x: x(line.toColumn),   y: size.height))
                }
                ctx.stroke(path, with: .color(stroke), lineWidth: 1.6)
            }

            // 2. Knotenkreis.
            let center = CGPoint(x: x(row.column), y: midY)
            let rect = CGRect(x: center.x - nodeRadius, y: center.y - nodeRadius,
                              width: nodeRadius * 2, height: nodeRadius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Self.color(row.colorIndex)))
            // Dünner heller Ring hebt den Knoten von kreuzenden Linien ab.
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -0.5, dy: -0.5)),
                       with: .color(Theme.surfaceBase), lineWidth: 1)
        }
        .frame(width: cellWidth, height: rowHeight)
    }

    /// Eine weiche vertikale Kurve zwischen zwei Punkten (VS-Code-Optik: an beiden
    /// Enden senkrecht). Gleiche Spalte → gerade Linie.
    private func addBend(_ path: inout Path, from a: CGPoint, to b: CGPoint) {
        path.move(to: a)
        if a.x == b.x {
            path.addLine(to: b)
        } else {
            let midY = (a.y + b.y) / 2
            path.addCurve(to: b,
                          control1: CGPoint(x: a.x, y: midY),
                          control2: CGPoint(x: b.x, y: midY))
        }
    }

    /// Rechte Spalte: Refs-Pillen, Betreff, Autor + Datum.
    private var info: some View {
        HStack(spacing: 6) {
            ForEach(row.commit.refs, id: \.self) { ref in
                refPill(ref)
            }
            Text(row.commit.subject)
                .font(Theme.uiSmall)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(row.commit.author)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Text(row.commit.date)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    /// Eine Branch-/Tag-Pille. Tags zeigen ein Tag-Symbol; der lokale HEAD-Branch
    /// wird kräftiger dargestellt.
    private func refPill(_ ref: String) -> some View {
        let isTag = ref.hasPrefix("tag: ")
        let isHead = ref.hasPrefix("HEAD")
        let label = ref
            .replacingOccurrences(of: "tag: ", with: "")
            .replacingOccurrences(of: "HEAD -> ", with: "")
        return HStack(spacing: 2) {
            if isTag {
                Image(systemName: "tag.fill").font(.system(size: 7))
            }
            Text(label)
                .font(.system(size: 9, weight: isHead ? .bold : .regular, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundColor(Theme.accentReadable)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(Theme.surfaceSand))
        .fixedSize()
    }
}
