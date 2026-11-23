// Markdown-Importfamilie mit echtem Werkzeug und kontrollierter UI-CLI; Laufzeit und zentraler Abschluss
// bleiben beim gestarteten SelfTest. Fortsetzungen halten diesen Besitzerwert.
import Foundation
import AppKit

struct SelfTestMarkdownImport {
    private let waitForBody: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
    private let finishBody: (Bool, String) -> Never
    private let finishOutcomeBody: (SelfTestOutcome, String) -> Never
    private let resolveWorkspace: () -> Workspace?

    init(waitFor: @escaping (TimeInterval, TimeInterval, @escaping () -> Bool,
                            @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void,
         finish: @escaping (Bool, String) -> Never,
         finishOutcome: @escaping (SelfTestOutcome, String) -> Never,
         resolveWorkspace: @escaping () -> Workspace?) {
        self.waitForBody = waitFor
        self.finishBody = finish
        self.finishOutcomeBody = finishOutcome
        self.resolveWorkspace = resolveWorkspace
    }

    // Argumentlabels und Abschlussarten bleiben an den Ablaufaufrufen erhalten;
    // die Funktionswerte führen weiterhin SelfTests private Helfer aus.
    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then: @escaping () -> Void) {
        waitForBody(budget, pause, condition, onTimeout, then)
    }

    private func finish(_ success: Bool, _ message: String) -> Never {
        finishBody(success, message)
    }

    private func finish(_ outcome: SelfTestOutcome, _ message: String) -> Never {
        finishOutcomeBody(outcome, message)
    }

    /// End-to-end gegen das echte `poormans-text`: Formatkatalog, eine
    /// Umwandlung ohne Bilder, eine mit Bildern und der Kollisionsschutz.
    ///
    /// Ein Unit-Test kann hier nur die Zerlegung der Antworten prüfen. Ob das
    /// Werkzeug wirklich gefunden wird, ob `--formats` von diesem Stand
    /// verstanden wird und ob das Ergebnis tatsächlich neben der Quelle landet,
    /// zeigt sich erst mit echten Dateien und einem echten Prozess.
    func runMarkdownImportTest() {
        guard MarkdownImportTool.locate() != nil else {
            finish(.environment, "Umgebungsproblem: poormans-text ist nicht installiert "
                + "(oder \(MarkdownImportTool.overrideEnvironmentKey) zeigt ins Leere)")
        }
        MarkdownImportService.shared.withCatalog { catalog in
            guard let catalog else {
                finish(.environment, "Umgebungsproblem: dieser poormans-text-Stand kennt "
                    + "--formats nicht — Werkzeug aktualisieren")
            }
            checkMarkdownImportCatalog(catalog)
        }
    }

    private func checkMarkdownImportCatalog(_ catalog: MarkdownImportCatalog) {
        guard let rtf = catalog.availableFormat(forExtension: "rtf") else {
            finish(.environment, "Katalog meldet RTF nicht als benutzbar — Pandoc installiert?")
        }
        guard !rtf.isPackage else {
            finish(false, "RTF darf kein Ordner-Paket sein")
        }
        // Fehlt die Paketkennzeichnung, öffnet ein Dokument still als Projekt.
        guard catalog.availableFormat(forExtension: "rtfd")?.isPackage == true else {
            finish(false, "RTFD wird nicht als Ordner-Paket gemeldet")
        }

        // Zweiter Abruf muss synchron aus dem Zwischenspeicher kommen, sonst
        // startet jedes Öffnen einer Datei einen neuen Prozess.
        var servedSynchronously = false
        MarkdownImportService.shared.withCatalog { _ in servedSynchronously = true }
        guard servedSynchronously else {
            finish(false, "Formatkatalog wird nicht zwischengespeichert")
        }

        let base: URL
        do {
            base = try makeMarkdownImportFixtures()
        } catch {
            finish(
                SelfTestFixtureOutcome.markdownImport(for: error),
                "Fixtures nicht erzeugbar: \(error.localizedDescription)"
            )
        }
        convertPlainMarkdownImportFixture(in: base)
    }

    /// Legt drei Quellen an: eine schlichte RTF, eine RTF mit eingebettetem
    /// PNG und eine bereits belegte `Belegt.md`, die nicht überschrieben
    /// werden darf.
    private func makeMarkdownImportFixtures() throws -> URL {
        let base = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-markdownimport-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        try Data(#"{\rtf1\ansi Schlichter Text ohne Bild.}"#.utf8)
            .write(to: base.appendingPathComponent("Schlicht.rtf"), options: .atomic)

        // Bereits belegter Zielname — die Umwandlung muss auf `-2` ausweichen
        // und diesen Inhalt unangetastet lassen.
        try Data("bereits da\n".utf8)
            .write(to: base.appendingPathComponent("Belegt.md"), options: .atomic)
        try Data(#"{\rtf1\ansi Zweites Dokument.}"#.utf8)
            .write(to: base.appendingPathComponent("Belegt.rtf"), options: .atomic)

        guard let png = markdownImportPNG() else { throw MarkdownImportFixtureError.png }
        let hex = png.map { String(format: "%02x", $0) }.joined()
        let withPicture = "{\\rtf1\\ansi Mit Bild: "
            + "{\\pict\\pngblip\\picw8\\pich8\\picwgoal120\\pichgoal120\n\(hex)\n}}"
        try Data(withPicture.utf8)
            .write(to: base.appendingPathComponent("MitBild.rtf"), options: .atomic)
        return base
    }

    private func markdownImportPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Schritt 1: RTF ohne Bilder → `Schlicht.md` direkt neben der Quelle.
    private func convertPlainMarkdownImportFixture(in base: URL) {
        let source = base.appendingPathComponent("Schlicht.rtf")
        let sourceBytes = try? Data(contentsOf: source)
        MarkdownImportService.shared.convert(source) { markdownFile in
            guard let markdownFile else {
                finishMarkdownImport(base, false,
                                     "schlichte RTF nicht umgewandelt: "
                                        + markdownImportFailureText(), decisions: nil)
            }
            guard markdownFile.path == base.appendingPathComponent("Schlicht.md").path else {
                finishMarkdownImport(base, false,
                                     "falscher Zielname: \(markdownFile.lastPathComponent)", decisions: nil)
            }
            let markdown = (try? String(contentsOf: markdownFile, encoding: .utf8)) ?? ""
            guard markdown.contains("Schlichter Text") else {
                finishMarkdownImport(base, false, "Markdown ohne Quelltext: \(markdown.prefix(80))", decisions: nil)
            }
            // Die Quelle darf die Umwandlung bytegleich überstehen.
            guard (try? Data(contentsOf: source)) == sourceBytes else {
                finishMarkdownImport(base, false, "die Quelldatei wurde verändert", decisions: nil)
            }
            // Kein Zwischenverzeichnis darf liegen bleiben.
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: base.path))?
                .filter { $0.hasPrefix(".fastra-markdown-") } ?? []
            guard leftovers.isEmpty else {
                finishMarkdownImport(base, false, "Zwischenverzeichnis blieb liegen: \(leftovers)", decisions: nil)
            }
            routeFileMarkdownImportFixture(in: base)
        }
    }

    private func routeFileMarkdownImportFixture(in base: URL) {
        Task { @MainActor in
            guard let workspace = resolveWorkspace() else {
                finishMarkdownImport(base, false, "Workspace fehlt", decisions: nil)
            }
            let decisions = workspace.markdownImportDecisions
            let source = base.appendingPathComponent("Direkt.RTF")
            let expected = base.appendingPathComponent("Direkt.md")
            let bytes = Data(#"{\rtf1\ansi Direkt geoeffnet.\par Zweiter Absatz.}"#.utf8)
            do { try bytes.write(to: source) }
            catch { finishMarkdownImport(base, .environment, "RTF-Fixture nicht erzeugbar", decisions: decisions) }
            let before = workspace.tabs.map(\.id)
            var asked = 0
            decisions.fileChoiceProvider = { [weak decisions] url, format in
                asked += 1
                guard url == source, format.identifier == "rtf" else {
                    finishMarkdownImport(base, false, "RTF-Rückfrage betrifft falsche Quelle", decisions: decisions)
                }
                return .cancel
            }
            workspace.openFileOrFolder(at: source)
            guard asked == 1, workspace.tabs.map(\.id) == before,
                  !FileManager.default.fileExists(atPath: expected.path) else {
                finishMarkdownImport(base, false, "RTF-Abbruch öffnet oder schreibt trotzdem", decisions: decisions)
            }
            decisions.fileChoiceProvider = { _, _ in asked += 1; return .convert }
            workspace.openFileOrFolder(at: source)
            for _ in 0..<200 {
                if workspace.activeTab?.url == expected.canonicalFileURL,
                   workspace.activeTab?.isLoading == false { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard asked == 2, workspace.activeTab?.url == expected.canonicalFileURL,
                  workspace.activeTab?.content.contains("Direkt geoeffnet.") == true,
                  !workspace.tabs.contains(where: { $0.url == source.canonicalFileURL }),
                  (try? Data(contentsOf: source)) == bytes else {
                finishMarkdownImport(base, false, "RTF-Öffnen liefert keinen Markdown-Tab oder verändert die Quelle", decisions: decisions)
            }
            decisions.fileChoiceProvider = { _, _ in asked += 1; return .openAsText }
            workspace.openFileOrFolder(at: source)
            for _ in 0..<200 {
                if workspace.activeTab?.url == source.canonicalFileURL,
                   workspace.activeTab?.isLoading == false { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard asked == 3, workspace.activeTab?.url == source.canonicalFileURL,
                  workspace.activeTab?.content == String(decoding: bytes, as: UTF8.self) else {
                finishMarkdownImport(base, false, "RTF lässt sich nicht ausdrücklich als Quelltext öffnen", decisions: decisions)
            }
            decisions.fileChoiceProvider = nil
            await routeAllMarkdownImportFormats(in: base, workspace: workspace, decisions: decisions)
        }
    }

    @MainActor
    private func routeAllMarkdownImportFormats(in base: URL, workspace: Workspace,
                                               decisions: MarkdownImportDecisions) async {
        guard let catalog = MarkdownImportService.shared.cachedCatalog else {
            finishMarkdownImport(base, false, "Formatkatalog fehlt", decisions: decisions)
        }
        let originalTabs = workspace.tabs.map(\.id), originalProject = workspace.projectURL
        var asked = 0, expectedSource: URL?, expectedFormat = ""
        decisions.fileChoiceProvider = { [weak decisions] url, format in
            guard url == expectedSource, format.identifier == expectedFormat else {
                finishMarkdownImport(base, false, "Dateirückfrage betrifft falsches Format", decisions: decisions)
            }
            asked += 1
            return .cancel
        }
        decisions.packageChoiceProvider = { [weak decisions] url, format in
            guard url == expectedSource, format.identifier == expectedFormat else {
                finishMarkdownImport(base, false, "Paketrückfrage betrifft falsches Format", decisions: decisions)
            }
            asked += 1
            return .cancel
        }
        do {
            // Alle Aliasse und Container des echten Katalogs müssen vor dem
            // Lesen erreichbar sein. Die Attrappen werden immer abgebrochen.
            for format in catalog.formats {
                for ext in format.fileExtensions {
                    for directory in [false, true] where format.supportsContainer(isDirectory: directory) {
                        let source = base.appendingPathComponent("Katalog-\(asked).\(ext.uppercased())")
                        if directory {
                            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                        } else {
                            try Data("Katalogprobe".utf8).write(to: source)
                        }
                        expectedSource = source; expectedFormat = format.identifier
                        let before = asked
                        workspace.openFileOrFolder(at: source)
                        guard asked == before + 1, workspace.tabs.map(\.id) == originalTabs,
                              workspace.projectURL == originalProject else {
                            finishMarkdownImport(base, false, "Öffnen/Abbruch umgeht den Dialog für \(ext)", decisions: decisions)
                        }
                        try FileManager.default.removeItem(at: source)
                    }
                }
            }
            decisions.packageChoiceProvider = nil
            let source = base.appendingPathComponent("Office.DOCX")
            let text = NSAttributedString(string: "DOCX Direktimport äöü.\nZweiter Absatz.")
            let bytes = try text.data(from: NSRange(location: 0, length: text.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try bytes.write(to: source)
            decisions.fileChoiceProvider = { [weak decisions] url, format in
                guard url == source, format.identifier == "docx" else {
                    finishMarkdownImport(base, false, "DOCX-Rückfrage fehlt", decisions: decisions)
                }
                return .convert
            }
            workspace.openFileOrFolder(at: source)
            let expected = base.appendingPathComponent("Office.md")
            for _ in 0..<240 {
                if workspace.activeTab?.url == expected.canonicalFileURL, workspace.activeTab?.isLoading == false { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard workspace.activeTab?.url == expected.canonicalFileURL,
                  workspace.activeTab?.content.contains("DOCX Direktimport äöü.") == true,
                  !workspace.tabs.contains(where: { $0.url == source.canonicalFileURL }),
                  try Data(contentsOf: source) == bytes else {
                finishMarkdownImport(base, false, "DOCX-Direktimport fehlgeschlagen: "
                    + "Zustand=\(MarkdownImportService.shared.state), "
                    + "Tab=\(workspace.activeTab?.url?.path ?? "kein Tab"), "
                    + "Text=\(workspace.activeTab?.content.prefix(160) ?? ""), "
                    + "Quelle unverändert=\((try? Data(contentsOf: source)) == bytes), "
                    + "Ziel vorhanden=\(FileManager.default.fileExists(atPath: expected.path))", decisions: decisions)
            }
            print("MARKDOWNIMPORT-KATALOG: \(asked) Endungs-/Containerkombinationen mit unverändertem Zustand abgebrochen; DOCX real konvertiert")
        } catch {
            finishMarkdownImport(base, false, "Formatprobe fehlgeschlagen: \(error.localizedDescription)", decisions: decisions)
        }
        decisions.fileChoiceProvider = nil
        convertCollidingMarkdownImportFixture(in: base, workspace: workspace, decisions: decisions)
    }

    /// Schritt 2: Zielname ist belegt → `-2`, ohne das Vorhandene anzufassen.
    private func convertCollidingMarkdownImportFixture(in base: URL, workspace: Workspace,
                                                     decisions: MarkdownImportDecisions) {
        let occupied = base.appendingPathComponent("Belegt.md")
        MarkdownImportService.shared.convert(base.appendingPathComponent("Belegt.rtf")) { file in
            guard let file else {
                finishMarkdownImport(base, false,
                                     "Kollisionsfall nicht umgewandelt: "
                                        + markdownImportFailureText(), decisions: decisions)
            }
            guard file.lastPathComponent == "Belegt-2.md" else {
                finishMarkdownImport(base, false,
                                     "Kollision falsch aufgelöst: \(file.lastPathComponent)", decisions: decisions)
            }
            let kept = (try? String(contentsOf: occupied, encoding: .utf8)) ?? ""
            guard kept == "bereits da\n" else {
                finishMarkdownImport(base, false, "bestehende Datei wurde überschrieben", decisions: decisions)
            }
            convertPictureMarkdownImportFixture(in: base, workspace: workspace, decisions: decisions)
        }
    }

    /// Schritt 3: RTF mit Bild → Ordner `MitBild` samt `MitBild.md` und Bild.
    private func convertPictureMarkdownImportFixture(in base: URL, workspace: Workspace,
                                                     decisions: MarkdownImportDecisions) {
        MarkdownImportService.shared.convert(base.appendingPathComponent("MitBild.rtf")) { file in
            guard let file else {
                finishMarkdownImport(base, false,
                                     "Bild-RTF nicht umgewandelt: " + markdownImportFailureText(), decisions: decisions)
            }
            let expected = base.appendingPathComponent("MitBild/MitBild.md")
            guard file.path == expected.path else {
                finishMarkdownImport(base, false, "Ordnerfall falsch benannt: \(file.path)", decisions: decisions)
            }
            var isDirectory: ObjCBool = false
            let folder = base.appendingPathComponent("MitBild")
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.fileExists(atPath: file.path) else {
                finishMarkdownImport(base, false, "Ordner oder Markdown fehlt", decisions: decisions)
            }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            guard contents.contains("images") else {
                finishMarkdownImport(base, false, "Bildordner fehlt: \(contents)", decisions: decisions)
            }
            routePackageMarkdownImportFixture(in: base, workspace: workspace, decisions: decisions)
        }
    }

    /// Schritt 4: Ein `.rtfd` ist auf der Platte ein Ordner. Fastra darf es
    /// deshalb nicht still als Projekt öffnen, sondern muss die Rückfrage
    /// anbieten und danach wirklich umwandeln. Genau das ging beim ersten
    /// Anlauf im Dateibaum verloren.
    private func routePackageMarkdownImportFixture(in base: URL, workspace: Workspace,
                                                     decisions: MarkdownImportDecisions) {
        let package = base.appendingPathComponent("Paket.rtfd", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: package,
                                                    withIntermediateDirectories: true)
            try Data(#"{\rtf1\ansi\ansicpg1252 Inhalt eines RTFD-Pakets.\par \'95 Suchfeld = OK\par \'95 Art = OK\par Schluss eins\par Schluss zwei\par}"#.utf8)
                .write(to: package.appendingPathComponent("TXT.rtf"), options: .atomic)
        } catch {
            finishMarkdownImport(base, .environment, "RTFD-Fixture nicht erzeugbar", decisions: decisions)
        }

        // Der Katalog muss das Paket als Paket erkennen — sonst landet es im
        // Ordnerzweig und wird als Projekt geöffnet.
        guard let format = workspace.markdownImportPackageFormat(at: package) else {
            finishMarkdownImport(base, false,
                                 "RTFD wird nicht als Dokumentpaket erkannt — "
                                    + "ein Klick würde es nur aufklappen", decisions: decisions)
        }
        guard format.identifier == "rtfd" else {
            finishMarkdownImport(base, false, "falsches Paketformat: \(format.identifier)", decisions: decisions)
        }
        // Ein echter Ordner darf davon unberührt bleiben.
        guard workspace.markdownImportPackageFormat(at: base) == nil else {
            finishMarkdownImport(base, false, "gewöhnlicher Ordner gilt fälschlich als Dokument", decisions: decisions)
        }

        // Die Rückfrage ist modal und würde einen fensterlosen Lauf anhalten;
        // der Testhaken beantwortet sie mit „umwandeln".
        var asked = 0
        decisions.packageChoiceProvider = { _, _ in
            asked += 1
            return .convert
        }
        workspace.openFileOrFolder(at: package)
        pollPackageMarkdownImport(base: base, package: package, workspace: workspace,
                                  decisions: decisions, asked: { asked })
    }

    private func pollPackageMarkdownImport(base: URL, package: URL, workspace: Workspace,
                                          decisions: MarkdownImportDecisions,
                                          asked: @escaping () -> Int) {
        let expected = base.appendingPathComponent("Paket.md")
        // Bisher 100 × 100 ms = 10 s. Eigener Timeout-Zweig: Der Testhaken der
        // Rückfrage muss in jedem Ausgang zurückgesetzt werden.
        waitFor(budget: 10, pause: 0.1,
                condition: { FileManager.default.fileExists(atPath: expected.path) },
                onTimeout: { book in
                    decisions.packageChoiceProvider = nil
                    finishMarkdownImport(base, false,
                                         "RTFD-Paket nicht umgewandelt (Rückfragen: \(asked()), "
                                            + "Zustand: " + markdownImportFailureText()
                                            + ") — " + book.summary, decisions: decisions)
                }) {
            decisions.packageChoiceProvider = nil
            guard asked() == 1 else {
                finishMarkdownImport(base, false,
                                     "Rückfrage \(asked())-mal statt einmal gestellt", decisions: decisions)
            }
            // Das Paket selbst muss unangetastet bleiben.
            guard FileManager.default.fileExists(
                atPath: package.appendingPathComponent("TXT.rtf").path
            ) else {
                finishMarkdownImport(base, false, "das RTFD-Paket wurde verändert", decisions: decisions)
            }
            let markdown = (try? String(contentsOf: expected, encoding: .utf8)) ?? ""
            let lines = markdown.components(separatedBy: "\n")
            guard let field = lines.firstIndex(where: { $0.hasPrefix("- ") && $0.contains("Suchfeld = OK") }),
                  field + 1 < lines.count,
                  lines[field + 1].hasPrefix("- "), lines[field + 1].contains("Art = OK"),
                  !markdown.contains("•"),
                  markdown.contains("Schluss eins\n\nSchluss zwei") else {
                finishMarkdownImport(base, false,
                                     "RTFD-Aufzählung oder Absatzgrenzen falsch: \(markdown)", decisions: decisions)
            }
            guard workspace.projectURL != package.canonicalFileURL else {
                finishMarkdownImport(base, false, "das Paket wurde als Projekt geöffnet", decisions: decisions)
            }
            finishMarkdownImport(base, true,
                                 "Formatkatalog, Zwischenspeicher, flache Umwandlung, "
                                    + "alle Format-Aliasse und Container, echter DOCX-Import, RTF-Öffnen/Abbruch/Quelltext, Kollisionsschutz, Bilder und RTFD-Absatzgrenzen ok", decisions: decisions)
        }
    }

    private func finishMarkdownImport(_ base: URL, _ ok: Bool, _ message: String,
                                      decisions: MarkdownImportDecisions?) -> Never {
        finishMarkdownImport(base, ok ? .pass : .fail, message, decisions: decisions)
    }

    private func finishMarkdownImport(
        _ base: URL, _ outcome: SelfTestOutcome, _ message: String,
        decisions: MarkdownImportDecisions?
    ) -> Never {
        decisions?.fileChoiceProvider = nil
        decisions?.packageChoiceProvider = nil
        try? FileManager.default.removeItem(at: base)
        finish(outcome, message)
    }

    /// Zwei Prozessstarts teilen nur ausdrücklich übergebene Fixtures. Phase 2
    /// öffnet die übernommenen Dateien, ohne den Konverter erneut zu starten.
    @MainActor
    func runMarkdownCollectionsTest() async {
        do {
            guard let path = ProcessInfo.processInfo.environment["FASTRA_COLLECTION_REVIEW_DIR"],
                  let ws = resolveWorkspace() else {
                finish(.environment, "Sammlungsfixture oder Workspace fehlt")
            }
            let root = URL(fileURLWithPath: path)
            let reopen = FileManager.default.fileExists(atPath: root.appendingPathComponent("reopen").path)
            for name in ["mail.mbox", "notes.enex"] {
                let source = root.appendingPathComponent(name)
                let stem = source.deletingPathExtension().lastPathComponent
                let index = root.appendingPathComponent(stem + "-2/index.md")
                if !reopen {
                    let result: URL? = await withCheckedContinuation { continuation in
                        MarkdownImportService.shared.convert(source, owner: ws) {
                            continuation.resume(returning: $0)
                        }
                    }
                    guard result?.standardizedFileURL == index.standardizedFileURL else {
                        finish(false, "Falscher Sammlungspfad: \(String(describing: result)); \(markdownImportFailureText())")
                    }
                }
                let files = try FileManager.default.subpathsOfDirectory(
                    atPath: index.deletingLastPathComponent().path).filter { $0.hasSuffix(".md") }
                guard files.count == 3 else { finish(false, "Sammlung unvollständig: \(files)") }
                for relative in files {
                    let file = index.deletingLastPathComponent().appendingPathComponent(relative)
                    let expected = try String(contentsOf: file, encoding: .utf8)
                    let loaded: Bool = await withCheckedContinuation { continuation in
                        ws.loadFile(at: file) { continuation.resume(returning: $0) }
                    }
                    guard loaded, ws.activeTab?.content == expected else {
                        finish(false, "Sammlungsdatei nicht im Editor geöffnet: \(relative)")
                    }
                }
                let loaded: Bool = await withCheckedContinuation { continuation in
                    ws.loadFile(at: index) { continuation.resume(returning: $0) }
                }
                guard loaded else { finish(false, "Übersicht nicht erneut geöffnet") }
            }
            finish(true, reopen ? "MBOX/ENEX nach Prozessende im Editor erneut geöffnet" : "MBOX/ENEX mit Kollision vollständig übernommen und im Editor geöffnet")
        } catch { finish(false, error.localizedDescription) }
    }

    private func markdownImportFailureText() -> String {
        if case .failed(let message) = MarkdownImportService.shared.state { return message }
        return "kein Grund gemeldet"
    }

    /// Ein kontrolliertes CLI hält den Lauf an der Ausgabegrenze fest. So
    /// werden echte Prozesse und der sichtbare Abbruchknopf geprüft, ohne die
    /// Testdauer von einem zufällig langsamen Dokument abhängig zu machen.
    @MainActor
    func runMarkdownImportUITest(
        findMarker: @escaping (String, NSView) -> NSView?,
        captureWindow: @escaping (NSWindow, @escaping (Data?) -> Void) -> Void,
        click: @escaping (NSPoint, NSWindow) -> Bool
    ) async {
        guard let ws = resolveWorkspace(),
              let window = CommandTargeting.registeredWindow(for: ws) else {
            finish(false, "Workspace oder Fenster fehlt")
        }
        let service = MarkdownImportService.shared
        let oldLocate = service.locateTool
        let base = selfTestTemporaryDirectory().appendingPathComponent("markdown-ui-\(UUID().uuidString)")
        let tool = base.appendingPathComponent("converter")
        let gate = base.appendingPathComponent("release")
        let warnings = [
            "Schriftarten, Farben und genaue Seitenumbrüche werden in Markdown nicht erhalten. Tabellen mit verbundenen Zellen können vereinfacht werden. Bitte das Ergebnis mit dem Original vergleichen, bevor es weitergegeben wird.",
            "Doppelte Warnung bleibt sichtbar.", "Doppelte Warnung bleibt sichtbar.",
        ]
        @MainActor func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MarkdownImportUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        @MainActor func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try require(condition(), "Umwandlungszustand wurde nicht bereit")
        }
        @MainActor func capture(_ state: String) async throws {
            for width: CGFloat in [650, 1100] {
                window.setContentSize(NSSize(width: width, height: 680))
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let root = window.contentView,
                      let bar = findMarker("markdownImportBar", root) else {
                    throw NSError(domain: "MarkdownImportUI", code: 2)
                }
                try require(!bar.isHidden, "Umwandlungsleiste fehlt")
                if let directory = ProcessInfo.processInfo.environment["FASTRA_MARKDOWN_IMPORT_UI_DIR"] {
                    let destination = URL(fileURLWithPath: directory).appendingPathComponent("\(state)-\(Int(width)).png")
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let saved = await withCheckedContinuation { continuation in
                        captureWindow(window) { snapshot in
                            let ok = snapshot.map { (try? $0.write(to: destination)) != nil } ?? false
                            continuation.resume(returning: ok)
                        }
                    }
                    try require(saved, "Fensteraufnahme fehlt")
                }
            }
        }
        @MainActor func checkOpeningDialogs() throws {
            func buttons(in view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
            }
            for identifier in ["rtf", "docx"] {
                let source = base.appendingPathComponent("Beispiel.\(identifier)")
                for available in [true, false] {
                    let format = MarkdownImportFormat(identifier: identifier, fileExtensions: [identifier],
                        isPackage: false, isAvailable: available,
                        unavailableReason: available ? nil : "missing required tool: pandoc")
                    let choices: [(String, MarkdownImportDecisions.FileChoice)] = available
                        ? [("In Markdown umwandeln", .convert), ("Als Quelltext öffnen", .openAsText), ("Abbrechen", .cancel)]
                        : [("Als Quelltext öffnen", .openAsText), ("Abbrechen", .cancel)]
                    for (index, choice) in choices.enumerated() {
                        var failure: String?
                        var clicked = false
                        let deadline = Date().addingTimeInterval(5)
                        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                            MainActor.assumeIsolated {
                                guard let dialog = NSApp.modalWindow, let content = dialog.contentView else {
                                    if Date() > deadline {
                                        failure = "Dokument-Rückfrage erscheint nicht"
                                        timer.invalidate()
                                        NSApp.abortModal()
                                    }
                                    return
                                }
                                timer.invalidate()
                                let controls = buttons(in: content).filter { !$0.title.isEmpty }
                                guard choices.allSatisfy({ expected in
                                    controls.contains { $0.title == L10n.string(expected.0) && $0.isEnabled }
                                }), let button = controls.first(where: { $0.title == L10n.string(choice.0) }),
                                      available || !controls.contains(where: { $0.title == L10n.string("In Markdown umwandeln") }) else {
                                    failure = "Dokument-Rückfrage bietet falsche oder deaktivierte Knöpfe"
                                    NSApp.abortModal()
                                    return
                                }
                                if index == 0,
                                   let directory = ProcessInfo.processInfo.environment["FASTRA_MARKDOWN_IMPORT_UI_DIR"] {
                                    let path = URL(fileURLWithPath: directory)
                                        .appendingPathComponent(available ? "\(identifier)-open.png" : "\(identifier)-unavailable.png")
                                    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                                        content.cacheDisplay(in: content.bounds, to: bitmap)
                                        let data = bitmap.representation(using: .png, properties: [:])
                                        do {
                                            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                                            try data?.write(to: path)
                                            if data == nil { failure = "Dokument-Dialogaufnahme ist leer" }
                                        } catch { failure = error.localizedDescription }
                                    } else { failure = "Dokument-Dialogaufnahme fehlt" }
                                }
                                clicked = true
                                button.performClick(nil)
                            }
                        }
                        RunLoop.main.add(timer, forMode: .modalPanel)
                        let result = ws.markdownImportDecisions.askFileChoice(for: source, format: format)
                        timer.invalidate()
                        try require(failure == nil && clicked && result == choice.1,
                                    failure ?? "Dokument-Dialog liefert die falsche Auswahl")
                    }
                }
            }
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try checkOpeningDialogs()
            let script = """
            #!/bin/sh
            output=''
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --output) output="$2"; shift 2 ;;
                --) source="$2"; break ;;
                *) shift ;;
              esac
            done
            name="$(basename "$source")"
            printf 'Progress: %s: converting page 2/8\\n' "$name" >&2
            while [ ! -f '\(gate.path)' ]; do sleep 0.1; done
            case "$name" in
              Fehler.rtf) cat '\(base.path)/error.json'; exit 65 ;;
            esac
            mkdir "$output"
            printf '# Ergebnis\\n' > "$output/converted.md"
            sed "s|OUTPUT|$output|g" '\(base.path)/success.json'
            """
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
            try JSONSerialization.data(withJSONObject: ["ok": true, "markdownFile": "OUTPUT/converted.md", "assets": [], "warnings": warnings])
                .write(to: base.appendingPathComponent("success.json"))
            try JSONSerialization.data(withJSONObject: ["ok": false, "error": "Das Dokument ist beschädigt. Die Quelle bleibt unverändert."])
                .write(to: base.appendingPathComponent("error.json"))
            service.locateTool = { tool }
            SelfTest.workspaceDefaults().set(false, forKey: MarkdownEditingMode.defaultsKey)
            SelfTest.workspaceDefaults().set(true, forKey: MarkdownAssist.firstUseDefaultsKey)
            for mode in ["Erfolg", "Abbruch", "Fehler"] {
                let source = base.appendingPathComponent(mode + ".rtf")
                try "Original".write(to: source, atomically: true, encoding: .utf8)
                var loaded = false
                ws.loadFile(at: source) { loaded = $0 }
                try await wait { loaded }
                service.clearState()
                ws.convertToMarkdown(source)
                try await wait { service.progress?.completed == 2 && service.isRunning }
                if mode == "Erfolg" { try await capture("running") }
                if mode == "Abbruch" {
                    try await wait {
                        window.contentView.flatMap {
                            findMarker("markdownImportCancelButton", $0)
                        } != nil
                    }
                    guard let root = window.contentView,
                          let button = findMarker("markdownImportCancelButton", root) else {
                        throw NSError(domain: "MarkdownImportUI", code: 3)
                    }
                    try require(click(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), window), "Abbruchknopf nicht bedienbar")
                } else {
                    try Data().write(to: gate)
                }
                try await wait { !service.isRunning }
                try require(try String(contentsOf: source, encoding: .utf8) == "Original", "Quelle verändert")
                if mode == "Erfolg" {
                    guard case .finished(let file, let actual) = service.state else {
                        throw NSError(domain: "MarkdownImportUI", code: 4)
                    }
                    try require(actual == warnings && FileManager.default.fileExists(atPath: file.path), "Warnungen oder Ausgabe fehlen")
                    try await wait { ws.activeTab?.url?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }
                    try await capture("finished")
                } else if mode == "Abbruch" {
                    try require(service.state == .cancelled, "Klick hat nicht abgebrochen")
                    try require(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Abbruch.md").path), "Abbruch veröffentlichte Ausgabe")
                    try await capture("cancelled")
                } else {
                    guard case .failed = service.state else { throw NSError(domain: "MarkdownImportUI", code: 5) }
                    try await capture("failed")
                }
                try? FileManager.default.removeItem(at: gate)
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path)
                    .filter { $0.hasPrefix(".fastra-markdown-") }
                try require(leftovers.isEmpty, "Arbeitsordner blieb liegen")
            }
            service.locateTool = oldLocate
            if let directory = ProcessInfo.processInfo.environment["FASTRA_MARKDOWN_IMPORT_REVIEW_DIR"] {
                let review = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
                service.state = .idle
                ws.openNewTab()
                try Data("ready\n".utf8).write(to: review.appendingPathComponent("ready"))
                let deadline = Date().addingTimeInterval(300)
                while !FileManager.default.fileExists(atPath: review.appendingPathComponent("continue").path),
                      Date() < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(Date() < deadline, "Manuelle Importabnahme nicht abgeschlossen")
            }
            try? FileManager.default.removeItem(at: base)
            finish(true, "RTF-/DOCX-Rückfragen mit/ohne Pandoc, alle Dialogknöpfe, laufende Seitenzählung, echter Abbruchknopf, Verlustwarnungen und Fehler; schmal/breit")
        } catch {
            service.cancelConversion()
            try? await wait { !service.isRunning }
            service.locateTool = oldLocate
            try? FileManager.default.removeItem(at: base)
            finish(false, error.localizedDescription)
        }
    }

}
