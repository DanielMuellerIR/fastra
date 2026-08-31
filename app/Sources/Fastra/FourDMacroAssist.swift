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
import Darwin
import SwiftUI

// MARK: - Diff-Vorschau eines Makrolaufs

/// Bindet Engine-Ergebnis und Vorschau an genau das Dokument und Projekt ihres
/// Starts. Ein flüchtiger Vorschau-Tab kann seine Tab-ID für eine andere Datei
/// wiederverwenden; Save As behält dagegen Dokument-ID und Inhaltsrevision.
/// Deshalb gehören alle Identitäten gemeinsam in die Prüfung.
struct FourDMacroExecutionLease: Equatable {
    let tabID: UUID
    let documentID: UUID
    let documentURL: URL
    let projectRoot: URL?
    let projectGeneration: UInt64
    let contentRevision: UInt64
    let originWindowID: ObjectIdentifier?

    init?(tab: EditorTab, projectRoot: URL?, projectGeneration: UInt64,
          originWindow: NSWindow? = nil) {
        guard let documentURL = tab.url else { return nil }
        self.tabID = tab.id
        self.documentID = tab.documentID
        self.documentURL = documentURL.canonicalFileURL
        self.projectRoot = projectRoot?.canonicalFileURL
        self.projectGeneration = projectGeneration
        self.contentRevision = tab.contentRevision
        self.originWindowID = originWindow.map(ObjectIdentifier.init)
    }

    @MainActor
    func isCurrent(in workspace: Workspace) -> Bool {
        guard workspace.projectGeneration == projectGeneration,
              workspace.projectURL?.canonicalFileURL == projectRoot,
              let tab = workspace.activeTab else { return false }
        guard tab.id == tabID
            && tab.documentID == documentID
            && tab.url?.canonicalFileURL == documentURL
            && tab.contentRevision == contentRevision else { return false }
        if let originWindowID {
            guard let window = CommandTargeting.registeredWindow(for: workspace),
                  ObjectIdentifier(window) == originWindowID else { return false }
        }
        return true
    }

    /// Das Fenster des Starts, solange es noch genau zu diesem Workspace
    /// registriert ist. Ein späterer Fokuswechsel ändert diese Bindung nicht.
    @MainActor func originWindow(in workspace: Workspace) -> NSWindow? {
        guard let originWindowID,
              let window = CommandTargeting.registeredWindow(for: workspace),
              ObjectIdentifier(window) == originWindowID else { return nil }
        return window
    }
}

/// Zustand des Vorschau-Sheets. Anwenden ist nur gültig, solange die Lease
/// noch exakt zum sichtbaren Dokument gehört — sonst würde das Ergebnis auf
/// eine andere Grundlage geschrieben als die sichtbare Vorschau.
struct FourDMacroPreviewState: Identifiable {
    let id = UUID()
    let macroName: String
    let lease: FourDMacroExecutionLease
    let resultText: String
    let request: FileDiffRequest
    let document: FileDiffDocument
}

// MARK: - Begrenztes Laden und projektweiter Katalog-Cache

/// Dateifingerabdruck des tatsächlich geöffneten Makro-XML-Deskriptors. Der
/// Cache darf nur wiederverwenden, was noch dieselbe Inode, Größe und
/// Nanosekunden-Änderungszeit besitzt.
struct FourDMacroSourceFingerprint: Hashable {
    let sourceLabel: String
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

/// Prozessweiter, gelockter Cache: Beim Wechsel zwischen zwei Methodenordnern
/// desselben 4D-Projekts werden die projektweiten XML-Dateien nicht erneut
/// gelesen und geparst, solange ihre Fingerabdrücke gleich sind.
final class FourDMacroCatalogCache: @unchecked Sendable {
    static let shared = FourDMacroCatalogCache()
    static let defaultMaximumEntryCount = 8
    static let defaultMaximumWeight = 16 * 1024 * 1024

    private struct Entry {
        let fingerprints: [FourDMacroSourceFingerprint]
        let macros: [FourDMacro]
        let weight: Int
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var totalWeight = 0
    private var accessCounter: UInt64 = 0
    private let maximumEntryCount: Int
    private let maximumWeight: Int

    init(maximumEntryCount: Int = defaultMaximumEntryCount,
         maximumWeight: Int = defaultMaximumWeight) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumWeight = max(0, maximumWeight)
    }

    func macros(for key: String,
                fingerprints: [FourDMacroSourceFingerprint]) -> [FourDMacro]? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            guard entry.fingerprints == fingerprints else {
                entries.removeValue(forKey: key)
                totalWeight -= entry.weight
                return nil
            }
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            entries[key] = entry
            return entry.macros
        }
    }

    func store(_ macros: [FourDMacro], for key: String,
               fingerprints: [FourDMacroSourceFingerprint], weight: Int) {
        lock.withLock {
            if let replaced = entries.removeValue(forKey: key) {
                totalWeight -= replaced.weight
            }
            guard weight <= maximumWeight else { return }
            accessCounter &+= 1
            entries[key] = Entry(fingerprints: fingerprints, macros: macros,
                                 weight: weight, lastAccess: accessCounter)
            totalWeight += weight
            while entries.count > maximumEntryCount
                    || totalWeight > maximumWeight,
                  let oldest = entries.min(by: {
                      $0.value.lastAccess < $1.value.lastAccess
                  }) {
                entries.removeValue(forKey: oldest.key)
                totalWeight -= oldest.value.weight
            }
        }
    }
}

enum FourDMacroCatalogLoader {
    static let maximumSourceCount = 256
    static let maximumCatalogMacros = 8_192
    static let maximumCatalogTextUTF16Units = 8 * 1024 * 1024
    static let maximumCatalogPartCount = 262_144
    static let maximumCachedCatalogCount =
        FourDMacroCatalogCache.defaultMaximumEntryCount

    /// Standalone-Dateien besitzen keine projektbezogenen Makroquellen. Sie
    /// teilen deshalb denselben Cache-Eintrag statt identische globale
    /// Kataloge einmal pro Dokumentordner im Speicher zu halten.
    static func cacheKey(projectRoot: URL?) -> String {
        projectRoot.map { "project:\($0.canonicalFileURL.path)" }
            ?? "standalone:global"
    }

    struct Result {
        let macros: [FourDMacro]
        let cacheHit: Bool
    }

    private struct OpenedSource {
        let data: Data?
        let fingerprint: FourDMacroSourceFingerprint
    }

    /// Öffnet nur reguläre Dateien und liest höchstens `sourceBytes` Bytes.
    /// Der gemeinsame Lesepfad (`BoundedFileReading`) öffnet nicht blockierend:
    /// Eine als `*.xml` gefundene FIFO hielt vorher schon das `open` und damit
    /// den gesamten seriellen Kataloglauf fest (Review 2026-08-31).
    private static func open(_ source: FourDMacroSource, readData: Bool,
                             limits: FourDMacroXML.Limits = .catalog) -> OpenedSource? {
        guard let file = BoundedFileReading.openRegularFile(
            at: source.url, maximumBytes: limits.sourceBytes, readData: readData
        ) else { return nil }
        let label = source.origin.displayLabel(fileName: source.url.lastPathComponent)
        let fingerprint = FourDMacroSourceFingerprint(
            sourceLabel: label,
            path: file.resolvedPath,
            device: UInt64(file.info.st_dev),
            inode: UInt64(file.info.st_ino),
            size: Int64(file.info.st_size),
            modifiedSeconds: Int64(file.info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(file.info.st_mtimespec.tv_nsec)
        )
        return OpenedSource(data: file.data, fingerprint: fingerprint)
    }

    struct RetainedCatalogMeasurements: Equatable {
        var textUTF16Units = 0
        var partCount = 0
        var cacheWeight = 0
        var visitedMacroCount = 0
    }

    /// Liefert alle drei Katalogbudgets in EINEM Durchlauf. `visitedMacroCount`
    /// macht diese Zusage im Regressionstest messbar; die Quelle wird nicht
    /// getrennt für Text, Bausteine und Cachegewicht erneut durchlaufen.
    static func retainedMeasurements(
        in macros: [FourDMacro]
    ) -> RetainedCatalogMeasurements {
        var measurements = RetainedCatalogMeasurements()
        for macro in macros {
            measurements.visitedMacroCount += 1
            measurements.textUTF16Units += (macro.displayName as NSString).length
            measurements.textUTF16Units += (macro.sourceLabel as NSString).length
            measurements.textUTF16Units += (macro.methodCall as NSString?)?.length ?? 0
            measurements.cacheWeight += 16
            measurements.cacheWeight += (macro.id as NSString).length
            measurements.cacheWeight +=
                (macro.unknownPlaceholder as NSString?)?.length ?? 0
            measurements.partCount += macro.textParts.count
            measurements.cacheWeight += macro.textParts.count * 8
            for part in macro.textParts {
                if case .literal(let text) = part {
                    measurements.textUTF16Units += (text as NSString).length
                }
            }
        }
        measurements.cacheWeight += measurements.textUTF16Units
        return measurements
    }

    static func load(sources allSources: [FourDMacroSource], cacheKey: String,
                     force: Bool,
                     cache: FourDMacroCatalogCache = .shared) -> Result {
        let sources = Array(allSources.prefix(maximumSourceCount))
        let currentSources = sources.compactMap { open($0, readData: false) }
        let currentFingerprints = currentSources.map(\.fingerprint)
        if !force, let cached = cache.macros(
            for: cacheKey, fingerprints: currentFingerprints
        ) {
            return Result(macros: cached, cacheHit: true)
        }

        var parsedMacros: [FourDMacro] = []
        var storedFingerprints: [FourDMacroSourceFingerprint] = []
        var retainedText = 0
        var retainedParts = 0
        var retainedWeight = 0
        for source in sources {
            guard parsedMacros.count < maximumCatalogMacros,
                  retainedText < maximumCatalogTextUTF16Units,
                  retainedParts < maximumCatalogPartCount,
                  let opened = open(source, readData: true),
                  let data = opened.data else { continue }
            let remainingMacros = maximumCatalogMacros - parsedMacros.count
            let remainingParts = maximumCatalogPartCount - retainedParts
            let limits = FourDMacroXML.Limits(
                sourceBytes: FourDMacroXML.Limits.catalog.sourceBytes,
                macroCount: min(FourDMacroXML.Limits.catalog.macroCount,
                                remainingMacros),
                textUTF16Units: FourDMacroXML.Limits.catalog.textUTF16Units,
                partCount: min(FourDMacroXML.Limits.catalog.partCount,
                               remainingParts)
            )
            let sourceMacros = FourDMacroXML.parse(
                data: data,
                sourceLabel: opened.fingerprint.sourceLabel,
                sourceKey: opened.fingerprint.path,
                limits: limits
            )
            let measurements = retainedMeasurements(in: sourceMacros)
            guard retainedText + measurements.textUTF16Units
                    <= maximumCatalogTextUTF16Units else {
                break
            }
            guard retainedParts + measurements.partCount
                    <= maximumCatalogPartCount else { break }
            parsedMacros.append(contentsOf: sourceMacros)
            retainedText += measurements.textUTF16Units
            retainedParts += measurements.partCount
            retainedWeight += measurements.cacheWeight
            storedFingerprints.append(opened.fingerprint)
        }
        // Nur einen vollständigen, in derselben Reihenfolge gelesenen
        // Quellenstand cachen. Verschwindet eine Datei während des Laufs, ist
        // das Ergebnis verwendbar, aber kein Treffer für den vorherigen Stand.
        if storedFingerprints == currentFingerprints {
            cache.store(
                parsedMacros, for: cacheKey,
                fingerprints: storedFingerprints, weight: retainedWeight
            )
        }
        return Result(macros: parsedMacros, cacheHit: false)
    }
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
    /// Die Nummern entsprechen den von 4D dokumentierten Makroformaten:
    /// Datum 0…8, Zeit 0…6. Unbekannte Werte lässt `capability` gar nicht bis
    /// hierher durch.
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
                text += renderDate(date, format: format, locale: locale)
            case .time(let format):
                text += renderTime(date, format: format, locale: locale)
            }
        }
        return Insertion(text: text, caretUTF16Offset: caret)
    }

    static func renderDate(_ date: Date, format: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        switch format {
        case 0, 1: formatter.dateStyle = .short       // Standard/System kurz
        case 2:
            // 4D „System date abbreviated“ enthält zusätzlich den
            // abgekürzten Wochentag; DateFormatter.medium tut das nicht.
            formatter.dateFormat = DateFormatter.dateFormat(
                fromTemplate: "EEE MMM d yyyy", options: 0, locale: locale
            )
        case 3: formatter.dateStyle = .full           // System lang
        case 4:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let year = Calendar(identifier: .gregorian).component(.year, from: date)
            // 4D „Internal date short special“ benutzt nur für 1930…2029
            // zwei Stellen; außerhalb bleibt das Jahrhundert sichtbar.
            formatter.dateFormat = (1930...2029).contains(year)
                ? "MM/dd/yy" : "MM/dd/yyyy"
        case 5:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM d, yyyy"     // Intern lang
        case 6:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d, yyyy"      // Intern abgekürzt
        case 7:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MM/dd/yyyy"       // Intern kurz
        case 8:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd'T'00:00:00"
        default:
            preconditionFailure("Nicht unterstütztes 4D-Datumsformat \(format)")
        }
        return formatter.string(from: date)
    }

    static func renderTime(_ date: Date, format: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        switch format {
        case 0, 1: formatter.dateFormat = "HH:mm:ss"
        case 2: formatter.dateFormat = "HH:mm"
        case 3, 4:
            var calendar = Calendar.current
            calendar.locale = locale
            let components = calendar.dateComponents([.hour, .minute, .second],
                                                      from: date)
            let componentFormatter = DateComponentsFormatter()
            componentFormatter.calendar = calendar
            componentFormatter.unitsStyle = .full
            componentFormatter.allowedUnits = format == 3
                ? [.hour, .minute, .second] : [.hour, .minute]
            componentFormatter.zeroFormattingBehavior = [.pad]
            return componentFormatter.string(from: components) ?? ""
        case 5: formatter.dateFormat = "h:mm a"
        case 6:
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            return String(format: "%d:%02d", minutes, parts.second ?? 0)
        default:
            preconditionFailure("Nicht unterstütztes 4D-Zeitformat \(format)")
        }
        return formatter.string(from: date)
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
            // EIN gemeinsames Arbeitsbudget für den gesamten Kataloglauf:
            // Schon die Suche nach der Projektwurzel verbraucht davon, die
            // anschließende Quellensuche bekommt nur den Rest. Ein riesiger
            // fremder `Project`-Ordner kann die Grenze so nicht mehr vor der
            // eigentlichen Makrosuche umgehen (Review 2026-08-31).
            var entryBudget = FourDMacroDiscovery.maximumDirectoryEntryCount
            let root = FourDMacroDiscovery.projectRoot(
                forDocument: document, fileManager: .default,
                entryBudget: &entryBudget)
            let cacheKey = FourDMacroCatalogLoader.cacheKey(projectRoot: root)
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
                ],
                maximumDirectoryEntryCount: entryBudget
            )
            let parsed = FourDMacroCatalogLoader.load(
                sources: sources, cacheKey: cacheKey, force: force
            ).macros
            await MainActor.run { [weak self] in
                guard let self, self.fourDMacroScanGeneration == generation,
                      // Der Katalog gilt nur für die Datei, für die er
                      // gescannt wurde.
                      self.fourDMacroScanKey == key,
                      self.activeTab?.url?.pathExtension.lowercased() == "4dm"
                else { return }
                self.fourDMacros = FourDMacroXML.resolvingShortcuts(
                    in: parsed,
                    reserved: AppMenuShortcutKeys.reservedMacroKeys(in: NSApp.mainMenu)
                )
            }
        }
    }

    /// Bricht Rücktokenisierung oder Diff eines Makro-Ergebnisses ab, wenn die
    /// Nachbearbeitung zum angegebenen Tab gehört. Inhaltsänderung, Tab- und
    /// Fensterschließung entwerten die Lease endgültig; ein bloßer Tabwechsel
    /// nicht. Die Makro-Sperre wird unmittelbar frei, auch wenn eine bereits
    /// laufende synchrone Diff-Operation erst danach aus ihrem Task zurückkehrt.
    func cancelFourDMacroPostprocessing(ifTab tabID: UUID? = nil) {
        if let tabID, fourDMacroPostprocessTabID != tabID { return }
        fourDMacroPostprocessTask?.cancel()
        clearFourDMacroPostprocessing()
    }

    private func clearFourDMacroPostprocessing() {
        fourDMacroPostprocessTask = nil
        fourDMacroPostprocessTabID = nil
        fourDMacroPostprocessID = nil
        // Auch ein noch laufender Engine-Lauf (Preflight/tool4d) verliert
        // damit seine Freigabe: Seine verspätete Completion darf die hier
        // freigegebene Sperre eines späteren Laufs nicht erneut löschen.
        fourDMacroEngineRunID = nil
        fourDMacroEngineBusy = false
    }

    /// Registriert einen neuen Engine-Lauf (Preflight + tool4d-Prozess) und
    /// setzt die gemeinsame Makro-Sperre. Freigeben dürfen sie nur die
    /// Completions GENAU dieses Laufs über `releaseFourDMacroEngineLock`.
    @discardableResult
    @MainActor func beginFourDMacroEngineRun() -> UUID {
        let runID = UUID()
        fourDMacroEngineRunID = runID
        fourDMacroEngineBusy = true
        return runID
    }

    /// Gibt die Makro-Sperre frei, sofern `runID` noch der aktuell
    /// registrierte Engine-Lauf ist. Eine verspätete Completion eines schon
    /// abgeräumten Laufs (Home, Fensterschluss) läuft dagegen ins Leere und
    /// kann die Sperre eines neueren Laufs nicht löschen (Review 2026-08-29).
    @MainActor func releaseFourDMacroEngineLock(runID: UUID) {
        guard fourDMacroEngineRunID == runID else { return }
        fourDMacroEngineRunID = nil
        fourDMacroEngineBusy = false
    }

    /// Menüweg: Makro über seine stabile ID ausführen.
    @MainActor func runFourDMacro(id: String) {
        guard let macro = fourDMacros.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        _ = runFourDMacro(macro)
    }

    /// Shortcut-Weg (⌘ + Kürzelzeichen aus dem Makronamen, z. B. ⌘# und ⌘T).
    /// Liefert `false`, wenn kein Makro dieses Kürzel trägt ODER es hier gar
    /// nicht ausführbar ist — der Aufrufer reicht die Taste dann normal
    /// weiter. Nur so behält ⌘T außerhalb einer 4D-Methode „Neuer Tab".
    @discardableResult
    @MainActor func runFourDMacro(shortcut key: Character) -> Bool {
        // Den lebenden Menübaum auch beim Tastendruck noch einmal prüfen.
        // Falls sich Menüs nach dem Katalogscan geändert haben, gewinnt der
        // App-Befehl weiterhin und das Ereignis wird unverändert weitergereicht.
        guard !AppMenuShortcutKeys.reservedMacroKeys(in: NSApp.mainMenu)
            .contains(key) else { return false }
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
            return false
        case .nativeText:
            return applyNativeMacro(macro, textView: target.textView,
                                    documentURL: url)
        case .engine(let variant):
            return runEngineMacro(macro, variant: variant,
                                  textView: target.textView,
                                  tab: tab, documentURL: url,
                                  originWindow: target.window)
        }
    }

    // MARK: Text-Makros (nativ)

    @MainActor private func applyNativeMacro(_ macro: FourDMacro, textView: TextView,
                                             documentURL: URL) -> Bool {
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
        guard !insertion.text.isEmpty else { return false }
        textView.fastraApplyTextOperation(replacing: selection,
                                          with: insertion.text)
        if let caret = insertion.caretUTF16Offset {
            // Cursor an die `<caret/>`-Marke des Makros setzen. Die Änderung
            // selbst bleibt EIN Undo-Schritt; die Auswahl ist kein Undo-Inhalt.
            textView.selectionManager.setSelectedRange(
                NSRange(location: selection.location + caret, length: 0))
        }
        return true
    }

    // MARK: Komplettieren-Familie (tool4d-Engine mit Diff-Vorschau)

    @MainActor private func runEngineMacro(
        _ macro: FourDMacro, variant: FourDKomplettierenVariant,
        textView: TextView, tab: EditorTab, documentURL: URL,
        originWindow: NSWindow
    ) -> Bool {
        guard !fourDMacroEngineBusy else { NSSound.beep(); return false }
        guard let lease = FourDMacroExecutionLease(
            tab: tab, projectRoot: projectURL,
            projectGeneration: projectGeneration,
            originWindow: originWindow
        ) else { return false }
        let methodName = FourDMacroXML.normalizedMethodName(
            forFileName: documentURL.lastPathComponent)
        // Daniels Ausnahmen fürs Komplettieren: warnen statt ausführen.
        if methodName == "00_DM_Info" || methodName.hasPrefix("Compiler_") {
            NSAlert.runWarning(
                title: L10n.string("Methode ist vom Komplettieren-Makro ausgenommen"),
                text: L10n.string("00_DM_Info und Compiler_*-Methoden sind bewusst von diesem Makro ausgenommen und bleiben unverändert."))
            return false
        }
        guard let engineRootPath = FourDMacroEngineSettings.projectRootPath else {
            NSAlert.runWarning(
                title: L10n.string("Makro-Engine nicht konfiguriert"),
                text: L10n.string("Dieses Makro läuft über ein 4D-Engine-Projekt mit der Methode MacroRun (MAO_Makros). Trage dessen Projektordner in den Einstellungen unter „4D“ ein."))
            return false
        }
        let engineRoot = URL(fileURLWithPath: engineRootPath)
        let originalText = textView.string
        let macroName = macro.displayName

        let engineRunID = beginFourDMacroEngineRun()
        // Projektdatei, tool4d-Discovery und Tokenanalyse greifen auf das
        // Dateisystem beziehungsweise den vollständigen Dokumenttext zu. Sie
        // laufen gemeinsam im Hintergrund; vor jeder UI-Aktion gilt die Lease.
        Task.detached(priority: .userInitiated) { [weak self] in
            let projectFile = FourDMacroEngine.engineProjectFile(root: engineRoot)
            let rememberedPath = Tool4DAssist.rememberedExecutablePath
            let pathProblem = Tool4DAssist.executablePathProblem(rememberedPath)
            let tool = pathProblem == nil
                ? Tool4DAssist.installedTool(rememberedPath: rememberedPath)
                : nil
            let learned = FourDTokenTransform.learnedSuffixes(from: originalText)
            // MacroRun erwartet untokenisierten Code (gemessen am 2026-08-19,
            // siehe FourDMacroEngine.swift); nach dem Lauf stellt `retokenize`
            // die Suffixe aus dem Original wieder her.
            let detokenized = FourDTokenTransform.detokenize(originalText)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Wurde dieser Lauf inzwischen abgeräumt (Home,
                // Fensterschluss), gehört die Sperre einem Nachfolger —
                // weder freigeben noch fortfahren.
                guard self.fourDMacroEngineRunID == engineRunID else { return }
                guard lease.isCurrent(in: self) else {
                    self.releaseFourDMacroEngineLock(runID: engineRunID)
                    return
                }
                guard let projectFile else {
                    self.releaseFourDMacroEngineLock(runID: engineRunID)
                    self.presentFourDMacroWarning(
                        title: L10n.string("Engine-Projekt nicht gefunden"),
                        text: L10n.format("Unter %@ liegt keine .4DProject-Datei (erwartet in „Project/“). Prüfe den Pfad in den Einstellungen unter „4D“.", engineRootPath),
                        lease: lease)
                    return
                }
                // Ein eingetragener, aber unbrauchbarer Pfad darf nicht still
                // auf eine andere automatisch gefundene Version fallen.
                if let pathProblem {
                    self.releaseFourDMacroEngineLock(runID: engineRunID)
                    self.presentFourDMacroWarning(
                        title: L10n.string("Eingetragenes tool4d ist nicht nutzbar"),
                        text: L10n.format("%@\n\nPrüfe den Pfad in den Einstellungen unter „4D“ oder leere das Feld, damit Fastra selbst sucht.",
                                          pathProblem),
                        lease: lease)
                    return
                }
                guard let tool else {
                    self.releaseFourDMacroEngineLock(runID: engineRunID)
                    // Das bereits bekannte Ergebnis anzeigen; `runFinder()`
                    // würde dieselben Fundorte ein zweites Mal durchsuchen.
                    if let window = lease.originWindow(in: self) {
                        Tool4DAssist.presentFinderResult(nil, asSheetFor: window)
                    }
                    return
                }
                self.startFourDMacroEngine(
                    tool: tool, engineRoot: engineRoot,
                    projectFile: projectFile, detokenized: detokenized,
                    learned: learned, variant: variant,
                    methodName: methodName, macroName: macroName,
                    originalText: originalText, lease: lease,
                    engineRunID: engineRunID
                )
            }
        }
        return true
    }

    /// Startet erst nach dem asynchronen Preflight den eigentlichen
    /// tool4d-Prozess. `fourDMacroEngineBusy` bleibt bis zur fertigen
    /// Diff-Vorschau gesetzt; dadurch kann kein älterer Diff einen neueren
    /// Makrolauf überholen.
    @MainActor private func startFourDMacroEngine(
        tool: Tool4DDiscovery.Finding, engineRoot: URL, projectFile: URL,
        detokenized: String, learned: [String: String],
        variant: FourDKomplettierenVariant, methodName: String,
        macroName: String, originalText: String,
        lease: FourDMacroExecutionLease,
        engineRunID: UUID
    ) {
        FourDMacroEngine.run(
            tool4d: tool.executableURL,
            engineProjectRoot: engineRoot,
            engineProjectFile: projectFile,
            code: detokenized,
            variant: variant.rawValue,
            methodName: methodName,
            shouldStart: { [weak self] in
                // `runQueue` ist ein Hintergrundthread. Die Lease gehört zum
                // Main-Actor und wird dort synchron unmittelbar vor jeder
                // Engine-Nebenwirkung geprüft.
                DispatchQueue.main.sync {
                    guard let self else { return false }
                    return lease.isCurrent(in: self)
                }
            }
        ) { [weak self] result in
            // Die Engine liefert ihr Ergebnis zugesichert auf der Main-Queue
            // (`FourDMacroEngine.run`); dem Compiler wird das hier zugesichert.
            MainActor.assumeIsolated {
            guard let self else { return }
            // Nur die Completion des noch registrierten Laufs darf die
            // gemeinsame Sperre anfassen; eine verspätete Completion eines
            // abgeräumten Laufs würde sonst die Sperre eines Nachfolgers
            // löschen (Review 2026-08-29).
            guard self.fourDMacroEngineRunID == engineRunID else { return }
            guard lease.isCurrent(in: self) else {
                self.releaseFourDMacroEngineLock(runID: engineRunID)
                return
            }
            switch result {
            case .cancelledBeforeStart:
                self.releaseFourDMacroEngineLock(runID: engineRunID)
            case .failed(let text):
                self.releaseFourDMacroEngineLock(runID: engineRunID)
                self.presentFourDMacroWarning(
                    title: L10n.format("Makro „%@“ fehlgeschlagen", macroName),
                    text: text, lease: lease)
            case .unchanged:
                self.releaseFourDMacroEngineLock(runID: engineRunID)
                self.presentFourDMacroWarning(
                    title: L10n.format("Makro „%@“", macroName),
                    text: L10n.string("Keine Änderungen — die Methode ist bereits vollständig."),
                    lease: lease)
            case .changed(let newCode):
                // Übergabe an die Nachbearbeitung: Der Engine-Lauf ist
                // beendet, die Sperre wechselt nahtlos an den
                // Postprocess-Zustand (`startFourDMacroPostprocessing`).
                self.fourDMacroEngineRunID = nil
                self.startFourDMacroPostprocessing(
                    newCode: newCode, learned: learned,
                    originalText: originalText, macroName: macroName,
                    lease: lease)
            }
            }
        }
    }

    /// Rücktokenisiert das Engine-Ergebnis und baut anschließend den Diff im
    /// selben verwalteten Task. `buildDiff` ist nur für den deterministischen
    /// Abbruchtest injizierbar; der Produktpfad nutzt die echte Berechnung.
    @MainActor func startFourDMacroPostprocessing(
        newCode: String, learned: [String: String], originalText: String,
        macroName: String, lease: FourDMacroExecutionLease,
        buildDiff: @escaping (FileDiffRequest) -> FileDiffDocument = {
            Workspace.computeFileDiffDocument(request: $0)
        }
    ) {
        // Inhaltsänderung, Tab- oder Fensterschluss brechen diesen Handle ab
        // und geben die Makro-Sperre sofort frei; ein später Rücklauf darf
        // keinen Nachfolger abräumen.
        cancelFourDMacroPostprocessing()
        fourDMacroEngineBusy = true
        let postprocessID = UUID()
        fourDMacroPostprocessID = postprocessID
        fourDMacroPostprocessTabID = lease.tabID
        let currentName = L10n.string("Aktueller Stand")
        let resultName = L10n.format("Ergebnis von „%@“", macroName)
        let unchangedTitle = L10n.format("Makro „%@“", macroName)
        let unchangedText = L10n.string(
            "Keine Änderungen — die Methode ist bereits vollständig.")
        let discardedTitle = L10n.string("Makro-Vorschau verworfen")
        let discardedText = L10n.string(
            "Das Dokument wurde während des Makrolaufs geändert. Führe das Makro erneut aus.")
        fourDMacroPostprocessTask = Task.detached(
            priority: .userInitiated
        ) { [weak self] in
            let retokenized = FourDTokenTransform.retokenize(
                newCode, learned: learned,
                isCancelled: { Task.isCancelled })
            guard let retokenized, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.fourDMacroPostprocessID == postprocessID else {
                        return
                    }
                    self.clearFourDMacroPostprocessing()
                }
                return
            }
            guard retokenized != originalText else {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.fourDMacroPostprocessID == postprocessID else {
                        return
                    }
                    self.clearFourDMacroPostprocessing()
                    guard lease.isCurrent(in: self) else { return }
                    self.presentFourDMacroWarning(
                        title: unchangedTitle, text: unchangedText,
                        lease: lease)
                }
                return
            }
            let request = FileDiffRequest(
                left: .text(originalText, name: currentName),
                right: .text(retokenized, name: resultName),
                options: FileDiffOptions()
            )
            let document = buildDiff(request)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.fourDMacroPostprocessID == postprocessID else {
                    return
                }
                self.clearFourDMacroPostprocessing()
                // Veraltete Grundlage? Dann keine Vorschau mehr anbieten —
                // Anwenden würde an der Lease scheitern.
                guard lease.isCurrent(in: self) else {
                    self.presentFourDMacroWarning(
                        title: discardedTitle, text: discardedText,
                        lease: lease)
                    return
                }
                self.fourDMacroPreview = FourDMacroPreviewState(
                    macroName: macroName, lease: lease,
                    resultText: retokenized, request: request,
                    document: document)
            }
        }
    }

    /// Wendet das Vorschau-Ergebnis als EINEN Undo-Schritt an. Gültig nur,
    /// solange Dokument-, Pfad-, Projekt- und Inhaltsidentität exakt der
    /// Vorschau entsprechen.
    @discardableResult
    @MainActor func applyFourDMacroPreview() -> Bool {
        guard let preview = fourDMacroPreview else { return false }
        // Während dieses Aufrufs ist das SwiftUI-Sheet selbst das Key-Window.
        // Eine neue globale Zielsuche würde es mit Recht als unbekanntes
        // Vorderfenster ablehnen. Die Vorschau kennt ihr Dokument bereits:
        // Fenster und Editor deshalb gemeinsam aus ihrer Lease holen.
        guard preview.lease.isCurrent(in: self),
              let originWindow = preview.lease.originWindow(in: self),
              let textView = CommandTargeting.editorTextView(for: self),
              textView.window === originWindow else {
            fourDMacroPreview = nil
            NSAlert.runWarning(
                title: L10n.string("Makro-Ergebnis nicht angewendet"),
                text: L10n.string("Das Dokument entspricht nicht mehr dem Stand der Vorschau. Führe das Makro erneut aus."))
            return false
        }
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.fastraApplyTextOperation(replacing: fullRange,
                                          with: preview.resultText)
        fourDMacroPreview = nil
        return true
    }

    /// Verzögerte Makro-Meldungen gehören als Sheet an das Dokumentfenster
    /// ihres Starts. Ein zwischenzeitlich aktiviertes anderes Fenster darf
    /// keinen anwendungsmodalen Dialog für den Hintergrundlauf erhalten.
    @MainActor private func presentFourDMacroWarning(
        title: String, text: String, lease: FourDMacroExecutionLease
    ) {
        guard let window = lease.originWindow(in: self), window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("OK"))
        alert.beginSheetModal(for: window)
    }
}

/// ⌘-Kürzel, die das echte App-Menü bereits belegt. Der lebende Menübaum ist
/// die Quelle der Wahrheit; dadurch kann ein neues Menükommando nicht unbemerkt
/// von einem 4D-Makro überschrieben werden.
///
/// Die Umschalttaste gehört ausdrücklich dazu: Der globale Router leitet ein
/// Makro-Kürzel auch mit gedrückter Umschalttaste weiter (`KeyRouting`, „Shift
/// bleibt erlaubt"). Zählte hier nur das schlichte ⌘, behielte ein Makro mit
/// `/l` oder `/m` sein Kürzel und schlüge in einer `.4dm`-Datei die realen
/// Menübefehle ⇧⌘L („Soft Wrap") und ⇧⌘M („Markdown-Vorschau rechts anzeigen").
/// Option und Control brechen im Router ab und reservieren deshalb nichts.
enum AppMenuShortcutKeys {
    @MainActor static func reservedMacroKeys(in menu: NSMenu?) -> Set<Character> {
        guard let menu else { return [] }
        var result = Set<Character>()
        for item in menu.items {
            let modifiers = item.keyEquivalentModifierMask
                .intersection([.command, .option, .control, .shift])
            // Genau ⌘ oder ⇧⌘ — die beiden Kombinationen, die der Router als
            // Makro annimmt. `keyEquivalent` kann den Großbuchstaben selbst
            // tragen (AppKit-Konvention für ⇧); das Kleinschreiben deckt das
            // mit ab, weil auch der Router `charactersIgnoringModifiers`
            // kleinschreibt.
            let key = item.keyEquivalent.lowercased()
            if modifiers.subtracting(.shift) == .command,
               key.count == 1, let character = key.first {
                result.insert(character)
            }
            result.formUnion(reservedMacroKeys(in: item.submenu))
        }
        return result
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
