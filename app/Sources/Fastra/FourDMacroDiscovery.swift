// FourDMacroDiscovery.swift
//
// Findet die „Macros v2"-Dateien, aus denen `FourDMacroXML` die Makros liest.
// Rein lesend, ohne Oberfläche und ohne Workspace; der `FileManager` ist wie
// in `FourDComponentIndex` injizierbar, damit Tests mit Wegwerf-Ordnern
// auskommen.
//
// 4D kennt drei Fundorte, und sie gelten alle gleichzeitig:
//
// 1. Komponenten des geöffneten Projekts. Bis 4D v20 liegt der Makro-Ordner
//    direkt im Komponenten-Bundle (`<Name>.4dbase/Macros v2/`), ab v21
//    darunter in `Contents/`. Zusätzlich kann eine Komponente über
//    `Project/Sources/dependencies.json` von woanders eingebunden sein — dann
//    steht ihr Ort dort als „path".
// 2. Benutzerweit unter `~/Library/Application Support/4D/Macros v2/`.
// 3. Die mitgelieferten Standardmakros in 4D.app selbst, je Sprache.
//
// Nichts hier wirft: Ein unlesbarer Ordner, ein kaputtes JSON oder ein
// fehlendes 4D bedeuten „hier gibt es keine Makros", nicht „Fehler". Ein
// defekter Fundort darf die anderen nicht verhindern.

import Foundation

/// Eine gefundene Makro-Datei samt ihrer Herkunft. Die Herkunft entscheidet
/// später über Gruppierung und Beschriftung im Menü.
struct FourDMacroSource: Equatable {
    let url: URL
    let origin: Origin

    enum Origin: Equatable {
        /// Aus einer Komponente des Projekts (Name ohne Endung).
        case component(name: String)
        /// Aus `~/Library/Application Support/4D/Macros v2`.
        case userLibrary
        /// Aus der installierten 4D.app (Version aus deren Info.plist).
        case fourDApplication(version: String?)

        /// Eindeutige, nutzersichtbare Herkunft für den Makro-Tooltip. Zwei
        /// Quellen heißen häufig beide `Macros.xml`; der Dateiname allein
        /// erklärt dann nicht, welchen Eintrag der Nutzer anklickt.
        func displayLabel(fileName: String) -> String {
            switch self {
            case .component(let name):
                return L10n.format("Komponente %@ — %@", name, fileName)
            case .userLibrary:
                return L10n.format("Eigene Makros — %@", fileName)
            case .fourDApplication(let version):
                if let version, !version.isEmpty {
                    return L10n.format("4D %@ — %@", version, fileName)
                }
                return L10n.format("4D — %@", fileName)
            }
        }
    }
}

/// Testnaht der Discovery-Verzeichnisaufzählung: `FileManager.enumerator(at:)`
/// ist eine nicht überschreibbare Swift-Extension — ein Test-FileManager kann
/// die lazy Aufzählung deshalb nicht per Override beobachten. Die Discovery
/// meldet die geöffnete Wurzel stattdessen an jeden FileManager, der dieses
/// Protokoll annimmt (Review 2026-08-31). Produktiv nimmt es niemand an; der
/// Cast kostet dann nur einen Typvergleich.
protocol MacroDirectoryEnumerationObserving {
    func noteDirectoryEnumeration(at url: URL)
}

enum FourDMacroDiscovery {

    /// Die beiden Lagen, in denen ein Komponenten-Bundle seinen Makro-Ordner
    /// haben kann: bis 4D v20 direkt, ab v21 unter `Contents`.
    private static let macroDirectoryPaths = ["Macros v2", "Contents/Macros v2"]

    /// Zentrale Erzeugung ALLER Discovery-Enumeratoren — immer nicht
    /// rekursiv, ohne versteckte Dateien und fehlertolerant. Nur hier wird
    /// die Testnaht bedient; ein zusätzlicher direkter `enumerator(at:)`-
    /// Aufruf wäre für die Budget-Tests unsichtbar.
    private static func directoryEnumerator(
        at url: URL, fileManager: FileManager
    ) -> FileManager.DirectoryEnumerator? {
        (fileManager as? MacroDirectoryEnumerationObserving)?
            .noteDirectoryEnumeration(at: url)
        return fileManager.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true })
    }
    /// Auch die Projekt-Abhängigkeitsliste ist fremder Dateiinhalt. Dieselbe
    /// Grenze wie für eine Makro-XML verhindert, dass die Discovery eine
    /// beliebig große JSON-Datei vollständig in den Speicher lädt.
    static let maximumDependenciesJSONBytes = 8 * 1024 * 1024
    /// Gemeinsames Arbeitsbudget für fremde Projekt- und Makroverzeichnisse.
    /// Das Quellenlimit allein genügt nicht: Bis zum ersten XML-Treffer können
    /// beliebig viele ungeeignete Einträge liegen.
    static let maximumDirectoryEntryCount = 4_096

    // MARK: - Projektwurzel

    /// Steigt vom Dokument aufwärts und liefert die 4D-Projektwurzel.
    /// Erkennungsmerkmal ist ein Unterordner `Project`, in dem (nicht
    /// rekursiv) eine `*.4DProject`-Datei liegt — dasselbe Merkmal, das auch
    /// `Tool4DProjectLocator` verwendet. Mehr als acht Ebenen werden nicht
    /// geprüft: Wer so tief liegt, gehört nicht mehr zum Projekt.
    static func projectRoot(forDocument url: URL,
                            fileManager: FileManager = .default) -> URL? {
        var entryBudget = maximumDirectoryEntryCount
        return projectRoot(forDocument: url, fileManager: fileManager,
                           entryBudget: &entryBudget)
    }

    /// Variante mit geteiltem Arbeitsbudget: Der Kataloglauf gibt dasselbe
    /// Budget anschließend an `macroSources` weiter, damit schon die Suche
    /// nach der Projektwurzel in sehr großen fremden `Project`-Ordnern nicht
    /// unbegrenzt Einträge materialisiert (Review 2026-08-31).
    static func projectRoot(forDocument url: URL,
                            fileManager: FileManager,
                            entryBudget: inout Int) -> URL? {
        var current = url.deletingLastPathComponent()
        for _ in 0..<8 {
            guard entryBudget > 0 else { return nil }
            if containsProjectFile(current, fileManager: fileManager,
                                   entryBudget: &entryBudget) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    /// `<Ordner>/Project/*.4DProject` — nur direkt in `Project`, nicht tiefer.
    /// Lazy über den Enumerator statt `contentsOfDirectory`: Der Ordner wird
    /// nur bis zum ersten Treffer bzw. bis zum verbrauchten Budget gelesen,
    /// ein riesiger fremder `Project`-Ordner also nie komplett materialisiert.
    private static func containsProjectFile(_ directory: URL,
                                            fileManager: FileManager,
                                            entryBudget: inout Int) -> Bool {
        let projectDirectory = directory.appendingPathComponent("Project", isDirectory: true)
        guard entryBudget > 0,
              let enumerator = directoryEnumerator(
                at: projectDirectory, fileManager: fileManager
              ) else { return false }
        while entryBudget > 0, let entry = enumerator.nextObject() as? URL {
            entryBudget -= 1
            if entry.pathExtension.lowercased() == "4dproject" { return true }
        }
        return false
    }

    // MARK: - Fundorte

    /// Alle Makro-Dateien in fester Reihenfolge: erst die Komponenten des
    /// Projekts, dann die benutzerweiten, zuletzt die von 4D mitgelieferten.
    /// Doppelte Funde — etwa weil dieselbe Komponente über `Components/` UND
    /// über `dependencies.json` erreichbar ist — fallen über den kanonischen
    /// Pfad heraus; der erste Fund gewinnt und behält seine Herkunft.
    static func macroSources(projectRoot: URL?,
                             homeDirectory: URL,
                             applicationDirectories: [URL],
                             fileManager: FileManager = .default,
                             preferredLanguages: [String] = Locale.preferredLanguages,
                             maximumSourceCount: Int
                                = FourDMacroCatalogLoader.maximumSourceCount,
                             maximumDirectoryEntryCount: Int
                                = maximumDirectoryEntryCount)
        -> [FourDMacroSource] {
        var sources: [FourDMacroSource] = []
        var seenPaths = Set<String>()
        // Das Quellenbudget gilt schon HIER: Ein fremder Makro-Ordner mit
        // sehr vielen Einträgen darf nicht erst beim späteren Laden gekürzt
        // werden, nachdem die Discovery bereits alles materialisiert und
        // sortiert hat.
        var remaining = max(0, maximumSourceCount)
        var remainingEntries = max(0, maximumDirectoryEntryCount)

        func add(_ url: URL, origin: FourDMacroSource.Origin) {
            guard remaining > 0 else { return }
            guard seenPaths.insert(url.canonicalFileURL.path).inserted else { return }
            sources.append(FourDMacroSource(url: url, origin: origin))
            remaining -= 1
        }

        if let projectRoot, remaining > 0, remainingEntries > 0 {
            for (name, container) in componentContainers(
                in: projectRoot, fileManager: fileManager,
                limit: remainingEntries, entryBudget: &remainingEntries
            ) {
                guard remaining > 0 else { break }
                for file in macroFiles(inComponent: container,
                                       fileManager: fileManager,
                                       limit: remaining,
                                       entryBudget: &remainingEntries) {
                    add(file, origin: .component(name: name))
                }
            }
        }

        if remaining > 0, remainingEntries > 0 {
            let userDirectory = homeDirectory
                .appendingPathComponent("Library/Application Support/4D/Macros v2",
                                        isDirectory: true)
            for file in xmlFiles(in: userDirectory, fileManager: fileManager,
                                 limit: remaining,
                                 entryBudget: &remainingEntries) {
                add(file, origin: .userLibrary)
            }
        }

        // Sobald höher priorisierte Fundorte das Budget verbraucht haben,
        // darf die reine Ergebnisgrenze nicht noch einen nutzlosen Scan der
        // Programme-Ordner auslösen.
        if remaining > 0, remainingEntries > 0 {
            let bundles = fourDApplicationBundles(
                in: applicationDirectories, fileManager: fileManager,
                entryBudget: &remainingEntries)
            if let choice = highestVersionBundle(bundles),
               remainingEntries > 0,
               let file = applicationMacrosFile(
                    inBundle: choice.url,
                    preferredLanguages: preferredLanguages,
                    fileManager: fileManager,
                    entryBudget: &remainingEntries) {
                add(file, origin: .fourDApplication(version: choice.version))
            }
        }

        return sources
    }

    // MARK: - Komponenten

    /// Alle Orte, an denen eine Komponente des Projekts liegen kann, als Paare
    /// aus Anzeigename und Ordner: die `.4dbase`-Bundles unter
    /// `Components`/`components` und die per `dependencies.json` eingebundenen.
    static func componentContainers(in projectRoot: URL,
                                    fileManager: FileManager) -> [(name: String, url: URL)] {
        var entryBudget = Int.max
        return componentContainers(
            in: projectRoot, fileManager: fileManager,
            limit: Int.max, entryBudget: &entryBudget)
    }

    private static func componentContainers(
        in projectRoot: URL,
        fileManager: FileManager,
        limit: Int,
        entryBudget: inout Int
    ) -> [(name: String, url: URL)] {
        var result: [(name: String, url: URL)] = []
        var seenPaths = Set<String>()

        func add(name: String, url: URL) {
            guard result.count < limit else { return }
            guard seenPaths.insert(url.canonicalFileURL.path).inserted else { return }
            result.append((name, url))
        }

        // 4D schreibt den Ordner mal groß, mal klein. Auf einem case-
        // insensitiven Dateisystem ist es derselbe — der Pfadvergleich in
        // `add` verhindert dann doppelte Einträge.
        for directoryName in ["Components", "components"] {
            guard result.count < limit, entryBudget > 0 else { break }
            let directory = projectRoot.appendingPathComponent(directoryName, isDirectory: true)
            let entries = boundedDirectoryEntries(
                in: directory, fileManager: fileManager,
                entryBudget: &entryBudget)
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.pathExtension.lowercased() == "4dbase" {
                add(name: entry.deletingPathExtension().lastPathComponent, url: entry)
                if result.count == limit { break }
            }
        }

        guard result.count < limit, entryBudget > 0 else { return result }
        for dependency in declaredDependencies(
            in: projectRoot, fileManager: fileManager,
            maximumCount: limit - result.count,
            entryBudget: &entryBudget
        ) {
            add(name: dependency.name, url: dependency.url)
        }
        return result
    }

    /// `Project/Sources/dependencies.json` liest 4D beim Öffnen des Projekts.
    /// Interessant ist hier nur ein Eintrag mit einem Feld „path": Er zeigt
    /// auf eine Komponente außerhalb des `Components`-Ordners. Alles andere
    /// (etwa Abhängigkeiten aus einem Repository) hat lokal keinen Pfad.
    static func declaredDependencies(
        in projectRoot: URL,
        fileManager: FileManager,
        maximumBytes: Int = maximumDependenciesJSONBytes
    ) -> [(name: String, url: URL)] {
        var entryBudget = Int.max
        return declaredDependencies(
            in: projectRoot, fileManager: fileManager,
            maximumBytes: maximumBytes, maximumCount: Int.max,
            entryBudget: &entryBudget)
    }

    private static func declaredDependencies(
        in projectRoot: URL,
        fileManager: FileManager,
        maximumBytes: Int = maximumDependenciesJSONBytes,
        maximumCount: Int,
        entryBudget: inout Int
    ) -> [(name: String, url: URL)] {
        let file = projectRoot
            .appendingPathComponent("Project/Sources/dependencies.json")
        // Über den gemeinsamen vorsichtigen Lesepfad: nicht blockierend
        // öffnen und nur eine reguläre Datei akzeptieren. Ein blockierendes
        // `FileHandle(forReadingFrom:)` hing vorher schon beim Öffnen einer
        // als `dependencies.json` untergeschobenen FIFO — noch vor der
        // Größenprüfung (Review 2026-08-31).
        guard fileManager.fileExists(atPath: file.path),
              let data = BoundedFileReading.openRegularFile(
                at: file, maximumBytes: maximumBytes, readData: true)?.data else {
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any] else { return [] }
        var result: [(name: String, url: URL)] = []
        // Ein JSON-Objekt hat keine feste Reihenfolge; alphabetisch sortiert
        // ist das Ergebnis über Programmstarts hinweg gleich.
        for name in dependencies.keys.sorted() {
            guard entryBudget > 0, result.count < maximumCount else { break }
            entryBudget -= 1
            guard let entry = dependencies[name] as? [String: Any],
                  let path = entry["path"] as? String, !path.isEmpty else { continue }
            result.append((name, resolve(path: path, relativeTo: projectRoot)))
        }
        return result
    }

    /// Pfad aus `dependencies.json` auflösen: absolut, mit `~` oder relativ
    /// zur Projektwurzel.
    static func resolve(path: String, relativeTo projectRoot: URL) -> URL {
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        // Die Basis MUSS ausdrücklich als Verzeichnis gebaut werden. Endet
        // ihr Pfad nicht auf „/", wirft `URL(fileURLWithPath:relativeTo:)`
        // die letzte Komponente weg (RFC-3986-Auflösung): „../Extern/X"
        // relativ zu „…/MeinProjekt" ergäbe sonst „…/Extern/X" statt
        // „…/MeinProjekt/../Extern/X" — eine Ebene zu hoch, gemessen am
        // 2026-08-19. `absoluteURL` löst danach den Bezug zur Basis auf,
        // `standardizedFileURL` die „..“-Schritte.
        let base = URL(fileURLWithPath: projectRoot.path, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: base)
            .absoluteURL.standardizedFileURL
    }

    /// Makro-Dateien einer Komponente, beide Lagen (v20 und v21), je Lage
    /// höchstens `limit` Dateien.
    private static func macroFiles(inComponent container: URL,
                                   fileManager: FileManager,
                                   limit: Int,
                                   entryBudget: inout Int) -> [URL] {
        var result: [URL] = []
        for relativePath in macroDirectoryPaths {
            guard result.count < limit, entryBudget > 0 else { break }
            result.append(contentsOf: xmlFiles(
                in: container.appendingPathComponent(relativePath, isDirectory: true),
                fileManager: fileManager, limit: limit - result.count,
                entryBudget: &entryBudget))
        }
        return result
    }

    /// Höchstens die `limit` alphabetisch ersten `*.xml` eines Ordners. Ein
    /// fehlender oder unlesbarer Ordner liefert eine leere Liste. Der Ordner
    /// wird lazy aufgezählt und nur eine begrenzte Auswahl gehalten und
    /// sortiert: Ein fremder Ordner mit sehr vielen Einträgen kann so weder
    /// Speicher noch Sortieraufwand jenseits des Quellenbudgets erzeugen.
    private static func xmlFiles(in directory: URL, fileManager: FileManager,
                                 limit: Int,
                                 entryBudget: inout Int) -> [URL] {
        guard limit > 0, entryBudget > 0 else { return [] }
        guard let enumerator = directoryEnumerator(
            at: directory, fileManager: fileManager
        ) else { return [] }
        let ascending = { (lhs: URL, rhs: URL) in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                == .orderedAscending
        }
        // Auswahl der alphabetisch kleinsten Namen: Kandidaten sammeln und
        // bei doppelter Budgetgröße auf die `limit` ersten eindampfen —
        // O(n log limit) statt einer Sortierung aller Einträge.
        let compactionThreshold = limit >= Int.max / 2 ? Int.max : limit * 2
        var selected: [URL] = []
        while entryBudget > 0, let entry = enumerator.nextObject() as? URL {
            entryBudget -= 1
            guard entry.pathExtension.lowercased() == "xml" else { continue }
            selected.append(entry)
            if selected.count >= compactionThreshold {
                selected.sort(by: ascending)
                selected.removeLast(selected.count - limit)
            }
        }
        selected.sort(by: ascending)
        if selected.count > limit {
            selected.removeLast(selected.count - limit)
        }
        return selected
    }

    /// Zählt höchstens das noch verfügbare Arbeitsbudget aus einem fremden
    /// Ordner auf. Anders als `contentsOfDirectory` materialisiert dieser
    /// Pfad nicht zuerst das komplette Verzeichnis.
    private static func boundedDirectoryEntries(
        in directory: URL,
        fileManager: FileManager,
        entryBudget: inout Int
    ) -> [URL] {
        guard entryBudget > 0,
              let enumerator = directoryEnumerator(
                at: directory, fileManager: fileManager) else { return [] }
        var entries: [URL] = []
        while entryBudget > 0, let entry = enumerator.nextObject() as? URL {
            entryBudget -= 1
            entries.append(entry)
        }
        return entries
    }

    // MARK: - 4D.app

    /// Sucht in den übergebenen Programme-Ordnern bis Tiefe 2 nach Bundles,
    /// die genau „4D.app" heißen. Die Tiefe 2 ist nötig, weil 4D üblicherweise
    /// in einem Versionsordner liegt (`/Applications/4D v21/4D.app`). Der
    /// exakte Name ist Absicht: „4D Server.app" und „tool4d.app" bringen
    /// andere oder gar keine Makros mit.
    static func fourDApplicationBundles(in directories: [URL],
                                        fileManager: FileManager) -> [URL] {
        var entryBudget = Int.max
        return fourDApplicationBundles(
            in: directories, fileManager: fileManager,
            entryBudget: &entryBudget)
    }

    private static func fourDApplicationBundles(
        in directories: [URL],
        fileManager: FileManager,
        entryBudget: inout Int
    ) -> [URL] {
        var found: [URL] = []
        var seenPaths = Set<String>()

        func scan(_ directory: URL, depth: Int) {
            guard depth <= 2, entryBudget > 0 else { return }
            let entries = boundedDirectoryEntries(
                in: directory, fileManager: fileManager,
                entryBudget: &entryBudget)
            for entry in entries {
                if entry.lastPathComponent.lowercased() == "4d.app" {
                    if seenPaths.insert(entry.canonicalFileURL.path).inserted {
                        found.append(entry)
                    }
                    continue
                }
                // Nicht in fremde App-Bundles hineinsteigen.
                guard entry.pathExtension.lowercased() != "app" else { continue }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                scan(entry, depth: depth + 1)
            }
        }

        for directory in directories { scan(directory, depth: 1) }
        return found.sorted { $0.path < $1.path }
    }

    /// Bei mehreren installierten 4D-Versionen gewinnt die höchste. Verglichen
    /// wird versionsnumerisch (`localizedStandardCompare`): „21.1" schlägt
    /// „20.5", und „20.10" schlägt „20.9" — lexikalisch wäre beides falsch.
    /// Ein Bundle ohne lesbare Version verliert gegen jedes mit Version; bei
    /// Gleichstand entscheidet der Pfad, damit das Ergebnis nicht von der
    /// Lesereihenfolge des Verzeichnisses abhängt.
    static func highestVersionBundle(_ bundles: [URL]) -> (url: URL, version: String?)? {
        let candidates: [(url: URL, version: String?)] = bundles.map {
            ($0, Tool4DDiscovery.bundleVersion(appURL: $0))
        }
        return candidates.max { lhs, rhs in
            switch (lhs.version, rhs.version) {
            case let (lhsVersion?, rhsVersion?):
                let byVersion = lhsVersion.localizedStandardCompare(rhsVersion)
                if byVersion != .orderedSame { return byVersion == .orderedAscending }
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case (nil, nil):
                break
            }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
    }

    /// `Contents/Resources/<Sprache>.lproj/Macros.xml` aus einem 4D-Bundle.
    /// Maßgeblich ist die Sprachreihenfolge des Systems; danach folgen fest
    /// Deutsch und Englisch, damit auf einem anderssprachigen Mac überhaupt
    /// etwas gefunden wird. Bringt 4D keine dieser Sprachen mit, gewinnt der
    /// alphabetisch erste `.lproj`-Ordner mit einer `Macros.xml`.
    static func applicationMacrosFile(inBundle bundle: URL,
                                      preferredLanguages: [String],
                                      fileManager: FileManager) -> URL? {
        var entryBudget = Int.max
        return applicationMacrosFile(
            inBundle: bundle, preferredLanguages: preferredLanguages,
            fileManager: fileManager, entryBudget: &entryBudget)
    }

    private static func applicationMacrosFile(
        inBundle bundle: URL,
        preferredLanguages: [String],
        fileManager: FileManager,
        entryBudget: inout Int
    ) -> URL? {
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let entries = boundedDirectoryEntries(
            in: resources, fileManager: fileManager,
            entryBudget: &entryBudget)
        let languageDirectories = entries.filter {
            $0.pathExtension.lowercased() == "lproj"
        }
        var directoriesByLanguage: [String: URL] = [:]
        for directory in languageDirectories {
            let language = directory.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            // Bei zwei nur durch Schreibweise verschiedenen Ordnern gewinnt
            // deterministisch der alphabetisch erste Pfad.
            if let previous = directoriesByLanguage[language],
               previous.path.localizedStandardCompare(directory.path)
                != .orderedDescending {
                continue
            }
            directoriesByLanguage[language] = directory
        }
        var order: [String] = []
        for language in preferredLanguages + ["de", "en"] {
            // Die BCP-47-Kennung von rechts verkürzen: `zh-Hant-TW` sucht
            // zuerst die Region, dann die Schriftvariante `zh-Hant` und erst
            // zuletzt die Basissprache `zh`. Bindestrich und Unterstrich
            // gelten dabei gleich.
            let normalized = language.replacingOccurrences(of: "_", with: "-")
                .lowercased()
            var components = normalized.split(separator: "-").map(String.init)
            while !components.isEmpty {
                let candidate = components.joined(separator: "-")
                if !order.contains(candidate) { order.append(candidate) }
                components.removeLast()
            }
        }
        for language in order {
            guard let directory = directoriesByLanguage[language] else { continue }
            let candidate = directory.appendingPathComponent("Macros.xml")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        let sorted = languageDirectories
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending }
        for directory in sorted {
            let candidate = directory.appendingPathComponent("Macros.xml")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
