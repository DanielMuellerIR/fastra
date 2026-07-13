import SwiftUI

/// Footer / Status Bar (BBEdit-Style). Phase 2: Encoding, Line-Ending und File-Type
/// kommen reaktiv aus dem aktiven `EditorTab`, nicht mehr hartkodiert.
struct StatusBarView: View {
    @EnvironmentObject var workspace: Workspace

    /// Aktiv-Status des Fensters, in dem der Footer steckt (Hauptfenster).
    /// `.key`   = Hauptfenster ist vorn und fokussiert.
    /// `.active`/`.inactive` = Suchmaske oder andere App ist vorn.
    /// Wir dimmen den Footer-Text dann (BBEdit-Verhalten), statt Inhalte
    /// auszublenden — der Editor behält ja seine Cursor-Position.
    @Environment(\.controlActiveState) private var activeState

    private var isFrontmost: Bool { activeState == .key }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                encodingMenu
                FooterChip(label: fileType)
                Text(cursorPosition)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                lineEndingMenu
                Text(workspace.documentStatsText)
                    .fastraFont(size: 11, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)
                    .help(workspace.statsIsSelection
                          ? "Zeichen / Wörter / Zeilen (Selektion)"
                          : "Zeichen / Wörter / Zeilen (ganze Datei)")
                if workspace.statsIsSelection {
                    Text("Sel")
                        .fastraFont(size: 9, weight: .semibold)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.surfaceSand)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("Statistik bezieht sich auf die Selektion")
                }
            }
            Spacer()
            HStack(spacing: 12) {
                if FooterLogic.shouldShowSearchSummary(isWelcomeScreen: workspace.isWelcomeScreen,
                                                       findPattern: workspace.findPattern) {
                    HStack(spacing: 4) {
                        // accentReadable statt accent: 7 px Indikator-Kreis
                        // auf hellem Hintergrund braucht ~4:1 Kontrast;
                        // Goldgelb lieferte dort nur ~1,4:1.
                        Circle().fill(Theme.accentReadable).frame(width: 7, height: 7)
                        Text(footerSummary.text)
                            .fastraFont(.small)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                Text("⌘F  Suchen")
                    .fastraFont(size: 11, design: .monospaced)
                    .foregroundColor(Theme.textSecondary.opacity(0.7))
                // Scope-Label (Datei / Ordner) aus den echten Workspace-Daten.
                if FooterLogic.shouldShowSearchSummary(isWelcomeScreen: workspace.isWelcomeScreen,
                                                       findPattern: workspace.findPattern) {
                    Text(footerSummary.label)
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.surfaceSand.opacity(0.5))
        // Gesamten Footer-Text dimmen, wenn das Hauptfenster nicht vorn ist.
        .opacity(isFrontmost ? 1.0 : 0.45)
    }

    /// Zeile/Spalte des primären Cursors, kompakt beschriftet („Z"/„Sp").
    /// Platzhalter „—", solange noch kein Cursor gemeldet wurde. Werte
    /// sind 1-indexed.
    private var cursorPosition: String {
        let line = workspace.cursorLine.map(String.init) ?? "—"
        let col  = workspace.cursorColumn.map(String.init) ?? "—"
        return L10n.format("Z %@ · Sp %@", line, col)
    }

    private var encoding: String {
        workspace.activeTab?.encoding.displayName ?? "UTF-8"
    }

    private var lineEnding: String {
        workspace.activeTab?.lineEnding.rawValue ?? "LF"
    }

    /// Encoding-Chip als Menü: „Neu öffnen mit Encoding" (K6). Lädt den
    /// aktiven Tab mit dem gewählten Encoding neu von der Platte — nur für
    /// gespeicherte Dateien sinnvoll.
    private var encodingMenu: some View {
        Menu {
            if workspace.activeTab?.url == nil {
                Button("Datei erst speichern…") { }.disabled(true)
            } else {
                Section("Neu öffnen mit Encoding") {
                    ForEach(Workspace.reopenEncodings, id: \.self) { enc in
                        Button(enc.displayName) { workspace.reopenActiveTab(withEncoding: enc) }
                    }
                }
            }
        } label: {
            Text(encoding)
                .fastraFont(size: 11, weight: .medium)
                .foregroundColor(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Encoding — neu öffnen mit anderem Encoding")
    }

    /// Zeilenenden-Chip als Menü (K7): wählt die Zeilenende-Konvention des
    /// aktiven Tabs. Wirkt beim Speichern (`Workspace.write` konvertiert).
    private var lineEndingMenu: some View {
        Menu {
            ForEach(LineEnding.allCases) { le in
                Button {
                    workspace.setActiveLineEnding(le)
                } label: {
                    // Häkchen am aktuell gewählten Zeilenende.
                    if workspace.activeTab?.lineEnding == le {
                        Label(L10n.string(le.menuLabel), systemImage: "checkmark")
                    } else {
                        Text(verbatim: L10n.string(le.menuLabel))
                    }
                }
            }
        } label: {
            Text(lineEnding)
                .fastraFont(size: 11, weight: .semibold, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zeilenenden — Änderung wirkt beim Speichern")
    }

    /// Berechnet Text und Label für den rechten Footer-Bereich aus den
    /// aktuellen Workspace-Suchdaten. Delegiert an `FooterLogic.searchSummary`,
    /// damit die Logik isoliert unit-testbar bleibt.
    private var footerSummary: FooterLogic.SearchSummary {
        FooterLogic.searchSummary(
            scope: workspace.scope,
            // Echte Gesamtzahl (kann > materialisierte Liste sein, wenn der
            // Cap griff) — konsistent mit dem Trefferzähler in der Suchmaske.
            bufferCount: workspace.bufferTotalMatches,
            // Geöffnet-Scope füttert dieselben Multi-Quellen-Parameter
            // (FooterLogic zeigt „N Treffer · M Dateien" für beide).
            folderTotal: workspace.scope == .open
                ? workspace.openTotalMatches : workspace.folderTotalMatches,
            folderFiles: workspace.scope == .open
                ? workspace.openResults.count : workspace.folderResults.count
        )
    }

    private var fileType: String {
        DocumentKind.footerLabel(filename: workspace.activeTab?.title ?? "")
    }
}

private struct FooterChip: View {
    let label: String
    var body: some View {
        Text(label)
            .fastraFont(size: 11, weight: .medium)
            .foregroundColor(Theme.textSecondary)
    }
}
