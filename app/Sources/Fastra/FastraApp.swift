import SwiftUI
import AppKit

@main
struct FastraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Selbsttest-Läufe bekommen eine isolierte, frisch geleerte
    // UserDefaults-Suite (immer „erster Start" → Demo-Tab vorhanden,
    // echtes Erststart-Flag bleibt unangetastet). Normalbetrieb: .standard.
    @StateObject private var workspace = Workspace(defaults: SelfTest.workspaceDefaults())
    // Controller des Markdown-Vorschau-Fensters (v0.8). Lebt hier, damit
    // der Menüpunkt ihn erreicht; @State hält die Instanz über
    // Re-Render hinweg stabil.
    @State private var markdownPreview = MarkdownPreviewController()
    // Zeilenumbruch am Fensterrand — app-weite, persistente Einstellung,
    // geteilt mit EditorView über denselben AppStorage-Schlüssel. Default AN.
    @AppStorage("editor.wrapLines") private var wrapLines = true

    var body: some Scene {
        // Das Startfenster bleibt eine einzelne `Window`-Scene. So kann SwiftUI
        // nicht unkontrolliert zwei Fenster mit DEMSELBEN Workspace restaurieren
        // (Daniel-Befund 2026-06-23). Gewollte zusätzliche Fenster erzeugt ⌘N
        // kontrolliert über `DocumentWindowController`; jedes erhält einen
        // EIGENEN Workspace und damit ein unabhängiges neues Dokument.
        Window("Fastra", id: "main") {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 1100, minHeight: 720)
                .background(Theme.surfaceBase.ignoresSafeArea())
        }
        // Die native Titelzeile zeigt den aktiven Dateinamen. Zusammen mit
        // `NSWindow.representedURL` liefert AppKit außerdem automatisch das
        // hierarchische Pfadmenü beim Command-Klick auf Titel oder Datei-Icon.
        .commands {
            // SwiftUI ergänzt automatisch ein „Edit"-Menü mit Items wie
            // „Find… (⌘F)" / „Find Next" etc. — diese binden CMD+F an
            // `performTextFinderAction:` und schicken damit den Editor
            // in seine eingebaute Find-Leiste. Wir wollen CMD+F selbst
            // verwalten, also leeren wir die textEditing-Gruppe.
            CommandGroup(replacing: .textEditing) { }

            // Eigener „Über Fastra"-Dialog statt des Standard-About-Panels.
            CommandGroup(replacing: .appInfo) {
                Button("Über Fastra") { AboutWindow.show() }
            }

            // Smart-Paste (Alleinstellung, ROADMAP H): formatierter
            // Clipboard-Inhalt wird via md-clip als Markdown eingefügt.
            // Synchron-blockierende Konvertierung → Hintergrund-Queue;
            // UI-Arbeit dispatcht performSmartPaste intern auf Main.
            CommandGroup(after: .pasteboard) {
                Button("Formatiert als Markdown einfügen") {
                    let target = commandWorkspace
                    DispatchQueue.global(qos: .userInitiated).async {
                        SmartPaste.performSmartPaste(into: target)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            // Markdown-Vorschau (ROADMAP H): separates Read-only-Fenster,
            // folgt dem aktiven Tab. WICHTIG: in das BESTEHENDE System-
            // „Darstellung"-Menü einhängen (CommandGroup after .sidebar),
            // NICHT als CommandMenu("Darstellung") — das legt ein ZWEITES
            // Menü gleichen Namens daneben (Befund Screenshot 2026-06-11).
            CommandGroup(after: .sidebar) {
                Divider()
                // Zeilenumbruch am Fensterrand (BBEdit „Soft Wrap Text").
                // Toggle in den Commands → checkbarer Menüpunkt im „Darstellung".
                Toggle("Zeilen umbrechen", isOn: $wrapLines)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Markdown-Vorschau ein-/ausblenden") {
                    markdownPreview.toggle(for: commandWorkspace)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .newItem) {
                Button("Neues Dokumentfenster") {
                    DocumentWindowController.openNewDocument()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Neuer Tab") { commandWorkspace.openNewTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Datei öffnen…") { commandWorkspace.openFile() }
                    .keyboardShortcut("o", modifiers: .command)
                // Zuletzt benutzte Dateien (K2). Eigene View mit
                // @ObservedObject, damit das Untermenü auf Änderungen der
                // recentFiles-Liste reagiert.
                RecentFilesMenu(workspace: workspace)
                Divider()
                // BBEdit „Reload from Disk" (Kap. 3 S. 59): aktiven Tab frisch
                // von der Platte laden; bei ungespeicherten Änderungen fragt
                // dieselbe Rückfrage wie die automatische Erkennung.
                Button("Von Festplatte neu laden") { commandWorkspace.reloadActiveTabFromDisk() }
                Divider()
                Button("Schließen") { commandWorkspace.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Speichern") { commandWorkspace.saveActiveTab() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Speichern unter…") { commandWorkspace.saveActiveTabAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Suchen") {
                // CMD+F: Suchen in der aktuellen Datei (kompakter Modus).
                Button("Suchen & Ersetzen…") {
                    commandWorkspace.scope = .file
                    commandWorkspace.showSearchDialog = true
                }
                .keyboardShortcut("f", modifiers: .command)

                // CMD+SHIFT+F: Suchen in Ordnern (erweiterter Modus).
                // Beim Öffnen wird der Scope auf „Ordner" gesetzt — das
                // Fenster wächst automatisch, falls noch zu klein.
                Button("In Ordnern suchen…") {
                    commandWorkspace.scope = .folder
                    commandWorkspace.showSearchDialog = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                // „Auswahl als Suchbegriff" (⌘E, BBEdit „Use Selection for
                // Find", K5): selektierten Editor-Text als Suchbegriff
                // übernehmen und die Maske öffnen (sucht NICHT von selbst).
                Button("Auswahl als Suchbegriff") {
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
                    commandWorkspace.showSearchDialog = false
                }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            // „Text"-Menü (BBEdit-Basics, TextOperations). Die Buttons posten
            // `.fastraTextOp` mit der TextOpKind; der AppDelegate wendet sie auf
            // den aktiven Editor an (gleiche Logik wie das Rechtsklick-Submenü).
            // Operieren auf der Selektion bzw. — ohne Selektion — der ganzen Datei.
            CommandMenu("Text") {
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
            }
        }

        // Einstellungs-Dialog (⌘,). SwiftUI bindet die Settings-Scene automatisch
        // an ⌘, und legt den Menüpunkt „Einstellungen…" unter dem App-Menü an.
        Settings {
            SettingsView()
        }
    }

    /// Ziel aller globalen Menübefehle. Das `@StateObject` gehört nur zum
    /// Startfenster; bei einem per ⌘N geöffneten Fenster zeigt `shared` auf
    /// dessen Workspace (gesetzt von der Fenster-Aktivierungsbrücke).
    private var commandWorkspace: Workspace {
        Workspace.shared ?? workspace
    }

    /// Schickt eine Text-Operation an den AppDelegate (→ aktiver Editor).
    /// `object` = `rawValue`, damit der Enum-Wert verlustfrei durch die
    /// Notification kommt (siehe `.fastraTextOp`).
    private func postTextOp(_ kind: TextOpKind) {
        NotificationCenter.default.post(name: .fastraTextOp, object: kind.rawValue)
    }
}

/// Untermenü „Zuletzt benutzt" (K2). Eigene View mit `@ObservedObject`, damit
/// SwiftUI das Menü neu aufbaut, sobald sich `recentFiles` ändert (eine
/// einfache Closure im CommandGroup würde nicht auf Änderungen reagieren).
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
                        (Workspace.shared ?? workspace).loadFile(
                            at: URL(fileURLWithPath: expanded)
                        )
                    }
                }
                Divider()
                Button("Einträge löschen") { workspace.recentFiles = [] }
            }
        }
    }
}
