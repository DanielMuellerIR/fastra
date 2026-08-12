import SwiftUI
import AppKit
import Darwin

enum FastraProcessGroupLauncher {
    static let flag = "--fastra-process-group-launcher"

    /// Derselbe signierte Fastra-Binary dient als winziger nativer Launcher.
    /// Er gründet die Prozessgruppe vor `exec`, also ohne das unvermeidbare
    /// post-spawn/EACCES-Fenster von `Process` + `setpgid` im Elternprozess.
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == flag else { return }
        guard Darwin.setpgid(0, 0) == 0 else { _exit(126) }
        let executable = arguments[2]
        let forwarded = [executable] + Array(arguments.dropFirst(3))
        var pointers = forwarded.map { strdup($0) }
        pointers.append(nil)
        _ = executable.withCString { path in
            pointers.withUnsafeMutableBufferPointer { buffer in
                execv(path, buffer.baseAddress!)
            }
        }
        pointers.compactMap { $0 }.forEach { free($0) }
        _exit(127)
    }
}

@main
struct FastraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Selbsttest-Läufe bekommen eine isolierte, frisch geleerte
    // UserDefaults-Suite (immer „erster Start" → Demo-Tab vorhanden,
    // echtes Erststart-Flag bleibt unangetastet). Normalbetrieb: .standard.
    @StateObject private var workspace: Workspace
    /// Beobachtbarer Fokuskontext für den formatspezifischen Soft-Wrap-
    /// Menüpunkt, auch bei zusätzlichen Dokumentfenstern.
    @StateObject private var activeDocumentContext = ActiveDocumentContext.shared
    // Rechter Vorschau-Streifen (Minimap) an/aus — geteilt mit EditorView über
    // denselben AppStorage-Schlüssel. Default AUS (siehe EditorView-Kommentar).
    @AppStorage("editor.showMinimap", store: SelfTest.workspaceDefaults()) private var showMinimap = false
    // Globale, persistente UI-Zoomstufe. Die eigentliche Weitergabe an alle
    // SwiftUI-/AppKit-Unteransichten erledigt `fastraScalingRoot()`.
    @AppStorage(UIZoom.defaultsKey, store: SelfTest.workspaceDefaults()) private var uiZoomLevel = 0
    @AppStorage(DocumentZoom.defaultsKey, store: SelfTest.workspaceDefaults()) private var documentZoomLevel = 0
    @AppStorage("markdown.integratedPreview", store: SelfTest.workspaceDefaults()) private var showMarkdownPreview = true
    @AppStorage("editor.sidebarVisible", store: SelfTest.workspaceDefaults()) private var showSidebar = true

    init() {
        FastraProcessGroupLauncher.runIfRequested()
        // Shot-Fixtures müssen vor der ersten EditorView stehen; ein Setzen
        // erst in `runIfRequested` käme nach dem SwiftUI-Fensteraufbau zu spät.
        SelfTest.prepareLaunchEnvironment()
        _workspace = StateObject(wrappedValue: Workspace(
            defaults: SelfTest.workspaceDefaults()
        ))
    }

    var body: some Scene {
        // Das Startfenster bleibt eine einzelne `Window`-Scene. So kann SwiftUI
        // nicht unkontrolliert zwei Fenster mit DEMSELBEN Workspace erzeugen
        // (Fehlerbefund 2026-06-23). Gewollte zusätzliche oder aus der
        // sicheren Fastra-Sitzung restaurierte Fenster entstehen kontrolliert
        // über `DocumentWindowController`; jedes erhält einen EIGENEN Workspace.
        Window("Fastra", id: "main") {
            ContentView()
                .environmentObject(workspace)
                .fastraScalingRoot()
                // Unterhalb dieser Größe wären Tab-Leiste, feste Seitenleiste
                // und Editor nicht mehr gleichzeitig bedienbar.
                .frame(minWidth: MainWindowSizing.minimumWidth,
                       minHeight: MainWindowSizing.minimumHeight)
                .background(Theme.surfaceBase.ignoresSafeArea())
        }
        // Kein sichtbarer nativer Titelbalken: Der eigene Fenster-Chrome darf
        // bis neben die Ampelknöpfe reichen und dort Tabs/Schalter aufnehmen.
        // Die Ampeln bleiben echte AppKit-Controls.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: MainWindowSizing.defaultWidth,
                     height: MainWindowSizing.defaultHeight)
        .commands {
            // SwiftUI ergänzt automatisch ein „Edit"-Menü mit Items wie
            // „Find… (⌘F)" / „Find Next" etc. — diese binden CMD+F an
            // `performTextFinderAction:` und schicken damit den Editor
            // in seine eingebaute Find-Leiste. Wir wollen CMD+F selbst
            // verwalten, also leeren wir die textEditing-Gruppe.
            CommandGroup(replacing: .textEditing) { }

            // Gruppierung: Der Commands-Builder erlaubt höchstens zehn
            // Einträge — thematisch verwandte Gruppen deshalb bündeln.
            Group {
                // Eigener „Über Fastra"-Dialog statt des Standard-About-Panels.
                CommandGroup(replacing: .appInfo) {
                    Button("Über Fastra") { AboutWindow.show() }
                }

                // Hilfe-Menü (Etappe 4 Wunschpaket 2026-07b): ersetzt den
                // Standard-Eintrag durch die mitgelieferte Markdown-Hilfe im
                // eigenen Fenster. ⌘? ist der macOS-Standard-Shortcut.
                CommandGroup(replacing: .help) {
                    Button("Fastra-Hilfe") { HelpWindow.show() }
                    // tool4d-Einrichtungshilfe (Etappe 4 Wunschpaket
                    // 2026-07c): sucht ein installiertes tool4d an den
                    // bekannten Orten — lädt nichts herunter, führt nichts aus.
                    Button("tool4d finden…") { Tool4DAssist.runFinder() }
                        .keyboardShortcut("?", modifiers: .command)
                }
            }

            // Smart-Paste (Alleinstellung, ROADMAP H): formatierter
            // Clipboard-Inhalt wird via md-clip als Markdown eingefügt.
            // Das Ziel wird auf dem Main-Thread eingefroren; nur die langsame
            // Konvertierung dispatcht SmartPaste selbst in den Hintergrund.
            CommandGroup(after: .pasteboard) {
                Button("Formatiert als Markdown einfügen") {
                    if let target = commandWorkspace {
                        SmartPaste.performSmartPaste(into: target)
                    }
                }
                .disabled(commandWorkspace == nil)
                .keyboardShortcut("v", modifiers: [.command, .shift])

                // Etappe 4 (BBEdit „Paste and Match Indentation"): setzt den
                // Clipboard-Block auf die Einrückung der Zielzeile, relative
                // Verschachtelung bleibt erhalten, Ausdruck in Tabs/
                // Leerzeichen des Formatprofils.
                Button("Einfügen und Einrückung angleichen") {
                    guard commandWorkspace != nil else { return }
                    NotificationCenter.default.post(
                        name: .fastraPasteMatchingIndentation,
                        object: nil
                    )
                }
                .disabled(commandWorkspace == nil)
                .keyboardShortcut("v", modifiers: [.command, .shift, .option])

                Divider()
                Button("Spalte einfügen") {
                    guard commandWorkspace != nil else { return }
                    NotificationCenter.default.post(
                        name: .fastraPasteColumn,
                        object: nil
                    )
                }
                .disabled(commandWorkspace == nil)
                .keyboardShortcut("v", modifiers: [.command, .control])
                Button("Rechteckauswahl nach oben") {
                    guard commandWorkspace != nil else { return }
                    NotificationCenter.default.post(
                        name: .fastraSelectColumnUp,
                        object: nil
                    )
                }
                .disabled(commandWorkspace == nil)
                .keyboardShortcut(.upArrow, modifiers: [.control, .shift])
                Button("Rechteckauswahl nach unten") {
                    guard commandWorkspace != nil else { return }
                    NotificationCenter.default.post(
                        name: .fastraSelectColumnDown,
                        object: nil
                    )
                }
                .disabled(commandWorkspace == nil)
                .keyboardShortcut(.downArrow, modifiers: [.control, .shift])
            }

            // Darstellungskommandos in das BESTEHENDE System-
            // „Darstellung"-Menü einhängen (CommandGroup after .sidebar),
            // NICHT als CommandMenu("Darstellung") — das legt ein ZWEITES
            // Menü gleichen Namens daneben (Befund Screenshot 2026-06-11).
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Darstellung vergrößern") {
                    uiZoomLevel = UIZoom.clamped(uiZoomLevel + 1)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(uiZoomLevel >= UIZoom.maximumLevel)
                Button("Darstellung verkleinern") {
                    uiZoomLevel = UIZoom.clamped(uiZoomLevel - 1)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(uiZoomLevel <= UIZoom.minimumLevel)
                Button("Originalgröße") { uiZoomLevel = 0 }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(uiZoomLevel == 0)
                Divider()
                Button("Dokumentschrift vergrößern") { documentZoomLevel = DocumentZoom.clamped(documentZoomLevel + 1) }
                    .keyboardShortcut("+", modifiers: [.command, .shift])
                Button("Dokumentschrift verkleinern") { documentZoomLevel = DocumentZoom.clamped(documentZoomLevel - 1) }
                    .keyboardShortcut("-", modifiers: [.command, .shift])
                Button("Dokumentschrift: Originalgröße") { documentZoomLevel = 0 }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Divider()
                // Ansichts-Umschalter (Etappe 2 Wunschpaket 2026-07): dieselben
                // drei Ansichten wie der Umschalter im Editorbereich, hier mit
                // Shortcuts. ⌃⌘1–3 kollidiert weder mit ⌘1-Tabwechseln noch mit
                // den CodeEdit-Tastatur-Monitoren (die fangen nur ⌘]/⌘[/⌘F ab).
                Button("Ansicht: Text") { commandWorkspace?.setViewMode(.text) }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Ansicht: Vorschau") { commandWorkspace?.setViewMode(.preview) }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Ansicht: Hex") { commandWorkspace?.setViewMode(.hex) }
                    .keyboardShortcut("3", modifiers: [.command, .control])
                Divider()
                // Hauptmenü und Fußzeile schalten denselben Wert des aktuell
                // effektiven Formats. Ohne Dokument bleibt der Zustand stabil
                // und der Eintrag ist nicht bedienbar.
                Button("Soft Wrap") {
                    activeDocumentContext.workspace?.toggleSoftWrap()
                }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(activeDocumentContext.workspace?.activeTab == nil)
                Toggle("Seitenlinie anzeigen", isOn: Binding(
                    get: { commandWorkspace?.showPageGuide ?? false },
                    set: { commandWorkspace?.setShowPageGuide($0) }
                ))
                // Rechter Vorschau-Streifen (Minimap). Default AUS — verdeckte
                // rechts Text und stand im Freeze-Verdacht (Daniel 2026-07-12).
                Toggle("Minimap anzeigen", isOn: $showMinimap)
                Toggle("Seitenleiste anzeigen", isOn: $showSidebar)
                Toggle("Markdown-Vorschau rechts anzeigen", isOn: $showMarkdownPreview)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .newItem) {
                Button("Neues Dokumentfenster") {
                    // Reiner Startzustand (ein Fenster, nur ein unberührter
                    // leerer Tab, kein Projekt): ⌘N legt wie ⌘T einen Tab im
                    // selben Fenster an, statt ein zweites Fenster zu stapeln
                    // (Wunschpaket 2026-07, Etappe 1). Sonst wie gehabt.
                    guard let target = commandWorkspace else {
                        DocumentWindowController.openNewDocument()
                        return
                    }
                    if WelcomeLogic.newWindowCommandOpensTab(
                        tabs: target.tabs,
                        hasProject: target.projectURL != nil,
                        visibleDocumentWindows:
                            DocumentWindowController.visibleDocumentWindowCount()
                    ) {
                        target.openNewTab()
                    } else {
                        DocumentWindowController.openNewDocument()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Neuer Tab") {
                    if let commandWorkspace {
                        commandWorkspace.openNewTab()
                    } else {
                        DocumentWindowController.openNewDocument()
                    }
                }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Datei öffnen…") {
                    DocumentWindowController.workspaceForOpening().openFile()
                }
                    .keyboardShortcut("o", modifiers: .command)
                // Ordner als Projekt öffnen (Projekt- & Git-Ausbau, Etappe 1):
                // lädt den Dateibaum in die Seitenleiste und merkt den Ordner
                // in „Zuletzt benutzte Projekte" (Willkommensbildschirm).
                Button("Ordner öffnen…") {
                    DocumentWindowController.workspaceForOpening().openFolderAsProject()
                }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Terminal im aktuellen Ordner …") {
                    commandWorkspace?.openTerminal()
                }
                .disabled(commandWorkspace?.terminalDirectory == nil)
                .help(commandWorkspace?.terminalDirectory == nil
                      ? (commandWorkspace?.terminalUnavailableReason
                         ?? L10n.string("Kein Dokumentfenster ist aktiv."))
                      : L10n.string("Öffnet Terminal.app nativ im aktuellen Projektordner; ohne Projekt im Ordner der aktiven Datei."))
                // Zuletzt benutzte Dateien (K2). Eigene View mit
                // @ObservedObject, damit das Untermenü auf Änderungen der
                // recentFiles-Liste reagiert.
                RecentFilesMenu(workspace: workspace)
                Divider()
                // BBEdit „Reload from Disk" (Kap. 3 S. 59): aktiven Tab frisch
                // von der Platte laden; bei ungespeicherten Änderungen fragt
                // dieselbe Rückfrage wie die automatische Erkennung.
                Button("Von Festplatte neu laden") { commandWorkspace?.reloadActiveTabFromDisk() }
                // Umwandlung eines erkannten Fremdformats (RTF, DOCX, …) nach
                // Markdown. Eigene View, damit der Punkt der Verfügbarkeit des
                // aktiven Tabs folgt; ohne installiertes „Poor Man's Text"
                // bleibt er still deaktiviert.
                MarkdownImportMenuItem(workspace: workspace)
                Divider()
                Button("Schließen") {
                    // Das Menü bleibt global sichtbar. Ist die Hilfe vorn,
                    // gehört ⌘W aber ihr und darf keinen Hintergrund-Tab
                    // schließen (gleiches Verhalten wie der Event-Monitor).
                    if HelpWindow.isHelpWindow(NSApp.keyWindow) {
                        HelpWindow.close()
                    } else if AboutWindow.isAboutWindow(NSApp.keyWindow) {
                        NSApp.keyWindow?.performClose(nil)
                    } else if SettingsWindowConfiguration.isSettingsWindow(
                        NSApp.keyWindow
                    ) {
                        NSApp.keyWindow?.performClose(nil)
                    } else if let searchWindow = NSApp.keyWindow,
                              SearchWindow.isSearchWindow(searchWindow),
                              let searchWorkspace = WorkspaceWindowRegistry.workspace(
                                  for: searchWindow
                              ) {
                        searchWorkspace.showSearchDialog = false
                    } else if let target = CommandTargeting.targetWorkspace() {
                        // Beim Schließen gibt es bewusst KEINEN Rückfall auf
                        // den Start-Workspace: Ist das Vorderfenster nicht
                        // eindeutig gebunden, ist ein No-op sicherer als ein
                        // geschlossenes Dokumentfenster dahinter.
                        target.closeActiveTab()
                    } else {
                        NSSound.beep()
                    }
                }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Speichern") { commandWorkspace?.saveActiveTab() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Speichern unter…") { commandWorkspace?.saveActiveTabAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Suchen") {
                // CMD+F: Suchen in der aktuellen Datei (kompakter Modus).
                Button("Suchen & Ersetzen…") {
                    guard let commandWorkspace else { return }
                    NotificationCenter.default.post(name: .fastraShowSearchFile,
                                                    object: commandWorkspace)
                }
                .disabled(commandWorkspace == nil)
                .keyboardShortcut("f", modifiers: .command)

                // CMD+SHIFT+F: Suchen in Ordnern (erweiterter Modus).
                // Beim Öffnen wird der Scope auf „Ordner" gesetzt — das
                // Fenster wächst automatisch, falls noch zu klein.
                //
                // Der Menüklick nutzt bewusst die ERZWINGENDE Notification:
                // Der Kurzbefehl ⇧⌘F holt eine bereits befüllte Maske nur nach
                // vorn und behält ihren Bereich, ein ausdrücklich mit „In
                // Ordnern suchen…" beschrifteter Menüpunkt muss dagegen immer
                // die Ordnersuche zeigen (Review 2026-08-06).
                Button("In Ordnern suchen…") {
                    guard let commandWorkspace else { return }
                    NotificationCenter.default.post(name: .fastraShowSearchFolderForced,
                                                    object: commandWorkspace)
                }
                .disabled(commandWorkspace == nil)
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                // „Auswahl als Suchbegriff" (⌘E, BBEdit „Use Selection for
                // Find", K5): selektierten Editor-Text als Suchbegriff
                // übernehmen und die Maske öffnen (sucht NICHT von selbst).
                Button("Auswahl als Suchbegriff") {
                    guard let commandWorkspace else { return }
                    commandWorkspace.useSelectionForFind()
                    commandWorkspace.scope = .file
                    // Der selektierte Text wird zum Suchbegriff → global
                    // danach suchen, nicht innerhalb der Selektion (sonst
                    // fände er nur sich selbst). „Nur in Auswahl" daher aus.
                    commandWorkspace.setSearchInSelectionOnly(false)
                    commandWorkspace.showSearchDialog = true
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Suchen & Ersetzen ausblenden") {
                    commandWorkspace?.showSearchDialog = false
                }
                    .keyboardShortcut(.escape, modifiers: [])

                Divider()

                // XPath-Navigation (Etappe 5 Wunschpaket 2026-07): schwebende
                // Leiste für XML-artige Dokumente. Teilset: /, //, *, [n],
                // [@attr], [@attr='wert'], @attr, text().
                Button("XPath-Navigation…") {
                    guard let commandWorkspace else { return }
                    NotificationCenter.default.post(name: .fastraShowXPathBar,
                                                    object: commandWorkspace)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(commandWorkspace?.activeTabSupportsXPath != true)

                Divider()

                // Datei-Vergleich ohne Git (Etappe 1 Wunschpaket 2026-07c;
                // BBEdit „Find Differences"). ⌃⌘D ist frei — ⌘D wäre mit
                // macOS-Konventionen (Lesezeichen/Duplizieren) belegt.
                Button("Dateien vergleichen…") {
                    commandWorkspace?.presentCompareFilesDialog()
                }
                .keyboardShortcut("d", modifiers: [.command, .control])

                // BBEdit „Compare Against Disk File": ungespeicherten
                // Editor-Inhalt gegen den Plattenstand derselben Datei —
                // ohne Dialog, direkt ins Differenzfenster.
                Button("Mit gespeicherter Fassung vergleichen") {
                    commandWorkspace?.compareActiveTabAgainstDisk()
                }
                .disabled(commandWorkspace?.canCompareActiveTabAgainstDisk != true)
                .help(commandWorkspace?.canCompareActiveTabAgainstDisk == true
                      ? L10n.string("Vergleicht den ungespeicherten Editor-Inhalt mit dem gespeicherten Stand der Datei.")
                      : L10n.string("Nur aktiv, wenn der aktive Tab ungespeicherte Änderungen an einer Datei hat."))
            }

            // „Text"-Menü (BBEdit-Basics, TextOperations). Die Buttons posten
            // `.fastraTextOp` mit der TextOpKind; der AppDelegate wendet sie auf
            // den aktiven Editor an (gleiche Logik wie das Rechtsklick-Submenü).
            // Operieren auf der Selektion bzw. — ohne Selektion — der ganzen Datei.
            CommandMenu("Text") {
                Button("Dokument formatieren") { postDocumentFormatting() }
                    .disabled(commandWorkspace?.activeDocumentFormattingExtension == nil)
                // Etappe 6 (Wunschpaket 2026-07): native JSON-/XML-Prüfung
                // mit Fehlerposition und konservatives Minify — bewusst keine
                // gebündelten Fremd-Linter (JS/CSS/HTML bleiben außen vor).
                Button("Dokument prüfen") {
                    guard commandWorkspace != nil else { return }
                    NotificationCenter.default.post(name: .fastraLintDocument,
                                                    object: nil)
                }
                .disabled(!DocumentLinter.supports(fileExtension: commandWorkspace?.activeTab?.url?.pathExtension
                    ?? (commandWorkspace?.activeTab?.title as NSString?)?.pathExtension))
                Button("Dokument minifizieren") {
                    guard commandWorkspace != nil else { return }
                    NotificationCenter.default.post(name: .fastraMinifyDocument,
                                                    object: nil)
                }
                .disabled(commandWorkspace?.activeDocumentFormattingExtension == nil)
                Divider()
                Button(TextOpKind.uppercase.title)  { postTextOp(.uppercase) }
                Button(TextOpKind.lowercase.title)  { postTextOp(.lowercase) }
                Button(TextOpKind.titlecase.title)  { postTextOp(.titlecase) }
                Divider()
                Button(TextOpKind.trimTrailing.title) { postTextOp(.trimTrailing) }
                Button(TextOpKind.detab.title)        { postTextOp(.detab) }
                Button(TextOpKind.entab.title)        { postTextOp(.entab) }
                Divider()
                // Texthygiene (BBEdit „Zap Gremlins" / „Straighten Quotes") —
                // Steuerzeichen und geschwungene Anführungszeichen aus Logs/
                // Exporten bereinigen, bevor man sucht/ersetzt.
                Button(TextOpKind.zapGremlins.title)      { postTextOp(.zapGremlins) }
                Button(TextOpKind.straightenQuotes.title) { postTextOp(.straightenQuotes) }
                Button(TextOpKind.educateQuotes.title)    { postTextOp(.educateQuotes) }
                // BBEdit „Convert Escape Sequences": \n/\xNN/\uNNNN/HTML-Entities/
                // %NN in echte Zeichen auflösen — Texthygiene für Logs/Exporte.
                Button(TextOpKind.convertEscapeSequences.title) { postTextOp(.convertEscapeSequences) }
                Divider()
                // Kein ⌘]/⌘[ als Kürzel: CodeEditTextView installiert einen
                // eigenen keyDown-Monitor (wie bei CMD+F), der diese Kombis
                // abfängt, bevor das SwiftUI-Command greift — der Shortcut wäre
                // also tot/irreführend. Auslösung daher nur per Menü-Klick.
                Button(TextOpKind.shiftRight.title) { postTextOp(.shiftRight) }
                Button(TextOpKind.shiftLeft.title)  { postTextOp(.shiftLeft) }
                Divider()
                Button(TextOpKind.reverseLines.title)     { postTextOp(.reverseLines) }
                Button(TextOpKind.removeBlankLines.title) { postTextOp(.removeBlankLines) }
                Button(LineOperations.SortDirection.ascending.title) {
                    postLineSort(.ascending)
                }
                Button(LineOperations.SortDirection.descending.title) {
                    postLineSort(.descending)
                }
                Button(TextOpKind.joinLines.title)        { postTextOp(.joinLines) }
                Button(TextOpKind.joinLinesTight.title)   { postTextOp(.joinLinesTight) }
                Button(TextOpKind.prefixLines.title)      { postTextOp(.prefixLines) }
                Button(TextOpKind.suffixLines.title)      { postTextOp(.suffixLines) }
                // Zeilennummern (BBEdit „Add/Remove Line Numbers") — rechtsbündig,
                // ein Trenner-Leerzeichen; Entfernen strippt die führende Nummer.
                Button(TextOpKind.addLineNumbers.title)    { postTextOp(.addLineNumbers) }
                Button(TextOpKind.removeLineNumbers.title) { postTextOp(.removeLineNumbers) }
                Divider()
                // Zeichen-/Wörter-Tauschen (BBEdit „Exchange Characters/Words") —
                // wirkt am Cursor bzw. an den Selektions-Enden.
                Button(TextOpKind.exchangeCharacters.title) { postTextOp(.exchangeCharacters) }
                Button(TextOpKind.exchangeWords.title)      { postTextOp(.exchangeWords) }
                Divider()
                // Zeilen-Verarbeitung (BBEdit „Process Lines Containing" / „Process
                // Duplicate Lines"): nach RegEx-Muster filtern bzw. Dubletten
                // finden/entfernen — die RegEx-nahen Werkzeuge im „Text"-Menü.
                Button(TextOpKind.keepLinesMatching.title)        { postTextOp(.keepLinesMatching) }
                Button(TextOpKind.deleteLinesMatching.title)      { postTextOp(.deleteLinesMatching) }
                Button(TextOpKind.keepDuplicateLines.title)       { postTextOp(.keepDuplicateLines) }
                Button(TextOpKind.removeAllDuplicatedLines.title) { postTextOp(.removeAllDuplicatedLines) }
                Divider()
                // BBEdit „Hard Wrap": jede Zeile an Wortgrenzen auf eine feste
                // Spaltenbreite umbrechen (Gegenstück zu „Zeilen verbinden").
                Button(TextOpKind.hardWrap.title) { postTextOp(.hardWrap) }
                Divider()
                // Unicode-Gruppe (BBEdit Kap. 5 S. 156): Leerzeichen-Varianten
                // vereinheitlichen, Diakritika entfernen, NFC/NFD-Normalisierung.
                Button(TextOpKind.normalizeSpaces.title)   { postTextOp(.normalizeSpaces) }
                Button(TextOpKind.stripDiacriticals.title) { postTextOp(.stripDiacriticals) }
                Button(TextOpKind.precomposeUnicode.title) { postTextOp(.precomposeUnicode) }
                Button(TextOpKind.decomposeUnicode.title)  { postTextOp(.decomposeUnicode) }
                // Emoji-Darstellung (Daniel-Befund 2026-07-27): Zeichen wie ⏸
                // sind laut Unicode Textzeichen und werden erst mit dem
                // Variantenselektor U+FE0F überall farbig gezeigt.
                Button(TextOpKind.addEmojiPresentation.title) {
                    postTextOp(.addEmojiPresentation)
                }
                Button(TextOpKind.removeEmojiPresentation.title) {
                    postTextOp(.removeEmojiPresentation)
                }
                Divider()
                // 4D-Export-Transformation (Etappe 6 Wunschpaket 2026-07c):
                // Token-Suffixe kanonischer Exporte strippen bzw. Befehls-
                // Token ergänzen (Konstanten-Nummern kennt keine öffentliche
                // Quelle — der Titel sagt ehrlich „Befehls-Token").
                Button(TextOpKind.fourDDetokenize.title)       { postTextOp(.fourDDetokenize) }
                Button(TextOpKind.fourDTokenizeCommands.title) { postTextOp(.fourDTokenizeCommands) }
            }

            // „Markdown"-Menü (Etappe 5 Wunschpaket 2026-07b):
            // Formatierungsbefehle auf den QUELLTEXT, nur für Markdown-Tabs
            // aktiv. Dieselben Befehle liegen in der Editor-Toolbar und im
            // Rechtsklickmenü; hier tragen sie die Tastenkürzel.
            CommandMenu("Markdown") {
                Group {
                    markdownFormatButton(.bold)
                    markdownFormatButton(.italic)
                    markdownFormatButton(.highlight)
                    markdownFormatButton(.code)
                    markdownFormatButton(.hardBreak)
                    Divider()
                    markdownFormatButton(.heading1)
                    markdownFormatButton(.heading2)
                    markdownFormatButton(.heading3)
                    markdownFormatButton(.plainParagraph)
                }
                .disabled(!activeTabIsMarkdown)
                Group {
                    Divider()
                    markdownFormatButton(.bulletList)
                    markdownFormatButton(.orderedList)
                    markdownFormatButton(.quote)
                    Divider()
                    markdownFormatButton(.link)
                    markdownFormatButton(.insertTable)
                }
                .disabled(!activeTabIsMarkdown)
            }

            // „Git"-Menü (Projekt- & Git-Ausbau, Etappe 2). Dieselben kuratierten
            // Aktionen wie das Popup in der Branch-Zeile (GitActionMenu), plus
            // Verlauf/Diff öffnen. Nur aktiv, wenn ein Git-Projekt offen ist —
            // ohne Projekt/git bleibt das Menü sichtbar, aber gedimmt.
            CommandMenu("Git") {
                Button("Verlauf anzeigen") { commandWorkspace?.openGitLog() }
                Button("Änderungen anzeigen (Diff)") { commandWorkspace?.openGitDiff() }
                Divider()
                if let commandWorkspace {
                    GitActionMenu(workspace: commandWorkspace)
                } else {
                    Button("Kein Dokumentfenster aktiv") { }.disabled(true)
                }
            }
        }

        // Einstellungs-Dialog (⌘,). SwiftUI bindet die Settings-Scene automatisch
        // an ⌘, und legt den Menüpunkt „Einstellungen…" unter dem App-Menü an.
        Settings {
            SettingsView()
                .fastraScalingRoot()
        }
    }

    /// Ziel der dokumentbezogenen globalen Menübefehle. Bei einem vorderen
    /// Hilfsfenster gibt es absichtlich keinen Rückfall auf ein Dokument im
    /// Hintergrund; Befehle sind dann deaktiviert oder ein sicherer No-op.
    private var commandWorkspace: Workspace? {
        CommandTargeting.targetWorkspace()
    }

    /// Schickt eine Text-Operation an den AppDelegate (→ aktiver Editor).
    /// `object` = `rawValue`, damit der Enum-Wert verlustfrei durch die
    /// Notification kommt (siehe `.fastraTextOp`).
    private func postTextOp(_ kind: TextOpKind) {
        guard commandWorkspace != nil else { return }
        NotificationCenter.default.post(name: .fastraTextOp, object: kind.rawValue)
    }

    private func postLineSort(_ direction: LineOperations.SortDirection) {
        guard commandWorkspace != nil else { return }
        NotificationCenter.default.post(name: .fastraSortLines,
                                        object: direction.rawValue)
    }

    /// Markdown-Formatbefehl an den AppDelegate (Etappe 5 Wunschpaket 2026-07b).
    private func postMarkdownFormat(_ command: MarkdownFormatCommand) {
        guard commandWorkspace != nil else { return }
        NotificationCenter.default.post(name: .fastraMarkdownFormat,
                                        object: command.rawValue)
    }

    /// Menüpunkt eines Markdown-Befehls. Das Tastenkürzel kommt aus der
    /// puren Beschreibung in `MarkdownEditing.swift` — derselben Quelle, die
    /// auch die Toolbar-Tooltips beschriftet. So können Menü und Tooltip
    /// nicht auseinanderlaufen.
    @ViewBuilder
    private func markdownFormatButton(_ command: MarkdownFormatCommand) -> some View {
        let button = Button(command.menuTitle) { postMarkdownFormat(command) }
        if let shortcut = command.shortcut {
            button.keyboardShortcut(
                KeyEquivalent(shortcut.key),
                modifiers: EventModifiers([.command])
                    .union(shortcut.shift ? [.shift] : [])
                    .union(shortcut.option ? [.option] : [])
            )
        } else {
            button
        }
    }

    /// Aktiver Tab ist ein Markdown-Dokument? Steuert das „Markdown“-Menü.
    private var activeTabIsMarkdown: Bool {
        commandWorkspace?.activeTabIsMarkdown == true
    }

    private func postDocumentFormatting() {
        guard commandWorkspace != nil else { return }
        NotificationCenter.default.post(name: .fastraFormatDocument, object: nil)
    }
}

/// Untermenü „Zuletzt benutzt" (K2). Eigene View mit `@ObservedObject`, damit
/// SwiftUI das Menü neu aufbaut, sobald sich `recentFiles` ändert (eine
/// einfache Closure im CommandGroup würde nicht auf Änderungen reagieren).
/// „In Markdown umwandeln…" für den aktiven Tab.
///
/// Der Punkt bleibt immer sichtbar, ist aber nur aktiv, wenn das externe
/// Werkzeug das Format des aktiven Tabs gerade wirklich umwandeln kann. Ein
/// verschwindender Menüpunkt wäre schwerer zu verstehen als ein grauer.
private struct MarkdownImportMenuItem: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var service = MarkdownImportService.shared

    var body: some View {
        Button("In Markdown umwandeln…") {
            commandWorkspace?.convertActiveTabToMarkdown()
        }
        .disabled(commandWorkspace?.activeMarkdownImportSource == nil || isBusy)
    }

    private var commandWorkspace: Workspace? {
        CommandTargeting.targetWorkspace()
    }

    /// Während einer laufenden Umwandlung ist der Punkt gesperrt — zwei
    /// gleichzeitige Läufe könnten denselben freien Zielnamen wählen.
    private var isBusy: Bool {
        if case .running = service.state { return true }
        return false
    }
}

private struct RecentFilesMenu: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Menu("Zuletzt benutzt") {
            if workspace.recentFiles.isEmpty {
                Button("(keine)") { }.disabled(true)
            } else {
                ForEach(workspace.recentFiles, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        let expanded = (path as NSString).expandingTildeInPath
                        commandWorkspace?.loadFile(
                            at: URL(fileURLWithPath: expanded)
                        )
                    }
                }
                Divider()
                Button("Einträge löschen") { workspace.recentFiles = [] }
            }
        }
        .disabled(commandWorkspace == nil)
    }

    private var commandWorkspace: Workspace? {
        CommandTargeting.targetWorkspace()
    }
}
