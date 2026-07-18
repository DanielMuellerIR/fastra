// GoToTarget.swift
//
// Alt-Doppelklick „Gehe zum Ziel" (Etappe 7 Wunschpaket 2026-07c) — nach
// dem Vorbild des 4D-Methodeneditors: Alt-Doppelklick auf einen Namen
// springt zur Definition.
//
// GESTEN-ENTSCHEIDUNG (Spez verlangt kurze Begründung): Es bleibt beim
// Alt-Doppelklick des Vorbilds. Die Alt-Drag-Spaltenauswahl kollidiert
// nicht — sie beginnt mit einem EINZELklick und Ziehen, der Doppelklick
// wird hier vorher abgefangen (`clickCount == 2`, `colsel`-Selbsttest
// bleibt grün). CESEs eigenes ⌘-Hover-Springen braucht tree-sitter-
// Identifier-Knoten und funktioniert für 4D (Plaintext-Grammatik) und
// Markdown-Links nicht — deshalb eine eigene, generische Provider-Geste.
//
// Provider-Schnittstelle: bewusst GENAU zwei Provider (4D und Markdown),
// nichts auf Vorrat. Nicht auflösbare Ziele melden sich dezent (Beep +
// kurzes Aufblitzen + Seitenleisten-Hinweis) — kein stiller No-Op.

import AppKit
import CodeEditTextView
import CodeEditSourceEditor

// MARK: - Aktionen und Provider-Schnittstelle

/// Ergebnis einer Ziel-Auflösung.
enum GoToTargetAction: Equatable {
    /// Datei im Editor öffnen (4D-Methode/Klasse, relative Markdown-Datei).
    case openFile(URL)
    /// In der AKTUELLEN Datei springen (Function-Definition, Markdown-Anker).
    case jumpToRange(NSRange)
    /// Im Browser öffnen (http/https/mailto).
    case openURL(URL)
    /// Fallback 4D: Suchdialog mit Ordner-Bereich und dem Namen öffnen.
    case searchProject(String)
    /// Verständliche, dezente Meldung — nie ein stiller No-Op.
    case notFound(String)
}

/// Eingaben einer Auflösung — pure Daten, damit die Provider ohne UI
/// testbar bleiben (FileManager injizierbar).
struct GoToTargetContext {
    let text: String
    /// UTF-16-Offset des Doppelklicks.
    let location: Int
    /// Datei des aktiven Tabs (nil bei unbenannten Tabs).
    let documentURL: URL?
    /// Projektwurzel der Seitenleiste (nil ohne Projekt).
    let projectURL: URL?
    var fileManager: FileManager = .default
}

/// Ein Provider je Sprache/Dokumenttyp. `nil` = an dieser Stelle ist kein
/// Ziel (die Geste reicht das Ereignis dann normal weiter).
protocol GoToTargetProvider {
    static func resolve(_ context: GoToTargetContext) -> GoToTargetAction?
}

/// Wählt den Provider nach Dateityp. Andere Typen: bewusst KEIN Provider —
/// weitere Sprachen sind späterer Ausbau (nichts auf Vorrat bauen).
enum GoToTarget {
    static func provider(forFileName name: String) -> GoToTargetProvider.Type? {
        switch (name as NSString).pathExtension.lowercased() {
        case "4dm": return FourDGoToTarget.self
        case "md", "markdown": return MarkdownGoToTarget.self
        default: return nil
        }
    }

    /// Die Wort-Phrase unter dem Cursor (Wortzeichen plus einzelne
    /// Leerzeichen — 4D-Namen sind mehrwortig). Für Tests öffentlich.
    static func phraseRange(in text: String, at location: Int) -> NSRange? {
        let scalars = Array(text.utf16)
        guard location >= 0, location <= scalars.count else { return nil }

        func char(_ at: Int) -> Character? {
            guard at >= 0, at < scalars.count,
                  let scalar = Unicode.Scalar(scalars[at]) else { return nil }
            return Character(scalar)
        }
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }

        // Startpunkt: das Zeichen unterm Klick oder direkt davor.
        var anchor = location
        if !(char(anchor).map(isWordChar) ?? false) {
            anchor -= 1
            guard char(anchor).map(isWordChar) ?? false else { return nil }
        }
        var start = anchor
        while let c = char(start - 1) {
            if isWordChar(c) { start -= 1; continue }
            if c == " ", let before = char(start - 2), isWordChar(before) {
                start -= 2
                continue
            }
            break
        }
        var end = anchor + 1
        while let c = char(end) {
            if isWordChar(c) { end += 1; continue }
            if c == " ", let after = char(end + 1), isWordChar(after) {
                end += 2
                continue
            }
            break
        }
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    static func substring(_ text: String, _ range: NSRange) -> String {
        guard let stringRange = Range(range, in: text) else { return "" }
        return String(text[stringRange])
    }
}

// MARK: - Provider 4D

/// 4D: Methodenname → Projektmethode (`Project/Sources/Methods/<Name>.4dm`),
/// Function-Definition in der aktuellen Klassendatei, Klassendatei in
/// `Project/Sources/Classes/`. Fallback: Suche im Projekt.
enum FourDGoToTarget: GoToTargetProvider {

    static func resolve(_ context: GoToTargetContext) -> GoToTargetAction? {
        guard let range = GoToTarget.phraseRange(in: context.text,
                                                 at: context.location) else {
            return nil
        }
        var name = GoToTarget.substring(context.text, range)
            .trimmingCharacters(in: .whitespaces)
        // Ein Doppelklick auf der Definitionszeile fängt das führende
        // Schlüsselwort mit ein („Function zwei") — Keyword-Wörter vorn
        // abwerfen, übrig bleibt der eigentliche Name.
        var words = name.split(separator: " ").map(String.init)
        while let first = words.first,
              FourDTokenizer.keywords.contains(first.lowercased()) {
            words.removeFirst()
        }
        name = words.joined(separator: " ")
        guard !name.isEmpty, name.first?.isLetter == true else { return nil }
        // Bekannte 4D-Befehle/Keywords haben keine Projektdefinition —
        // dort gibt es nichts anzuspringen (kein irreführender Fallback).
        let lowered = name.lowercased()
        if FourDSymbols.commandDetails[lowered] != nil
            || FourDTokenizer.keywords.contains(lowered) {
            return nil
        }

        // 1) Function-Definition in der aktuellen Datei (Klassen-Methoden).
        if let functionRange = functionDefinitionRange(named: name,
                                                       in: context.text) {
            return .jumpToRange(functionRange)
        }
        // 2) Projektmethode bzw. Klasse im 4D-Projektbaum.
        for root in sourceRoots(context: context) {
            let method = root.appendingPathComponent("Methods/\(name).4dm")
            if context.fileManager.fileExists(atPath: method.path) {
                return .openFile(method)
            }
            let klass = root.appendingPathComponent("Classes/\(name).4dm")
            if context.fileManager.fileExists(atPath: klass.path) {
                return .openFile(klass)
            }
        }
        // 3) Fallback laut Spez: Suche im Projekt (Ordner-Scope).
        if context.projectURL != nil || context.documentURL != nil {
            return .searchProject(name)
        }
        return .notFound(L10n.format("Kein Ziel für „%@“ gefunden.", name))
    }

    /// `Function <name>` bzw. `Class constructor` am Zeilenanfang der
    /// aktuellen Datei — Ziel ist der Zeilenbeginn (UTF-16-Range).
    static func functionDefinitionRange(named name: String,
                                        in text: String) -> NSRange? {
        let ns = text as NSString
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "^[ \\t]*Function[ \\t]+\(escaped)\\b"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]
        ) else { return nil }
        return regex.firstMatch(in: text,
                                range: NSRange(location: 0, length: ns.length))?
            .range
    }

    /// Mögliche `Project/Sources`-Wurzeln: Vorfahren der aktiven Datei
    /// (eine `.4dm` liegt üblicherweise unter `Project/Sources/…`) und
    /// bekannte Ableger unter der Projektwurzel der Seitenleiste.
    static func sourceRoots(context: GoToTargetContext) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            var isDirectory: ObjCBool = false
            if context.fileManager.fileExists(atPath: url.path,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                roots.append(url)
            }
        }
        if let document = context.documentURL {
            var current = document.deletingLastPathComponent()
            for _ in 0..<8 {
                if current.lastPathComponent == "Sources",
                   current.deletingLastPathComponent()
                       .lastPathComponent == "Project" {
                    add(current)
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        if let project = context.projectURL {
            add(project.appendingPathComponent("Project/Sources"))
            add(project.appendingPathComponent("Sources"))
        }
        return roots
    }
}

// MARK: - Provider Markdown

/// Markdown: Inline-Links/Bilder, Autolinks und nackte URLs. Relative
/// Dateien öffnen im Editor, URLs im Browser, `#anker` springen in der
/// Datei zur Überschrift.
enum MarkdownGoToTarget: GoToTargetProvider {

    static func resolve(_ context: GoToTargetContext) -> GoToTargetAction? {
        guard let target = linkTarget(in: context.text,
                                      at: context.location) else { return nil }
        if target.hasPrefix("http://") || target.hasPrefix("https://")
            || target.hasPrefix("mailto:") {
            guard let url = URL(string: target) else {
                return .notFound(L10n.format("„%@“ ist keine gültige Adresse.",
                                             target))
            }
            return .openURL(url)
        }
        if target.hasPrefix("#") {
            let anchor = String(target.dropFirst())
            if let range = headingRange(forAnchor: anchor, in: context.text) {
                return .jumpToRange(range)
            }
            return .notFound(L10n.format("Keine Überschrift zu „%@“ gefunden.",
                                         target))
        }
        // Relativer (oder absoluter) Dateipfad; ein #anker-Teil hinter dem
        // Pfad wird fürs Öffnen ignoriert.
        let pathPart = target.split(separator: "#", maxSplits: 1)[0]
        let decoded = String(pathPart)
            .removingPercentEncoding ?? String(pathPart)
        guard !decoded.isEmpty else { return nil }
        let resolved: URL
        if decoded.hasPrefix("/") {
            resolved = URL(fileURLWithPath: decoded)
        } else if let base = context.documentURL?.deletingLastPathComponent() {
            resolved = URL(fileURLWithPath: decoded, relativeTo: base)
                .standardizedFileURL
        } else {
            return .notFound(L10n.string("Relative Ziele brauchen eine gespeicherte Datei als Ausgangspunkt."))
        }
        guard context.fileManager.fileExists(atPath: resolved.path) else {
            return .notFound(L10n.format("Datei „%@“ nicht gefunden.", decoded))
        }
        return .openFile(resolved)
    }

    /// Das Link-Ziel unter dem Cursor: Inline-Link/Bild `[…](ziel)`,
    /// Autolink `<https://…>` oder nackte URL. Für Tests öffentlich.
    static func linkTarget(in text: String, at location: Int) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Inline-Links und Bilder: Klick auf Beschriftung ODER Ziel zählt.
        if let regex = try? NSRegularExpression(
            pattern: #"!?\[[^\]\n]*\]\(([^)\n]+)\)"#
        ) {
            for match in regex.matches(in: text, range: full)
            where match.range.contains(location) {
                var target = ns.substring(with: match.range(at: 1))
                // Optionalen Titel (`pfad "Titel"`) abtrennen.
                if let quote = target.range(of: " \"") {
                    target = String(target[..<quote.lowerBound])
                }
                return target.trimmingCharacters(in: .whitespaces)
            }
        }
        if let regex = try? NSRegularExpression(
            pattern: #"<((?:https?|mailto)[^>\s]+)>"#
        ) {
            for match in regex.matches(in: text, range: full)
            where match.range.contains(location) {
                return ns.substring(with: match.range(at: 1))
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]]+"#) {
            for match in regex.matches(in: text, range: full)
            where match.range.contains(location) {
                var target = ns.substring(with: match.range)
                // Satzzeichen am Ende gehören zum Text, nicht zur URL.
                while let last = target.last, ".,;:!?…".contains(last) {
                    target.removeLast()
                }
                return target
            }
        }
        return nil
    }

    /// Überschrift zum Anker-Slug (gleiche Slug-Regeln wie die Hilfe).
    static func headingRange(forAnchor anchor: String,
                             in text: String) -> NSRange? {
        let ns = text as NSString
        let wanted = anchor.lowercased()
        guard let regex = try? NSRegularExpression(
            pattern: #"^#{1,6}[ \t]+(.+)$"#, options: [.anchorsMatchLines]
        ) else { return nil }
        let full = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: text, range: full) {
            let heading = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            if HelpContent.anchor(forHeading: heading) == wanted {
                return match.range
            }
        }
        return nil
    }
}

// MARK: - Geste (Alt-Doppelklick)

/// Lokaler Maus-Monitor nach dem Muster des Rechtsklick-Menüs
/// (`EditorContextMenu`): Alt-Doppelklick in der Editor-TextView löst die
/// Provider-Auflösung aus; alle anderen Ereignisse laufen unverändert
/// weiter (Alt-Drag-Spaltenauswahl bleibt unberührt).
final class GoToTargetGesture: NSObject {

    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.clickCount == 2,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                  == .option,
              let window = event.window,
              let contentView = window.contentView else { return event }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point),
              let textView = textViewAncestor(of: hit),
              let workspace = Workspace.shared,
              let tab = workspace.activeTab,
              let provider = GoToTarget.provider(
                forFileName: tab.url?.lastPathComponent ?? tab.title
              ) else { return event }
        let textViewPoint = textView.convert(event.locationInWindow, from: nil)
        guard let location = textView.layoutManager
            .textOffsetAtPoint(textViewPoint) else { return event }

        let context = GoToTargetContext(
            text: textView.string,
            location: location,
            documentURL: tab.url,
            projectURL: workspace.projectURL
        )
        guard let action = provider.resolve(context) else {
            // Kein Ziel an dieser Stelle → normales Doppelklick-Verhalten.
            return event
        }
        perform(action, workspace: workspace, textView: textView,
                clickLocation: location)
        return nil
    }

    private func textViewAncestor(of view: NSView) -> TextView? {
        var current: NSView? = view
        while let v = current {
            if let tv = v as? TextView { return tv }
            current = v.superview
        }
        return nil
    }

    /// Führt die aufgelöste Aktion aus. Alles sind normale, sichtbare
    /// Editor-/App-Aktionen — nichts davon schreibt Dateien.
    private func perform(_ action: GoToTargetAction, workspace: Workspace,
                         textView: TextView, clickLocation: Int) {
        switch action {
        case .openFile(let url):
            workspace.loadFile(at: url)
        case .jumpToRange(let range):
            NotificationCenter.default.post(
                name: .fastraJumpToRange, object: workspace,
                userInfo: ["range": NSValue(range: range)]
            )
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .searchProject(let name):
            // Fallback laut Spez: Suche im Projekt — sichtbar über den
            // Suchdialog, Wort als Literal-Suchbegriff.
            workspace.findPattern = name
            workspace.useRegex = false
            workspace.scope = .folder
            workspace.showSearchDialog = true
        case .notFound(let message):
            // Dezent, aber NIE still: Beep, kurzes Aufblitzen am Wort,
            // Hinweis in der Seitenleiste.
            NSSound.beep()
            if let range = GoToTarget.phraseRange(in: textView.string,
                                                  at: clickLocation) {
                flash(range: range, in: textView)
            }
            workspace.showSidebarNotice(message)
        }
    }

    /// Kurzes Hervorhebungs-Aufblitzen (gleiche Emphasis-Mechanik wie die
    /// Such-Markierungen).
    private func flash(range: NSRange, in textView: TextView) {
        let id = "fastra.gototarget"
        textView.emphasisManager?.addEmphasis(
            Emphasis(range: range,
                     style: .outline(color: .systemRed, fill: true)),
            for: id
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak textView] in
            textView?.emphasisManager?.removeEmphases(for: id)
        }
    }
}
