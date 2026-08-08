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
        let lowered = context.methodName.lowercased()
        var title: NSAttributedString?
        if workspace.fourDProjectMethodNames.contains(lowered),
           let fileURL = FourDSignatureHelpLogic.methodFileURL(
               named: context.methodName,
               projectURL: workspace.projectURL,
               documentURL: workspace.activeTab?.url
           ),
           let signature = signature(for: fileURL) {
            title = Self.attributedSignature(
                methodName: context.methodName,
                signature: signature,
                activeParameterIndex: context.activeParameterIndex
            )
        } else if let componentMethod = workspace.fourDComponentMethods[lowered],
                  let signature = signature(forComponentMethod: componentMethod) {
            // Geteilte Komponentenmethode: Signatur aus `.4dm`-Quelle
            // (Platte oder 4DZ-Archiv) bzw. aus der Methodendokumentation.
            // Eine Doku ohne Deklarationszeilen beweist NICHT, dass die
            // Methode parameterlos ist.
            let documentationBased: Bool
            if case .documentation = componentMethod.source {
                documentationBased = true
            } else {
                documentationBased = false
            }
            title = Self.attributedSignature(
                methodName: context.methodName,
                signature: signature,
                activeParameterIndex: context.activeParameterIndex,
                parametersAreKnown: !documentationBased
                    || !signature.parameters.isEmpty
                    || signature.returnParameter != nil
            )
        } else if let details = FourDSymbols.commandDetails[lowered],
                  let commandSignature = details.signature {
            // Eingebauter 4D-Befehl: Signatur aus der Befehlsliste.
            let text = NSMutableAttributedString(
                string: commandSignature,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: NSFont.smallSystemFontSize, weight: .regular
                    ),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            title = text
        }
        guard let title else {
            hide()
            return
        }
        show(text: title, anchoredAt: context.openParenLocation,
             textView: textView, window: window)
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

    private func signature(for fileURL: URL) -> FourDMethodSignature? {
        let path = fileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
        if let cached = cache[path], cached.modified == modified {
            return cached.signature
        }
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let parsed = FourDSignatureParser.parse(methodSource: source)
        cache[path] = (modified, parsed)
        return parsed
    }

    /// Signatur einer Komponentenmethode. Quellen auf der Platte laufen über
    /// den Datei-Cache; 4DZ-Einträge werden einzeln gelesen und pro Archiv-
    /// Änderungsdatum gecacht. Ohne Signaturquelle (kompiliert, keine Doku)
    /// gibt es ehrlich keine Hilfe — niemals erfundene Parameter.
    private func signature(
        forComponentMethod method: FourDComponentMethod
    ) -> FourDMethodSignature? {
        switch method.source {
        case .sourceFile(let url), .documentation(let url):
            return signature(for: url)
        case .zipEntry(let archive, let entryPath):
            let key = archive.path + "#" + entryPath
            let modified = (try? FileManager.default
                .attributesOfItem(atPath: archive.path)[.modificationDate] as? Date)
                .flatMap { $0 } ?? .distantPast
            if let cached = cache[key], cached.modified == modified {
                return cached.signature
            }
            guard let entries = FourDZipArchive.entries(of: archive),
                  let entry = entries.first(where: { $0.path == entryPath }),
                  let data = FourDZipArchive.data(
                    of: entry, in: archive,
                    maximumSize: FourDComponentIndex.maximumEntryBytes
                  ),
                  let source = FourDComponentIndex.decodeText(data) else {
                return nil
            }
            let parsed = FourDSignatureParser.parse(methodSource: source)
            cache[key] = (modified, parsed)
            return parsed
        case .nameOnly:
            return nil
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
