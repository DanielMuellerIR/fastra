// DocumentPrinting.swift
//
// Der ausführende Teil des Druckens: Aus einer Druckvorlage (`PrintTarget`)
// entsteht ein echter `NSPrintOperation`. Die Entscheidungen — was ist
// druckbar, was nimmt ⌘P, wie ist die Fußzeile beschriftet — stehen ohne
// AppKit in `PrintSetup.swift`.
//
// Vier Wege, weil vier verschiedene Dinge gedruckt werden:
//   • Fließtext (Quelltext, Git-Verlauf, Hex-Abzug) → eigener `NSTextView`
//     mit selbst berechneter Seitenaufteilung plus Kopf-/Fußzeile.
//   • Markdown-Vorschau → WebKit druckt die gerenderte Seite. Nur so sieht
//     der Ausdruck wirklich aus wie die Vorschau, inklusive Tabellen,
//     Formeln und Diagrammen.
//   • Bild/SVG-Vorschau → auf eine Seite eingepasst.
//   • PDF → PDFKit druckt das Dokument unverändert Seite für Seite.
//
// Warum die Seitenaufteilung des Textwegs selbst gerechnet wird: Die
// Voreinstellung von `NSView` schneidet eine Seite stur nach Höhe ab und
// zerlegt dabei die Zeile an der Kante in zwei Hälften. `knowsPageRange`
// unten setzt jede Seitengrenze deshalb auf eine echte Zeilengrenze.

import AppKit
import PDFKit
import WebKit

/// Ergebnis eines Druckauftrags — auch für Selbsttests auswertbar.
enum PrintOutcome: Equatable {
    case printed
    /// Der Nutzer hat den Systemdialog abgebrochen.
    case cancelled
    case failed(String)
}

@MainActor
enum DocumentPrinting {

    // MARK: - Menüeinstiege

    /// „Drucken…" (⌘P): druckt, was das vordere Fenster gerade zeigt.
    static func printVisibleDocument() {
        guard let context = CommandTargeting.targetDocument(),
              let document = context.workspace.printableDocument,
              let target = PrintRouting.defaultTarget(document) else {
            NSSound.beep()
            return
        }
        run(target: target, workspace: context.workspace, window: context.window)
    }

    /// Menüpunkt mit ausdrücklich gewählter Vorlage (Markdown: Vorschau oder
    /// Quelltext). Nicht verfügbare Vorlagen werden abgewiesen statt still
    /// durch eine andere ersetzt.
    static func printVisibleDocument(as target: PrintTarget) {
        guard let context = CommandTargeting.targetDocument(),
              let document = context.workspace.printableDocument,
              PrintRouting.availableTargets(document).contains(target) else {
            NSSound.beep()
            return
        }
        run(target: target, workspace: context.workspace, window: context.window)
    }

    /// „Papierformat…" (⇧⌘P): Papiergröße und Ausrichtung für alle folgenden
    /// Ausdrucke. Die Werte gehören dem System, nicht Fastra.
    static func presentPageLayout() {
        let layout = NSPageLayout()
        if let window = CommandTargeting.targetDocument()?.window {
            layout.beginSheet(with: NSPrintInfo.shared, modalFor: window,
                              delegate: nil, didEnd: nil, contextInfo: nil)
        } else {
            layout.runModal(with: NSPrintInfo.shared)
        }
    }

    // MARK: - Kern

    /// Führt einen Druckauftrag aus.
    ///
    /// - Parameter savingTo: Nicht `nil` → der Auftrag läuft ohne Dialoge in
    ///   diese PDF-Datei. Genau das nutzt der `print`-Selbsttest: Er prüft am
    ///   fertigen PDF Seitenzahl und Inhalt und beweist damit den ganzen
    ///   Druckweg, ohne einen Drucker zu brauchen.
    static func run(target: PrintTarget,
                    workspace: Workspace,
                    window: NSWindow?,
                    savingTo: URL? = nil,
                    completion: @escaping (PrintOutcome) -> Void = { _ in }) {
        guard let tab = workspace.activeTab else {
            report(.failed(L10n.string("Kein Dokument zum Drucken.")),
                   window: window, completion: completion)
            return
        }
        let defaults = workspace.preferencesStore
        let printInfo = makePrintInfo(defaults: defaults, savingTo: savingTo)
        let jobTitle = tab.title

        switch target {
        case .source:
            printSourceText(tab: tab, workspace: workspace, printInfo: printInfo,
                            defaults: defaults, window: window, savingTo: savingTo,
                            completion: completion)
        case .hexDump:
            printHexDump(tab: tab, workspace: workspace, printInfo: printInfo,
                         defaults: defaults, window: window, savingTo: savingTo,
                         completion: completion)
        case .markdownPreview:
            printMarkdownPreview(tab: tab, workspace: workspace, printInfo: printInfo,
                                 defaults: defaults, jobTitle: jobTitle,
                                 window: window, savingTo: savingTo,
                                 completion: completion)
        case .image:
            printImage(tab: tab, printInfo: printInfo, defaults: defaults,
                       window: window, savingTo: savingTo, completion: completion)
        case .pdf:
            printPDF(tab: tab, printInfo: printInfo, jobTitle: jobTitle,
                     window: window, savingTo: savingTo, completion: completion)
        }
    }

    // MARK: - Druckvorgaben

    /// Papier, Ausrichtung und Ränder für einen Auftrag.
    ///
    /// Papiergröße und Ausrichtung kommen aus `NSPrintInfo.shared`, also aus
    /// „Papierformat" — sie gehören dem Nutzer. Verändert werden nur die
    /// Ränder, und zwar nur nach oben: Ein zu enger Rand ließe Kopf- und
    /// Fußzeile in den Text laufen.
    static func makePrintInfo(defaults: UserDefaults, savingTo: URL?) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let minimumMargin: CGFloat = 40
        let decorationSpace: CGFloat =
            PrintPreferences.showsHeaderFooter(defaults) ? 24 : 0
        info.leftMargin = max(info.leftMargin, minimumMargin)
        info.rightMargin = max(info.rightMargin, minimumMargin)
        info.topMargin = max(info.topMargin, minimumMargin) + decorationSpace
        info.bottomMargin = max(info.bottomMargin, minimumMargin) + decorationSpace
        if let savingTo {
            // Druck in eine Datei: kein Dialog, keine Rückfrage. Der Pfad
            // kommt ausschließlich aus dem Programm (Selbsttest), nie aus
            // einem Dokumentinhalt.
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = savingTo as NSURL
        }
        return info
    }

    /// Bedruckbare Fläche einer Seite.
    static func contentSize(of printInfo: NSPrintInfo) -> NSSize {
        NSSize(
            width: max(72, printInfo.paperSize.width - printInfo.leftMargin
                        - printInfo.rightMargin),
            height: max(72, printInfo.paperSize.height - printInfo.topMargin
                        - printInfo.bottomMargin)
        )
    }

    // MARK: - Fließtext

    private static func printSourceText(tab: EditorTab,
                                        workspace: Workspace,
                                        printInfo: NSPrintInfo,
                                        defaults: UserDefaults,
                                        window: NSWindow?,
                                        savingTo: URL?,
                                        completion: @escaping (PrintOutcome) -> Void) {
        // Eine große Datei liegt nicht als String im Tab, sondern wird
        // abschnittsweise angezeigt. Gedruckt wird dann genau der sichtbare
        // Abschnitt — und die Kopfzeile sagt, welcher.
        let section = workspace.visiblePrintPage(for: tab)
        let text = tab.content.isEmpty ? (section?.text ?? "") : tab.content
        guard !text.isEmpty else {
            report(.failed(L10n.string("Dieses Dokument enthält keinen druckbaren Text.")),
                   window: window, completion: completion)
            return
        }
        // Erst nach einer möglichen Rückfrage bauen: Schon das Aufbauen teilt
        // den Text in Seiten und ist bei sehr großen Dokumenten der teure
        // Schritt.
        let start = {
            let operation = makeTextPrintOperation(
                text: text,
                monospaced: true,
                printInfo: printInfo,
                defaults: defaults,
                jobTitle: tab.title,
                headerLeft: PrintDecoration.headerLeft(title: tab.title,
                                                       section: section),
                footerLeft: PrintDecoration.footerLeft(path: tab.url?.path)
            )
            execute(operation, window: window, savingTo: savingTo,
                    completion: completion)
        }
        confirmLargePrintIfNeeded(text: text, printInfo: printInfo,
                                  defaults: defaults, window: window,
                                  savingTo: savingTo,
                                  completion: completion, start: start)
    }

    /// Fragt vor einem sehr großen Ausdruck nach und nennt die geschätzte
    /// Seitenzahl. Ohne Fenster oder beim Druck in eine Datei (Selbsttest,
    /// Automatisierung) gibt es keine Rückfrage — dort wartet niemand vor dem
    /// Bildschirm.
    private static func confirmLargePrintIfNeeded(
        text: String,
        printInfo: NSPrintInfo,
        defaults: UserDefaults,
        window: NSWindow?,
        savingTo: URL?,
        completion: @escaping (PrintOutcome) -> Void,
        start: @escaping () -> Void
    ) {
        guard savingTo == nil, let window,
              PrintVolume.needsConfirmation(byteCount: text.utf8.count) else {
            start()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("Großer Ausdruck")
        alert.informativeText = L10n.format(
            "Dieses Dokument ergibt etwa %ld Seiten. Das Aufteilen in Seiten kann einen Moment dauern; Fastra ist währenddessen nicht bedienbar.",
            estimatedPageCount(text: text, printInfo: printInfo, defaults: defaults)
        )
        alert.addButton(withTitle: L10n.string("Drucken"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                start()
            } else {
                completion(.cancelled)
            }
        }
    }

    /// Geschätzte Seitenzahl aus den echten Druckmaßen: Spaltenzahl aus
    /// Seitenbreite und Zeichenbreite, Zeilen je Seite aus Seitenhöhe und
    /// Zeilenhöhe.
    private static func estimatedPageCount(text: String, printInfo: NSPrintInfo,
                                           defaults: UserDefaults) -> Int {
        let font = printFont(size: CGFloat(PrintPreferences.fontSize(defaults)),
                             monospaced: true, defaults: defaults)
        let content = contentSize(of: printInfo)
        let characterWidth = ("0" as NSString)
            .size(withAttributes: [.font: font]).width
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        guard characterWidth > 0, lineHeight > 0 else { return 1 }
        let lines = PrintLineNumbers.lines(of: text)
        let gutter = PrintPreferences.showsLineNumbers(defaults)
            ? PrintLineNumbers.digits(forLineCount: lines.count)
                + PrintLineNumbers.gap
            : 0
        let columns = Int(content.width / characterWidth) - gutter
        return PrintVolume.estimatedPageCount(
            lines: lines,
            columnsPerLine: columns,
            linesPerPage: Int(content.height / lineHeight)
        )
    }

    private static func printHexDump(tab: EditorTab,
                                     workspace: Workspace,
                                     printInfo: NSPrintInfo,
                                     defaults: UserDefaults,
                                     window: NSWindow?,
                                     savingTo: URL?,
                                     completion: @escaping (PrintOutcome) -> Void) {
        guard let section = workspace.visiblePrintPage(for: tab),
              !section.text.isEmpty else {
            report(.failed(L10n.string("Die Hex-Ansicht hat noch keinen Abschnitt geladen.")),
                   window: window, completion: completion)
            return
        }
        let operation = makeTextPrintOperation(
            text: section.text,
            monospaced: true,
            printInfo: printInfo,
            defaults: defaults,
            jobTitle: tab.title,
            headerLeft: PrintDecoration.headerLeft(title: tab.title, section: section),
            footerLeft: PrintDecoration.footerLeft(path: tab.url?.path),
            // Der Hex-Abzug trägt seine Adressen schon in jeder Zeile. Eine
            // zweite Nummernspalte daneben wäre nur Verwirrung.
            forcesLineNumbersOff: true,
            // Feste Zeilenbreite: Die Schrift wird so weit verkleinert, dass
            // eine Rasterzeile ganz auf die Seite passt.
            fixedColumns: HexDump.lineWidthInCharacters
        )
        execute(operation, window: window, savingTo: savingTo, completion: completion)
    }

    /// Baut den Druckauftrag für Fließtext.
    static func makeTextPrintOperation(text: String,
                                       monospaced: Bool,
                                       printInfo: NSPrintInfo,
                                       defaults: UserDefaults,
                                       jobTitle: String,
                                       headerLeft: String,
                                       footerLeft: String,
                                       forcesLineNumbersOff: Bool = false,
                                       fixedColumns: Int? = nil)
        -> NSPrintOperation {
        let desired = PrintPreferences.fontSize(defaults)
        var font = printFont(size: CGFloat(desired), monospaced: monospaced,
                             defaults: defaults)
        if let fixedColumns {
            // Text mit festem Raster (Hex): Schrift so verkleinern, dass eine
            // ganze Zeile auf die Seite passt. Sonst bricht jede Zeile um und
            // das Raster ist unlesbar (gesehen am 2026-08-17).
            let characterWidth = ("0" as NSString)
                .size(withAttributes: [.font: font]).width
            let fitted = PrintTextFit.fittedFontSize(
                desired: desired,
                characterWidthAtDesired: Double(characterWidth),
                columns: fixedColumns,
                availableWidth: Double(contentSize(of: printInfo).width)
            )
            if fitted < desired {
                font = printFont(size: CGFloat(fitted), monospaced: monospaced,
                                 defaults: defaults)
            }
        }
        let showsLineNumbers = !forcesLineNumbersOff
            && PrintPreferences.showsLineNumbers(defaults)
        let attributed = attributedText(text, font: font,
                                        showsLineNumbers: showsLineNumbers)
        let content = contentSize(of: printInfo)

        // TextKit 1 mit ausdrücklich erzeugtem Container: Seine Breite ist
        // FEST. Das ist wichtig, weil die Kopf-/Fußzeile die View kurzzeitig
        // auf Seitengröße zieht — mit mitwachsendem Container würde der Text
        // dabei neu umbrechen und die Seitenaufteilung mitten im Druck
        // verschieben.
        let container = NSTextContainer(
            size: NSSize(width: content.width, height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage(attributedString: attributed)
        storage.addLayoutManager(layoutManager)

        let view = PrintDocumentTextView(
            frame: NSRect(origin: .zero, size: content),
            textContainer: container
        )
        view.pageContentSize = content
        view.headerLeft = headerLeft
        view.headerRight = PrintDecoration.headerRight(date: Date())
        view.footerLeftText = footerLeft
        view.drawsDecoration = PrintPreferences.showsHeaderFooter(defaults)
        view.topMargin = printInfo.topMargin
        view.bottomMargin = printInfo.bottomMargin
        view.sideMargin = printInfo.leftMargin
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = content
        view.maxSize = NSSize(width: content.width, height: .greatestFiniteMagnitude)
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = jobTitle
        return operation
    }

    /// Druckschrift: die im Editor eingestellte Dokumentschrift, damit der
    /// Ausdruck aussieht wie der Bildschirm. Fehlt sie (deinstalliert), bleibt
    /// die feste Systemschrift — eine stille Ersatzschrift ist hier harmlos,
    /// ändert aber den Zeilenumbruch, deshalb wird sie hier bewusst gewählt
    /// statt AppKit raten zu lassen.
    private static func printFont(size: CGFloat, monospaced: Bool,
                                  defaults: UserDefaults) -> NSFont {
        guard monospaced else { return .systemFont(ofSize: size) }
        let name = defaults.string(forKey: EditorFonts.defaultsKey)
            ?? EditorFonts.systemMonospacedName
        if let font = NSFont(name: name, size: size), font.isFixedPitch {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Text mit optionaler Zeilennummernspalte.
    ///
    /// Die Nummer steht als Text am Zeilenanfang. Umgebrochene Fortsetzungen
    /// rücken über `headIndent` genau um die Spaltenbreite ein — dadurch bleibt
    /// der Text auch bei langen Zeilen als Block lesbar.
    static func attributedText(_ text: String, font: NSFont,
                               showsLineNumbers: Bool) -> NSAttributedString {
        let lines = PrintLineNumbers.lines(of: text)
        let digits = PrintLineNumbers.digits(forLineCount: lines.count)
        let characterWidth = ("0" as NSString)
            .size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        // Quelltext zeichenweise umbrechen: Ein langer Pfad oder ein
        // Base64-Block hat keine Wortgrenzen, würde bei Wortumbruch also über
        // den Rand hinauslaufen und abgeschnitten wirken.
        paragraph.lineBreakMode = .byCharWrapping
        if showsLineNumbers {
            paragraph.headIndent = characterWidth
                * CGFloat(digits + PrintLineNumbers.gap)
        }
        let result = NSMutableAttributedString()
        for (offset, line) in lines.enumerated() {
            if showsLineNumbers {
                result.append(NSAttributedString(
                    string: PrintLineNumbers.prefix(line: offset + 1, digits: digits),
                    attributes: [.font: font, .foregroundColor: NSColor.gray,
                                 .paragraphStyle: paragraph]
                ))
            }
            result.append(NSAttributedString(
                string: line + "\n",
                attributes: [.font: font, .foregroundColor: NSColor.black,
                             .paragraphStyle: paragraph]
            ))
        }
        return result
    }

    // MARK: - Markdown-Vorschau

    private static func printMarkdownPreview(tab: EditorTab,
                                             workspace: Workspace,
                                             printInfo: NSPrintInfo,
                                             defaults: UserDefaults,
                                             jobTitle: String,
                                             window: NSWindow?,
                                             savingTo: URL?,
                                             completion: @escaping (PrintOutcome) -> Void) {
        guard !tab.content.isEmpty else {
            report(.failed(L10n.string("Diese Markdown-Datei ist noch leer.")),
                   window: window, completion: completion)
            return
        }
        let job = MarkdownPrintJob(printInfo: printInfo, targetWindow: window,
                                   savingTo: savingTo, jobTitle: jobTitle,
                                   completion: completion)
        job.start(markdown: tab.content, documentURL: tab.url,
                  fontName: defaults.string(forKey: PreviewFonts.defaultsKey)
                      ?? PreviewFonts.systemName,
                  fontSize: 11)
    }

    // MARK: - Bild und PDF

    private static func printImage(tab: EditorTab,
                                   printInfo: NSPrintInfo,
                                   defaults: UserDefaults,
                                   window: NSWindow?,
                                   savingTo: URL?,
                                   completion: @escaping (PrintOutcome) -> Void) {
        // Dasselbe Laden wie in der Vorschau: `ImagePreviewLoader` dekodiert
        // über ImageIO direkt auf Zielgröße und übernimmt die EXIF-Drehung.
        // `NSImage(contentsOf:)` würde stattdessen ein 100-Megapixel-Foto
        // vollständig in den Speicher holen — und zwar auf dem Main-Thread,
        // von dem aus der Druckauftrag läuft.
        guard let url = tab.url,
              let image = ImagePreviewLoader.loadPreviewImage(url: url),
              image.size.width > 0, image.size.height > 0 else {
            report(.failed(L10n.string("Diese Datei ist nicht als Bild lesbar.")),
                   window: window, completion: completion)
            return
        }
        let content = contentSize(of: printInfo)
        let view = PrintImageView(frame: NSRect(origin: .zero, size: content),
                                  image: image)
        view.headerLeft = tab.title
        view.headerRight = PrintDecoration.headerRight(date: Date())
        view.footerLeftText = PrintDecoration.footerLeft(path: url.path)
        view.drawsDecoration = PrintPreferences.showsHeaderFooter(defaults)
        view.topMargin = printInfo.topMargin
        view.bottomMargin = printInfo.bottomMargin
        view.sideMargin = printInfo.leftMargin
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = tab.title
        execute(operation, window: window, savingTo: savingTo, completion: completion)
    }

    private static func printPDF(tab: EditorTab,
                                 printInfo: NSPrintInfo,
                                 jobTitle: String,
                                 window: NSWindow?,
                                 savingTo: URL?,
                                 completion: @escaping (PrintOutcome) -> Void) {
        guard let url = tab.url, let document = PDFDocument(url: url),
              document.pageCount > 0 else {
            report(.failed(L10n.string("Dieses PDF ist nicht lesbar.")),
                   window: window, completion: completion)
            return
        }
        // PDFKit druckt das Dokument selbst — Seitengröße, Drehung und
        // eingebettete Schriften bleiben dabei unverändert. Eine eigene
        // Kopfzeile gibt es hier absichtlich nicht: Sie würde in ein fremdes,
        // fertig gesetztes Dokument hineinzeichnen.
        guard let operation = document.printOperation(
            for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true
        ) else {
            report(.failed(L10n.string("Dieses PDF ist nicht lesbar.")),
                   window: window, completion: completion)
            return
        }
        operation.jobTitle = jobTitle
        execute(operation, window: window, savingTo: savingTo, completion: completion)
    }

    // MARK: - Ausführen

    /// Startet den Auftrag: mit Systemdialog als Blatt am Fenster, oder ohne
    /// Dialog direkt in eine Datei.
    static func execute(_ operation: NSPrintOperation,
                        window: NSWindow?,
                        savingTo: URL?,
                        completion: @escaping (PrintOutcome) -> Void) {
        let interactive = savingTo == nil
        operation.showsPrintPanel = interactive
        operation.showsProgressPanel = interactive
        guard let window else {
            let ok = operation.run()
            completion(ok ? .printed : .cancelled)
            return
        }
        PrintCompletionRelay.run(operation, in: window, completion: completion)
    }

    /// Fehler sichtbar machen. Ein stiller Abbruch wäre für den Nutzer nicht
    /// von „nichts passiert" zu unterscheiden.
    private static func report(_ outcome: PrintOutcome,
                               window: NSWindow?,
                               completion: @escaping (PrintOutcome) -> Void) {
        if case .failed(let message) = outcome {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Drucken nicht möglich")
            alert.informativeText = message
            alert.addButton(withTitle: L10n.string("OK"))
            if let window {
                alert.beginSheetModal(for: window) { _ in }
            } else if !SelfTest.isSelfTestRun {
                alert.runModal()
            }
        }
        completion(outcome)
    }
}

// MARK: - Rückmeldung des Systemdialogs

/// Hält sich selbst am Leben, bis der Druckauftrag fertig ist.
///
/// `runModal(for:delegate:didRun:contextInfo:)` erwartet ein Objective-C-Ziel
/// mit einer bestimmten Methode. Ohne diesen Umweg gibt es kein Blatt am
/// Fenster, sondern nur einen anwendungsmodalen Dialog.
///
/// **AppKit ruft diese Rückmeldung in einem EIGENEN Thread.** Ein modaler
/// Druckauftrag läuft nicht auf dem Main-Thread, und die Meldung kommt von dort
/// zurück, wo er lief. Deshalb geht hier ausdrücklich alles auf die Main-Queue:
/// Am 2026-08-17 brach die Anwendung mit SIGTRAP in WebKits
/// `WKWindowVisibilityObserver` ab, weil der Abbau der Druck-WebView aus diesem
/// fremden Thread lief. Von außen sah das wie ein hängender Druckauftrag aus —
/// der Prozess war einfach weg.
private final class PrintCompletionRelay: NSObject {
    private static var active: [PrintCompletionRelay] = []
    private let completion: (PrintOutcome) -> Void

    private init(completion: @escaping (PrintOutcome) -> Void) {
        self.completion = completion
    }

    @MainActor
    static func run(_ operation: NSPrintOperation,
                    in window: NSWindow,
                    completion: @escaping (PrintOutcome) -> Void) {
        let relay = PrintCompletionRelay(completion: completion)
        active.append(relay)
        operation.runModal(
            for: window,
            delegate: relay,
            didRun: #selector(PrintCompletionRelay.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc
    private func printOperationDidRun(_ operation: NSPrintOperation,
                                      success: Bool,
                                      contextInfo: UnsafeMutableRawPointer?) {
        let outcome: PrintOutcome = success ? .printed : .cancelled
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.completion(outcome)
                PrintCompletionRelay.active.removeAll { $0 === self }
            }
        }
    }
}

// MARK: - Textseite

/// Textansicht, die nur zum Drucken existiert: eigene Seitenaufteilung an
/// Zeilengrenzen plus Kopf- und Fußzeile im Seitenrand.
final class PrintDocumentTextView: NSTextView {
    var headerLeft = ""
    var headerRight = ""
    var footerLeftText = ""
    var drawsDecoration = true
    var pageContentSize: NSSize = .zero
    var topMargin: CGFloat = 40
    var bottomMargin: CGFloat = 40
    var sideMargin: CGFloat = 40

    /// Ergebnis der eigenen Seitenaufteilung.
    private var pageRects: [NSRect] = []

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        computePageRects()
        range.pointee = NSRange(location: 1, length: max(1, pageRects.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        if pageRects.isEmpty { computePageRects() }
        guard page >= 1, page <= pageRects.count else {
            return NSRect(origin: .zero, size: pageContentSize)
        }
        return pageRects[page - 1]
    }

    /// Teilt das Dokument in Seiten, deren Grenzen immer zwischen zwei Zeilen
    /// liegen. Eine Seite behält dabei ihre vollständige Höhe: So bleibt der
    /// Textanfang auf jeder Seite auf derselben Höhe, auch wenn die letzte
    /// Zeile davor knapp nicht mehr passte.
    private func computePageRects() {
        pageRects = []
        guard let layoutManager, let textContainer, pageContentSize.height > 0 else {
            pageRects = [NSRect(origin: .zero, size: pageContentSize)]
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.numberOfGlyphs
        guard glyphs > 0 else {
            pageRects = [NSRect(origin: .zero, size: pageContentSize)]
            return
        }
        let pageHeight = pageContentSize.height
        var pageTop: CGFloat = 0
        var lastBottom: CGFloat = 0
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: glyphs)
        ) { rect, _, _, _, _ in
            // Passt diese Zeile nicht mehr auf die laufende Seite, beginnt an
            // ihrer Oberkante eine neue.
            if rect.maxY - pageTop > pageHeight, rect.minY > pageTop {
                rects.append(NSRect(x: 0, y: pageTop,
                                    width: self.pageContentSize.width,
                                    height: pageHeight))
                pageTop = rect.minY
            }
            lastBottom = max(lastBottom, rect.maxY)
        }
        if rects.isEmpty || lastBottom > pageTop {
            rects.append(NSRect(x: 0, y: pageTop,
                                width: pageContentSize.width, height: pageHeight))
        }
        pageRects = rects
    }

    override func drawPageBorder(with borderSize: NSSize) {
        guard drawsDecoration else { return }
        // Kopf- und Fußzeile liegen im Seitenrand, also AUSSERHALB der
        // Textfläche. AppKit erlaubt das Zeichnen dort nur, solange die View
        // für diesen Moment so groß ist wie die ganze Seite. Der Textcontainer
        // hat eine feste Breite (siehe `makeTextPrintOperation`) — die
        // Größenänderung löst deshalb keinen Neuumbruch aus.
        let savedSize = frame.size
        setFrameSize(borderSize)
        PrintPageDecoration.draw(
            headerLeft: headerLeft, headerRight: headerRight,
            footerLeft: footerLeftText,
            pageSize: borderSize, topMargin: topMargin,
            bottomMargin: bottomMargin, sideMargin: sideMargin
        )
        setFrameSize(savedSize)
    }
}

// MARK: - Bildseite

/// Eine Seite mit einem eingepassten Bild.
final class PrintImageView: NSView {
    private let image: NSImage
    var headerLeft = ""
    var headerRight = ""
    var footerLeftText = ""
    var drawsDecoration = true
    var topMargin: CGFloat = 40
    var bottomMargin: CGFloat = 40
    var sideMargin: CGFloat = 40

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("nicht unterstützt") }

    override func draw(_ dirtyRect: NSRect) {
        let target = PrintImageLayout.fit(imageSize: image.size, in: bounds.size)
        image.draw(in: target.offsetBy(dx: bounds.minX, dy: bounds.minY))
    }

    override func drawPageBorder(with borderSize: NSSize) {
        guard drawsDecoration else { return }
        let savedSize = frame.size
        setFrameSize(borderSize)
        PrintPageDecoration.draw(
            headerLeft: headerLeft, headerRight: headerRight,
            footerLeft: footerLeftText,
            pageSize: borderSize, topMargin: topMargin,
            bottomMargin: bottomMargin, sideMargin: sideMargin
        )
        setFrameSize(savedSize)
    }
}

/// Bild auf eine Seite einpassen — reine Rechnung, ohne AppKit-Zustand.
enum PrintImageLayout {
    /// Seitenverhältnis bleibt erhalten, das Ergebnis ist zentriert. Kleine
    /// Bilder werden bewusst hochskaliert: Ein Ausdruck, auf dem ein
    /// 64×32-Bild als Briefmarke in der Ecke klebt, ist nicht brauchbar.
    static func fit(imageSize: NSSize, in pageSize: NSSize) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0,
              pageSize.width > 0, pageSize.height > 0 else {
            return NSRect(origin: .zero, size: pageSize)
        }
        let scale = min(pageSize.width / imageSize.width,
                        pageSize.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale,
                          height: imageSize.height * scale)
        return NSRect(x: (pageSize.width - size.width) / 2,
                      y: (pageSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Kopf- und Fußzeile zeichnen

/// Zeichnet die Randzeilen einer Seite. Gemeinsam für Text- und Bildseiten,
/// damit beide Ausdrucke gleich aussehen.
enum PrintPageDecoration {
    static let fontSize: CGFloat = 8.5

    /// Zeichnet Kopf- und Fußzeile einer Seite.
    ///
    /// **Der Zeichenraum von `drawPageBorder` ist das PAPIER, und sein
    /// Nullpunkt liegt unten links — y wächst nach OBEN.** Das gilt auch für
    /// eine geflippte View wie `NSTextView`: Ihre eigene Zeilenrichtung spielt
    /// hier keine Rolle. Nachgemessen am 2026-08-17 an einem erzeugten PDF; die
    /// erste Fassung rechnete mit der Flippung der View und setzte die Kopfzeile
    /// dadurch unten und die Fußzeile oben auf die Seite.
    static func draw(headerLeft: String, headerRight: String, footerLeft: String,
                     pageSize: NSSize, topMargin: CGFloat, bottomMargin: CGFloat,
                     sideMargin: CGFloat) {
        let operation = NSPrintOperation.current
        let page = operation?.currentPage ?? 1
        let total = (operation?.pageRange.length).flatMap { $0 > 0 ? $0 : nil }
        let footerRight = PrintDecoration.footerRight(page: page, of: total)

        let width = pageSize.width - 2 * sideMargin
        guard width > 40 else { return }
        let lineHeight: CGFloat = fontSize * 1.6
        let headerY = pageSize.height - topMargin + 6
        let footerY = bottomMargin - lineHeight - 6

        // Linke und rechte Angabe bekommen je eine eigene Hälfte der Zeile.
        // In EINEM gemeinsamen Rechteck lief ein langer Dateipfad sonst unter
        // die rechts stehende Seitenzahl (gesehen am 2026-08-17).
        let leftWidth = width * 0.62
        let rightWidth = width - leftWidth - 8
        let rightX = sideMargin + leftWidth + 8
        draw(headerLeft, in: NSRect(x: sideMargin, y: headerY,
                                    width: leftWidth, height: lineHeight),
             alignment: .left)
        draw(headerRight, in: NSRect(x: rightX, y: headerY,
                                     width: rightWidth, height: lineHeight),
             alignment: .right)
        draw(footerLeft, in: NSRect(x: sideMargin, y: footerY,
                                    width: leftWidth, height: lineHeight),
             alignment: .left)
        draw(footerRight, in: NSRect(x: rightX, y: footerY,
                                     width: rightWidth, height: lineHeight),
             alignment: .right)
    }

    private static func draw(_ text: String, in rect: NSRect,
                             alignment: NSTextAlignment) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        // Ein langer Pfad wird in der Mitte gekürzt und behält damit Anfang
        // und Dateinamen. Der Inhalt des Dokuments ist davon nie betroffen.
        paragraph.lineBreakMode = .byTruncatingMiddle
        // `draw(in:)` bricht in einem hohen Rechteck um, statt zu kürzen —
        // deshalb ist das Rechteck genau eine Zeile hoch.
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: paragraph
        ])
    }
}

// MARK: - Markdown-Vorschau drucken

/// Lädt die Druckfassung der Markdown-Vorschau in ein unsichtbares WebKit-
/// Dokument und druckt sie, sobald Formeln, Diagramme und Code-Einfärbung
/// fertig sind.
///
/// Der Umweg über WebKit ist Absicht: Die Vorschau IST ein WebKit-Dokument.
/// Ein zweiter, eigener Textsatz derselben Markdown-Quelle würde anders
/// aussehen als das, was der Nutzer neben dem Editor sieht.
@MainActor
final class MarkdownPrintJob: NSObject, WKNavigationDelegate {
    /// Solange ein Auftrag läuft, hält ihn diese Liste am Leben — sonst
    /// verschwände er samt WebView, bevor das Dokument geladen ist.
    private static var active: [MarkdownPrintJob] = []

    private let webView: WKWebView
    private let hostWindow: OffscreenPrintWindow
    private let assetHandler = MarkdownPreviewSchemeHandler()
    private let printInfo: NSPrintInfo
    private let targetWindow: NSWindow?
    private let savingTo: URL?
    private let jobTitle: String
    private let completion: (PrintOutcome) -> Void
    private let contentSize: NSSize
    private var isFinished = false

    init(printInfo: NSPrintInfo, targetWindow: NSWindow?, savingTo: URL?,
         jobTitle: String, completion: @escaping (PrintOutcome) -> Void) {
        self.printInfo = printInfo
        self.targetWindow = targetWindow
        self.savingTo = savingTo
        self.jobTitle = jobTitle
        self.completion = completion
        self.contentSize = DocumentPrinting.contentSize(of: printInfo)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Der Scheme-Handler MUSS vor dem Erzeugen der View gesetzt werden:
        // WKWebView kopiert seine Konfiguration, spätere Änderungen daran
        // erreichen die View nicht mehr.
        configuration.setURLSchemeHandler(
            assetHandler, forURLScheme: MarkdownPreviewAssets.scheme
        )
        webView = WKWebView(frame: NSRect(origin: .zero, size: contentSize),
                            configuration: configuration)
        // Fenster für die Druckvorbereitung. Es liegt zusätzlich weit
        // außerhalb jedes Bildschirms — falls es je doch eingeordnet würde,
        // bliebe es dadurch unsichtbar.
        hostWindow = OffscreenPrintWindow(
            contentRect: NSRect(x: -30000, y: -30000,
                                width: contentSize.width, height: contentSize.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        super.init()
        webView.navigationDelegate = self
        hostWindow.isReleasedWhenClosed = false
        hostWindow.hasShadow = false
        hostWindow.ignoresMouseEvents = true
        hostWindow.isExcludedFromWindowsMenu = true
        hostWindow.contentView = webView
        // Das Fenster wird ABSICHTLICH nie eingeordnet (kein `orderFront`,
        // kein `orderBack`). Es hat zwei Aufgaben, und für beide muss es nicht
        // sichtbar sein: Es gibt der WebView ein Zuhause, damit WebKit das
        // Dokument setzt, und es ist der Anker für den modalen Druckauftrag,
        // wenn kein Dokumentfenster übergeben wurde (Selbsttest). Ein
        // eingeordnetes Fenster wäre dagegen `isVisible` — und würde von
        // Suchen nach „dem sichtbaren Hauptfenster" mitgezählt.
    }

    func start(markdown: String, documentURL: URL?, fontName: String,
               fontSize: CGFloat) {
        MarkdownPrintJob.active.append(self)
        // Rendern kostet einen cmark-Durchlauf und je Bild einen
        // Dateisystemzugriff — beides gehört nicht auf den Main-Thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let fragment = MarkdownRichText.renderedFragment(
                markdown: markdown, documentURL: documentURL
            )
            let html = MarkdownRichText.htmlDocument(
                fragment: fragment, fontName: fontName, fontSize: fontSize,
                darkMode: false, purpose: .print
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.assetHandler.setImageURLs(fragment.imageURLs)
                self.webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForEnhancement(tick: 0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        finish(.failed(error.localizedDescription))
    }

    /// Formeln (KaTeX), Diagramme (Mermaid) und Code-Einfärbung entstehen erst
    /// im Dokument. Wer sofort druckt, druckt das halbfertige Dokument.
    private func waitForEnhancement(tick: Int) {
        webView.evaluateJavaScript(
            "document.documentElement.getAttribute('data-fastra-enhanced') === '1'"
        ) { [weak self] value, _ in
            guard let self, !self.isFinished else { return }
            if (value as? Bool) == true {
                // NICHT direkt aus dieser Closure drucken: Sie ist eine
                // WebKit-Rückmeldung. Der Druckvorgang von WebKit dreht selbst
                // den RunLoop und wartet auf den Webprozess — mitten in dessen
                // eigener Rückmeldung aufgerufen, blockiert er dauerhaft
                // (beobachtet am 2026-08-17: der Auftrag kam nie zurück).
                DispatchQueue.main.async { self.startPrinting() }
                return
            }
            // 8 Sekunden. Danach fragt Fastra nach, statt stillschweigend
            // einen unfertigen Ausdruck zu erzeugen.
            guard tick < 80 else {
                self.confirmUnfinishedRender()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.waitForEnhancement(tick: tick + 1)
            }
        }
    }

    private func confirmUnfinishedRender() {
        // Ohne Dialogweg (Selbsttest, Druck in eine Datei) gilt der Auftrag
        // als gescheitert: Ein unfertiger Ausdruck darf nicht als Erfolg
        // durchgehen.
        guard savingTo == nil, !SelfTest.isSelfTestRun else {
            finish(.failed(L10n.string(
                "Die Vorschau wurde nicht rechtzeitig fertig gerendert.")))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Vorschau noch nicht fertig")
        alert.informativeText = L10n.string(
            "Formeln oder Diagramme sind noch nicht vollständig gerendert. Der Ausdruck kann an diesen Stellen unfertig aussehen.")
        alert.addButton(withTitle: L10n.string("Trotzdem drucken"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.startPrinting()
            } else {
                self.finish(.cancelled)
            }
        }
        if let targetWindow {
            alert.beginSheetModal(for: targetWindow, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    private func startPrinting() {
        guard !isFinished else { return }
        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = jobTitle
        // WebKit bricht die Seite an der Breite dieser View um.
        operation.view?.frame = NSRect(origin: .zero, size: contentSize)
        DocumentPrinting.execute(operation, window: targetWindow ?? hostWindow,
                                 savingTo: savingTo) { [weak self] outcome in
            self?.finish(outcome)
        }
    }

    private func finish(_ outcome: PrintOutcome) {
        guard !isFinished else { return }
        isFinished = true
        webView.navigationDelegate = nil
        hostWindow.contentView = nil
        hostWindow.close()
        completion(outcome)
        MarkdownPrintJob.active.removeAll { $0 === self }
    }
}

/// Fenster für die Druckvorbereitung — bewusst außerhalb jedes Bildschirms.
///
/// `NSWindow` schiebt ein Fenster normalerweise auf einen sichtbaren
/// Bildschirm zurück. Genau das wäre hier falsch: Das Fenster muss in der
/// Fensterliste stehen, damit WebKit überhaupt rendert, darf aber nie
/// aufblitzen.
private final class OffscreenPrintWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect,
                                     to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Der Tab als Druckvorlage

extension Workspace {
    /// Beschreibung des aktiven Tabs für die Druck-Logik.
    var printableDocument: PrintableDocument? {
        guard let tab = activeTab, !tab.isLoading else { return nil }
        // Derselbe Schlüssel, den `EditorView` für den Vorschau-Streifen liest.
        // Von hier gibt es keinen Weg in die View, und die Voreinstellung ist
        // AN — ein nie gesetzter Schlüssel bedeutet also „Vorschau sichtbar".
        let previewVisible = preferencesStore
            .object(forKey: "markdown.integratedPreview") as? Bool ?? true
        return PrintableDocument(
            fileExtension: tab.url?.pathExtension ?? "",
            hasURL: tab.url != nil,
            isMarkdown: activeTabIsMarkdown,
            hasEditorText: !tab.content.isEmpty,
            viewMode: activeViewMode,
            showsPagedText: tab.displayMode == .chunkedText,
            integratedPreviewVisible: activeTabIsMarkdown && previewVisible,
            isStructuredDiff: tab.gitDiffRequest != nil || tab.fileDiffRequest != nil
        )
    }

    /// Der sichtbare Abschnitt einer seitenweisen Ansicht — nur, wenn er
    /// wirklich zu DIESEM Tab gehört.
    func visiblePrintPage(for tab: EditorTab) -> VisiblePrintPage? {
        guard let page = visiblePrintPage, let url = tab.url,
              page.url == url else { return nil }
        return page
    }
}
