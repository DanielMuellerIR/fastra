// MarkdownSourceMarkers.swift
//
// Verknüpft die gerenderte Markdown-Vorschau mit dem Quelltext im Editor:
// Jeder Block im Vorschau-HTML bekommt die Zeile mit, aus der er stammt.
// Ein Klick in die Vorschau kann daraus die Editorposition bestimmen.
//
// Die Blockposition liefert cmark selbst (`CMARK_OPT_SOURCEPOS`). Das erfasst
// alle Blockarten, auch die aus Erweiterungen (Tabellenzeilen, Aufgabenlisten),
// ohne dass wir jede einzeln behandeln müssen. Die Ausgabe ist allerdings
// geschwätzig (`data-sourcepos="12:1-14:23"`) und bezieht sich auf den
// VORVERARBEITETEN Text, weshalb sie hier auf ein knappes `data-srcline="12"`
// mit Originalzeile umgeschrieben wird.
//
// ZEILEN INNERHALB EINES BLOCKS haben bewusst KEINE eigene Marke. Ein Absatz
// aus zehn Quellzeilen ist ein <p> und kennt nur seine erste Zeile — die
// restlichen löst das Vorschau-JS auf, indem es die Zeilenumbrüche vor der
// Klickstelle zählt. Im gerenderten HTML steht jeder Umbruch des Quelltextes
// nämlich als echtes Newline im Text.
//
// Der naheliegende Weg — unsichtbare <span>-Marken in den Baum hängen —
// funktioniert hier NICHT: Die Vorschau rendert bewusst ohne
// `CMARK_OPT_UNSAFE`, weshalb cmark jedes rohe HTML durch
// „<!-- raw HTML omitted -->" ersetzt. Das gilt auch für selbst eingefügte
// Marken. Diese Sicherheitseinstellung dafür aufzuweichen wäre der falsche
// Tausch: Sie verhindert HTML-Injektion aus geöffneten Markdown-Dateien.

import Foundation
import cmark_gfm

enum MarkdownSourceMarkers {

    /// Attributname, unter dem die Quellzeile im HTML steht. Bewusst kurz:
    /// er taucht bei großen Dokumenten sehr oft auf.
    static let attribute = "data-srcline"

    // MARK: Codeblöcke

    /// Erste INHALTSZEILE jedes Codeblocks, in Dokumentreihenfolge.
    ///
    /// Nötig, weil cmark als Blockposition eines Fenced-Blocks die Zeile mit
    /// den Backticks meldet. Ein Klick auf die erste Codezeile landete damit
    /// im Editor auf der ``` -Zeile darüber.
    ///
    /// Ob ein Block eingerückt oder mit Fences geschrieben wurde, verrät die
    /// öffentliche API nicht direkt. Der Vergleich von belegten Quellzeilen
    /// mit den tatsächlichen Inhaltszeilen tut es: Nur bei Fences ist der
    /// Bereich größer als der Inhalt, nämlich um die beiden Fence-Zeilen.
    static func codeBlockContentLines(
        document: UnsafeMutablePointer<cmark_node>,
        extraction: MarkdownMath.Extraction
    ) -> [Int] {
        guard let iterator = cmark_iter_new(document) else { return [] }
        defer { cmark_iter_free(iterator) }

        var lines: [Int] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator),
                  cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK else { continue }

            let start = Int(cmark_node_get_start_line(node))
            let end = Int(cmark_node_get_end_line(node))
            let literal = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
            // Der Inhalt endet immer mit einem Newline; die Zahl der Umbrüche
            // ist deshalb die Zahl der Codezeilen.
            let contentLines = literal.isEmpty
                ? 0
                : literal.components(separatedBy: "\n").count - 1
            let isFenced = (end - start + 1) > contentLines
            lines.append(extraction.originalLine(for: isFenced ? start + 1 : start))
        }
        return lines
    }

    // MARK: Blockpositionen umschreiben

    // Ein Codeblock trägt sein Attribut immer direkt am <pre>; cmark rendert
    // keinen anderen Block als <pre>.
    private static let codeBlockPosition = try! NSRegularExpression(
        pattern: #"(?<=<pre)\sdata-sourcepos="\d+:\d+-\d+:\d+""#
    )
    private static let anyPosition = try! NSRegularExpression(
        pattern: #"\sdata-sourcepos="(\d+):\d+-\d+:\d+""#
    )

    /// Ersetzt die ausführlichen `data-sourcepos`-Angaben des Renderers durch
    /// `data-srcline` mit der Zeile im Originaldokument.
    ///
    /// - Parameter codeBlockLines: Inhaltszeilen aus `codeBlockContentLines`,
    ///   in derselben Reihenfolge, in der die `<pre>`-Elemente im HTML stehen.
    static func rewriteBlockPositions(in html: String,
                                      extraction: MarkdownMath.Extraction,
                                      codeBlockLines: [Int] = []) -> String {
        // Codeblöcke zuerst: Sie brauchen die korrigierte Inhaltszeile statt
        // der von cmark gemeldeten Fence-Zeile.
        let withCode = replaceCodeBlockPositions(in: html, lines: codeBlockLines)

        // Alles Übrige übernimmt die gemeldete Startzeile, umgerechnet aufs
        // Original. Die oben ersetzten Codeblöcke tragen kein
        // `data-sourcepos` mehr und werden hier nicht noch einmal getroffen.
        let mutable = NSMutableString(string: withCode)
        let matches = anyPosition.matches(
            in: withCode,
            range: NSRange(withCode.startIndex..., in: withCode)
        )
        // Von hinten ersetzen, damit die noch offenen Trefferbereiche gültig bleiben.
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let reported = Int((withCode as NSString).substring(with: match.range(at: 1))) ?? 1
            let line = extraction.originalLine(for: reported)
            mutable.replaceCharacters(in: match.range, with: " \(attribute)=\"\(line)\"")
        }
        return mutable as String
    }

    private static func replaceCodeBlockPositions(in html: String,
                                                  lines: [Int]) -> String {
        guard !lines.isEmpty else { return html }
        let mutable = NSMutableString(string: html)
        let matches = codeBlockPosition.matches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        )
        // Rückwärts ersetzen (stabile Bereiche), aber mit dem VORWÄRTS-Index
        // zählen — nur so passt das n-te <pre> zum n-ten Codeblock des Baums.
        for (index, match) in matches.enumerated().reversed() {
            guard index < lines.count else { continue }
            mutable.replaceCharacters(in: match.range,
                                      with: " \(attribute)=\"\(lines[index])\"")
        }
        return mutable as String
    }
}
