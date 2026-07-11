import SwiftUI
import AppKit

// Floating Search Dialog (L1) — Variante 1.
//
// Stand v0.5: Grobschnitt-Layout nach Suchmasken-Konzept v1.0.
// Sichtbare Bausteine (statisch — Logik kommt in v0.6/v0.7):
//   • Scope-Tabs
//   • Vorlagen-Dropdown (Pattern aus BuiltInPatterns auswählen)
//   • Find-Feld mit Token-Highlighting + Element-Picker-Button [+]
//   • Such-Optionen-Toggle-Zeile (RegEx · Groß-Klein · Ganzes Wort · Wrap-around)
//     — alle deutsch, alle mit Tooltip
//   • Replace-Feld
//   • Gruppen-Tray (nur wenn RegEx an)
//   • Trefferliste in der Maske (Sofort-Treffer — Konzept Abschnitt 2)
//   • Detail-Bereich für aktiven Treffer mit Group-Markierungen
//     (Konzept Abschnitt 3 — Capture-Group-Definition am Treffer)
//   • Action-Zeile (Preview · Alle ersetzen)
//
// Die Logik (echte Suche, Token-Parsing, Group-Snap) folgt in späteren v0.x.

struct FloatingSearchDialog: View {
    @EnvironmentObject var workspace: Workspace

    /// Steuert das Element-Picker-Popover am `[+]`-Button.
    @State private var showElementPicker = false

    /// Live-Tokenisierung des Find-Patterns (tree-sitter-regex, v0.7) —
    /// Grundlage für Inline-Highlighting im Find-Feld, die Gruppen-Pills
    /// und die Token-Snap-Logik. `nil` bei RegEx=aus oder leerem Pattern.
    /// Patterns sind kurz → tokenize ist <1 ms, kein Debounce nötig.
    @State private var findTokenization: RegexTokenization? = nil

    /// Nutzer-Selektion im Treffer-Detail (UTF-16-Range im Match-Text).
    /// Daraus baut „Gruppe definieren" via GroupBuilder die Capture Group.
    @State private var detailSelection = NSRange(location: 0, length: 0)

    /// Steuer-Handles für Caret-genaues Einfügen: Element-Picker →
    /// Find-Feld, Pill-Klick → Replace-Feld. (@State hält die Instanzen
    /// über Re-Render hinweg stabil; die Klassen selbst sind leichtgewichtig.)
    @State private var findFieldController = RegexFieldController()
    @State private var replaceFieldController = RegexFieldController()

    var body: some View {
        // Maske ist seit v0.5 in einem eigenen NSWindow — kein eigener
        // Card-Hintergrund, kein interner Header (Fenster-Titel weg via
        // `titleVisibility = .hidden`, Schließen geht über die roten
        // Punkte der Titelleiste oder den Abbrechen-Button unten).
        VStack(alignment: .leading, spacing: 12) {
            scopeRow

            // Wachsender Ordner-Block — nur bei Scope „Ordner" sichtbar,
            // animiert. Konzept-Frage 1 (Daniel, 2026-05-26): „Maske
            // wächst dynamisch statt zwei separate Fenster".
            if workspace.scope == .folder {
                folderSourcesSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().opacity(0.4)

            templateRow
            findRow
            optionsRow
            replaceRow

            // Wildcard-Überzahl-Hinweis (Review-Befund 2026-06-23, Daniel-Entscheid:
            // dezenter Hinweis statt Block): Wenn im Platzhalter-Modus das Ersetzen-
            // Feld MEHR `*` enthält als das Suchen-Feld, haben die überzähligen
            // Sterne keine Capture-Gruppe und werden zu leerem Text. Transparent
            // machen (App-Linie „keine stille Trunkierung").
            if let warn = wildcardReplaceWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warn)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            if workspace.useRegex {
                groupsRow
            } else if usesWildcard {
                // Plain-Modus-Pendant zum Gruppen-Tray: nummerierte Pillen
                // pro `*` (Feature J, todo 1+2).
                wildcardGroupsRow
            }

            // Inline Live-Vorschau Vorher→Nachher direkt unter den Feldern
            // (Feature J, todo 3) — leer, wenn nicht anwendbar.
            livePreviewStrip

            Divider().opacity(0.4)

            hitsSection

            Divider().opacity(0.4)

            detailSection

            Divider().opacity(0.4)

            actionRow
        }
        .padding(16)
        .frame(minWidth: 500, maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.surfaceRaised.ignoresSafeArea())
        .animation(.easeOut(duration: 0.22), value: workspace.scope)
        .animation(.easeOut(duration: 0.18), value: workspace.useRegex)
        // Tokenisierung live nachziehen — beim Öffnen und bei jeder
        // Änderung von Pattern oder RegEx-Schalter.
        .onAppear { retokenize() }
        .onChange(of: workspace.findPattern) { retokenize() }
        .onChange(of: workspace.useRegex) { retokenize() }
    }

    /// Tokenisiert das Find-Pattern neu (oder setzt `nil` bei RegEx=aus).
    private func retokenize() {
        findTokenization = (workspace.useRegex && !workspace.findPattern.isEmpty)
            ? RegexTokenizer.tokenize(workspace.findPattern)
            : nil
    }

    /// Spiegelt `SearchOptions.usesWildcard` für die Maske (Single Source of
    /// Truth): Plain-Modus, Mini-Schalter „∗ wörtlich" aus, mindestens ein `*`
    /// im Suchausdruck. Steuert die Platzhalter-Pillen-Zeile — das Plain-
    /// Pendant zum `groupsRow` des RegEx-Modus.
    private var usesWildcard: Bool {
        workspace.currentSearchOptions.usesWildcard
    }

    /// Anzahl der Platzhalter-Sterne im Suchausdruck = Anzahl der Pillen. Über
    /// `WildcardPattern.compileFind` als SSoT (zählt UTF-16-genau, dieselbe
    /// Wahrheit wie die Such-Engine), statt das `*` hier separat zu zählen.
    private var wildcardStarCount: Int {
        WildcardPattern.compileFind(workspace.findPattern).starCount
    }

    // MARK: - Suchbereich-Zeile (Datei / Geöffnet / Ordner)

    private var scopeRow: some View {
        HStack(spacing: 8) {
            Text("Suchbereich")
                .font(Theme.uiSmall)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)

            HStack(spacing: 4) {
                // `.open` („Geöffnet") ist noch NICHT wirklich implementiert:
                // die Such-Engine durchsucht in diesem Scope faktisch nur den
                // aktiven Tab, nicht alle geöffneten Tabs (siehe SearchRunner /
                // runBufferSearch). Deshalb blenden wir den Button aus, bis die
                // echte Mehr-Tab-Suche existiert — sonst verspräche das UI etwas,
                // das die App nicht tut. Der Enum-Fall bleibt bestehen (Engine-
                // Verhalten + Tests unverändert), nur die Auswahl ist gefiltert.
                ForEach(Workspace.SearchScope.allCases) { s in
                    Button {
                        workspace.scope = s
                    } label: {
                        // Kein Zahlen-Badge mehr: war ein hartcodierter
                        // Prototyp-Überrest (8/51/51, an nichts gekoppelt) und
                        // wurde regelmäßig mit der Treffer-Zahl verwechselt
                        // (Daniel-Befund 2026-06-22). Die echte Treffer-Zahl
                        // steht unten bei „Treffer (N)". Die Scope-Auswahl bleibt
                        // über die Sand-Füllung markiert.
                        Text(s.rawValue)
                            .font(Theme.uiSmall)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(workspace.scope == s ? Theme.surfaceSand : Color.clear)
                            )
                            .foregroundColor(workspace.scope == s ? Theme.textPrimary : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    // Kein Tastatur-Fokusring auf den Scope-Buttons: der erste
                    // Button bekäme beim Öffnen den Fokus und zeigte einen
                    // amber Ring (App-Tint = Gold) um „Datei" — irreführend, da
                    // der gewählte Scope bereits über die Sand-Füllung markiert
                    // ist (Daniel-Befund 2026-06-13). Auswahl ≠ Fokus.
                    .focusEffectDisabled()
                    .help(tooltip(for: s))
                }
            }
            Spacer()
        }
    }

    private func tooltip(for scope: Workspace.SearchScope) -> String {
        switch scope {
        case .file:   return "Nur in der aktuell sichtbaren Datei suchen."
        case .open:   return "In allen geöffneten Tabs suchen."
        case .folder: return "In einem oder mehreren Ordnern suchen — Ordner werden weiter unten ausgewählt."
        }
    }

    // MARK: - Ordner-Quellen (sichtbar nur bei Scope „Ordner")
    //
    // Stub für die Recent-Folders-Liste + Dateityp-Filter. Persistenz
    // und „Auswählen…"-Dialog folgen in v0.6, sobald die echte Folder-
    // Suche kommt.

    private var folderSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ordner")
                    .font(Theme.uiSmall)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 80, alignment: .leading)
                Text("Zuletzt verwendete Ordner (Auswahl zum Durchsuchen ankreuzen):")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }

            VStack(spacing: 2) {
                ForEach($workspace.recentSearchFolders) { $entry in
                    HStack(spacing: 6) {
                        Toggle("", isOn: $entry.enabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Text(entry.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            workspace.recentSearchFolders.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Diesen Ordner aus der Liste entfernen.")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceSand.opacity(0.5))
            )

            HStack(spacing: 8) {
                Spacer().frame(width: 80)
                Button("Ordner hinzufügen…") {
                    workspace.addSearchFolders()
                }
                .controlSize(.small)
                .help("Einen oder mehrere Ordner zur Liste hinzufügen.")

                Picker("Dateitypen", selection: $workspace.fileTypeFilter) {
                    ForEach(FileTypeFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .help("„Bekannte Textformate\" ignoriert Binärdateien automatisch. „Alle Dateien\" sucht überall — Binärdateien werden trotzdem übersprungen, kein Crash.")

                Spacer()
            }
        }
    }

    // MARK: - Vorlagen-Dropdown

    /// Zeile mit dem Vorlagen-Picker. Auswahl füllt im Echtbetrieb das
    /// Find-Feld (und ggf. das Replace-Feld bei `defaultReplacement`).
    /// Im Grobschnitt: rein visuell, ohne Wirkung.
    private var templateRow: some View {
        HStack(spacing: 8) {
            Text("Vorlage")
                .font(Theme.uiSmall)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)

            // Vorlage-Dropdown ist **immer** aktiv. Alle Vorlagen sind
            // RegEx-Patterns — beim Auswählen wird der RegEx-Schalter
            // automatisch eingeschaltet (sonst wirken die Patterns nicht).
            Menu {
                Button("— Keine —") {
                    workspace.selectedTemplateID = nil
                }
                Divider()
                ForEach(PatternCategory.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(BuiltInPatterns.patterns(in: category)) { template in
                            Button(template.name) {
                                applyTemplate(template)
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(currentTemplateLabel)
                        .font(Theme.uiSmall)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.surfaceSand)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .help("Fertige Such-Patterns einsetzen — z.B. E-Mail, ISO-Datum, Dateipfad. Auswahl füllt das Suchen-Feld komplett.")
        }
    }

    private var currentTemplateLabel: String {
        guard
            let id = workspace.selectedTemplateID,
            let template = BuiltInPatterns.all.first(where: { $0.id == id })
        else { return "— Vorlage auswählen —" }
        return template.name
    }

    /// Vorlage anwenden: Find-Pattern setzen, ggf. Replace-Vorschlag
    /// übernehmen, RegEx-Schalter aktivieren. Im Grobschnitt einfach;
    /// echte Capture-Group-Erkennung folgt in v0.7.
    private func applyTemplate(_ template: PatternTemplate) {
        workspace.selectedTemplateID = template.id
        workspace.findPattern = template.regex
        if let replace = template.defaultReplacement {
            workspace.replacePattern = replace
        }
        // Vorlagen sind RegEx-Patterns → RegEx-Modus zwingend an.
        workspace.useRegex = true
    }

    // MARK: - Find-Feld mit Element-Picker-Button

    private var findRow: some View {
        HStack(spacing: 8) {
            Text("Suchen")
                .font(Theme.uiSmall)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)

            // Editierbares Feld MIT Inline-Token-Highlighting (v0.7):
            // NSTextView-basiert (RegexFieldView), Farben pro Token-Typ
            // aus der tree-sitter-Tokenisierung. Bei RegEx=aus keine
            // Färbung (tokenization == nil). Return = Weitersuchen bzw.
            // im Ordner-Scope Suche erzwingen (gleiches Verhalten wie
            // die Buttons in der Action-Zeile).
            RegexFieldView(
                text: $workspace.findPattern,
                tokenization: findTokenization,
                placeholder: "Suchausdruck…",
                controller: findFieldController,
                onSubmit: {
                    if workspace.scope == .folder {
                        workspace.runFolderSearchNow()
                    } else {
                        NotificationCenter.default.post(name: .fastraGotoNextMatch, object: nil)
                    }
                },
                accessibilityID: "fastra.findField"
            )
            .frame(height: 24)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            // accentReadable statt accent: Goldgelb (~1,4:1) war
                            // als Stroke auf weißem Grund kaum sichtbar; Bernstein
                            // (#A07800) erreicht ~4,0:1 auf Weiß.
                            .stroke(workspace.useRegex ? Theme.accentReadable.opacity(0.8) : Theme.stroke,
                                    lineWidth: 1.5)
                    )
            )

            // Element-Picker [+]: öffnet ein Popover mit RegEx-Bausteinen,
            // kategorisiert (Anker / Zeichenklassen / Quantifizierer /
            // Gruppen). Auswahl hängt den Token ans Find-Pattern an.
            Button {
                showElementPicker = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14, weight: .regular))
                    // Dunkelgrau statt Gelb — gelb auf weiß war zu undeutlich.
                    .foregroundColor(workspace.useRegex ? Theme.textPrimary : Theme.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!workspace.useRegex)
            .help("RegEx-Element einfügen — Zeichenklassen, Quantifizierer, Anker, Gruppen. Nur aktiv, wenn der RegEx-Schalter an ist.")
            .popover(isPresented: $showElementPicker, arrowEdge: .bottom) {
                ElementPickerView { element in
                    // Caret-genau ins Find-Feld einfügen (seit v0.7 über
                    // den RegexFieldController). Hat das Feld keinen
                    // Fokus, hängt insertAtCaret ans Ende an.
                    findFieldController.insertAtCaret(element.insert)
                }
            }

            // Such-Verlauf (K4): Uhr-Popup mit den letzten Find-/Replace-
            // Paaren. Auswahl füllt beide Felder (BBEdit „Search History").
            searchHistoryMenu
        }
    }

    /// Uhr-Popup rechts neben dem Element-Picker — listet `searchHistory`.
    private var searchHistoryMenu: some View {
        Menu {
            if workspace.searchHistory.isEmpty {
                Button("(kein Verlauf)") { }.disabled(true)
            } else {
                ForEach(workspace.searchHistory) { entry in
                    Button(Self.historyLabel(entry)) { workspace.applyHistoryEntry(entry) }
                }
                Divider()
                Button("Verlauf löschen") { workspace.searchHistory = [] }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zuletzt verwendete Such- und Ersetz-Paare. Auswahl füllt beide Felder.")
    }

    /// Baut die Menü-Beschriftung eines Verlaufs-Eintrags: Suchbegriff, bei
    /// nicht-leerem Ersetzen „ → Ersetzung". Auf ~48 Zeichen gekürzt, damit
    /// das Menü nicht ausufert.
    static func historyLabel(_ entry: SearchHistoryEntry) -> String {
        let raw = entry.replace.isEmpty ? entry.find : "\(entry.find) → \(entry.replace)"
        let oneLine = raw.replacingOccurrences(of: "\n", with: "⏎")
        return oneLine.count > 48 ? String(oneLine.prefix(47)) + "…" : oneLine
    }

    // MARK: - Such-Optionen-Toggle-Zeile (BBEdit-Stil)
    //
    // Vier deutsch beschriftete Toggles, jeder mit Tooltip-Erklärung.
    // Reihenfolge bewusst: RegEx als Master-Schalter ganz links, dann
    // die Modifier in der Reihenfolge, in der man sie typischerweise braucht.

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("Optionen")
                    .font(Theme.uiSmall)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 80, alignment: .leading)

                // Alle Toggles mit fixedSize, damit ihre Labels bei
                // minimaler Fensterbreite nicht auf mehrere Zeilen umbrechen.
                Toggle("RegEx", isOn: $workspace.useRegex)
                    .toggleStyle(.checkbox)
                    .font(Theme.uiSmall)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Suchausdruck als regulären Ausdruck behandeln. Aus = wörtliche Suche; Sonderzeichen wie . oder ? werden buchstäblich gesucht.")

                // „Groß = klein" ist die Kompaktform. Achtung: Semantik ist
                // gegenüber `caseSensitive` invertiert (Toggle AN heißt:
                // groß und klein als gleich behandeln, also case-insensitiv).
                Toggle("Groß = klein", isOn: Binding(
                    get: { !workspace.caseSensitive },
                    set: { workspace.caseSensitive = !$0 }
                ))
                    .toggleStyle(.checkbox)
                    .font(Theme.uiSmall)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Groß- und Kleinschreibung gleich behandeln. Aus = unterscheiden; „Max\" findet dann nicht „max\". Standard: an.")

                Toggle("Ganzes Wort", isOn: $workspace.wholeWord)
                    .toggleStyle(.checkbox)
                    .font(Theme.uiSmall)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Findet nur vollständige Wörter. „Test\" findet „Test\", aber nicht „Tester\" oder „Kontest\".")

                Toggle("Wrap-around", isOn: $workspace.wrapAround)
                    .toggleStyle(.checkbox)
                    .font(Theme.uiSmall)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Nach dem letzten Treffer geht die Suche oben wieder von vorn los. Aus = die Suche hält am Dateiende an.")

                // „Nur in Auswahl" (K3, BBEdit „Selected Text Only") — nur in den
                // Buffer-Scopes sinnvoll (im Ordner-Scope gibt es keine Editor-
                // Selektion). Nur aktivierbar, wenn gerade Text selektiert ist.
                if workspace.scope == .file {
                    Toggle("Nur in Auswahl", isOn: Binding(
                        get: { workspace.searchInSelectionOnly },
                        set: { workspace.setSearchInSelectionOnly($0) }
                    ))
                        .toggleStyle(.checkbox)
                        .font(Theme.uiSmall)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(workspace.selectionRange == nil && !workspace.searchInSelectionOnly)
                        .help("Suchen und Ersetzen nur innerhalb des aktuell im Editor markierten Texts. Aktivierbar, sobald etwas selektiert ist; die Auswahl wird beim Einschalten eingefroren.")
                }

                Spacer()
            }

            // Der kontextuelle Schalter passte zusammen mit „Nur in Auswahl"
            // nicht mehr in die feste 640-Pixel-Mindestbreite der Suchmaske:
            // SwiftUI hielt dank `fixedSize` zwar alle Labels einzeilig, schob
            // „∗ wörtlich" dadurch aber rechts aus dem sichtbaren Fenster.
            // Eine eigene, am Eingabefeld ausgerichtete zweite Zeile hält den
            // seltenen Schalter vollständig sichtbar und lässt die normale
            // Optionszeile unverändert kompakt.
            if !workspace.useRegex && WildcardPattern.containsWildcard(workspace.findPattern) {
                HStack {
                    Toggle("∗ wörtlich", isOn: $workspace.treatWildcardLiterally)
                        .toggleStyle(.checkbox)
                        .font(Theme.uiSmall)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Den Stern ∗ als gewöhnliches Zeichen suchen statt als Platzhalter für beliebigen Text innerhalb einer Zeile (∗∗ fängt auch über Zeilenumbrüche). Standard: aus (∗ ist Platzhalter).")

                    Spacer()
                }
                // 80 px Labelbreite + 14 px Abstand der ersten Zeile. So
                // beginnt der Schalter exakt dort, wo auch die Suchfelder und
                // die übrigen Optionen beginnen.
                .padding(.leading, 94)
            }
        }
    }

    // MARK: - Replace-Feld

    /// Hinweistext, wenn im Platzhalter-Modus das Ersetzen-Feld MEHR `*` enthält
    /// als das Suchen-Feld. Die überzähligen Sterne haben keine Capture-Gruppe
    /// (`compileReplace` macht aus dem N-ten `*` ein `$N`, aber `compileFind`
    /// erzeugt nur so viele Gruppen wie Sterne im Suchen) → sie werden zu leerem
    /// Text. `nil` = kein Hinweis. Spiegelt `SearchOptions.usesWildcard`.
    private var wildcardReplaceWarning: String? {
        guard !workspace.useRegex,
              !workspace.treatWildcardLiterally,
              WildcardPattern.containsWildcard(workspace.findPattern) else { return nil }
        // Lauf-Zählung, nicht Roh-Zählung: `**` ist EIN Platzhalter (eine
        // mehrzeilige Gruppe bzw. ein Verweis), siehe WildcardPattern #6.
        let findStars = WildcardPattern.starRunCount(workspace.findPattern)
        let replaceStars = WildcardPattern.starRunCount(workspace.replacePattern)
        guard replaceStars > findStars else { return nil }
        let extra = replaceStars - findStars
        return extra == 1
            ? "Ersetzen hat ein ∗ mehr als Suchen — das überzählige ∗ bleibt leer."
            : "Ersetzen hat \(extra) ∗ mehr als Suchen — die überzähligen bleiben leer."
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Text("Ersetzen")
                .font(Theme.uiSmall)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)
            // Seit v0.7 ebenfalls NSTextView-basiert (RegexFieldView):
            // nimmt Drops der Gruppen-Pills nativ an der Maus-Position an
            // und erlaubt Caret-genaues Einfügen per Pill-Klick (über den
            // replaceFieldController). Keine Tokenisierung — das Replace-
            // Template ist kein RegEx. (Die frühere Dark-Mode-Textfarben-
            // Falle betrifft die Komponente nicht: sie setzt ihre
            // Ink-Textfarbe explizit in sRGB.)
            RegexFieldView(
                text: $workspace.replacePattern,
                tokenization: nil,
                placeholder: "Ersetzen durch… ($1, $2 für Gruppen)",
                controller: replaceFieldController,
                accessibilityID: "fastra.replaceField"
            )
            .frame(height: 24)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )

            // Swap-Button (K9, BBEdit „Swap"): vertauscht Suchen- und
            // Ersetzen-Feld. Sitzt am Ende der Ersetzen-Zeile, dort wo bei
            // der Suchen-Zeile der Element-Picker steht (symmetrisch).
            Button {
                workspace.swapFindReplace()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Suchen und Ersetzen vertauschen")
        }
    }

    // MARK: - Gruppen-Tray (nur bei RegEx=an)

    private var groupsRow: some View {
        HStack(spacing: 8) {
            Text("GRUPPEN")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)

            // Pills LIVE aus der Tokenisierung (v0.7) — eine pro fangender
            // Gruppe im Find-Pattern. Drag ins Replace-Feld ODER Klick
            // fügt dort `$N` ein (Low-Friction-Leitplanke: beides geht).
            if let groups = findTokenization?.groups, !groups.isEmpty {
                HStack(spacing: 6) {
                    ForEach(groups, id: \.number) { group in
                        GroupPill(group: group,
                                  patternText: workspace.findPattern) {
                            replaceFieldController.insertAtCaret("$\(group.number)")
                        }
                    }
                }
            } else {
                // Kein Klammern-Wissen voraussetzen: sagen, wie Gruppen
                // entstehen — tippen ODER geführt im Detail-Bereich.
                Text("Keine Gruppen — (…) im Suchausdruck setzen oder unten im Detail markieren + „Gruppe definieren\".")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    // MARK: - Platzhalter-Tray (nur bei RegEx=aus + aktivem `*`)
    //
    // Das Plain-Modus-Pendant zum Gruppen-Tray (Feature J): jeder `*` im
    // Suchausdruck ist eine gierige Fanggruppe und bekommt eine nummerierte
    // Pille `$1`, `$2`, … — dieselbe Low-Friction-Mechanik wie die Capture-
    // Group-Pillen (Drag aufs Ersetzen-Feld ODER Klick fügt dort `$N` ein).
    // Sichtbar nur, wenn `usesWildcard` true ist (Plain + Schalter aus + `*`
    // vorhanden) → `wildcardStarCount` ist dann ≥ 1.
    private var wildcardGroupsRow: some View {
        HStack(spacing: 8) {
            Text("PLATZHALTER")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Theme.textSecondary)
                // „PLATZHALTER" ist breiter als die 80-pt-Label-Spalte (anders
                // als „GRUPPEN") und brach sonst hässlich um („PLATZHALTE"/„R").
                // Eine Zeile erzwingen und bei Bedarf leicht schrumpfen.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 80, alignment: .leading)

            // Eine Pille pro Stern. `max(1, …)` ist nur eine defensive Klammer:
            // die Zeile rendert ohnehin nur bei `usesWildcard` (≥ 1 Stern), aber
            // falls sich das Muster zwischen Bedingung und Body-Aufbau ändert,
            // bleibt `1...n` gültig (ForEach-Range darf nicht leer/absteigend sein).
            //
            // BEWUSST nur die Pillen, kein erklärender Fließtext — exakt wie das
            // `groupsRow`-Pendant im RegEx-Modus (Konsistenz + „chirurgisch").
            // Die Bedeutung tragen der Pillen-Tooltip und der Ersetzen-Feld-
            // Platzhalter („$1, $2 für Gruppen").
            HStack(spacing: 6) {
                ForEach(1...max(1, wildcardStarCount), id: \.self) { n in
                    WildcardPill(number: n) {
                        replaceFieldController.insertAtCaret("$\(n)")
                    }
                }
            }
        }
    }

    // MARK: - Inline Live-Vorschau Vorher→Nachher (Feature J, todo 3)

    /// Zeilen-Obergrenze der INLINE-Vorschau. Bewusst klein — das große
    /// „Vorschau der Änderungen"-Sheet zeigt alle Zeilen; hier geht es nur um
    /// Sofort-Feedback beim Tippen.
    private var livePreviewMaxRows: Int { 3 }

    /// Kompakte, LIVE mittippende Vorher→Nachher-Vorschau direkt unter den
    /// Feldern. Reuse der getesteten `ReplacePreview.build`-Logik (gleiche
    /// Quelle wie das große Sheet) — hier nur die ersten Zeilen als Sofort-
    /// Feedback (Produktprinzip „Vorschau ist das Produkt"). Nur in den Buffer-
    /// Scopes (Datei/Geöffnet — der Ordner-Scope hat keinen einzelnen aktiven
    /// Buffer), nur wenn ein Ersetzen-Text getippt ist UND es Treffer gibt;
    /// sonst leer → im Normalfall kein Layout-Sprung. `replacePattern` ist ein
    /// Such-Trigger (SearchRunner) → die `replacedText` der Treffer sind beim
    /// Tippen frisch, die Vorschau also korrekt.
    @ViewBuilder
    private var livePreviewStrip: some View {
        if workspace.scope != .folder,
           !workspace.replacePattern.isEmpty,
           !workspace.bufferMatches.isEmpty {
            let preview = ReplacePreview.build(text: workspace.activeTab?.content ?? "",
                                               matches: workspace.bufferMatches,
                                               maxRows: livePreviewMaxRows)
            // Treffer, deren Ersetzung == Original (z.B. Suchen == Ersetzen),
            // liefern keine Zeilen → dann zeigen wir nichts.
            if !preview.rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VORSCHAU")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(Theme.textSecondary)
                    ForEach(preview.rows) { row in
                        LivePreviewRow(row: row)
                    }
                    // Ehrlich über die Begrenzung (App-Linie „keine stille
                    // Trunkierung"): auf das vollständige Sheet verweisen.
                    if preview.totalChangedLines > preview.rows.count {
                        Text("… und \(preview.totalChangedLines - preview.rows.count) weitere geänderte Zeilen — „Vorschau der Änderungen\" zeigt alle.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.surfaceSand.opacity(0.5))
                )
            }
        }
    }

    // MARK: - Trefferliste in der Maske (Sofort-Treffer)

    private var hitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Treffer (\(scopeTotalMatches))")
                    .font(Theme.uiSmall)
                    .foregroundColor(Theme.textPrimary)
                // Spinner, solange im Hintergrund gesucht wird — Folder- ODER
                // Buffer-Scope (beide laufen async). „Suche noch läuft"-Signal,
                // damit der ehrliche Count nicht als „fertig" missverstanden wird.
                if workspace.folderSearching || workspace.bufferSearching {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
                Spacer()
                hitNavigator
            }

            // Fehler-Streifen unter dem Header, wenn das Pattern kaputt
            // ist. Erfüllt Interview-Erkenntnis 5 (Fehler erklären, nicht
            // nur markieren). Verschwindet, sobald das Pattern wieder
            // gültig ist.
            if let msg = workspace.searchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
            }

            // Cap-Hinweis: Trefferliste wurde durch den Gesamt-Cap abgeschnitten.
            // Erscheint NUR im Ordner-Scope und NUR wenn der Cap tatsächlich
            // ausgelöst hat — stilles Abschneiden ist schlechter UX.
            // Stil analog zum Fehler-Streifen, aber Gelb/Orange statt Rot,
            // da es kein Fehler ist, sondern ein informativer Hinweis.
            if (workspace.scope == .folder && workspace.folderResultsWereCapped)
                || (workspace.scope == .open && workspace.openResultsWereCapped) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(workspace.scope == .folder
                         ? "Trefferliste auf 10.000 gekappt — Suchbegriff verfeinern."
                         : "Trefferliste gekappt — Zähler zeigt die wahre Gesamtzahl.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            // Cap-Hinweis im Buffer-Scope: nur die ersten N von vielen Treffern
            // sind als Liste materialisiert. Der Header zeigt die echte
            // Gesamtzahl; hier steht ehrlich, wie viele davon gelistet sind.
            // „Alle ersetzen" wirkt trotzdem auf ALLE Treffer (Voll-Replace).
            if workspace.scope != .folder && workspace.bufferResultsWereCapped {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Erste \(workspace.bufferMatches.count) von \(workspace.bufferTotalMatches) Treffern gelistet — Suchbegriff verfeinern. „Alle ersetzen“ erfasst dennoch alle.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .lineLimit(3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            // Trefferliste über SwiftUI `List` (NSTableView-backed) =
            // VIRTUALISIERT: rendert nur die SICHTBAREN Zeilen, nicht alle bis
            // zu 2000 Treffer. Das war der Performance-Killer (Daniel-Befund
            // 2026-06-22): der frühere nicht-lazy VStack baute bei JEDEM Render
            // alle Zeilen neu auf — und weil der geteilte Workspace den offenen
            // Dialog bei jeder Cursor-Bewegung mit-rendert, blockierte das den
            // Main-Thread → Beachball beim Treffer-Klick, träges CMD+W, träge
            // Klicks im Hauptfenster. `List` aktualisiert sichtbare Zeilen
            // zuverlässig bei Zustandswechsel (die `isActive`-Markierung stimmt
            // — anders als bei LazyVStack, das genau daran scheiterte — und es
            // gibt keinen AttributeGraph-Crash bei vielen Treffern).
            Group {
                if scopeTotalMatches == 0 && workspace.searchError == nil
                    && !workspace.folderSearching && !workspace.bufferSearching {
                    // Leerer Zustand: nur der Hinweis (kein List-Chrome), volle
                    // Breite/Höhe, damit die dunkle Box gefüllt wirkt.
                    Text(emptyHint)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List {
                        ForEach(groupedHits) { group in
                            Section {
                                ForEach(group.matches) { match in
                                    HitRow(match: match,
                                           isActive: activeMatch?.id == match.id) {
                                        handleMatchTap(match: match, fileURL: group.url,
                                                       tabID: group.tabID)
                                    }
                                    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                }
                            } header: {
                                Text("\(group.label) (\(group.matches.count))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                    // List-Eigenhintergrund ausblenden, damit die Sand-Box
                    // darunter sichtbar bleibt (macOS 13+).
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 20)
                }
            }
            // Flexibel — wächst mit dem Fenster. `maxWidth: .infinity`: die Box
            // füllt immer die volle Maskenbreite, egal wie kurz der Inhalt ist.
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceSand.opacity(0.5))
            )
        }
    }

    /// Das vollständige Navigationsziel des aktuell aktiven Treffers. Anders
    /// als der nackte `BufferSearch.Match` trägt es im „Geöffnet"-Scope die
    /// Ziel-Tab-ID und im Ordner-Scope die Datei-URL. Detailtext, Dateiname und
    /// Sprung beziehen sich dadurch garantiert auf denselben Treffer.
    private var activeNavMatch: Workspace.NavMatch? {
        let matches = workspace.navMatches
        guard !matches.isEmpty else { return nil }
        let idx = max(0, min(matches.count - 1, workspace.activeMatchIndex))
        return matches[idx]
    }

    /// Der aktuell „aktive" Treffer (für Detail-Bereich + List-Highlight).
    /// `nil`, wenn keine Treffer da sind. Die Auswahl des passenden Indexes
    /// geschieht zentral in `activeNavMatch`, damit Metadaten und Text niemals
    /// aus verschiedenen Tabs stammen.
    private var activeMatch: BufferSearch.Match? {
        activeNavMatch?.match
    }

    /// Treffer-Gruppe für die Anzeige in der Maske. `url` ist nur im
    /// Folder-Scope gesetzt — die Maske braucht sie, um beim Klick die
    /// passende Datei zu öffnen.
    private struct HitGroup: Identifiable {
        // Stabile Identität über Renders hinweg. Vorher `UUID()` pro Erzeugung
        // → `groupedHits` lieferte bei jedem Render „neue" Gruppen, ForEach/List
        // bauten alles neu auf und die List-Virtualisierung lief ins Leere.
        // Datei-/Geöffnet-Scope: genau eine Gruppe ("buffer"); Ordner-Scope:
        // eine Gruppe je Datei (Pfad ist eindeutig).
        // Geöffnet-Scope: mehrere Gruppen ohne URL → Tab-ID als Identität.
        var id: String { url?.path ?? tabID?.uuidString ?? "buffer" }
        let label: String
        let url: URL?
        var tabID: UUID? = nil
        let matches: [BufferSearch.Match]
    }

    /// Treffer gruppiert nach Datei. Im Datei-Scope eine Gruppe (= aktiver
    /// Tab); im Folder-Scope eine Gruppe pro Datei mit Treffern.
    private var groupedHits: [HitGroup] {
        if workspace.scope == .folder {
            return workspace.folderResults
                .filter { !$0.matches.isEmpty }
                .map { HitGroup(label: $0.url.lastPathComponent,
                                url: $0.url,
                                matches: $0.matches) }
        }
        if workspace.scope == .open {
            // Eine Gruppe pro offenem Tab mit Treffern (BBEdit-Results-
            // Browser-Analogon; Klick aktiviert den Tab statt zu laden).
            return workspace.openResults
                .filter { !$0.matches.isEmpty }
                .map { HitGroup(label: $0.title, url: nil,
                                tabID: $0.id, matches: $0.matches) }
        }
        guard !workspace.bufferMatches.isEmpty else { return [] }
        let title = workspace.activeTab?.title ?? "Aktiver Buffer"
        return [HitGroup(label: title, url: nil, matches: workspace.bufferMatches)]
    }

    /// Summe aller Treffer im aktuellen Scope.
    private var scopeTotalMatches: Int {
        // Echte Gesamtzahl (kann > materialisierte Liste sein, wenn der
        // Cap griff) — ehrlicher Count wie BBEdits Statuszeile.
        switch workspace.scope {
        case .folder: return workspace.folderTotalMatches
        case .open:   return workspace.openTotalMatches
        case .file:   return workspace.bufferTotalMatches
        }
    }

    /// Hinweistext bei leerer Trefferliste, scope-spezifisch formuliert.
    private var emptyHint: String {
        if workspace.findPattern.isEmpty { return "Suchausdruck eingeben…" }
        if workspace.scope == .folder {
            if workspace.enabledSearchFolderURLs.isEmpty {
                return "Kein Ordner ausgewählt. Mindestens einen aktivieren."
            }
            // Unter der Live-Mindestlänge sucht der Ordner-Scope nicht
            // automatisch (Freeze-Schutz bei kurzen Pattern, siehe
            // SearchRunner.shouldRunFolderLive) — Hinweis statt „Keine Treffer.".
            if !SearchRunner.shouldRunFolderLive(for: workspace.findPattern) {
                return "Mindestens \(SearchRunner.minFolderLiveChars) Zeichen für die Live-Ordner-Suche — oder „Suchen“ klicken."
            }
            // Ab Mindestlänge wird live gesucht; ist noch nichts da (z.B.
            // direkt nach Scope-Wechsel, vor dem Debounce), explizit anstoßen.
            if workspace.folderNeedsSearch {
                return "„Suchen“ klicken oder Return drücken, um die Ordner zu durchsuchen."
            }
        }
        // Ordner-Scope, Suche abgeschlossen, 0 Treffer: informativer Hinweis
        // statt generischem „Keine Treffer.", damit klar ist, dass tatsächlich
        // Dateien durchsucht wurden und nicht nur noch kein Suchlauf lief.
        if workspace.scope == .folder
            && !workspace.folderNeedsSearch
            && !workspace.folderSearching {
            return "Keine Treffer in den durchsuchten Ordnern."
        }
        return "Keine Treffer."
    }

    /// Click-Handler für eine Treffer-Zeile. Im Buffer-Scope einfach den
    /// activeMatchIndex setzen + Editor-Sprung. Im Folder-Scope zusätzlich
    /// die Datei öffnen (falls noch nicht offen) und auf den Buffer
    /// umschalten — der Editor scrollt dann zur Range.
    // codereview-ok: Tap-Handler und Ergebnis-Zuweisung laufen beide serialisiert auf dem Main-Actor, firstIndex-Lookup ist synchron; schlägt er fehl, bleibt activeMatchIndex unverändert — kein Race, benigne (2026-07-01)
    private func handleMatchTap(match: BufferSearch.Match, fileURL: URL?,
                                tabID: UUID? = nil) {
        if workspace.scope == .folder, let url = fileURL {
            // activeMatchIndex auf den flachen Treffer-Index setzen, damit
            // CMD+G beim nächsten Treffer ansetzt — schon VOR dem loadFile,
            // damit der Index auch dann stimmt, wenn Completion schnell kommt.
            let flat = workspace.folderResults.flatMap(\.matches)
            if let idx = flat.firstIndex(where: { $0.id == match.id }) {
                workspace.activeMatchIndex = idx
            }
            // Tab öffnen oder aktivieren — asynchron. Editor-Sprung erst in
            // der Completion, nachdem der Tab vollständig geladen ist
            // (Race vermieden: postMatchJump braucht den fertigen Inhalt).
            workspace.loadFile(at: url) { ok in
                guard ok else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.postMatchJump(match)
                }
            }
            return
        }
        if workspace.scope == .open, let tabID = tabID {
            // Geöffnet-Scope: Index über die FLACHE Liste aller Tab-Treffer
            // (CMD+G setzt dort an), dann den Ziel-Tab aktivieren und den
            // Sprung einen Tick später posten (Editor wird beim Tab-Wechsel
            // neu erzeugt — gleiche Race-Vermeidung wie im Ordner-Pfad).
            let flat = workspace.openResults.flatMap(\.matches)
            if let idx = flat.firstIndex(where: { $0.id == match.id }) {
                workspace.activeMatchIndex = idx
            }
            if workspace.activeTabID != tabID { workspace.activeTabID = tabID }
            DispatchQueue.main.async {
                NotificationCenter.default.postMatchJump(match)
            }
            return
        }
        if let idx = workspace.bufferMatches.firstIndex(where: { $0.id == match.id }) {
            workspace.activeMatchIndex = idx
            NotificationCenter.default.postMatchJump(match)
        }
    }

    /// „Treffer kopieren"-Button + Pfeile + Anzeige „2 / 9" für die
    /// Detail-Navigation. Der Extrahieren-Dialog (Trennzeichen-Wahl,
    /// Quoting, Dedup) folgt erst nach v1.0 — siehe AGENTS.md
    /// „v1.1+ Roadmap".
    private var hitNavigator: some View {
        HStack(spacing: 10) {
            // Textbutton statt Icon — das Feature ist zu praktisch, um
            // hinter einem kleinen Symbol zu verstecken (Daniel,
            // 2026-05-26). Voller Extrahieren-Dialog folgt in v1.1+.
            Button("Treffer kopieren") {
                workspace.copyHitsToClipboard()
            }
            .controlSize(.small)
            .help("Alle gefundenen Treffer als Liste ins Clipboard kopieren — je Treffer eine Zeile, ohne Duplikat-Filter. Erweiterter Extrahieren-Dialog mit Trennzeichen-Auswahl folgt nach v1.0.")

            // BBEdit „Extract" (Handbuch S. 168/193): Treffer in ein neues
            // Dokument statt ins Clipboard — mit gefülltem Ersetzen-Feld
            // transformiert ($1/\U/Pillen), sonst roh.
            Button("Treffer extrahieren") {
                workspace.extractHitsToNewTab()
            }
            .controlSize(.small)
            .help("Alle gefundenen Treffer in ein neues Dokument extrahieren — je Treffer eine Zeile. Ist das Ersetzen-Feld gefüllt, wird jeder Treffer zuerst damit transformiert (z.B. $1 für eine reine Gruppen-Liste); leer = Treffer unverändert übernehmen.")

            Divider().frame(height: 14)

            HStack(spacing: 4) {
                Button {
                    NotificationCenter.default.post(name: .fastraGotoPreviousMatch, object: nil)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(workspace.navMatches.isEmpty)
                .help("Vorheriger Treffer (⇧⌘G)")

                Text(workspace.navMatches.isEmpty
                     ? "0 / 0"
                     : "\(workspace.activeMatchIndex + 1) / \(workspace.navMatches.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)

                Button {
                    NotificationCenter.default.post(name: .fastraGotoNextMatch, object: nil)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(workspace.navMatches.isEmpty)
                .help("Nächster Treffer (⌘G)")
            }
        }
    }

    // MARK: - Detail-Bereich für den aktiven Treffer

    /// Zeigt genau einen Treffer ohne Kontext drumherum (Konzept §3).
    /// Seit v0.7 echt: Der Nutzer markiert im Match-Text eine Teil-
    /// Selektion; „Gruppe definieren" snappt sie auf Token-Grenzen
    /// (GroupBuilder) und setzt die `(...)`-Gruppe im Suchausdruck.
    /// Beiträge BESTEHENDER Gruppen sind farbig hinterlegt (gleiche
    /// Farbreihe wie die Pills).
    private var detailSection: some View {
        let fileLabel = Self.detailFileLabel(for: activeNavMatch,
                                             tabs: workspace.tabs,
                                             fallback: workspace.activeTab?.title ?? "Aktiver Buffer")
        let lineText = activeMatch.map { "Zeile \($0.line) · Spalte \($0.column)" } ?? "kein Treffer"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Detail · \(fileLabel) · \(lineText)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            // Bei aktivem Treffer: selektierbarer Match-Text mit Gruppen-
            // Hinterlegung. Ohne Treffer: dezenter Hinweis — gleiche Höhe und
            // gleiches Padding wie das Textfeld, damit das Layout nicht springt.
            if let match = activeMatch {
                SelectableMatchText(matchText: match.matchText,
                                    groupRanges: detailGroupRanges,
                                    selection: $detailSelection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surfaceSand)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1)
                            )
                    )
            } else {
                Text("Kein Treffer ausgewählt.")
                    .font(Theme.uiSmall)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surfaceSand)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1)
                            )
                    )
            }

            HStack(spacing: 8) {
                Button("Gruppe definieren") { defineGroupFromSelection() }
                    .controlSize(.small)
                    .disabled(!workspace.useRegex || activeMatch == nil)
                    .help("Markierten Text-Ausschnitt als Capture Group im Suchausdruck speichern. Die Auswahl snappt automatisch auf ganze RegEx-Bausteine.")
                Button("Gruppe löschen") { deleteGroupAtSelection() }
                    .controlSize(.small)
                    .disabled(!workspace.useRegex || (findTokenization?.groups.isEmpty ?? true))
                    .help("Die Capture Group im markierten Bereich wieder auflösen — die Klammern verschwinden, der Inhalt bleibt.")
                Spacer()
            }
        }
    }

    /// Ermittelt den Dateinamen für den Detailkopf aus DEMSELBEN
    /// Navigationsziel wie den angezeigten Treffertext. Diese kleine pure
    /// Funktion ist separat testbar, weil ein falscher Name im „Geöffnet"-
    /// Scope visuell plausibel aussah und deshalb durch reine Suchtests nicht
    /// auffiel.
    static func detailFileLabel(for target: Workspace.NavMatch?,
                                tabs: [EditorTab],
                                fallback: String) -> String {
        if let tabID = target?.tabID,
           let targetTab = tabs.first(where: { $0.id == tabID }) {
            return targetTab.title
        }
        if let fileURL = target?.url {
            return fileURL.lastPathComponent
        }
        return fallback
    }

    /// Formatiert die Zeilennummer in der Trefferliste ohne Präfix.
    ///
    /// Früher stand ein „Z" davor. In der kleinen Monospace-Schrift sah es
    /// leicht wie eine „2" aus und machte Angaben wie „Z12" unnötig schwer
    /// lesbar. Die Spalte ist bereits eindeutig eine Zeilennummern-Spalte;
    /// deshalb genügt die rohe Zahl. `String(line)` vermeidet außerdem die
    /// lokalisierte Tausendertrennung, die SwiftUIs interpolierter `Text`-
    /// Initializer sonst erzeugen kann.
    static func hitLineLabel(_ line: Int) -> String {
        String(line)
    }

    /// Beiträge der bestehenden Gruppen im aktiven Match-Text — für die
    /// farbige Hinterlegung im Detail. Re-Match des Patterns gegen den
    /// Match-Text (verankert am Anfang); pro fangender Gruppe die
    /// gelieferte Range.
    private var detailGroupRanges: [(number: Int, range: NSRange)] {
        guard workspace.useRegex,
              let matchText = activeMatch?.matchText,
              let groups = findTokenization?.groups, !groups.isEmpty else { return [] }
        let options = SearchOptions(find: workspace.findPattern,
                                    replace: "",
                                    isRegex: true,
                                    caseSensitive: workspace.caseSensitive,
                                    wholeWord: false)
        guard let regex = try? ApplyEngine.buildRegex(options) else { return [] }
        let ns = matchText as NSString
        guard let match = regex.firstMatch(in: matchText,
                                           options: [.anchored],
                                           range: NSRange(location: 0, length: ns.length))
        else { return [] }
        return groups.compactMap { group in
            guard group.number < match.numberOfRanges else { return nil }
            let r = match.range(at: group.number)
            guard r.location != NSNotFound, r.length > 0 else { return nil }
            return (group.number, r)
        }
    }

    /// „Gruppe definieren": Detail-Selektion → GroupBuilder.propose →
    /// Pattern + Replace-Template aktualisieren. Verweigerung (nil)
    /// oder „ist schon eine Gruppe" → Beep statt stiller Änderung.
    private func defineGroupFromSelection() {
        guard let matchText = activeMatch?.matchText,
              let tokenization = findTokenization,
              let proposal = GroupBuilder.propose(selection: detailSelection,
                                                  pattern: workspace.findPattern,
                                                  tokenization: tokenization,
                                                  matchText: matchText,
                                                  replacement: workspace.replacePattern,
                                                  caseSensitive: workspace.caseSensitive)
        else {
            NSSound.beep()
            return
        }
        guard !proposal.isAlreadyGroup else {
            // Schon eine Gruppe — nichts zu tun, kein Fehler.
            return
        }
        workspace.findPattern = proposal.newPattern
        workspace.replacePattern = proposal.rewrittenReplacement
    }

    /// „Gruppe löschen": Gruppe unter der Detail-Selektion (oder die
    /// letzte, wenn nichts markiert ist) via GroupRemoval auflösen.
    /// GroupRemoval verweigert bei Semantik-Risiko (Quantifier dahinter,
    /// Top-Level-Alternation im Inhalt, $N-Referenz) → Beep.
    private func deleteGroupAtSelection() {
        guard let tokenization = findTokenization,
              let lastGroup = tokenization.groups.last else {
            NSSound.beep()
            return
        }
        // Gruppe wählen: deren Match-Beitrag die Selektion schneidet
        // bzw. den Cursor enthält; sonst die letzte Gruppe.
        let hit = detailGroupRanges.first { entry in
            if detailSelection.length == 0 {
                return entry.range.location <= detailSelection.location
                    && detailSelection.location <= entry.range.location + entry.range.length
            }
            return NSIntersectionRange(entry.range, detailSelection).length > 0
        }
        let number = hit?.number ?? lastGroup.number
        guard let result = GroupRemoval.remove(group: number,
                                               pattern: workspace.findPattern,
                                               tokenization: tokenization,
                                               replacement: workspace.replacePattern)
        else {
            NSSound.beep()
            return
        }
        workspace.findPattern = result.newPattern
        workspace.replacePattern = result.rewrittenReplacement
    }

    // MARK: - Action-Zeile

    // Zweizeilig (Daniel-Feedback 2026-06-04): die sechs Buttons passten
    // bei minimaler Fensterbreite nicht sauber in eine Zeile. Aufteilung
    // nach Absicht — Zeile 1 navigiert nur durch die Treffer, Zeile 2
    // schließt die Maske bzw. ersetzt.
    private var actionRow: some View {
        VStack(spacing: 8) {
            // --- Zeile 1 · Such-Cluster: reines Navigieren durch die
            // Treffer, OHNE zu ersetzen. Deckt den „nur suchen"-Fall ab,
            // der bisher im Footer fehlte. Wiederverwendet die bestehende
            // Sprung-Logik (navigateMatch in ContentView, via Notification).
            HStack(spacing: 8) {
                // „Suchen" nur im Ordner-Scope: ab der Live-Mindestlänge sucht
                // der Ordner zwar automatisch beim Tippen, aber Klick/Return
                // erzwingen die Suche auch bei kürzeren Pattern (umgeht die
                // Schwelle) bzw. lösen sofort aus, ohne aufs Debounce zu warten.
                if workspace.scope == .folder {
                    Button("Suchen") { workspace.runFolderSearchNow() }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.bordered)
                        .disabled(workspace.findPattern.isEmpty
                                  || workspace.enabledSearchFolderURLs.isEmpty)
                        .help("Die ausgewählten Ordner jetzt durchsuchen. Ab \(SearchRunner.minFolderLiveChars) Zeichen läuft die Ordner-Suche live beim Tippen mit; Klick oder Return erzwingen sie auch bei kürzeren Suchausdrücken und ohne Wartezeit.")
                }

                Button("Voriger") {
                    NotificationCenter.default.post(name: .fastraGotoPreviousMatch, object: nil)
                }
                    .disabled(workspace.navMatches.isEmpty)
                    .help("Zum vorherigen Treffer springen — im Dokument an die Fundstelle. Tastenkürzel: ⇧⌘G.")

                Button("Nächster") {
                    NotificationCenter.default.post(name: .fastraGotoNextMatch, object: nil)
                }
                    // Return = weitersuchen (BBEdit-Verhalten) — aber nur in
                    // Buffer-Scopes. Im Ordner-Scope gehört Return zu „Suchen"
                    // (zwei Views mit demselben Shortcut wären mehrdeutig).
                    .keyboardShortcut(workspace.scope == .folder
                                      ? nil
                                      : KeyboardShortcut(.return, modifiers: []))
                    .disabled(workspace.navMatches.isEmpty)
                    .help("Zum nächsten Treffer springen — im Dokument an die Fundstelle. Tastenkürzel: ⌘G oder Return.")

                Spacer()
            }

            // --- Zeile 2 · Schließen + Ersetzen-Cluster.
            HStack(spacing: 8) {
                // Abbrechen links — alternativer Weg raus aus dem Dialog,
                // falls der Nutzer die Schließen-Punkte oben nicht findet.
                Button("Abbrechen") { workspace.showSearchDialog = false }
                    .keyboardShortcut(.cancelAction)   // ESC
                    .help("Suchmaske ausblenden. Tastenkürzel: Escape.")

                Spacer()

                Button("Vorschau der Änderungen") { workspace.livePreview = true }
                    .buttonStyle(.bordered)
                    .help("Zeigt im Hauptfenster ein Vorher/Nachher-Diff aller Ersetzungen im aktiven Buffer — jede betroffene Zeile vorher und nachher.")

                // Einzel-Ersetzen (ein Treffer + zum nächsten springen). Nur im
                // Buffer-Scope (Datei/Geöffnet) — Ordner-Einzelersetzen schreibt
                // auf die Platte und kommt mit dem Ergebnis-Fenster (Schritt 2).
                Button("Ersetzen") { workspace.replaceActiveMatch() }
                    .disabled(workspace.scope == .folder
                              || workspace.bufferMatches.isEmpty
                              || workspace.searchError != nil)
                    .help("Nur den aktiven Treffer ersetzen und zum nächsten springen. Im Ordner-Modus (noch) nicht verfügbar.")

                // Im Folder-Scope und nach einem erfolgreichen Apply gibt es
                // eine Rückgängig-Möglichkeit aus dem Backup-Ordner.
                if workspace.scope == .folder, workspace.lastApplySession != nil {
                    Button("Rückgängig") { workspace.undoLastFolderApply() }
                        .help("Spielt die letzte Ordner-Apply-Session bit-exakt aus dem Backup-Ordner zurück.")
                }

                Button("Alle ersetzen · \(scopeTotalMatches)") {
                    switch workspace.scope {
                    case .folder: workspace.applyAllInFolder()
                    case .open:   workspace.applyAllInOpenTabs()
                    case .file:   workspace.applyAllInActiveBuffer()
                    }
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(scopeTotalMatches == 0 || workspace.searchError != nil)
                    .help({
                        switch workspace.scope {
                        case .folder:
                            return "Alle Treffer in allen aktivierten Ordnern ersetzen — atomar pro Datei, mit automatischem Backup unter ~/Library/Application Support/Fastra/undo/."
                        case .open:
                            return "Alle Treffer in ALLEN geöffneten Tabs ersetzen — nur im Speicher, geänderte Tabs werden als ungesichert markiert. Speichern wie gewohnt mit ⌘S."
                        case .file:
                            return "Alle Treffer im aktiven Buffer durch das Replace-Pattern ersetzen."
                        }
                    }())
            }
        }
    }
}

// MARK: - Hilfs-Views

/// Eine Zeile in der Trefferliste — anklickbar, markiert sich beim Klick.
private struct HitRow: View {
    let match: BufferSearch.Match
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // `verbatim:` ist hier Pflicht: Ein interpolierter Text würde
                // den LocalizedStringKey-Initializer wählen und die Zahl im
                // deutschen Gebietsschema mit Tausenderpunkt formatieren.
                // Das frühere Präfix „Z" entfällt, weil es wie „2" aussah.
                // `lineLimit(1)` + `fixedSize` verhindern den Umbruch bei ≥5-stelligen Zeilen
                // (feste 28 pt waren dafür zu schmal); `minWidth` hält die rechtsbündige Spalte.
                Text(verbatim: FloatingSearchDialog.hitLineLabel(match.line))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 28, alignment: .trailing)
                Text(match.matchText)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pille im Gruppen-Tray — seit v0.7 LIVE aus der Tokenisierung.
///
/// Zwei Wege ins Replace-Feld (Low Friction, Konzept B):
///   - DRAG der Pille aufs Replace-Feld: NSTextView nimmt den String
///     (`$N`) nativ an der Maus-Position an.
///   - KLICK auf die Pille: fügt `$N` an der Replace-Caret-Position ein.
private struct GroupPill: View {
    /// Die fangende Gruppe aus der Tokenisierung (Nummer, Name, Ranges).
    let group: CaptureGroupInfo
    /// Das aktuelle Find-Pattern — für das Label (Gruppen-Inhalt).
    let patternText: String
    /// Klick-Aktion: `$N` ins Replace-Feld einfügen.
    let onInsert: () -> Void

    /// Anzeige-Label: Gruppen-Name (bei `(?<name>…)`) oder der
    /// Gruppen-Inhalt aus dem Pattern, auf Pillen-Breite gekürzt.
    private var label: String {
        if let name = group.name, !name.isEmpty { return name }
        let ns = patternText as NSString
        guard group.innerRange.location + group.innerRange.length <= ns.length else {
            return "Gruppe \(group.number)"
        }
        let inner = ns.substring(with: group.innerRange)
        return inner.count > 14 ? String(inner.prefix(13)) + "…" : inner
    }

    private var pillColor: Color {
        // abs(): defensive Klammer gegen negativen Swift-Modulo (Gruppen
        // sind 1-basiert, number 0 sollte nie vorkommen).
        Theme.groupColors[abs(group.number - 1) % Theme.groupColors.count]
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("$\(group.number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textPrimary.opacity(0.8))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(pillColor.opacity(0.35)))
        // groupColors sind für Fill-Tönung gedacht; gelber Stroke auf
        // Weiß war fast unsichtbar (~1,3:1). textSecondary gibt einen
        // neutralen, lesbaren Rahmen ohne Farb-Clash.
        .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.4), lineWidth: 1))
        // Drag-Source: liefert `$N` als Plain-String — das Replace-Feld
        // (NSTextView) nimmt ihn nativ an der Maus-Position an.
        .onDrag { NSItemProvider(object: "$\(group.number)" as NSString) }
        .onTapGesture(perform: onInsert)
        .help("Gruppe \(group.number) ins Ersetzen-Feld übernehmen — Pille dorthin ziehen oder einfach klicken (fügt $\(group.number) ein).")
    }
}

/// Pille im Platzhalter-Tray (Feature J) — eine pro `*` im Suchausdruck.
///
/// Wie `GroupPill`, aber ohne Capture-Group-Inhalt: der `*` SELBST ist die
/// (gierige) Fanggruppe, es gibt keinen Klammer-Inhalt zum Anzeigen. Zwei Wege
/// ins Ersetzen-Feld (Low-Friction-Leitplanke, identisch zu GroupPill):
///   - DRAG der Pille aufs Ersetzen-Feld → NSTextView nimmt den String (`$N`)
///     nativ an der Maus-Position an (RegexFieldTextView akzeptiert den Drop
///     auch bei Fokus).
///   - KLICK auf die Pille → `$N` an der Replace-Caret-Position (über onInsert).
private struct WildcardPill: View {
    /// 1-basierte Platzhalter-Nummer: der N-te `*` (von links) → `$N`.
    let number: Int
    /// Klick-Aktion: `$N` ins Ersetzen-Feld einfügen.
    let onInsert: () -> Void

    private var pillColor: Color {
        // Gleiche Farbreihe wie die Capture-Group-Pillen → visuelle Kontinuität;
        // abs(): defensive Klammer gegen negativen Swift-Modulo.
        Theme.groupColors[abs(number - 1) % Theme.groupColors.count]
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("$\(number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
            // Der Stern als Inhalts-Hinweis (statt eines Gruppen-Texts) — macht
            // sichtbar, dass diese Pille zum N-ten `*` gehört.
            Text("∗")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textPrimary.opacity(0.8))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(pillColor.opacity(0.35)))
        .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.4), lineWidth: 1))
        // Drag-Source: liefert `$N` als Plain-String — das Ersetzen-Feld nimmt
        // ihn nativ an (exakt dieselbe Mechanik wie GroupPill).
        .onDrag { NSItemProvider(object: "$\(number)" as NSString) }
        .onTapGesture(perform: onInsert)
        .help("Platzhalter \(number) (der \(number). Stern ∗) ins Ersetzen-Feld übernehmen — Pille dorthin ziehen oder einfach klicken (fügt $\(number) ein).")
    }
}

/// Eine kompakte Inline-Vorschau-Zeile (Feature J, todo 3): Zeilennummer ·
/// Vorher (getönt entfernt) → Nachher (getönt hinzugefügt). Schmaler und
/// einzeilig (Truncation in der Mitte) — die ausführliche, mehrzeilige
/// `DiffRow` lebt im großen „Vorschau der Änderungen"-Sheet.
private struct LivePreviewRow: View {
    let row: ReplacePreview.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(row.line)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 40, alignment: .trailing)
            Text(row.before)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.diffRemovedFG)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(Theme.textSecondary)
            Text(row.after)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.diffAddedFG)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Element-Picker-Popover

/// Inhalt des Element-Picker-Popovers: kategorisierte RegEx-Bausteine.
/// Ein Klick ruft `onPick` mit dem gewählten Element auf.
private struct ElementPickerView: View {
    let onPick: (RegexElement) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(RegexElements.categories) { category in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.bottom, 2)

                        ForEach(category.elements) { element in
                            Button {
                                onPick(element)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(element.symbol)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(Theme.tokenCharClass)
                                        .frame(width: 56, alignment: .leading)
                                    Text(element.hint)
                                        .font(Theme.uiSmall)
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                            }
                            .buttonStyle(ElementRowButtonStyle())
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 320, height: 380)
        // Opaker Hintergrund — sonst schimmert das halbtransparente
        // Popover-Material durch und die Symbole sind schlecht lesbar.
        .background(Theme.surfaceRaised)
    }
}

/// Dezenter Hover-Hintergrund für eine Picker-Zeile.
private struct ElementRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Theme.surfaceSand : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}
