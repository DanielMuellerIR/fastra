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

@MainActor
enum MarkdownAssist {
    struct ImageStoreOutcome: Sendable {
        let storedImages: [MarkdownImageStore.StoredImage]
        let failures: [String]

        var links: [String] { storedImages.map(\.link) }
    }

    /// Reiner, testbarer Teil der revisionsgebundenen Einfügemarke.
    struct ImageInsertionState: Equatable {
        let tabID: UUID
        let contentRevision: UInt64
        let selectionRevision: Int
        let selectedRange: NSRange
    }

    /// Bindet einen asynchronen Bildvorgang an Dokument und Fenster. Der
    /// Editor selbst darf von SwiftUI inzwischen neu aufgebaut worden sein;
    /// dann wird ausschließlich im selben Fenster ein Ersatz gesucht.
    @MainActor
    private final class ImageInsertionLease {
        private weak var workspace: Workspace?
        private weak var window: NSWindow?
        private weak var editor: TextView?
        let documentURL: URL
        let initialState: ImageInsertionState

        private init(workspace: Workspace, window: NSWindow, editor: TextView,
                     documentURL: URL, state: ImageInsertionState) {
            self.workspace = workspace
            self.window = window
            self.editor = editor
            self.documentURL = documentURL
            initialState = state
        }

        static func capture(workspace: Workspace, textView: TextView,
                            documentURL: URL) -> ImageInsertionLease? {
            guard let window = textView.window,
                  let tab = workspace.activeTab,
                  tab.url == documentURL,
                  WorkspaceWindowRegistry.workspace(for: window) === workspace else {
                return nil
            }
            let state = ImageInsertionState(
                tabID: tab.id,
                contentRevision: tab.contentRevision,
                selectionRevision: workspace.selectionRevision,
                selectedRange: textView.fastraSafeSelectedRange
            )
            return ImageInsertionLease(workspace: workspace, window: window,
                                       editor: textView, documentURL: documentURL,
                                       state: state)
        }

        func target() -> (textView: TextView, replacementRange: NSRange)? {
            guard let workspace, let window,
                  WorkspaceWindowRegistry.workspace(for: window) === workspace,
                  let tab = workspace.activeTab,
                  tab.id == initialState.tabID,
                  tab.url == documentURL else { return nil }
            let target = editor?.window === window
                ? editor
                : MarkdownAssist.editorTextView(for: workspace)
            guard let target, target.window === window else { return nil }
            let current = ImageInsertionState(
                tabID: tab.id,
                contentRevision: tab.contentRevision,
                selectionRevision: workspace.selectionRevision,
                selectedRange: target.fastraSafeSelectedRange
            )
            return (target, MarkdownAssist.imageInsertionRange(
                initial: initialState, current: current
            ))
        }
    }

    /// Nur ein vollständig unverändertes Ziel darf die damals markierte
    /// Auswahl ersetzen. Nach Tippen oder Cursorbewegung wird am aktuellen
    /// Auswahlanfang eingefügt, ohne den inzwischen gewählten Text zu löschen.
    nonisolated static func imageInsertionRange(initial: ImageInsertionState,
                                                current: ImageInsertionState) -> NSRange {
        if initial == current { return initial.selectedRange }
        return NSRange(location: current.selectedRange.location, length: 0)
    }

    /// Ist der aktive Tab des Workspace ein Markdown-Dokument? Entscheidend
    /// ist das effektive Format aus der Fußzeile, nicht die Dateiendung.
    static func isMarkdownTabActive(in workspace: Workspace?) -> Bool {
        workspace?.activeTabIsMarkdown ?? false
    }

    // MARK: - Formatbefehle

    /// Wendet einen Formatbefehl auf die TextView an — als normaler
    /// Undo-Schritt über `replaceCharacters` (nie über das SwiftUI-Binding).
    static func applyFormat(_ command: MarkdownFormatCommand, on textView: TextView,
                            workspace: Workspace) {
        switch command {
        case .insertTable:
            guard let configuration = promptForTable() else { return }
            let edit = MarkdownFormat.insertTable(
                textView.string, selection: textView.fastraSafeSelectedRange,
                columns: configuration.columns, header: configuration.header
            )
            perform(edit, on: textView)
        default:
            guard let edit = MarkdownFormat.edit(for: command,
                                                 text: textView.string,
                                                 selection: textView.fastraSafeSelectedRange)
            else { return }
            perform(edit, on: textView)
        }
        noteFirstUse(in: workspace)
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
        // Editor UND Workspace aus DEMSELBEN Fenster. Vorher kam der Editor
        // aus dem Tastatur-Fenster, der Workspace aber aus `Workspace.shared`:
        // Zeigten die auf verschiedene Fenster, landete die Bilddatei neben
        // dem einen Dokument und der Link im anderen (Fehlerbericht
        // 2026-08-07).
        guard let keyWindow = NSApp.keyWindow,
              !SearchWindow.isSearchWindow(keyWindow),
              let workspace = WorkspaceWindowRegistry.workspace(for: keyWindow),
              isMarkdownTabActive(in: workspace),
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

    /// CodeEditTextView als echten Drag-Zielbereich konfigurieren. Nur dieser
    /// native Pfad kennt die Mausposition im Text und kann deshalb während des
    /// Ziehens Einfügemarke und Rand-Autoscroll anbieten.
    static func configureExternalDrop(on textView: TextView, workspace: Workspace) {
        let types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.image.identifier),
            NSPasteboard.PasteboardType(UTType.png.identifier),
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            .tiff,
        ]
        textView.fastraConfigureExternalDrop(
            acceptedTypes: types,
            canHandle: { pasteboard in
                MainActor.assumeIsolated {
                    canHandleImageDrop(types: pasteboard.types ?? [])
                }
            },
            perform: { pasteboard, _ in
                MainActor.assumeIsolated {
                    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
                       !urls.isEmpty {
                        return handleDroppedFileURLs(urls, workspace: workspace)
                    }
                    guard let (data, type) = readImageData(from: pasteboard) else {
                        return false
                    }
                    handleDroppedImageData(data, typeIdentifier: type, workspace: workspace)
                    return true
                }
            }
        )
    }

    /// Während AppKit einen Drag bewegt, wird diese Prüfung sehr oft
    /// aufgerufen. Nur deklarierte Typen ansehen; Datei-URLs und Bildbytes
    /// werden erst beim tatsächlichen Ablegen materialisiert.
    static func canHandleImageDrop(types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(.fileURL) || types.contains { type in
            UTType(type.rawValue)?.conforms(to: .image) == true
        }
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
        // Die Einfügemarke gehört zum Drop-Zeitpunkt, nicht zum späteren
        // Abschluss der Dateityp-Prüfung oder des Kopierens.
        let initialTextView = editorTextView(for: workspace)
        let initialLease: ImageInsertionLease? = {
            guard let initialTextView, let documentURL = workspace.activeTab?.url else {
                return nil
            }
            return ImageInsertionLease.capture(
                workspace: workspace, textView: initialTextView,
                documentURL: documentURL
            )
        }()
        // Symlink-Auflösung und Dateityp-Prüfung greifen auf das Dateisystem
        // zu und laufen deshalb nicht im UI-Thread.
        Task {
            let partition = await Task.detached(priority: .userInitiated) {
                MarkdownImageStore.partitionDroppedURLs(urls)
            }.value
            // Nicht-Bilder: bestehender „öffnen“-Pfad (Dateien → Tabs,
            // Ordner → Projekt) — derselbe wie beim Fenster-Drop.
            let openables = await Task.detached(priority: .userInitiated) {
                DropHandling.openableItems(from: partition.open)
            }.value
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
            if !partition.insert.isEmpty,
               let textView = initialTextView ?? editorTextView(for: workspace) {
                insertImageFiles(partition.insert, workspace: workspace,
                                 textView: textView, lease: initialLease,
                                 completion: openRemaining)
            } else {
                openRemaining()
            }
        }
        return true
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
                                         lease capturedLease: ImageInsertionLease? = nil,
                                         completion: (() -> Void)? = nil) {
        guard let documentURL = savedDocumentURL(workspace) else {
            completion?()
            return
        }
        guard let lease = capturedLease ?? ImageInsertionLease.capture(
            workspace: workspace, textView: textView, documentURL: documentURL
        ), lease.documentURL == documentURL else {
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
        // darf Workspace und Einfüge-Lease deshalb halten. Nur der abgetrennte
        // innere Task verlässt den Main-Thread — und der bekommt ausschließlich
        // Werte, die gefahrlos zwischen Threads wandern (Dateiadressen).
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                storeImageFiles(urls, documentURL: documentURL)
            }.value
            finishImageInsertion(outcome, lease: lease, workspace: workspace)
            completion?()
        }
    }

    /// Legt alle Bilddateien ab und sammelt Links und Fehlertexte ein.
    ///
    /// Bewusst `nonisolated` und ohne UI: So ist sichtbar, dass dieser Teil
    /// abseits des Main-Threads laufen darf, und er lässt sich ohne Fenster
    /// testen.
    nonisolated static func storeImageFiles(_ urls: [URL], documentURL: URL)
    -> ImageStoreOutcome {
        var storedImages: [MarkdownImageStore.StoredImage] = []
        var failures: [String] = []
        for url in urls {
            do {
                let stored = try MarkdownImageStore.storeImageFile(url, documentURL: documentURL)
                storedImages.append(stored)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return ImageStoreOutcome(storedImages: storedImages, failures: failures)
    }

    /// Zweiter Halbschritt auf dem Main-Thread: meldet Fehler und fügt die
    /// fertigen Links ein.
    ///
    /// Zwischen Ablage und Einfügen kann der Nutzer Text, Auswahl oder Tab
    /// geändert oder das Fenster geschlossen haben. Der Lease prüft deshalb
    /// Dokument und Fenster und entscheidet zwischen ursprünglicher Auswahl
    /// und aktueller reiner Einfügestelle. Abgelegte Bilddateien bleiben bei
    /// einem nicht mehr vorhandenen Ziel erhalten.
    private static func finishImageInsertion(
        _ outcome: ImageStoreOutcome,
        lease: ImageInsertionLease, workspace: Workspace
    ) {
        for message in outcome.failures {
            NSAlert.runWarning(title: L10n.string("Bild konnte nicht übernommen werden"),
                               text: message)
        }
        guard !outcome.storedImages.isEmpty,
              let target = lease.target() else { return }
        insertLinks(outcome.storedImages, into: target.textView,
                    replacing: target.replacementRange, workspace: workspace)
    }

    private static func insertImageData(_ data: Data, typeIdentifier: String,
                                        workspace: Workspace, textView: TextView) {
        guard let documentURL = savedDocumentURL(workspace) else { return }
        guard let lease = ImageInsertionLease.capture(
            workspace: workspace, textView: textView, documentURL: documentURL
        ) else { return }
        // Auch TIFF/HEIC-Dekodierung und das atomare Schreiben können bei
        // großen Pasteboard-Bildern dauern. Der abgetrennte Task erhält nur
        // Bilddaten, Typkennung und Dokumentadresse, niemals UI-Objekte.
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                storeImageData(data, typeIdentifier: typeIdentifier,
                               documentURL: documentURL)
            }.value
            finishImageInsertion(outcome, lease: lease, workspace: workspace)
        }
    }

    /// Bereitet rohe Bilddaten auf und schreibt sie ohne UI-Zugriff.
    nonisolated static func storeImageData(_ data: Data, typeIdentifier: String,
                                           documentURL: URL)
    -> ImageStoreOutcome {
        guard let prepared = MarkdownImageStore.prepare(
            imageData: data, typeIdentifier: typeIdentifier
        ) else {
            return ImageStoreOutcome(
                storedImages: [],
                failures: [MarkdownImageStore.StoreError.unreadableImage.localizedDescription]
            )
        }
        do {
            let stored = try MarkdownImageStore.storePastedData(
                prepared, documentURL: documentURL
            )
            return ImageStoreOutcome(storedImages: [stored], failures: [])
        } catch {
            return ImageStoreOutcome(storedImages: [], failures: [error.localizedDescription])
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

    /// Fügt die Links an der validierten Stelle ein (mehrere zeilenweise),
    /// setzt den Cursor dahinter und meldet der Vorschau die Einfügezeile.
    private static func insertLinks(_ storedImages: [MarkdownImageStore.StoredImage],
                                    into textView: TextView,
                                    replacing selection: NSRange,
                                    workspace: Workspace) {
        let links = storedImages.map(\.link)
        guard !links.isEmpty else { return }
        let insertion = links.joined(separator: "\n")
        textView.replaceCharacters(in: selection, with: insertion)
        MarkdownImageUndo.register(textView: textView, insertion: insertion,
                                   storedImages: storedImages)
        let caret = selection.location + (insertion as NSString).length
        textView.selectionManager.setSelectedRange(NSRange(location: caret, length: 0))
        revealInPreview(textView: textView, characterLocation: selection.location,
                        workspace: workspace)
        noteFirstUse(in: workspace)
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
    static func noteFirstUse(
        in workspace: Workspace,
        defaults: UserDefaults = SelfTest.workspaceDefaults(),
        notificationCenter: NotificationCenter = .default
    ) {
        guard !defaults.bool(forKey: firstUseDefaultsKey) else { return }
        // Der Workspace ist Teil des Ereignisses: Bei mehreren Fenstern darf
        // nur der Editor reagieren, in dem die Aktion wirklich stattfand.
        notificationCenter.post(name: .fastraMarkdownAssistUsed, object: workspace)
    }

    /// Gemeinsame Identitätsprüfung für den SwiftUI-Empfänger und den
    /// fensterlosen Regressionstest.
    static func firstUseNotification(_ notification: Notification,
                                     targets workspace: Workspace) -> Bool {
        (notification.object as? Workspace) === workspace
    }

    // MARK: - TextView-Suche

    /// Editor-TextView des Workspace-Fensters.
    ///
    /// Die Fenstersuche liegt in `CommandTargeting` — siehe dort, warum es in
    /// der ganzen Anwendung nur einen Weg zu Fenstern geben darf.
    static func editorTextView(for workspace: Workspace) -> TextView? {
        CommandTargeting.editorTextView(for: workspace)
    }

}
