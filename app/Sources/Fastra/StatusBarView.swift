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
                languageMenu
                softWrapControl
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
                // Ansichts-Umschalter (Text/Vorschau/Hex) — seit Etappe 1
                // Wunschpaket 2026-07b hier statt in einer eigenen Zeile über
                // dem Editor. Weiterhin nur sichtbar, wenn die Datei mehr als
                // eine Ansicht bietet; Menüpunkte und Shortcuts unverändert.
                if workspace.availableViewModes.count > 1 {
                    viewModePicker
                }
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

    /// Kompakter Ansichts-Umschalter in der Fußzeile. Schreibt die Wahl in
    /// den aktiven Tab — die manuelle Wahl bleibt für dessen Lebensdauer
    /// erhalten (Logik unverändert aus der früheren `viewModeBar`).
    private var viewModePicker: some View {
        Picker("Ansicht", selection: Binding(
            get: { workspace.activeViewMode },
            set: { workspace.setViewMode($0) }
        )) {
            ForEach(workspace.availableViewModes, id: \.self) { mode in
                Text(verbatim: mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Ansicht dieser Datei umschalten (Text / Vorschau / Hex)")
        .accessibilityIdentifier("viewModePicker")
        // Marker für den Fenster-Selbsttest `sidebarheader`: existiert nur,
        // solange der Umschalter wirklich in der Fußzeile layoutet wird.
        .background(SelfTestMarker(id: "viewModePickerMarker").frame(width: 0, height: 0))
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

    /// Beschriftung des Sprach-Chips aus derselben effektiven Formatidentität,
    /// die auch Grammatik und Soft-Wrap-Profil steuert.
    private var fileType: String {
        workspace.activeDocumentFormat.displayName
    }

    /// Ist dieser Menü-Eintrag die aktuelle manuelle Wahl des aktiven Tabs?
    private func isSelectedEntry(_ entry: LanguageMenuSupport.Entry) -> Bool {
        guard let tab = workspace.activeTab else { return false }
        switch entry {
        case .grammar(let language):
            return tab.languageOverride == language && tab.customLanguageOverrideID == nil
        case .custom(let language):
            return tab.customLanguageOverrideID == language.id
        }
    }

    /// Sprach-Chip als Menü (Etappe 3): manueller Sprachumschalter. Die Wahl
    /// gewinnt immer vor Endung und Inhalts-Erkennung; „Automatisch" kehrt
    /// zur Automatik zurück. Enthält seit Etappe 3 Wunschpaket 2026-07b auch
    /// die Eigen-Sprachen der Registry (derzeit 4D).
    private var languageMenu: some View {
        Menu {
            Button {
                workspace.setLanguageOverride(nil)
            } label: {
                if workspace.activeTab?.languageOverride == nil
                    && workspace.activeTab?.customLanguageOverrideID == nil {
                    Label("Automatisch", systemImage: "checkmark")
                } else {
                    Text("Automatisch")
                }
            }
            Divider()
            ForEach(LanguageMenuSupport.selectableEntries) { entry in
                Button {
                    switch entry {
                    case .grammar(let language):
                        workspace.setLanguageOverride(language)
                    case .custom(let language):
                        workspace.setCustomLanguageOverride(language)
                    }
                } label: {
                    if isSelectedEntry(entry) {
                        Label(entry.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: entry.displayName)
                    }
                }
            }
        } label: {
            FooterChip(label: fileType)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sprache/Format — manuelle Wahl gewinnt vor der Automatik")
    }

    /// Schneller Hauptschalter plus separater Menüpfeil. Ein Rechtsklick auf
    /// den gesamten Control öffnet denselben echten Optionsinhalt.
    private var softWrapControl: some View {
        HStack(spacing: 0) {
            Button {
                workspace.toggleSoftWrap()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.left")
                    Text(verbatim: softWrapStatusText)
                }
                .fastraFont(size: 11, weight: .medium)
                .foregroundColor(workspace.softWrapEnabled
                                 ? Theme.accentReadable : Theme.textSecondary)
                .padding(.leading, 5)
                .padding(.trailing, 3)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(softWrapStatusText)
            .accessibilityHint(L10n.format(
                "Schaltet Soft Wrap für das Format %@ um.",
                workspace.activeDocumentFormat.displayName
            ))

            Menu {
                softWrapOptions
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 2)
                    .padding(.trailing, 5)
                    .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.string("Soft-Wrap-Optionen"))
        }
        .background(Theme.surfaceSand.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .fixedSize()
        .help(L10n.format(
            "Soft Wrap für %@: %@. Hauptklick schaltet um; Pfeil oder Rechtsklick öffnet Optionen.",
            workspace.activeDocumentFormat.displayName,
            workspace.softWrapEnabled ? L10n.string("Ein") : L10n.string("Aus")
        ))
        .contextMenu {
            softWrapOptions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("softWrapControl")
    }

    private var softWrapStatusText: String {
        L10n.format("Soft Wrap: %@",
                    workspace.softWrapEnabled ? L10n.string("Ein") : L10n.string("Aus"))
    }

    @ViewBuilder
    private var softWrapOptions: some View {
        Button {
            workspace.toggleSoftWrap()
        } label: {
            if workspace.softWrapEnabled {
                Label(softWrapStatusText, systemImage: "checkmark")
            } else {
                Text(verbatim: softWrapStatusText)
            }
        }
        Divider()
        Button {
            workspace.selectSoftWrapTarget(.window)
        } label: {
            if workspace.softWrapTarget == .window {
                Label("Fensterbreite", systemImage: "checkmark")
            } else {
                Text("Fensterbreite")
            }
        }
        Button {
            workspace.selectSoftWrapTarget(.pageGuide)
        } label: {
            if workspace.softWrapTarget == .pageGuide {
                Label("Page Guide", systemImage: "checkmark")
            } else {
                Text("Page Guide")
            }
        }
        Menu {
            ForEach([72, 80, 100, 120], id: \.self) { column in
                Button {
                    workspace.setSoftWrapFixedColumn(column)
                } label: {
                    if workspace.softWrapTarget == .fixedColumn,
                       workspace.softWrapFixedColumn == column {
                        Label(L10n.format("Spalte %ld", column),
                              systemImage: "checkmark")
                    } else {
                        Text(verbatim: L10n.format("Spalte %ld", column))
                    }
                }
            }
            Button("Andere …") {
                if let column = SoftWrapColumnInput.prompt(
                    title: L10n.string("Feste Umbruchbreite"),
                    currentValue: workspace.softWrapFixedColumn
                ) {
                    workspace.setSoftWrapFixedColumn(column)
                }
            }
        } label: {
            if workspace.softWrapTarget == .fixedColumn {
                Label(
                    L10n.format("Feste Breite: Spalte %ld",
                                workspace.softWrapFixedColumn),
                    systemImage: "checkmark"
                )
            } else {
                Text("Feste Breite")
            }
        }
        Divider()
        Toggle("Seitenlinie anzeigen", isOn: Binding(
            get: { workspace.showPageGuide },
            set: { workspace.setShowPageGuide($0) }
        ))
        Menu("Spalte der Seitenlinie") {
            ForEach([72, 80, 100, 120], id: \.self) { column in
                Button {
                    workspace.setPageGuideColumn(column)
                } label: {
                    if workspace.pageGuideColumn == column {
                        Label(L10n.format("Spalte %ld", column),
                              systemImage: "checkmark")
                    } else {
                        Text(verbatim: L10n.format("Spalte %ld", column))
                    }
                }
            }
            Button("Andere …") {
                if let column = SoftWrapColumnInput.prompt(
                    title: L10n.string("Spalte der Seitenlinie"),
                    currentValue: workspace.pageGuideColumn
                ) {
                    workspace.setPageGuideColumn(column)
                }
            }
        }
        Divider()
        Button {
            workspace.resetSoftWrapToFactoryDefault()
        } label: {
            Text(verbatim: L10n.format(
                "Für %@ auf Werkseinstellung zurücksetzen",
                workspace.activeDocumentFormat.displayName
            ))
        }
        .disabled(!workspace.softWrapHasOverride)
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
