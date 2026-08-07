// MarkdownAssist.swift
//
// Anwendungsschicht des assistierten Markdown-Schreibens (Etappe 5
// Wunschpaket 2026-07b): wendet die puren Formatierungsbefehle
// (`MarkdownFormat`) Undo-fähig auf den Editor an, fügt Bilder aus
// Pasteboard und Drag-and-drop ein und meldet der Vorschau die
// Einfügestelle. Die Bild-Ablage selbst (Namen, Dedup, Atomarität)
// liegt in `MarkdownImageStore`.

import AppKit
import CodeEditTextView
import UniformTypeIdentifiers

extension Notification.Name {
    /// Menüleiste/Toolbar → Formatbefehl (`object` = `MarkdownFormatCommand.rawValue`).
    static let fastraMarkdownFormat = Notification.Name("fastra.markdown.format")
    /// Editor → Vorschau: zur Quellzeile scrollen (`object` = 1-basierte Zeile).
    static let fastraMarkdownRevealSourceLine = Notification.Name("fastra.markdown.reveal.line")
    /// Erste Nutzung von Toolbar/Bild-Einfügen → dezenter Hilfe-Hinweis.
    static let fastraMarkdownAssistUsed = Notification.Name("fastra.markdown.assist.used")
}

/// Sammelt asynchron geladene Drop-URLs auf dem Main-Thread und ruft die
/// Completion genau EINMAL, sobald alle Provider geantwortet haben —
/// so bleibt die Einfüge-Reihenfolge stabil und es gibt kein Data-Race.
@MainActor
final class DroppedURLCollector {
    private var urls: [URL] = []
    private var remaining: Int
    private let completion: ([URL]) -> Void

    init(expected: Int, completion: @escaping ([URL]) -> Void) {
        remaining = max(1, expected)
        self.completion = completion
    }

    func add(_ url: URL?) {
        if let url { urls.append(url) }
        remaining -= 1
        if remaining == 0 { completion(urls) }
    }
}

@MainActor
enum MarkdownAssist {

    /// Ist der aktive Tab des Workspace ein Markdown-Dokument? Entscheidend
    /// ist das effektive Format aus der Fußzeile, nicht die Dateiendung.
    static func isMarkdownTabActive(in workspace: Workspace?) -> Bool {
        workspace?.activeTabIsMarkdown ?? false
    }

    // MARK: - Formatbefehle

    /// Wendet einen Formatbefehl auf die TextView an — als normaler
    /// Undo-Schritt über `replaceCharacters` (nie über das SwiftUI-Binding).
    static func applyFormat(_ command: MarkdownFormatCommand, on textView: TextView) {
        switch command {
        case .insertTable:
            guard let configuration = promptForTable() else { return }
            let edit = MarkdownFormat.insertTable(
                textView.string, selection: textView.selectedRange(),
                columns: configuration.columns, header: configuration.header
            )
            perform(edit, on: textView)
        default:
            guard let edit = MarkdownFormat.edit(for: command,
                                                 text: textView.string,
                                                 selection: textView.selectedRange())
            else { return }
            perform(edit, on: textView)
        }
        noteFirstUse()
    }

    private static func perform(_ edit: MarkdownFormat.Edit, on textView: TextView) {
        textView.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.selectionManager.setSelectedRange(edit.selection)
    }

    /// Kleiner Dialog für „Tabelle einfügen…“: Spaltenzahl + Kopfzeile.
    private static func promptForTable() -> (columns: Int, header: Bool)? {
        let alert = NSAlert()
        alert.messageText = L10n.string("Tabelle einfügen")
        alert.informativeText = L10n.string("Anzahl der Spalten:")
        alert.addButton(withTitle: L10n.string("Einfügen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        let field = NSTextField(string: "3")
        field.frame = NSRect(x: 0, y: 28, width: 200, height: 24)
        let checkbox = NSButton(checkboxWithTitle: L10n.string("Mit Kopfzeile"),
                                target: nil, action: nil)
        checkbox.state = .on
        checkbox.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 54))
        accessory.addSubview(field)
        accessory.addSubview(checkbox)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let columns = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              (1...50).contains(columns) else {
            NSSound.beep()
            return nil
        }
        return (columns, checkbox.state == .on)
    }

    // MARK: - Bild einfügen (Paste)

    /// ⌘V-Interception: Enthält das Pasteboard Bilddaten oder Bilddateien
    /// und ist ein Markdown-Editor fokussiert, wird das Bild als Datei
    /// abgelegt und relativ verlinkt. Rückgabe `true` = Event verbraucht.
    ///
    /// Reihenfolge (bewusst definiert, siehe Spez „Bilddaten haben
    /// Vorrang“): 1. Bild-DATEIEN vom Pasteboard (Finder-Kopie) →
    /// kopieren + verlinken; 2. rohe BILDDATEN → Datei anlegen; 3. sonst
    /// normales Einfügen (Event läuft weiter; ⌘⇧V bleibt die explizite
    /// Rich-Text-Konvertierung via SmartPaste).
    static func handlePasteCommand() -> Bool {
        guard let workspace = Workspace.shared,
              isMarkdownTabActive(in: workspace),
              let keyWindow = NSApp.keyWindow,
              !SearchWindow.isSearchWindow(keyWindow),
              let textView = keyWindow.firstResponder as? TextView else { return false }

        let pasteboard = NSPasteboard.general
        // 1. Bild-Dateien (Finder-Kopie).
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            let images = urls.filter {
                MarkdownImageStore.insertableImageExtensions.contains($0.pathExtension.lowercased())
            }
            guard !images.isEmpty else { return false }
            insertImageFiles(images, workspace: workspace, textView: textView)
            return true
        }
        // 2. Rohe Bilddaten.
        guard let (data, type) = readImageData(from: pasteboard) else { return false }
        insertImageData(data, typeIdentifier: type,
                        workspace: workspace, textView: textView)
        return true
    }

    /// Bilddaten vom Pasteboard, bevorzugt verlustfreie/deklarierte Typen.
    private static func readImageData(from pasteboard: NSPasteboard) -> (Data, String)? {
        let candidates: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType(UTType.png.identifier),
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            .tiff,
        ]
        for type in candidates {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return (data, type.rawValue)
            }
        }
        return nil
    }

    // MARK: - Bild einfügen (Drop)

    /// Drop im Markdown-Editorbereich: Bilddateien werden EINGEFÜGT, alle
    /// anderen Dateien behalten das bestehende Verhalten „öffnen“ (klare
    /// Abgrenzung; außerhalb des Markdown-Editors gilt weiter der
    /// Fenster-Drop in ContentView). Rückgabe `true`, wenn irgendetwas
    /// verarbeitet wurde.
    @discardableResult
    static func handleDroppedFileURLs(_ urls: [URL], workspace: Workspace) -> Bool {
        guard !urls.isEmpty else { return false }
        let partition = MarkdownImageStore.partitionDroppedURLs(urls)
        // Nicht-Bilder: bestehender „öffnen“-Pfad (Dateien → Tabs,
        // Ordner → Projekt) — derselbe wie beim Fenster-Drop.
        let openables = DropHandling.openableItems(from: partition.open)
        func openRemaining() {
            for url in openables {
                workspace.openFileOrFolder(at: url)
            }
        }
        // Das Öffnen macht einen ANDEREN Tab aktiv. Seit die Bild-Ablage im
        // Hintergrund läuft, muss es deshalb warten, bis der Link wirklich im
        // Markdown-Dokument steht: Sonst ist beim Abschluss der Ablage längst
        // die mitgezogene Textdatei aktiv, und `finishImageInsertion` verwirft
        // den Link, weil er sonst im fremden Text landen würde. Das Bild lag
        // dann kopiert im `images`-Ordner, ohne dass es jemand verlinkt hatte
        // (Regression aus 1.63.1, gefunden vom `mdassist`-Selbsttest).
        if !partition.insert.isEmpty, let textView = editorTextView(for: workspace) {
            insertImageFiles(partition.insert, workspace: workspace,
                             textView: textView, completion: openRemaining)
        } else {
            openRemaining()
        }
        return !(partition.insert.isEmpty && partition.open.isEmpty)
    }

    /// Browser-Drop ohne lokale Datei (Bilddaten) — verhält sich wie Paste.
    static func handleDroppedImageData(_ data: Data, typeIdentifier: String,
                                       workspace: Workspace) {
        guard let textView = editorTextView(for: workspace) else { return }
        insertImageData(data, typeIdentifier: typeIdentifier,
                        workspace: workspace, textView: textView)
    }

    // MARK: - Gemeinsame Einfüge-Pfade

    /// `completion` läuft auf dem Main-Thread, sobald die Ablage abgeschlossen
    /// ist — auch dann, wenn gar nicht eingefügt werden konnte. Der Drop-Pfad
    /// hängt daran das Öffnen der übrigen Dateien.
    private static func insertImageFiles(_ urls: [URL], workspace: Workspace,
                                         textView: TextView,
                                         completion: (() -> Void)? = nil) {
        guard let documentURL = savedDocumentURL(workspace) else {
            completion?()
            return
        }
        // Ablegen heißt kopieren und im Kollisionsfall bis zu 9 999 Mal ganze
        // Dateien byteweise vergleichen. Das lief bisher auf dem Main-Thread:
        // Ein großes Bild oder viele gleichnamige Kandidaten froren die
        // Oberfläche beim Ablegen sichtbar ein (Review 2026-08-06). Das
        // Datei-I/O läuft deshalb im Hintergrund, das Einfügen wieder auf dem
        // Main-Thread.
        //
        // `Task` statt `DispatchQueue`: Der äußere Task erbt den Main-Actor und
        // darf Workspace und TextView deshalb weiterreichen. Nur der abgetrennte
        // innere Task verlässt den Main-Thread — und der bekommt ausschließlich
        // Werte, die gefahrlos zwischen Threads wandern (Dateiadressen).
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                storeImageFiles(urls, documentURL: documentURL)
            }.value
            finishImageInsertion(outcome, documentURL: documentURL,
                                 workspace: workspace, textView: textView)
            completion?()
        }
    }

    /// Legt alle Bilddateien ab und sammelt Links und Fehlertexte ein.
    ///
    /// Bewusst `nonisolated` und ohne UI: So ist sichtbar, dass dieser Teil
    /// abseits des Main-Threads laufen darf, und er lässt sich ohne Fenster
    /// testen.
    nonisolated static func storeImageFiles(_ urls: [URL], documentURL: URL)
    -> (links: [String], failures: [String]) {
        var links: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                let stored = try MarkdownImageStore.storeImageFile(url, documentURL: documentURL)
                links.append(stored.link)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return (links, failures)
    }

    /// Zweiter Halbschritt auf dem Main-Thread: meldet Fehler und fügt die
    /// fertigen Links ein.
    ///
    /// Zwischen Ablage und Einfügen kann der Nutzer den Tab gewechselt oder
    /// das Fenster geschlossen haben. Deshalb erst prüfen, ob noch dasselbe
    /// Dokument aktiv ist und sein Editor noch in einem Fenster hängt — sonst
    /// landete der Link in einem fremden Text. Die abgelegten Bilddateien
    /// bleiben in beiden Fällen erhalten.
    private static func finishImageInsertion(
        _ outcome: (links: [String], failures: [String]),
        documentURL: URL, workspace: Workspace, textView: TextView
    ) {
        for message in outcome.failures {
            NSAlert.runWarning(title: L10n.string("Bild konnte nicht übernommen werden"),
                               text: message)
        }
        guard !outcome.links.isEmpty,
              workspace.activeTab?.url == documentURL else { return }
        let target = textView.window != nil ? textView : editorTextView(for: workspace)
        guard let target else { return }
        insertLinks(outcome.links, into: target, workspace: workspace)
    }

    private static func insertImageData(_ data: Data, typeIdentifier: String,
                                        workspace: Workspace, textView: TextView) {
        guard let documentURL = savedDocumentURL(workspace) else { return }
        guard let prepared = MarkdownImageStore.prepare(imageData: data,
                                                        typeIdentifier: typeIdentifier) else {
            NSAlert.runWarning(title: L10n.string("Bild konnte nicht übernommen werden"),
                               text: MarkdownImageStore.StoreError.unreadableImage.localizedDescription)
            return
        }
        do {
            let stored = try MarkdownImageStore.storePastedData(prepared,
                                                                documentURL: documentURL)
            insertLinks([stored.link], into: textView, workspace: workspace)
        } catch {
            NSAlert.runWarning(title: L10n.string("Bild konnte nicht übernommen werden"),
                               text: error.localizedDescription)
        }
    }

    /// Ohne Speicherort keine Bild-Ablage: verständliche Meldung statt
    /// stillem Fallback (Spez Punkt 4).
    private static func savedDocumentURL(_ workspace: Workspace) -> URL? {
        if let url = workspace.activeTab?.url { return url }
        NSAlert.runWarning(
            title: L10n.string("Erst speichern"),
            text: MarkdownImageStore.StoreError.documentNotSaved.localizedDescription
        )
        return nil
    }

    /// Fügt die Links an der Cursorposition ein (mehrere zeilenweise),
    /// setzt den Cursor dahinter und meldet der Vorschau die Einfügezeile.
    private static func insertLinks(_ links: [String], into textView: TextView,
                                    workspace: Workspace) {
        guard !links.isEmpty else { return }
        let selection = textView.selectedRange()
        let insertion = links.joined(separator: "\n")
        textView.replaceCharacters(in: selection, with: insertion)
        let caret = selection.location + (insertion as NSString).length
        textView.selectionManager.setSelectedRange(NSRange(location: caret, length: 0))
        revealInPreview(textView: textView, characterLocation: selection.location,
                        workspace: workspace)
        noteFirstUse()
    }

    /// Meldet der integrierten Vorschau DIESES Workspace die 1-basierte
    /// Quellzeile der Einfügestelle (`data-srcline`-Mechanik rückwärts).
    static func revealInPreview(textView: TextView, characterLocation: Int,
                                workspace: Workspace) {
        let ns = textView.string as NSString
        let clamped = min(max(0, characterLocation), ns.length)
        let prefix = ns.substring(to: clamped)
        let line = prefix.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        NotificationCenter.default.post(name: .fastraMarkdownRevealSourceLine,
                                        object: workspace,
                                        userInfo: ["line": line])
    }

    // MARK: - Erst-Nutzungs-Hinweis

    static let firstUseDefaultsKey = "markdown.assistHintShown"

    /// Beim ersten Format- oder Bild-Einfügen einen dezenten Hinweis
    /// auslösen (EditorView zeigt ihn nicht-modal an).
    private static func noteFirstUse() {
        guard !UserDefaults.standard.bool(forKey: firstUseDefaultsKey) else { return }
        NotificationCenter.default.post(name: .fastraMarkdownAssistUsed, object: nil)
    }

    // MARK: - TextView-Suche

    /// Editor-TextView des Workspace-Fensters (gleiche Heuristik wie
    /// `EditorView.firstEditorTextView`, hier über den Fenster-Registry-Weg).
    static func editorTextView(for workspace: Workspace) -> TextView? {
        for window in NSApp.windows where window.isVisible {
            guard !SearchWindow.isSearchWindow(window),
                  WorkspaceWindowRegistry.workspace(for: window) === workspace,
                  let content = window.contentView else { continue }
            if let textView = descendantTextView(in: content) { return textView }
        }
        return nil
    }

    private static func descendantTextView(in view: NSView) -> TextView? {
        if let tv = view as? TextView { return tv }
        for sub in view.subviews {
            if let found = descendantTextView(in: sub) { return found }
        }
        return nil
    }
}
