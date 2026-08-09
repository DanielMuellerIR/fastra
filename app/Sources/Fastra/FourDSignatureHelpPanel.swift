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
    /// Signatur-Cache pro Methodendatei; ungültig, sobald sich das
    /// Änderungsdatum der Datei ändert.
    private var cache: [String: (modified: Date, signature: FourDMethodSignature)] = [:]
    /// Zählt bei jeder Cursorbewegung hoch. Ein Hintergrund-Signaturabruf,
    /// der erst nach der nächsten Bewegung zurückkommt, ist damit erkennbar
    /// veraltet und wird verworfen.
    private var updateGeneration = 0

    /// Zentraler Einstieg: bei jeder Cursorbewegung im aktiven 4D-Editor.
    func update(workspace: Workspace,
                cursorPositions: [CursorPosition],
                isFourDActive: Bool) {
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
        // Der eigentliche Signaturabruf kann Platten- und Archivzugriffe
        // kosten und läuft deshalb im Hintergrund (Cache-Treffer antworten
        // synchron). Die Generation verwirft ein verspätetes Ergebnis, wenn
        // der Cursor längst weitergewandert ist (Review 2026-08-02).
        updateGeneration &+= 1
        let generation = updateGeneration
        resolveTitle(workspace: workspace, context: context) { [weak self] title in
            guard let self, generation == self.updateGeneration else { return }
            guard let title else {
                self.hide()
                return
            }
            // Fenster oder Editor können sich während eines Hintergrund-Reads
            // geändert haben — dann nicht mehr an die alte Ansicht ankern.
            guard textView.window === window, window.isVisible else {
                self.hide()
                return
            }
            self.show(text: title, anchoredAt: context.openParenLocation,
                      textView: textView, window: window)
        }
    }

    /// Baut den Panel-Text: Projektmethode → Komponentenmethode → 4D-Befehl.
    /// `completion` läuft immer auf dem Main-Thread; sie liefert `nil`, wenn
    /// keine der drei Quellen etwas Ehrliches zu zeigen hat.
    private func resolveTitle(workspace: Workspace,
                              context: FourDCallContext,
                              completion: @escaping (NSAttributedString?) -> Void) {
        let lowered = context.methodName.lowercased()
        if workspace.fourDProjectMethodNames.contains(lowered),
           let fileURL = FourDSignatureHelpLogic.methodFileURL(
               // Die Schreibweise der DATEI kommt aus dem Index, nicht aus dem
               // getippten Aufruf: 4D vergleicht Methodennamen ohne Groß-/
               // Kleinschreibung, ein case-sensitives Dateisystem aber nicht —
               // `alert(…)` fände `ALERT.4dm` sonst nicht (Review 2026-08-02).
               named: workspace.fourDProjectMethodDisplayNames
                   .first(where: { $0.lowercased() == lowered })
                   ?? context.methodName,
               projectURL: workspace.projectURL,
               documentURL: workspace.activeTab?.url
           ) {
            withSignature(for: fileURL) { [weak self] signature in
                guard let self else { return completion(nil) }
                if let signature {
                    completion(Self.attributedSignature(
                        methodName: context.methodName,
                        signature: signature,
                        activeParameterIndex: context.activeParameterIndex
                    ))
                } else {
                    self.resolveFallbackTitle(workspace: workspace,
                                              context: context,
                                              lowered: lowered,
                                              completion: completion)
                }
            }
            return
        }
        resolveFallbackTitle(workspace: workspace, context: context,
                             lowered: lowered, completion: completion)
    }

    private func resolveFallbackTitle(workspace: Workspace,
                                      context: FourDCallContext,
                                      lowered: String,
                                      completion: @escaping (NSAttributedString?) -> Void) {
        if let componentMethod = workspace.fourDComponentMethods[lowered] {
            // Geteilte Komponentenmethode: Signatur aus `.4dm`-Quelle
            // (Platte oder 4DZ-Archiv) bzw. aus der Methodendokumentation.
            // Eine Doku ohne Deklarationszeilen beweist NICHT, dass die
            // Methode parameterlos ist.
            withSignature(forComponentMethod: componentMethod) { signature in
                if let signature {
                    let documentationBased: Bool
                    if case .documentation = componentMethod.source {
                        documentationBased = true
                    } else {
                        documentationBased = false
                    }
                    completion(Self.attributedSignature(
                        methodName: context.methodName,
                        signature: signature,
                        activeParameterIndex: context.activeParameterIndex,
                        parametersAreKnown: !documentationBased
                            || !signature.parameters.isEmpty
                            || signature.returnParameter != nil
                    ))
                } else {
                    completion(Self.commandTitle(lowered: lowered))
                }
            }
            return
        }
        completion(Self.commandTitle(lowered: lowered))
    }

    /// Eingebauter 4D-Befehl: Signatur aus der mitgelieferten Befehlsliste.
    private static func commandTitle(lowered: String) -> NSAttributedString? {
        guard let details = FourDSymbols.commandDetails[lowered],
              let commandSignature = details.signature else { return nil }
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

    func hide() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        panelHost = nil
    }

    // MARK: - Signatur laden

    /// Liefert die Signatur einer Methodendatei. Cache-Treffer antworten
    /// SYNCHRON (kein Flackern beim Tippen); nur der echte Plattenzugriff
    /// samt Parsen läuft im Hintergrund — er blockierte sonst bei jeder
    /// ersten Anzeige den Main-Thread (Review 2026-08-02). `completion`
    /// läuft immer auf dem Main-Thread.
    private func withSignature(for fileURL: URL,
                               completion: @escaping (FourDMethodSignature?) -> Void) {
        let path = fileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
        if let cached = cache[path], cached.modified == modified {
            completion(cached.signature)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = (try? String(contentsOf: fileURL, encoding: .utf8))
                .map { FourDSignatureParser.parse(methodSource: $0) }
            DispatchQueue.main.async {
                if let parsed { self.cache[path] = (modified, parsed) }
                completion(parsed)
            }
        }
    }

    /// Signatur einer Komponentenmethode. Quellen auf der Platte laufen über
    /// den Datei-Cache; 4DZ-Einträge werden einzeln gelesen und pro Archiv-
    /// Änderungsdatum gecacht. Ohne Signaturquelle (kompiliert, keine Doku)
    /// gibt es ehrlich keine Hilfe — niemals erfundene Parameter.
    private func withSignature(
        forComponentMethod method: FourDComponentMethod,
        completion: @escaping (FourDMethodSignature?) -> Void
    ) {
        switch method.source {
        case .sourceFile(let url), .documentation(let url):
            withSignature(for: url, completion: completion)
        case .zipEntry(let archive, let entryPath):
            let key = archive.path + "#" + entryPath
            let modified = (try? FileManager.default
                .attributesOfItem(atPath: archive.path)[.modificationDate] as? Date)
                .flatMap { $0 } ?? .distantPast
            if let cached = cache[key], cached.modified == modified {
                completion(cached.signature)
                return
            }
            // Archiv öffnen und Eintrag dekomprimieren kostet spürbar Zeit —
            // gehört wie der Plattenpfad oben in den Hintergrund.
            DispatchQueue.global(qos: .userInitiated).async {
                var parsed: FourDMethodSignature?
                if let entries = FourDZipArchive.entries(of: archive),
                   let entry = entries.first(where: { $0.path == entryPath }),
                   let data = FourDZipArchive.data(
                       of: entry, in: archive,
                       maximumSize: FourDComponentIndex.maximumEntryBytes
                   ),
                   let source = FourDComponentIndex.decodeText(data) {
                    parsed = FourDSignatureParser.parse(methodSource: source)
                }
                DispatchQueue.main.async {
                    if let parsed { self.cache[key] = (modified, parsed) }
                    completion(parsed)
                }
            }
        case .nameOnly:
            completion(nil)
        }
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
