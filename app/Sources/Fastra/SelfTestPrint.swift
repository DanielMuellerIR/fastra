// Vollständige Druck-Selbsttestkette; Laufzeit, Fixturebesitz und Abschluss
// bleiben beim gestarteten SelfTest. Fortsetzungen halten diesen Besitzerwert.
import Foundation
import AppKit
import PDFKit

struct SelfTestPrint {
    private let waitForBody: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
    private let finish: (Bool, String) -> Never
    private let windows: () -> [NSWindow]
    private let menuItemBody: (String, NSEvent.ModifierFlags, NSMenu?) -> NSMenuItem?
    private let writeSolidPNGBody: (URL, Int, Int, NSColor) throws -> Void
    private let writeSinglePagePDFBody: (URL) throws -> Void
    private let windowsSummary: () -> String
    private let registerFixtureDirectory: (URL) -> Void

    init(waitFor: @escaping (TimeInterval, TimeInterval, @escaping () -> Bool,
                            @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void,
         finish: @escaping (Bool, String) -> Never,
         windows: @escaping () -> [NSWindow],
         menuItem: @escaping (String, NSEvent.ModifierFlags, NSMenu?) -> NSMenuItem?,
         writeSolidPNG: @escaping (URL, Int, Int, NSColor) throws -> Void,
         writeSinglePagePDF: @escaping (URL) throws -> Void,
         windowsSummary: @escaping () -> String,
         registerFixtureDirectory: @escaping (URL) -> Void) {
        self.waitForBody = waitFor
        self.finish = finish
        self.windows = windows
        self.menuItemBody = menuItem
        self.writeSolidPNGBody = writeSolidPNG
        self.writeSinglePagePDFBody = writeSinglePagePDF
        self.windowsSummary = windowsSummary
        self.registerFixtureDirectory = registerFixtureDirectory
    }

    // Argumentlabels bleiben an den Ablaufaufrufen erhalten; die Funktionswerte
    // führen weiterhin SelfTests private Helfer aus.
    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then: @escaping () -> Void) {
        waitForBody(budget, pause, condition, onTimeout, then)
    }

    private func menuItem(forExactKeyEquivalent key: String,
                          modifiers: NSEvent.ModifierFlags,
                          in menu: NSMenu?) -> NSMenuItem? {
        menuItemBody(key, modifiers, menu)
    }

    private func writeSolidPNG(to url: URL, width: Int, height: Int,
                              color: NSColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) throws {
        try writeSolidPNGBody(url, width, height, color)
    }

    private func writeSinglePagePDF(to url: URL) throws {
        try writeSinglePagePDFBody(url)
    }

    // MARK: - Drucken

    /// Beweist den vollständigen Druckweg, ohne einen Drucker zu brauchen:
    /// Jeder Auftrag läuft mit `jobDisposition = .save` in eine PDF-Datei, und
    /// geprüft wird danach am Ergebnis — Seitenzahl und wirklich enthaltener
    /// Text. Ein Test, der nur „kein Fehler geworfen" prüft, würde einen leeren
    /// oder einseitigen Ausdruck durchgehen lassen.
    ///
    /// Sechs Fassungen in neun PDFs: mehrseitiger Quelltext mit Kopf-/Fußzeile
    /// und Zeilennummern (einschließlich Swift mit/ohne Syntaxfarben), gerenderte
    /// Markdown-Vorschau und Markdown-Quelltext (die Wahl muss etwas ändern),
    /// Hex-Abzug des sichtbaren Abschnitts, Bild samt erhaltenem Vorschau-Snapshot
    /// nach Plattenersetzung sowie PDF.
    func runPrintTest(ws: Workspace) {
        // Die erzeugten PDFs sind das eigentliche Ergebnis dieses Tests. Wer
        // sie ansehen will (Sichtprüfung von Umbruch, Kopf- und Fußzeile),
        // setzt FASTRA_PRINT_TEST_OUTPUT_DIR — dann bleiben sie liegen.
        let keepDirectory = ProcessInfo.processInfo.environment[
            "FASTRA_PRINT_TEST_OUTPUT_DIR"
        ]
        // Immer einen frischen Unterordner anlegen: Feste Fixture-Namen wie
        // quelltext.txt und bild.png dürfen keine vorhandenen Nutzerdateien überschreiben.
        let base = (keepDirectory.map { URL(fileURLWithPath: $0) }
            ?? selfTestTemporaryDirectory())
            .appendingPathComponent("fastra-print-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: base,
                                                    withIntermediateDirectories: true)
        } catch {
            finish(false, "Testordner nicht anlegbar: \(error.localizedDescription)")
        }
        if keepDirectory == nil { registerFixtureDirectory(base) }

        let txt = base.appendingPathComponent("quelltext.txt")
        // 400 Zeilen: sicher mehr als eine Seite, und die letzte Zeile ist ein
        // Beleg dafür, dass die Seitenaufteilung nichts verschluckt.
        let content = (1...400).map { "Zeile \($0): abcdefghijklmnop" }
            .joined(separator: "\n")
        do { try content.write(to: txt, atomically: true, encoding: .utf8) }
        catch { finish(false, "Quelltext-Fixture nicht schreibbar") }

        ws.loadFile(at: txt) { ok in
            guard ok else { finish(false, "loadFile (Quelltext) schlug fehl") }
            guard let document = ws.printableDocument else {
                finish(false, "Textdatei meldet keine Druckvorlage")
            }
            guard PrintRouting.defaultTarget(document) == .source else {
                finish(false, "⌘P nimmt bei einer Textdatei nicht den Quelltext")
            }
            printToPDF(target: .source, ws: ws, base: base, name: "quelltext") { pdf, text in
                guard pdf.pageCount >= 2 else {
                    finish(false, "400 Zeilen ergeben nur \(pdf.pageCount) Seite(n)")
                }
                guard text.contains("Zeile 1:"), text.contains("Zeile 400:") else {
                    finish(false, "erste oder letzte Zeile fehlt im Ausdruck")
                }
                guard text.contains("quelltext.txt") else {
                    finish(false, "Kopfzeile ohne Dokumentnamen")
                }
                guard text.contains(PrintDecoration.footerRight(page: 1, of: pdf.pageCount))
                        || text.contains(PrintDecoration.footerRight(page: 1, of: nil)) else {
                    finish(false, "Fußzeile ohne Seitenzahl")
                }
                runPrintSyntaxColorPart(ws: ws, base: base)
            }
        }
    }

    /// Syntaxfarben auf jeder Seite eines mehrseitigen Swift-Ausdrucks prüfen,
    /// auch für im Editor nie sichtbare Zeilen. Ohne Syntaxfarben bleibt derselbe
    /// Text einfarbig; Inhalt, Seitenzahl und Kopfzeile bleiben gleich.
    private func runPrintSyntaxColorPart(ws: Workspace, base: URL) {
        let swift = base.appendingPathComponent("farben.swift")
        let code = (1...400).map {
            "let wert\($0) = \"Text \($0)\" // Kommentar \($0)"
        }.joined(separator: "\n")
        do { try code.write(to: swift, atomically: true, encoding: .utf8) }
        catch { finish(false, "Swift-Fixture nicht schreibbar") }
        let defaults = ws.preferencesStore
        defaults.set(true, forKey: PrintPreferences.Keys.syntaxColors)
        ws.loadFile(at: swift) { ok in
            guard ok else { finish(false, "loadFile (Swift) schlug fehl") }
            printToPDF(target: .source, ws: ws, base: base, name: "farben") { colored, coloredText in
                guard colored.pageCount >= 2 else {
                    finish(false, "400 Swift-Zeilen ergeben nur \(colored.pageCount) Seite(n)")
                }
                for page in 0..<colored.pageCount
                where !pageHasPixel(colored, page: page, matching: isSaturatedColor) {
                    finish(false, "Seite \(page + 1) des Farbausdrucks trägt keine Tokenfarbe")
                }
                guard coloredText.contains("wert400"), coloredText.contains("farben.swift") else {
                    finish(false, "letzte Swift-Zeile oder Kopfzeile fehlt im Farbausdruck")
                }
                defaults.set(false, forKey: PrintPreferences.Keys.syntaxColors)
                printToPDF(target: .source, ws: ws, base: base, name: "farben-einfarbig") { mono, monoText in
                    defaults.set(true, forKey: PrintPreferences.Keys.syntaxColors)
                    guard mono.pageCount == colored.pageCount else {
                        finish(false, "einfarbiger Ausdruck hat \(mono.pageCount) statt "
                               + "\(colored.pageCount) Seiten")
                    }
                    for page in 0..<mono.pageCount
                    where pageHasPixel(mono, page: page, matching: isSaturatedColor) {
                        finish(false, "Seite \(page + 1) des einfarbigen Ausdrucks trägt Farbe")
                    }
                    guard monoText == coloredText else {
                        finish(false, "Farben verändern den gedruckten Text")
                    }
                    runPrintMarkdownPart(ws: ws, base: base)
                }
            }
        }
    }

    /// Eine Tokenfarbe ist bunt (Rot-, Grün- oder Blauanteil weichen deutlich
    /// voneinander ab); Schwarz, Weiß und Grau sind es nicht.
    private func isSaturatedColor(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return (channels.max() ?? 0) - (channels.min() ?? 0) > 0.2
    }

    /// Rendert eine Seite als Bitmap und sucht in einem dichten Raster nach
    /// einem Pixel, das die Bedingung erfüllt. Dicht, weil Glyphen nur wenige
    /// Pixel hoch sind und ein grobes Raster sie verfehlen kann.
    private func pageHasPixel(
        _ pdf: PDFDocument, page index: Int, matching predicate: (NSColor) -> Bool
    ) -> Bool {
        guard let page = pdf.page(at: index) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let image = page.thumbnail(of: bounds.size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return false }
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let color = rep.colorAt(x: x, y: y), predicate(color) {
                    return true
                }
            }
        }
        return false
    }

    /// Markdown: erst die gerenderte Vorschau, dann derselbe Text als
    /// Quelltext. Die beiden Ausdrucke müssen sich nachweisbar unterscheiden —
    /// sonst wäre die Wahl im Menü ohne Wirkung.
    private func runPrintMarkdownPart(ws: Workspace, base: URL) {
        let markdown = base.appendingPathComponent("bericht.md")
        // Formel und Diagramm gehören ausdrücklich dazu: Sie entstehen erst im
        // Dokument (KaTeX, Mermaid) und beweisen damit, dass der Ausdruck auf
        // das fertige Rendern wartet statt das halbfertige Dokument zu drucken.
        let text = """
        # Druckprobe

        Ein Absatz mit **Fettung** und der Formel $E = mc^2$.

        | Spalte | Wert |
        | --- | --- |
        | Messung | Tabellenwert |

        - erster Punkt
        - zweiter Punkt

        ```mermaid
        graph LR
          Anfangsknoten --> Endknoten
        ```
        """
        do { try text.write(to: markdown, atomically: true, encoding: .utf8) }
        catch { finish(false, "Markdown-Fixture nicht schreibbar") }

        ws.loadFile(at: markdown) { ok in
            guard ok else { finish(false, "loadFile (Markdown) schlug fehl") }
            guard let document = ws.printableDocument else {
                finish(false, "Markdown meldet keine Druckvorlage")
            }
            guard PrintRouting.availableTargets(document).contains(.markdownPreview),
                  PrintRouting.availableTargets(document).contains(.source) else {
                finish(false, "Markdown bietet nicht beide Fassungen an")
            }
            printToPDF(target: .markdownPreview, ws: ws, base: base,
                       name: "vorschau") { previewPDF, previewText in
                guard previewPDF.pageCount >= 1 else {
                    finish(false, "Vorschau-Ausdruck hat keine Seite")
                }
                guard previewText.contains("Druckprobe"),
                      previewText.contains("Tabellenwert") else {
                    finish(false, "Vorschau-Ausdruck ohne gerenderten Inhalt")
                }
                // Das Diagramm steht als echter SVG-Text im PDF, wenn Mermaid
                // fertig geworden ist. Fehlt der Knotenname oder steht statt
                // des Diagramms die Fehlermeldung da, wurde zu früh gedruckt.
                guard previewText.contains("Anfangsknoten"),
                      previewText.contains("Endknoten") else {
                    finish(false, "Vorschau-Ausdruck ohne gerendertes Diagramm")
                }
                guard !previewText.contains(
                    L10n.string("Diagramm konnte nicht gerendert werden.")) else {
                    finish(false, "Diagramm im Ausdruck als Fehler gemeldet")
                }
                guard !previewText.contains("```mermaid") else {
                    finish(false, "Diagramm im Ausdruck als roher Codeblock")
                }
                // Die Formel gehört ebenfalls geprüft: Gerendert (KaTeX) sind
                // die TeX-Zeichen weg. Steht „mc^2" im PDF, wurde entweder
                // roher Quelltext gedruckt oder KaTeX ist gescheitert und hat
                // seine Fehlerdarstellung (den TeX-Quelltext) ausgegeben.
                guard !previewText.contains("mc^2") else {
                    finish(false, "Formel im Ausdruck nicht gerendert (TeX-Quelltext sichtbar)")
                }
                // Die gerenderte Formel im PDF positiv nachweisen: KaTeX-Matheschriften
                // liefern bei Textauslese „𝐸=𝑚𝑐2“ mit mathematischen Kursivzeichen
                // (U+1D438, U+1D45A, U+1D450). Roher Quelltext enthielte normale Buchstaben.
                // Eine reine Prüfung auf Abwesenheit des Quelltexts würde auch bei ganz
                // fehlender Formel bestehen.
                let compactPreview = String(previewText.filter { !$0.isWhitespace })
                guard compactPreview.contains("𝐸=𝑚𝑐2") else {
                    finish(false, "gerenderte Formel fehlt im Ausdruck "
                           + "(erwartet „𝐸=𝑚𝑐2\" im leerraumfreien PDF-Text) — "
                           + "Text: \(compactPreview.prefix(500))")
                }
                // Gerendert heißt: Die Auszeichnungszeichen sind weg. Stünden
                // „# " oder die Tabellenstriche im PDF, wäre versehentlich der
                // Quelltext gedruckt worden.
                guard !previewText.contains("# Druckprobe"),
                      !previewText.contains("| --- |") else {
                    finish(false, "Vorschau-Ausdruck enthält rohes Markdown")
                }
                printToPDF(target: .source, ws: ws, base: base,
                           name: "md-quelltext") { _, sourceText in
                    guard sourceText.contains("# Druckprobe") else {
                        finish(false, "Quelltext-Ausdruck ohne Markdown-Auszeichnung")
                    }
                    runPrintHexPart(ws: ws, base: base)
                }
            }
        }
    }

    /// Hex: Gedruckt wird der sichtbare Abschnitt. Der Test wartet deshalb
    /// darauf, dass die Hex-Ansicht ihren geladenen Abschnitt gemeldet hat.
    private func runPrintHexPart(ws: Workspace, base: URL) {
        let binary = base.appendingPathComponent("daten.bin")
        var bytes = Data()
        for index in 0..<2048 { bytes.append(UInt8(index % 251)) }
        // Ein Nullbyte macht die Datei für den Loader eindeutig binär.
        bytes[0] = 0
        do { try bytes.write(to: binary) }
        catch { finish(false, "Binär-Fixture nicht schreibbar") }

        ws.loadFile(at: binary) { ok in
            guard ok else { finish(false, "loadFile (Binärdatei) schlug fehl") }
            guard ws.activeViewMode == .hex else {
                finish(false, "Binärdatei öffnet nicht in der Hex-Ansicht")
            }
            pollPrintHexPage(ws: ws, base: base)
        }
    }

    private func pollPrintHexPage(ws: Workspace, base: URL) {
        waitFor(budget: 15, pause: 0.25,
                condition: {
                    guard let page = ws.visiblePrintPage else { return false }
                    return !page.text.isEmpty
                },
                onTimeout: { book in
                    finish(false, "Hex-Ansicht meldet keinen geladenen Abschnitt — \(book.summary)")
                },
                then: {
                    guard let document = ws.printableDocument,
                          PrintRouting.defaultTarget(document) == .hexDump else {
                        finish(false, "⌘P nimmt in der Hex-Ansicht nicht den Abzug")
                    }
                    printToPDF(target: .hexDump, ws: ws, base: base, name: "hex") { pdf, text in
                        guard pdf.pageCount >= 1 else {
                            finish(false, "Hex-Ausdruck hat keine Seite")
                        }
                        guard text.contains("000000000000"), text.contains("|") else {
                            finish(false, "Hex-Ausdruck ohne Adressspalte oder ASCII-Spalte")
                        }
                        // Jede Rasterzeile muss vollständig auf einer Druckzeile
                        // stehen: Adresse, Bytes und die ASCII-Spalte bis zum
                        // schließenden Strich. Bricht die Zeile um, ist der Abzug
                        // unlesbar — genau das passierte, solange die Druckschrift
                        // nicht an die Seitenbreite angepasst wurde.
                        let addressRows = text.split(separator: "\n").filter { row in
                            row.count >= 12 && row.prefix(12).allSatisfy { $0.isHexDigit }
                        }
                        guard addressRows.count >= 16 else {
                            finish(false, "Hex-Ausdruck enthält nur \(addressRows.count) "
                                   + "Rasterzeilen")
                        }
                        // Geprüft wird auf die beiden senkrechten Striche der
                        // ASCII-Spalte, nicht auf das Zeilenende: Die Textauslese des
                        // PDFs hängt an die letzte Zeile einer Seite die Fußzeile an.
                        // Eine umgebrochene Rasterzeile bricht dagegen vor oder in der
                        // ASCII-Spalte ab und hat damit weniger als zwei Striche.
                        if let wrapped = addressRows.first(where: {
                            $0.filter { $0 == "|" }.count < 2
                        }) {
                            finish(false, "Hex-Rasterzeile umgebrochen: \(wrapped)")
                        }
                        runPrintImageAndPDFPart(ws: ws, base: base,
                                                hexPages: pdf.pageCount)
                    }
                })
    }

    /// Bild und PDF: Beides sind Vorschau-Ansichten ohne Editor-Text. Sie
    /// beweisen, dass „Drucken" nicht am Texteditor hängt.
    private func runPrintImageAndPDFPart(ws: Workspace, base: URL,
                                               hexPages: Int) {
        let png = base.appendingPathComponent("bild.png")
        do { try writeSolidPNG(to: png, width: 64, height: 32) }
        catch { finish(false, "PNG-Fixture nicht schreibbar") }

        ws.loadFile(at: png) { ok in
            guard ok else { finish(false, "loadFile (PNG) schlug fehl") }
            guard let document = ws.printableDocument,
                  PrintRouting.defaultTarget(document) == .image else {
                finish(false, "⌘P nimmt bei einem Bild nicht die Bildvorschau")
            }
            // Gedruckt wird das gemeldete Objekt der Vorschau, kein Neuladen
            // von der Platte — der Test wartet deshalb wie beim Hex-Abzug,
            // bis die Ansicht ihren Snapshot gemeldet hat.
            pollPreviewSnapshot(ws: ws, label: "Bild") {
            printToPDF(target: .image, ws: ws, base: base, name: "bild") { imagePDF, imageText in
                guard imagePDF.pageCount == 1 else {
                    finish(false, "Bildausdruck hat \(imagePDF.pageCount) Seiten "
                           + "statt einer")
                }
                guard imageText.contains("bild.png") else {
                    finish(false, "Bildausdruck ohne Kopfzeile")
                }
                // Das Bild-Fixture ist vollflächig rot. Farbdominanz prüfen, damit eine
                // leere Seite mit Kopfzeile nicht besteht. Feste RGB-Werte wären wegen
                // Farbraumwandlung im Druckweg ungeeignet.
                guard firstPageHasPixel(imagePDF, matching: { color in
                    color.redComponent > 0.6
                        && color.redComponent
                            - max(color.greenComponent, color.blueComponent) > 0.25
                }) else {
                    finish(false, "Bildausdruck zeigt das rote Fixture-Bild nicht")
                }
                // Die Datei durch ein blaues Bild ersetzen, während die Vorschau den roten
                // Snapshot behält. Auch der nächste Ausdruck muss rot bleiben; so wird ein
                // unerlaubtes Neuladen von der Platte erkennbar.
                do {
                    try writeSolidPNG(to: png, width: 64, height: 32,
                                      color: NSColor(srgbRed: 0, green: 0,
                                                     blue: 1, alpha: 1))
                } catch { finish(false, "Blaues Ersatz-PNG nicht schreibbar") }
                printToPDF(target: .image, ws: ws, base: base,
                           name: "bild-ersetzt") { replacedPDF, _ in
                guard firstPageHasPixel(replacedPDF, matching: { color in
                    color.redComponent > 0.6
                        && color.redComponent
                            - max(color.greenComponent, color.blueComponent) > 0.25
                }) else {
                    finish(false, "Bildausdruck lädt von der Platte neu, statt "
                           + "den sichtbaren Vorschau-Stand zu drucken")
                }
                let sourcePDF = base.appendingPathComponent("vorlage.pdf")
                do { try writeSinglePagePDF(to: sourcePDF) }
                catch { finish(false, "PDF-Fixture nicht schreibbar") }
                ws.loadFile(at: sourcePDF) { pdfLoaded in
                    guard pdfLoaded else { finish(false, "loadFile (PDF) schlug fehl") }
                    guard let pdfDocument = ws.printableDocument,
                          PrintRouting.defaultTarget(pdfDocument) == .pdf else {
                        finish(false, "⌘P nimmt bei einem PDF nicht das PDF")
                    }
                    // Auch das PDF druckt sein gemeldetes Vorschau-Objekt.
                    pollPreviewSnapshot(ws: ws, label: "PDF") {
                    printToPDF(target: .pdf, ws: ws, base: base,
                               name: "pdf-druck") { printed, _ in
                        guard printed.pageCount == 1 else {
                            finish(false, "PDF-Ausdruck hat \(printed.pageCount) "
                                   + "Seiten statt einer")
                        }
                        // Das blaue Rechteck im Vorlagen-PDF über Farbdominanz nachweisen.
                        // Die Seitenzahl allein würde auch bei leerem Inhalt stimmen.
                        guard firstPageHasPixel(printed, matching: { color in
                            color.blueComponent > 0.6
                                && color.blueComponent
                                    - max(color.redComponent, color.greenComponent) > 0.25
                        }) else {
                            finish(false, "PDF-Ausdruck zeigt das blaue Fixture-Rechteck nicht")
                        }
                        runPrintPanelPart(ws: ws, base: base, hexPages: hexPages)
                    }
                    }
                }
                }
            }
            }
        }
    }

    /// Auf den gemeldeten Bild-/PDF-Snapshot warten: Dieses Objekt ist die
    /// Druckvorlage (wie in `pollPrintHexPage`).
    private func pollPreviewSnapshot(ws: Workspace, label: String,
                                            then: @escaping () -> Void) {
        waitFor(budget: 15, pause: 0.25,
                condition: {
                    guard let tab = ws.activeTab else { return false }
                    return ws.visiblePreviewSnapshot(for: tab) != nil
                },
                onTimeout: { book in
                    finish(false, "\(label)-Vorschau meldet kein geladenes "
                           + "Druckobjekt — \(book.summary)")
                },
                then: then)
    }

    /// Der Menüweg: Zum Abschluss prüft der Test die ⌘P-/⌥⌘P-/⇧⌘P-Menüpunkte
    /// strukturell und löst dann den Druckbefehl aus (siehe
    /// `runPrintPanelStage`); daraufhin muss das System-Druckfenster als
    /// Blatt am Dokumentfenster erscheinen — Fenster-Zielwahl und Rückmeldung
    /// des Systemdialogs inklusive. Vorher kommt die Rückfrage vor einem sehr
    /// großen Ausdruck an die Reihe; ihr Prüfgegenstand ist das
    /// Rückfrage-Blatt.
    private func runPrintPanelPart(ws: Workspace, base: URL, hexPages: Int) {
        // Zuerst der große Ausdruck: Über zwei Megabyte Text fragt Fastra
        // vorher nach, weil das Aufteilen in Seiten den Main-Thread belegt.
        // Geprüft wird am echten Blatt, dass diese Frage wirklich kommt — die
        // Schätzung selbst deckt der Unit-Test ab.
        let large = base.appendingPathComponent("gross.txt")
        let block = String(repeating: "Eine Zeile mit etwas Text zum Drucken.\n",
                           count: 60_000)
        do { try block.write(to: large, atomically: true, encoding: .utf8) }
        catch { finish(false, "Großes Fixture nicht schreibbar") }
        guard block.utf8.count > PrintVolume.confirmationThresholdBytes else {
            finish(false, "Großes Fixture ist unter der Rückfrage-Schwelle")
        }
        ws.loadFile(at: large) { ok in
            guard ok else { finish(false, "loadFile (großes Dokument) schlug fehl") }
            MainActor.assumeIsolated { DocumentPrinting.printVisibleDocument() }
            pollLargePrintWarning(ws: ws, base: base, hexPages: hexPages)
        }
    }

    /// Wartet auf das Rückfrage-Blatt und schließt es mit „Abbrechen" wieder.
    private func pollLargePrintWarning(ws: Workspace, base: URL,
                                             hexPages: Int) {
        var sheet: NSWindow?
        waitFor(budget: 15, pause: 0.25,
                condition: {
                    sheet = windows().compactMap({ $0.attachedSheet }).first
                    return sheet != nil
                },
                onTimeout: { book in
                    finish(false, "über zwei Megabyte Text fragen nicht nach — \(book.summary)")
                },
                then: {
                    guard let sheet else { finish(false, "Rückfrage-Blatt nach Erfolg verschwunden") }
                    let texts = sheetTexts(in: sheet)
                    guard texts.contains(where: { $0.contains(L10n.string("Großer Ausdruck")) }) else {
                        finish(false, "Blatt vor dem großen Ausdruck ist nicht die Rückfrage: "
                               + texts.joined(separator: " / "))
                    }
                    // Die Seitenschätzung muss eine Zahl nennen, nicht bloß Text.
                    guard texts.contains(where: { $0.contains(where: \.isNumber) }) else {
                        finish(false, "Rückfrage nennt keine geschätzte Seitenzahl")
                    }
                    // Abbrechen ist die zweite Taste. Erst wenn das Blatt wirklich weg
                    // ist, geht der Test weiter: Sonst könnte die anschließende Prüfung
                    // „⌘P öffnet ein Blatt" versehentlich noch dieses hier sehen.
                    MainActor.assumeIsolated {
                        sheet.sheetParent?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                    }
                    pollSheetGone(ws: ws, base: base, hexPages: hexPages)
                })
    }

    private func pollSheetGone(ws: Workspace, base: URL, hexPages: Int) {
        waitFor(budget: 10, pause: 0.25,
                condition: { windows().allSatisfy({ $0.attachedSheet == nil }) },
                onTimeout: { book in
                    finish(false, "die Rückfrage zum großen Ausdruck schließt nicht — \(book.summary)")
                },
                then: {
                    // Abgebrochen heißt abgebrochen: Der große Ausdruck darf jetzt
                    // nicht doch laufen.
                    runPrintPanelStage(ws: ws, base: base, hexPages: hexPages)
                })
    }

    /// Sichtbare Beschriftungen eines Blattes — für die Prüfung, welche
    /// Rückfrage erscheint. Neben Textfeldern zählen auch Button-Titel:
    /// Die Druckdialog-Optionen (Checkboxen) sind nur so auffindbar.
    private func sheetTexts(in sheet: NSWindow) -> [String] {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                texts.append(field.stringValue)
            }
            if let button = view as? NSButton, !button.title.isEmpty {
                texts.append(button.title)
            }
            view.subviews.forEach(walk)
        }
        if let content = sheet.contentView { walk(content) }
        return texts
    }

    private func runPrintPanelStage(ws: Workspace, base: URL, hexPages: Int) {
        ws.loadFile(at: base.appendingPathComponent("quelltext.txt")) { ok in
            guard ok else { finish(false, "loadFile (Quelltext, zweiter Lauf) schlug fehl") }
            // Menüeintrag samt Titel und Kürzel strukturell prüfen, danach den
            // zugehörigen Befehl direkt aufrufen und das Druckblatt prüfen.
            // SwiftUI-Menüpunkte besitzen kein klassisches Target/Action; synthetische
            // ⌘-Events über `NSApp.postEvent` erreichen diese Shortcut-Zustellung nicht.
            // Ein echter System-Tastendruck benötigt zusätzliche Berechtigungen.
            // Der Test belegt deshalb Menübindung und Blatt separat, nicht die komplette
            // Tastenzustellung. Bei reinem Quelltext heißt der Eintrag „Drucken…“.
            guard let printItem = menuItem(forExactKeyEquivalent: "p",
                                           modifiers: [.command],
                                           in: NSApp.mainMenu),
                  printItem.title == L10n.string("Drucken…") else {
                finish(false, "kein ⌘P-Menüpunkt mit Titel „Drucken…\"")
            }
            guard let sourceItem = menuItem(forExactKeyEquivalent: "p",
                                            modifiers: [.command, .option],
                                            in: NSApp.mainMenu),
                  sourceItem.title == L10n.string("Quelltext drucken…"),
                  let layoutItem = menuItem(forExactKeyEquivalent: "p",
                                            modifiers: [.command, .shift],
                                            in: NSApp.mainMenu),
                  layoutItem.title == L10n.string("Papierformat…") else {
                finish(false, "⌥⌘P- (Quelltext drucken…) oder ⇧⌘P-Menüpunkt "
                       + "(Papierformat…) fehlt oder trägt den falschen Titel")
            }
            // Das Druckblatt muss am Dokumentfenster hängen — dem Fenster,
            // das der Befehl über CommandTargeting trifft. Ein Blatt an einem
            // beliebigen anderen Fenster zählt nicht.
            guard let expectedWindow = MainActor.assumeIsolated({
                CommandTargeting.targetDocument()?.window
            }) else {
                finish(false, "kein Dokumentfenster für den Druckbefehl")
            }
            MainActor.assumeIsolated { DocumentPrinting.printVisibleDocument() }
            pollPrintPanel(expectedWindow: expectedWindow, hexPages: hexPages)
        }
    }

    private func pollPrintPanel(expectedWindow: NSWindow, hexPages: Int) {
        // Nur das Blatt am erwarteten Dokumentfenster zählt — nicht irgendein
        // Blatt in irgendeinem Fenster.
        var sheet: NSWindow?
        waitFor(budget: 15, pause: 0.25,
                condition: {
                    sheet = expectedWindow.attachedSheet
                    return sheet != nil
                },
                onTimeout: { book in
                    finish(false, "der Druckbefehl öffnet kein Druckfenster am "
                        + "Dokumentfenster — \(book.summary) — " + windowsSummary())
                },
                then: {
                    guard let sheet else { finish(false, "Druck-Blatt nach Erfolg verschwunden") }
                    // Das Druckblatt muss Fastras Checkboxen enthalten. Das schützt das
                    // Zubehörfeld und unterscheidet den Dialog von einem Fehler-/Warn-NSAlert.
                    let texts = sheetTexts(in: sheet)
                    guard texts.contains(L10n.string("Kopf- und Fußzeile drucken")),
                          texts.contains(L10n.string("Zeilennummern drucken")) else {
                        finish(false, "Blatt am Dokumentfenster ist kein Druckdialog "
                               + "mit Fastra-Optionen (Kopf-/Fußzeile, Zeilennummern) "
                               + "— gefunden: " + texts.joined(separator: " / "))
                    }
                    finish(true, "mehrseitiger Quelltext mit Kopf-/Fußzeile, Syntaxfarben "
                           + "auf jeder Seite eines Swift-Ausdrucks (einfarbig per Einstellung), "
                           + "gerenderte Markdown-Vorschau (Formel + Diagramm), Markdown-Quelltext, "
                           + "Hex-Abzug ohne Umbruch (\(hexPages) Seiten), Bild- und "
                           + "PDF-Ausdruck im PDF geprüft (Bild bleibt nach "
                           + "Platten-Ersetzung der sichtbare Stand); großer Text fragt "
                           + "mit Seitenschätzung nach; ⌘P öffnet das System-Druckfenster "
                           + "am Dokumentfenster mit den Fastra-Optionen")
                })
    }

    /// Druckt in eine PDF-Datei und liefert Dokument plus extrahierten Text.
    ///
    /// Die Datei entsteht über die Druck-Warteschlange; sie kann deshalb einen
    /// Moment nach der Rückmeldung des Auftrags noch wachsen. Der Test wartet
    /// darauf, statt eine halb geschriebene Datei zu lesen.
    private func printToPDF(target: PrintTarget, ws: Workspace, base: URL,
                                   name: String,
                                   then: @escaping (PDFDocument, String) -> Void) {
        let output = base.appendingPathComponent("\(name).pdf")
        // Die Selbsttest-Ketten laufen alle auf dem Main-Thread (jede Stufe
        // hängt an `DispatchQueue.main`); der Compiler weiß das hier nur nicht.
        MainActor.assumeIsolated {
            DocumentPrinting.run(target: target, workspace: ws, window: nil,
                                 savingTo: output) { outcome in
                guard outcome == .printed else {
                    finish(false, "Druck „\(name)\" endete mit \(outcome)")
                }
                pollPrintedPDF(at: output, name: name, then: then)
            }
        }
    }

    private func pollPrintedPDF(at url: URL, name: String,
                                       then: @escaping (PDFDocument, String) -> Void) {
        var document: PDFDocument?
        waitFor(budget: 20, pause: 0.25,
                condition: {
                    guard let candidate = PDFDocument(url: url), candidate.pageCount > 0 else { return false }
                    document = candidate
                    return true
                },
                onTimeout: { book in
                    finish(false, "PDF „\(name)\" ist nicht lesbar — \(book.summary)")
                },
                then: {
                    guard let document else { finish(false, "PDF „\(name)\" nach Erfolg nicht mehr lesbar") }
                    then(document, document.string ?? "")
                })
    }

    /// Rendert die erste Seite eines PDFs als Bitmap und sucht in einem
    /// Abtastraster nach einem Pixel, das die Bedingung erfüllt. Damit weisen
    /// Bild- und PDF-Ausdruck ihre markante Fixture-Fläche nach — die Lage auf
    /// der Seite (Einpassung, Zentrierung) muss der Test dafür nicht kennen.
    private func firstPageHasPixel(
        _ pdf: PDFDocument, matching predicate: (NSColor) -> Bool
    ) -> Bool {
        guard let page = pdf.page(at: 0) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let image = page.thumbnail(of: bounds.size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return false }
        let strideX = max(1, rep.pixelsWide / 48)
        let strideY = max(1, rep.pixelsHigh / 48)
        for x in stride(from: 0, to: rep.pixelsWide, by: strideX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: strideY) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   predicate(color) {
                    return true
                }
            }
        }
        return false
    }
}
