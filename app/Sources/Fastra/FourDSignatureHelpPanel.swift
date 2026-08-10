// FourDSignatureHelpPanel.swift
//
// Anzeige der 4D-Parameterhilfe: ein kleines, nicht aktivierbares Panel wie
// ein Tooltip, direkt unter der Aufrufzeile. Es erscheint, sobald der Cursor
// innerhalb der runden Klammern eines Projektmethoden-Aufrufs steht, hebt
// den aktiven Parameter hervor und zeigt darunter den Kommentarkopf der
// Methode. Für bekannte 4D-Befehle erscheint deren Signatur aus der
// mitgelieferten Befehlsliste.

import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
final class FourDSignatureHelpController: ObservableObject {

    /// Höchstens so viele Kommentarkopf-Zeilen werden angezeigt.
    static let maximumHeaderLines = 14

    private var panel: NSPanel?
    private var panelHost: NSWindow?
    /// Signatur-Cache pro Methodendatei bzw. Archiveintrag; ungültig, sobald
    /// sich das Änderungsdatum ändert. Der Cache wird ausschließlich aus dem
    /// Hintergrundauftrag benutzt und sperrt sich deshalb selbst.
    private let cache = FourDSignatureResolver.Cache()
    /// Zählt bei jeder Cursorbewegung hoch. Ein Hintergrund-Signaturabruf,
    /// der erst nach der nächsten Bewegung zurückkommt, ist damit erkennbar
    /// veraltet und wird verworfen.
    private var updateGeneration = 0

    /// Zentraler Einstieg: bei jeder Cursorbewegung im aktiven 4D-Editor.
    func update(workspace: Workspace,
                cursorPositions: [CursorPosition],
                isFourDActive: Bool) {
        // Zuerst ALLE noch laufenden Hintergrundauflösungen entwerten — auch
        // dann, wenn dieser Aufruf gleich unten abbricht. Vorher zählte nur
        // der Erfolgsfall hoch: Eine bereits laufende Auflösung behielt ihre
        // gültige Generation und zeigte die längst veraltete Hilfe danach
        // erneut an (Review 2026-08-10).
        updateGeneration &+= 1
        let generation = updateGeneration
        guard isFourDActive,
              cursorPositions.count == 1,
              let cursor = cursorPositions.first,
              cursor.range.length == 0,
              let window = Self.editorWindow(for: workspace),
              let root = window.contentView,
              let textView = Self.firstTextView(in: root),
              let context = FourDSignatureHelpLogic.callContext(
                in: textView.string,
                utf16CursorLocation: cursor.range.location
              ) else {
            hide()
            return
        }
        // Alles, was die Platte anfasst — Existenzprüfung der Methodendatei,
        // Änderungsdatum, Lesen des Archivs und Parsen —, läuft im
        // Hintergrund. Auf einem Netz- oder Wechseldatenträger blockierte
        // sonst jede Cursorbewegung die Oberfläche (Review 2026-08-10). Aus
        // dem Workspace werden hier nur reine Daten entnommen; die Generation
        // verwirft ein verspätetes Ergebnis.
        let request = titleRequest(workspace: workspace, context: context)
        let cache = cache
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = FourDSignatureResolver.title(for: request, cache: cache)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.updateGeneration else { return }
                guard let resolved else {
                    self.hide()
                    return
                }
                // Fenster oder Editor können sich während eines Hintergrund-
                // Reads geändert haben — dann nicht mehr an die alte Ansicht
                // ankern.
                guard textView.window === window, window.isVisible else {
                    self.hide()
                    return
                }
                self.show(
                    text: Self.attributedTitle(
                        resolved, methodName: context.methodName,
                        activeParameterIndex: context.activeParameterIndex
                    ),
                    anchoredAt: context.openParenLocation,
                    textView: textView, window: window
                )
            }
        }
    }

    private func titleRequest(workspace: Workspace,
                              context: FourDCallContext) -> FourDSignatureResolver.Request {
        let lowered = context.methodName.lowercased()
        // Die Schreibweise der DATEI kommt aus dem Index, nicht aus dem
        // getippten Aufruf: 4D vergleicht Methodennamen ohne Groß-/
        // Kleinschreibung, ein case-sensitives Dateisystem aber nicht —
        // `alert(…)` fände `ALERT.4dm` sonst nicht (Review 2026-08-02).
        let fileName = workspace.fourDProjectMethodNames.contains(lowered)
            ? (workspace.fourDProjectMethodDisplayNames
                .first(where: { $0.lowercased() == lowered }) ?? context.methodName)
            : nil
        return FourDSignatureResolver.Request(
            lowered: lowered,
            projectMethodFileName: fileName,
            projectURL: workspace.projectURL,
            documentURL: workspace.activeTab?.url,
            componentMethod: workspace.fourDComponentMethods[lowered]
        )
    }

    /// Main-Thread: aus dem Auflösungsergebnis den fertigen Panel-Text bauen.
    private static func attributedTitle(_ resolved: FourDSignatureResolver.Title,
                                        methodName: String,
                                        activeParameterIndex: Int) -> NSAttributedString {
        switch resolved {
        case .signature(let signature, let parametersAreKnown):
            return attributedSignature(methodName: methodName,
                                       signature: signature,
                                       activeParameterIndex: activeParameterIndex,
                                       parametersAreKnown: parametersAreKnown)
        case .command(let commandSignature):
            return NSAttributedString(
                string: commandSignature,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: NSFont.smallSystemFontSize, weight: .regular
                    ),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }
    }

    func hide() {
        // Ausblenden entwertet ebenfalls jede laufende Auflösung: Sonst
        // könnte ein Tabwechsel (`hide()` von außen) vom verspäteten
        // Ergebnis der alten Datei wieder überschrieben werden.
        updateGeneration &+= 1
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        panelHost = nil
    }

    // MARK: - Darstellung

    static func attributedSignature(
        methodName: String,
        signature: FourDMethodSignature,
        activeParameterIndex: Int,
        parametersAreKnown: Bool = true
    ) -> NSAttributedString {
        let size = NSFont.smallSystemFontSize
        let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let result = NSMutableAttributedString()
        func append(_ string: String, font: NSFont = regular,
                    color: NSColor = .labelColor) {
            result.append(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: color,
            ]))
        }
        append(methodName, font: bold)
        append("(")
        if signature.parameters.isEmpty {
            // Aus einer Methodendoku ohne Deklarationszeilen lässt sich
            // „keine Parameter“ nicht ehrlich behaupten — dann nur „…“.
            append(parametersAreKnown ? L10n.string("keine Parameter") : "…",
                   color: .secondaryLabelColor)
        }
        for (index, parameter) in signature.parameters.enumerated() {
            if index > 0 { append("; ") }
            let isActive = index == activeParameterIndex
                // Der letzte Parameter bleibt aktiv, wenn dahinter weitere
                // Argumente getippt werden (variadisch bzw. Überzählige).
                || (index == signature.parameters.count - 1
                    && activeParameterIndex >= signature.parameters.count)
            let font = isActive ? bold : regular
            let color: NSColor = isActive ? .labelColor : .secondaryLabelColor
            append(parameter.name, font: font, color: color)
            if let type = parameter.type {
                append(" : \(type)", font: font, color: color)
            }
        }
        append(")")
        if let back = signature.returnParameter {
            append(" -> ")
            append(back.name, color: .secondaryLabelColor)
            if let type = back.type {
                append(" : \(type)", color: .secondaryLabelColor)
            }
        }
        if !signature.headerComment.isEmpty {
            let lines = signature.headerComment.components(separatedBy: "\n")
            let shown = lines.prefix(maximumHeaderLines)
            var comment = shown.joined(separator: "\n")
            if lines.count > maximumHeaderLines { comment += "\n…" }
            append("\n\n")
            append(comment,
                   font: NSFont.monospacedSystemFont(ofSize: size - 1,
                                                     weight: .regular),
                   color: .secondaryLabelColor)
        }
        return result
    }

    private func show(text: NSAttributedString, anchoredAt offset: Int,
                      textView: TextView, window: NSWindow) {
        guard let anchorRect = textView.layoutManager.rectForOffset(offset),
              textView.visibleRect.intersects(anchorRect) else {
            hide()
            return
        }

        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 560

        let padding: CGFloat = 8
        let size = label.fittingSize
        let content = NSView(frame: NSRect(
            x: 0, y: 0,
            width: size.width + padding * 2,
            height: size.height + padding * 2
        ))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.borderWidth = 1
        content.layer?.cornerRadius = 6
        label.frame = NSRect(x: padding, y: padding,
                             width: size.width, height: size.height)
        content.addSubview(label)

        let panel = reusablePanel(in: window)
        panel.setContentSize(content.frame.size)
        panel.contentView = content

        // Unterhalb der Zeile mit der öffnenden Klammer; reicht der Platz
        // im Fenster nicht, oberhalb.
        let anchorInWindow = textView.convert(anchorRect, to: nil)
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        var origin = NSPoint(
            x: anchorOnScreen.minX,
            y: anchorOnScreen.minY - content.frame.height - 4
        )
        if let screen = window.screen,
           origin.y < screen.visibleFrame.minY {
            origin.y = anchorOnScreen.maxY + 4
        }
        if let screen = window.screen {
            origin.x = min(origin.x,
                           screen.visibleFrame.maxX - content.frame.width - 8)
        }
        panel.setFrameOrigin(origin)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func reusablePanel(in window: NSWindow) -> NSPanel {
        if let panel, panelHost === window { return panel }
        hide()
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Reiner Hinweis: Klicks gehen am Panel vorbei in den Editor.
        panel.ignoresMouseEvents = true
        self.panel = panel
        self.panelHost = window
        return panel
    }

    // MARK: - Fenster-/View-Suche (gleiche Muster wie EditorView)

    private static func editorWindow(for workspace: Workspace) -> NSWindow? {
        CommandTargeting.documentWindow(for: workspace)
    }

    private static func firstTextView(in view: NSView) -> TextView? {
        if let textView = view as? TextView, textView.frame.height > 50 {
            return textView
        }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - Signatur laden (Hintergrund)

/// Der Teil der Parameterhilfe, der die PLATTE anfasst: Methodendatei suchen,
/// Änderungsdatum lesen, Datei bzw. 4DZ-Eintrag lesen und parsen. Er steht
/// bewusst außerhalb des `@MainActor`-Controllers, damit er vollständig auf
/// einer Hintergrund-Queue laufen kann — auf einem Netz- oder
/// Wechseldatenträger blockierte jede dieser Fragen sonst die Oberfläche
/// (Review 2026-08-10).
private enum FourDSignatureResolver {

    /// Alle Eingaben einer Auflösung als reine Daten. Der Hintergrundauftrag
    /// darf den Workspace nicht anfassen — der lebt auf dem Main-Thread —,
    /// deshalb wird vorher dort alles Nötige herauskopiert.
    struct Request {
        let lowered: String
        /// Dateiname der Projektmethode in Original-Schreibweise; `nil`, wenn
        /// der Aufruf keine Projektmethode trifft.
        let projectMethodFileName: String?
        let projectURL: URL?
        let documentURL: URL?
        let componentMethod: FourDComponentMethod?
    }

    /// Ergebnis der Auflösung — bewusst reine Daten: Schrift und Farben
    /// (AppKit) entstehen erst auf dem Main-Thread.
    enum Title {
        case signature(FourDMethodSignature, parametersAreKnown: Bool)
        /// Signaturtext eines eingebauten 4D-Befehls.
        case command(String)
    }

    /// Signatur-Cache pro Methodendatei bzw. Archiveintrag; ein Eintrag gilt
    /// nur, solange das gemerkte Änderungsdatum stimmt. Er wird aus dem
    /// Hintergrund gelesen und geschrieben und sperrt sich deshalb selbst.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (modified: Date, signature: FourDMethodSignature)] = [:]

        func signature(forKey key: String, modified: Date) -> FourDMethodSignature? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key], entry.modified == modified else { return nil }
            return entry.signature
        }

        func store(_ signature: FourDMethodSignature, forKey key: String,
                   modified: Date) {
            lock.lock()
            defer { lock.unlock() }
            entries[key] = (modified, signature)
        }
    }

    /// Reihenfolge der Quellen: Projektmethode → Komponentenmethode →
    /// 4D-Befehl. `nil`, wenn keine davon etwas Ehrliches zu zeigen hat.
    static func title(for request: Request, cache: Cache) -> Title? {
        if let fileName = request.projectMethodFileName,
           let fileURL = FourDSignatureHelpLogic.methodFileURL(
               named: fileName,
               projectURL: request.projectURL,
               documentURL: request.documentURL
           ),
           let signature = signature(forFileAt: fileURL, cache: cache) {
            return .signature(signature, parametersAreKnown: true)
        }
        // Geteilte Komponentenmethode: Signatur aus `.4dm`-Quelle (Platte
        // oder 4DZ-Archiv) bzw. aus der Methodendokumentation. Eine Doku ohne
        // Deklarationszeilen beweist NICHT, dass die Methode parameterlos ist.
        if let componentMethod = request.componentMethod,
           let signature = signature(forComponentMethod: componentMethod,
                                     cache: cache) {
            let documentationBased: Bool
            if case .documentation = componentMethod.source {
                documentationBased = true
            } else {
                documentationBased = false
            }
            return .signature(
                signature,
                parametersAreKnown: !documentationBased
                    || !signature.parameters.isEmpty
                    || signature.returnParameter != nil
            )
        }
        // Eingebauter 4D-Befehl: Signatur aus der mitgelieferten Befehlsliste.
        guard let details = FourDSymbols.commandDetails[request.lowered],
              let commandSignature = details.signature else { return nil }
        return .command(commandSignature)
    }

    /// Änderungsdatum einer Datei; nicht lesbar → `distantPast`. Dann gilt ein
    /// vorhandener Cache-Eintrag als veraltet und wird neu gelesen.
    private static func modificationDate(ofItemAt path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
    }

    /// Signatur einer Methodendatei — Änderungsdatum, Lesen und Parsen.
    private static func signature(forFileAt fileURL: URL,
                                  cache: Cache) -> FourDMethodSignature? {
        let path = fileURL.path
        let modified = modificationDate(ofItemAt: path)
        if let cached = cache.signature(forKey: path, modified: modified) {
            return cached
        }
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let parsed = FourDSignatureParser.parse(methodSource: source)
        cache.store(parsed, forKey: path, modified: modified)
        return parsed
    }

    /// Signatur einer Komponentenmethode. Quellen auf der Platte laufen über
    /// den Datei-Cache; 4DZ-Einträge werden einzeln gelesen und pro Archiv-
    /// Änderungsdatum gecacht. Ohne Signaturquelle (kompiliert, keine Doku)
    /// gibt es ehrlich keine Hilfe — niemals erfundene Parameter.
    private static func signature(forComponentMethod method: FourDComponentMethod,
                                  cache: Cache) -> FourDMethodSignature? {
        switch method.source {
        case .sourceFile(let url), .documentation(let url):
            return signature(forFileAt: url, cache: cache)
        case .zipEntry(let archive, let entryPath):
            let key = archive.path + "#" + entryPath
            let modified = modificationDate(ofItemAt: archive.path)
            if let cached = cache.signature(forKey: key, modified: modified) {
                return cached
            }
            // Archiv öffnen und Eintrag dekomprimieren kostet spürbar Zeit —
            // gehört wie der Plattenpfad oben in den Hintergrund.
            guard let entries = FourDZipArchive.entries(of: archive),
                  let entry = entries.first(where: { $0.path == entryPath }),
                  let data = FourDZipArchive.data(
                      of: entry, in: archive,
                      maximumSize: FourDComponentIndex.maximumEntryBytes
                  ),
                  let source = FourDComponentIndex.decodeText(data) else { return nil }
            let parsed = FourDSignatureParser.parse(methodSource: source)
            cache.store(parsed, forKey: key, modified: modified)
            return parsed
        case .nameOnly:
            return nil
        }
    }
}
