import SwiftUI

/// Read-only Anzeige eines Git-Text-Tabs (Etappe 2). Wählt anhand der `kind`
/// die passende Darstellung: klickbarer Verlaufs-Graph oder gefärbter Diff.
/// Beide sind bewusst schlicht — Monospace, kein Editor, keine Bearbeitung,
/// links-oben-bündig mit horizontalem UND vertikalem Scrollen (kein Umbruch,
/// damit Code-/Graph-Zeilen ihre Struktur behalten).
struct GitTextView: View {
    let kind: GitTabKind
    let content: String
    @StateObject private var textSelection = DiffTextSelection()

    /// Zeilen als indizierte Paare — der Index ist die stabile `ForEach`-ID.
    private var lines: [(offset: Int, line: String)] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset, String($0.element)) }
    }

    private var selectionItems: [DiffDisplayItem] {
        lines.map { item in
            .row(DiffDisplayRow(id: "git-text-\(item.offset)", ordinal: item.offset,
                                kind: .unchanged, beforeNumber: nil, afterNumber: nil,
                                before: item.line, after: nil,
                                beforeHighlight: nil, afterHighlight: nil,
                                beforeMissingFinalNewline: false, afterMissingFinalNewline: false,
                                intralineWasLimited: false))
        }
    }

    var body: some View {
        // GeometryReader liefert die Viewport-Breite: Der Inhalt bekommt sie als
        // MINDESTbreite (links ausgerichtet). Sonst zentriert ein bidirektionaler
        // ScrollView Inhalt, der schmaler als der Viewport ist (Befund
        // Screenshot 2026-07-12) — mit minWidth klebt er links und wächst nur
        // bei langen Zeilen nach rechts (dann horizontaler Scroll).
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.offset) { item in
                        row(for: item.line, index: item.offset)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Mindestens Viewport-Größe in BEIDEN Achsen, oben-links
                // verankert — sonst zentriert der ScrollView kurzen Inhalt
                // auch vertikal.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height,
                       alignment: .topLeading)
            }
        }
        .background(Theme.surfaceRaised)
        .onAppear { updateSelection() }
        .onChange(of: content) { updateSelection() }
        .onChange(of: kind) { updateSelection() }
    }

    private func updateSelection() {
        guard kind != .log else { return }
        textSelection.update(items: selectionItems)
    }

    @ViewBuilder
    private func row(for line: String, index: Int) -> some View {
        switch kind {
        case .log:
            GitLogRow(line: line, hash: GitLog.commitHash(inLine: line))
        case .diff, .commit:
            GitDiffRow(line: line, rowID: "git-text-\(index)", selection: textSelection)
        }
    }
}

/// Eine Zeile im Verlaufs-Graphen. Mit Hash → klickbar (öffnet den Commit per
/// `git show` in einem neuen Tab); ohne Hash (reine Graph-Verbindung) → statisch.
private struct GitLogRow: View {
    let line: String
    let hash: String?
    @EnvironmentObject var workspace: Workspace
    @State private var hovered = false

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .fastraFont(.monoSmall)
            .foregroundColor(hash == nil ? Theme.textSecondary : Theme.textPrimary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(hovered && hash != nil ? Theme.surfaceSand.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
            .onHover { if hash != nil { hovered = $0 } }
            .onTapGesture { if let hash { workspace.openGitCommit(hash: hash) } }
            .help(hash != nil ? L10n.format("Commit %@ anzeigen (git show)", hash!) : "")
    }
}

/// Eine Diff-Zeile in ihrer Klassen-Farbe. Added/removed bekommen zusätzlich
/// einen zarten Hintergrund (wie die Such-Diff-Vorschau).
private struct GitDiffRow: View {
    let line: String
    let rowID: String
    let selection: DiffTextSelection

    private var kind: GitDiffLineKind { GitDiff.classify(line) }

    private var foreground: Color {
        switch kind {
        case .added:      return Theme.diffAddedFG
        case .removed:    return Theme.diffRemovedFG
        case .hunk:       return Theme.tokenCharClass
        case .fileHeader: return Theme.textPrimary
        case .commitMeta: return Theme.accentReadable
        case .context:    return Theme.textSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .added:   return Theme.diffAddedBG.opacity(0.5)
        case .removed: return Theme.diffRemovedBG.opacity(0.5)
        default:       return .clear
        }
    }

    var body: some View {
        DiffSelectableText(text: line, highlight: nil, color: foreground,
                           highlightColor: foreground, before: true, rowID: rowID,
                           wraps: false, selection: selection)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.vertical, 0.5)
            .padding(.horizontal, 4)
            .background(background)
    }
}
