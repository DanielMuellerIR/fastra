// FourDMacroAssist.swift
//
// Anwendung der 4D-Methodeneditor-Makros im Editor (Idee #28, 2026-08-19).
// Der Katalog (`FourDMacros.swift` + `FourDMacroDiscovery.swift`) liefert die
// Makros der aktiven `.4dm`-Datei; hier leben die drei Ausführungswege:
//
// - Text-Makros wendet Fastra NATIV an (Platzhalter ersetzen, Cursor über
//   `<caret/>` setzen) — ein Undo-Schritt, wie die übrigen Textoperationen.
// - Die Komplettieren-Familie läuft headless über die tool4d-Engine
//   (`FourDMacroEngine.swift`) und zeigt ihr Ergebnis IMMER zuerst als
//   Diff-Vorschau (Produktinvariante: keine Schreibänderung ohne Vorschau).
// - Alles andere braucht den echten 4D-Methodeneditor und bleibt sichtbar,
//   aber mit erklärender Deaktivierung.

import AppKit
import CodeEditTextView
import SwiftUI

// MARK: - Diff-Vorschau eines Makrolaufs

/// Zustand des Vorschau-Sheets. Anwenden ist nur gültig, solange der Tab und
/// seine Inhaltsgeneration exakt denen beim Makrolauf entsprechen — sonst
/// würde das Ergebnis auf eine andere Trefferbasis geschrieben als die
/// sichtbare Vorschau.
struct FourDMacroPreviewState: Identifiable {
    let id = UUID()
    let macroName: String
    let tabID: UUID
    let contentRevision: UInt64
    let resultText: String
    let request: FileDiffRequest
    let document: FileDiffDocument
}

// MARK: - Pure Platzhalter-Übersetzung (unit-getestet)

enum FourDMacroRendering {

    /// Ergebnis einer Text-Makro-Übersetzung: der einzufügende Text und die
    /// gewünschte Cursorposition (UTF-16-Offset im eingefügten Text), falls
    /// das Makro ein `<caret/>` enthält.
    struct Insertion: Equatable {
        let text: String
        let caretUTF16Offset: Int?
    }

    /// Übersetzt die Platzhalter-Bausteine eines Text-Makros in echten Text.
    /// 4D-Datumsformate: 0 = kurzes Systemformat, 1 = ausgeschrieben; alle
    /// weiteren Nummern fallen bewusst aufs kurze Format zurück.
    static func render(parts: [FourDMacroTextPart], selection: String,
                       methodName: String, fullText: String,
                       date: Date = Date(),
                       userName: String = NSUserName(),
                       locale: Locale = .current) -> Insertion {
        var text = ""
        var caret: Int?
        for part in parts {
            switch part {
            case .literal(let literal):
                text += literal
            case .caret:
                // Erste Caret-Marke gewinnt; weitere wären mehrdeutig.
                if caret == nil { caret = (text as NSString).length }
            case .selection:
                text += selection
            case .fullText:
                text += fullText
            case .methodName:
                text += methodName
            case .userOS:
                text += userName
            case .clipboard:
                // Nativ nicht unterstützt — die Capability-Prüfung lässt
                // solche Makros gar nicht erst hierher.
                break
            case .date(let format):
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateStyle = format == 1 ? .long : .short
                text += formatter.string(from: date)
            case .time(let format):
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeStyle = format == 1 ? .medium : .short
                text += formatter.string(from: date)
            }
        }
        return Insertion(text: text, caretUTF16Offset: caret)
    }
}

// MARK: - Ausführung im Workspace

extension Workspace {

    /// Katalog neu aufbauen, wenn die aktive Datei eine `.4dm` in einem noch
    /// nicht gescannten Ordner ist. Scan läuft im Hintergrund; ein veralteter
    /// Scan wird über die Generation verworfen.
    func refreshFourDMacroCatalogIfNeeded(force: Bool = false) {
        guard let url = activeTab?.url,
              url.pathExtension.lowercased() == "4dm" else {
            if !fourDMacros.isEmpty { fourDMacros = [] }
            fourDMacroScanKey = nil
            // Die Generation MUSS mitwandern: Sonst besteht die Completion
            // eines noch laufenden Scans ihre Prüfung und füllt den gerade
            // geleerten Katalog wieder. Dessen Kürzel schluckten dann ⌘T & Co.
            // außerhalb von 4D.
            fourDMacroScanGeneration = UUID()
            return
        }
        let key = url.deletingLastPathComponent().path
        guard force || key != fourDMacroScanKey else { return }
        fourDMacroScanKey = key
        let generation = UUID()
        fourDMacroScanGeneration = generation
        let document = url
        Task.detached(priority: .utility) { [weak self] in
            let root = FourDMacroDiscovery.projectRoot(forDocument: document)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let sources = FourDMacroDiscovery.macroSources(
                projectRoot: root,
                homeDirectory: home,
                // Dieselben Programme-Ordner, in denen auch der tool4d-Finder
                // sucht (`Tool4DDiscovery.locate`) — einschließlich des
                // benutzereigenen `~/Applications`, in dem eine ohne
                // Administratorrechte installierte 4D.app landet.
                applicationDirectories: [
                    home.appendingPathComponent("4D"),
                    URL(fileURLWithPath: "/Applications"),
                    home.appendingPathComponent("Applications"),
                ]
            )
            var macros: [FourDMacro] = []
            for source in sources {
                guard let data = try? Data(contentsOf: source.url) else { continue }
                macros.append(contentsOf: FourDMacroXML.parse(
                    data: data, sourceLabel: source.url.lastPathComponent,
                    // Der volle Pfad trennt zwei gleichnamige „Macros.xml".
                    sourceKey: source.url.canonicalFileURL.path))
            }
            let parsed = macros
            await MainActor.run { [weak self] in
                guard let self, self.fourDMacroScanGeneration == generation,
                      // Der Katalog gilt nur für die Datei, für die er
                      // gescannt wurde.
                      self.fourDMacroScanKey == key,
                      self.activeTab?.url?.pathExtension.lowercased() == "4dm"
                else { return }
                self.fourDMacros = parsed
            }
        }
    }

    /// Menüweg: Makro über seine stabile ID ausführen.
    @MainActor func runFourDMacro(id: String) {
        guard let macro = fourDMacros.first(where: { $0.id == id }) else { return }
        if !runFourDMacro(macro) { NSSound.beep() }
    }

    /// Shortcut-Weg (⌘ + Kürzelzeichen aus dem Makronamen, z. B. ⌘# und ⌘T).
    /// Liefert `false`, wenn kein Makro dieses Kürzel trägt ODER es hier gar
    /// nicht ausführbar ist — der Aufrufer reicht die Taste dann normal
    /// weiter. Nur so behält ⌘T außerhalb einer 4D-Methode „Neuer Tab".
    @discardableResult
    @MainActor func runFourDMacro(shortcut key: Character) -> Bool {
        guard let macro = fourDMacros.first(where: { $0.shortcutKey == key }) else {
            return false
        }
        return runFourDMacro(macro)
    }

    /// Führt ein Makro aus. `false` heißt: Dieses Fenster ist gar kein
    /// gültiges Ziel (kein 4D-Dokument im Vordergrund) — dann ist nichts
    /// passiert und der Aufrufer entscheidet, was stattdessen gilt.
    @discardableResult
    @MainActor private func runFourDMacro(_ macro: FourDMacro) -> Bool {
        guard let target = CommandTargeting.target(), target.workspace === self,
              let tab = activeTab, let url = tab.url,
              url.pathExtension.lowercased() == "4dm" else {
            return false
        }
        switch FourDMacroXML.capability(of: macro) {
        case .unsupported(let reason):
            NSAlert.runWarning(
                title: L10n.format("Makro „%@“ ist hier nicht ausführbar",
                                   macro.displayName),
                text: reason)
        case .nativeText:
            applyNativeMacro(macro, textView: target.textView, documentURL: url)
        case .engine(let variant):
            runEngineMacro(macro, variant: variant, textView: target.textView,
                           tab: tab, documentURL: url)
        }
        return true
    }

    // MARK: Text-Makros (nativ)

    @MainActor private func applyNativeMacro(_ macro: FourDMacro, textView: TextView,
                                  documentURL: URL) {
        let selection = textView.fastraSafeSelectedRange
        let fullText = textView.string
        let selectedText = (fullText as NSString).substring(with: selection)
        let insertion = FourDMacroRendering.render(
            parts: macro.textParts,
            selection: selectedText,
            methodName: FourDMacroXML.normalizedMethodName(
                forFileName: documentURL.lastPathComponent),
            fullText: fullText
        )
        guard !insertion.text.isEmpty else { return }
        textView.fastraApplyTextOperation(replacing: selection,
                                          with: insertion.text)
        if let caret = insertion.caretUTF16Offset {
            // Cursor an die `<caret/>`-Marke des Makros setzen. Die Änderung
            // selbst bleibt EIN Undo-Schritt; die Auswahl ist kein Undo-Inhalt.
            textView.selectionManager.setSelectedRange(
                NSRange(location: selection.location + caret, length: 0))
        }
    }

    // MARK: Komplettieren-Familie (tool4d-Engine mit Diff-Vorschau)

    @MainActor private func runEngineMacro(_ macro: FourDMacro, variant: FourDKomplettierenVariant,
                                textView: TextView, tab: EditorTab,
                                documentURL: URL) {
        guard !fourDMacroEngineBusy else { NSSound.beep(); return }
        let methodName = FourDMacroXML.normalizedMethodName(
            forFileName: documentURL.lastPathComponent)
        // Daniels Ausnahmen fürs Komplettieren: warnen statt ausführen.
        if methodName == "00_DM_Info" || methodName.hasPrefix("Compiler_") {
            NSAlert.runWarning(
                title: L10n.string("Methode ist vom Komplettieren-Makro ausgenommen"),
                text: L10n.string("00_DM_Info und Compiler_*-Methoden sind bewusst von diesem Makro ausgenommen und bleiben unverändert."))
            return
        }
        guard let engineRootPath = FourDMacroEngineSettings.projectRootPath else {
            NSAlert.runWarning(
                title: L10n.string("Makro-Engine nicht konfiguriert"),
                text: L10n.string("Dieses Makro läuft über ein 4D-Engine-Projekt mit der Methode MacroRun (MAO_Makros). Trage dessen Projektordner in den Einstellungen unter „4D“ ein."))
            return
        }
        let engineRoot = URL(fileURLWithPath: engineRootPath)
        guard let projectFile = FourDMacroEngine.engineProjectFile(root: engineRoot) else {
            NSAlert.runWarning(
                title: L10n.string("Engine-Projekt nicht gefunden"),
                text: L10n.format("Unter %@ liegt keine .4DProject-Datei (erwartet in „Project/“). Prüfe den Pfad in den Einstellungen unter „4D“.", engineRootPath))
            return
        }
        // Ein eingetragener, aber unbrauchbarer tool4d-Pfad ist ein
        // Konfigurationsfehler und darf nicht still in die automatische Suche
        // rutschen — sonst liefe eine andere Version als die eingestellte.
        if let problem = Tool4DAssist.executablePathProblem(
            Tool4DAssist.rememberedExecutablePath
        ) {
            NSAlert.runWarning(
                title: L10n.string("Eingetragenes tool4d ist nicht nutzbar"),
                text: L10n.format("%@\n\nPrüfe den Pfad in den Einstellungen unter „4D“ oder leere das Feld, damit Fastra selbst sucht.",
                                  problem))
            return
        }
        guard let tool = Tool4DAssist.installedTool() else {
            // Der bestehende tool4d-Finder erklärt Fundorte und Download.
            Tool4DAssist.runFinder()
            return
        }

        let originalText = textView.string
        let learned = FourDTokenTransform.learnedSuffixes(from: originalText)
        // MacroRun erwartet untokenisierten Code (gemessen am 2026-08-19,
        // siehe FourDMacroEngine.swift); tokenisierte Zeilen zerlegt das
        // Makro in Müll. Nach dem Lauf stellt `retokenize` die Suffixe aus
        // dem Original wieder her.
        let detokenized = FourDTokenTransform.detokenize(originalText)
        let macroName = macro.displayName
        let tabID = tab.id
        let revision = tab.contentRevision

        fourDMacroEngineBusy = true
        FourDMacroEngine.run(
            tool4d: tool.executableURL,
            engineProjectFile: projectFile,
            code: detokenized,
            variant: variant.rawValue,
            methodName: methodName
        ) { [weak self] result in
            // Die Engine liefert ihr Ergebnis zugesichert auf der Main-Queue
            // (`FourDMacroEngine.run`); dem Compiler wird das hier zugesichert.
            MainActor.assumeIsolated {
            guard let self else { return }
            self.fourDMacroEngineBusy = false
            switch result {
            case .failed(let text):
                NSAlert.runWarning(
                    title: L10n.format("Makro „%@“ fehlgeschlagen", macroName),
                    text: text)
            case .unchanged:
                NSAlert.runWarning(
                    title: L10n.format("Makro „%@“", macroName),
                    text: L10n.string("Keine Änderungen — die Methode ist bereits vollständig."))
            case .changed(let newCode):
                let retokenized = FourDTokenTransform.retokenize(newCode,
                                                                 learned: learned)
                guard retokenized != originalText else {
                    NSAlert.runWarning(
                        title: L10n.format("Makro „%@“", macroName),
                        text: L10n.string("Keine Änderungen — die Methode ist bereits vollständig."))
                    return
                }
                self.presentFourDMacroPreview(macroName: macroName,
                                              tabID: tabID, revision: revision,
                                              original: originalText,
                                              result: retokenized)
            }
            }
        }
    }

    /// Baut den Diff „aktueller Puffer → Makro-Ergebnis" im Hintergrund und
    /// zeigt danach das Vorschau-Sheet.
    @MainActor private func presentFourDMacroPreview(macroName: String, tabID: UUID,
                                          revision: UInt64,
                                          original: String, result: String) {
        let request = FileDiffRequest(
            left: .text(original, name: L10n.string("Aktueller Stand")),
            right: .text(result, name: L10n.format("Ergebnis von „%@“", macroName)),
            options: FileDiffOptions()
        )
        Task.detached(priority: .userInitiated) {
            let document = Workspace.computeFileDiffDocument(request: request)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Veraltete Grundlage? Dann keine Vorschau mehr anbieten —
                // Anwenden würde ohnehin an der Revisionsprüfung scheitern.
                guard self.activeTab?.id == tabID,
                      self.activeTab?.contentRevision == revision else {
                    NSAlert.runWarning(
                        title: L10n.string("Makro-Vorschau verworfen"),
                        text: L10n.string("Das Dokument wurde während des Makrolaufs geändert. Führe das Makro erneut aus."))
                    return
                }
                self.fourDMacroPreview = FourDMacroPreviewState(
                    macroName: macroName, tabID: tabID,
                    contentRevision: revision, resultText: result,
                    request: request, document: document)
            }
        }
    }

    /// Wendet das Vorschau-Ergebnis als EINEN Undo-Schritt an. Gültig nur,
    /// solange Tab und Inhaltsgeneration exakt der Vorschau entsprechen.
    @discardableResult
    @MainActor func applyFourDMacroPreview() -> Bool {
        guard let preview = fourDMacroPreview else { return false }
        guard let target = CommandTargeting.target(), target.workspace === self,
              let tab = activeTab, tab.id == preview.tabID,
              tab.contentRevision == preview.contentRevision else {
            fourDMacroPreview = nil
            NSAlert.runWarning(
                title: L10n.string("Makro-Ergebnis nicht angewendet"),
                text: L10n.string("Das Dokument entspricht nicht mehr dem Stand der Vorschau. Führe das Makro erneut aus."))
            return false
        }
        let textView = target.textView
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.fastraApplyTextOperation(replacing: fullRange,
                                          with: preview.resultText)
        fourDMacroPreview = nil
        return true
    }
}

// MARK: - Menüleisten-Einträge („Makros"-Menü)

/// Dynamische Einträge des „Makros"-Menüs — eine eigene View mit
/// `@ObservedObject`, damit die Menüleiste auf Katalogänderungen reagiert
/// (dieselbe Falle wie beim „Zuletzt benutzt"-Menü: eine bloße Closure im
/// CommandMenu aktualisiert sich nicht).
struct FourDMacroMenuItems: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if workspace.activeTab?.url?.pathExtension.lowercased() != "4dm" {
            Button("Makros gelten für 4D-Methoden (.4dm-Dateien)") { }
                .disabled(true)
        } else if workspace.fourDMacros.isEmpty {
            Button("Keine Makros gefunden") { }.disabled(true)
            Button("Erneut suchen") {
                workspace.refreshFourDMacroCatalogIfNeeded(force: true)
            }
        } else {
            ForEach(workspace.fourDMacros) { macro in
                if macro.isSeparator {
                    Divider()
                } else {
                    macroButton(macro)
                }
            }
            Divider()
            Button("Makros neu laden") {
                workspace.refreshFourDMacroCatalogIfNeeded(force: true)
            }
        }
    }

    /// Ein Makro-Eintrag. Nicht ausführbare Makros bleiben sichtbar und
    /// erklären beim Klick, warum sie den 4D-Methodeneditor brauchen — ein
    /// gedimmter Eintrag ohne erreichbaren Grund wäre unverständlicher.
    @ViewBuilder private func macroButton(_ macro: FourDMacro) -> some View {
        let title = macro.shortcutKey.map {
            "\(macro.displayName)   ⌘\(String($0).uppercased())"
        } ?? macro.displayName
        Button(title) {
            workspace.runFourDMacro(id: macro.id)
        }
        .disabled(workspace.fourDMacroEngineBusy)
        .help(macro.sourceLabel)
    }
}
