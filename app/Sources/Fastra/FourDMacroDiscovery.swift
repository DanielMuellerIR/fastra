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

enum FourDMacroDiscovery {

    /// Die beiden Lagen, in denen ein Komponenten-Bundle seinen Makro-Ordner
    /// haben kann: bis 4D v20 direkt, ab v21 unter `Contents`.
    private static let macroDirectoryPaths = ["Macros v2", "Contents/Macros v2"]
    /// Auch die Projekt-Abhängigkeitsliste ist fremder Dateiinhalt. Dieselbe
    /// Grenze wie für eine Makro-XML verhindert, dass die Discovery eine
    /// beliebig große JSON-Datei vollständig in den Speicher lädt.
    static let maximumDependenciesJSONBytes = 8 * 1024 * 1024

    // MARK: - Projektwurzel

    /// Steigt vom Dokument aufwärts und liefert die 4D-Projektwurzel.
    /// Erkennungsmerkmal ist ein Unterordner `Project`, in dem (nicht
    /// rekursiv) eine `*.4DProject`-Datei liegt — dasselbe Merkmal, das auch
    /// `Tool4DProjectLocator` verwendet. Mehr als acht Ebenen werden nicht
    /// geprüft: Wer so tief liegt, gehört nicht mehr zum Projekt.
    static func projectRoot(forDocument url: URL,
                            fileManager: FileManager = .default) -> URL? {
        var current = url.deletingLastPathComponent()
        for _ in 0..<8 {
            if containsProjectFile(current, fileManager: fileManager) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    /// `<Ordner>/Project/*.4DProject` — nur direkt in `Project`, nicht tiefer.
    private static func containsProjectFile(_ directory: URL,
                                            fileManager: FileManager) -> Bool {
        let projectDirectory = directory.appendingPathComponent("Project", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return false }
        return entries.contains { $0.pathExtension.lowercased() == "4dproject" }
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
                                = FourDMacroCatalogLoader.maximumSourceCount)
        -> [FourDMacroSource] {
        var sources: [FourDMacroSource] = []
        var seenPaths = Set<String>()
        // Das Quellenbudget gilt schon HIER: Ein fremder Makro-Ordner mit
        // sehr vielen Einträgen darf nicht erst beim späteren Laden gekürzt
        // werden, nachdem die Discovery bereits alles materialisiert und
        // sortiert hat.
        var remaining = max(0, maximumSourceCount)

        func add(_ url: URL, origin: FourDMacroSource.Origin) {
            guard remaining > 0 else { return }
            guard seenPaths.insert(url.canonicalFileURL.path).inserted else { return }
            sources.append(FourDMacroSource(url: url, origin: origin))
            remaining -= 1
        }

        if let projectRoot, remaining > 0 {
            for (name, container) in componentContainers(in: projectRoot,
                                                         fileManager: fileManager) {
                guard remaining > 0 else { break }
                for file in macroFiles(inComponent: container,
                                       fileManager: fileManager,
                                       limit: remaining) {
                    add(file, origin: .component(name: name))
                }
            }
        }

        if remaining > 0 {
            let userDirectory = homeDirectory
                .appendingPathComponent("Library/Application Support/4D/Macros v2",
                                        isDirectory: true)
            for file in xmlFiles(in: userDirectory, fileManager: fileManager,
                                 limit: remaining) {
                add(file, origin: .userLibrary)
            }
        }

        // Sobald höher priorisierte Fundorte das Budget verbraucht haben,
        // darf die reine Ergebnisgrenze nicht noch einen nutzlosen Scan der
        // Programme-Ordner auslösen.
        if remaining > 0 {
            let bundles = fourDApplicationBundles(
                in: applicationDirectories, fileManager: fileManager)
            if let choice = highestVersionBundle(bundles),
               let file = applicationMacrosFile(
                    inBundle: choice.url,
                    preferredLanguages: preferredLanguages,
                    fileManager: fileManager) {
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
        var result: [(name: String, url: URL)] = []
        var seenPaths = Set<String>()

        func add(name: String, url: URL) {
            guard seenPaths.insert(url.canonicalFileURL.path).inserted else { return }
            result.append((name, url))
        }

        // 4D schreibt den Ordner mal groß, mal klein. Auf einem case-
        // insensitiven Dateisystem ist es derselbe — der Pfadvergleich in
        // `add` verhindert dann doppelte Einträge.
        for directoryName in ["Components", "components"] {
            let directory = projectRoot.appendingPathComponent(directoryName, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.pathExtension.lowercased() == "4dbase" {
                add(name: entry.deletingPathExtension().lastPathComponent, url: entry)
            }
        }

        for dependency in declaredDependencies(in: projectRoot, fileManager: fileManager) {
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
        let file = projectRoot
            .appendingPathComponent("Project/Sources/dependencies.json")
        guard maximumBytes >= 0, maximumBytes < Int.max,
              fileManager.fileExists(atPath: file.path),
              let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        // In kleinen Blöcken bis höchstens Grenze + 1 lesen. `read(upToCount:)`
        // darf weniger als angefordert liefern; ein einzelner Read wäre daher
        // kein harter Beleg, dass hinter einem gültigen JSON-Präfix nichts mehr
        // folgt.
        var data = Data()
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            return []
        }
        guard data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any] else { return [] }
        var result: [(name: String, url: URL)] = []
        // Ein JSON-Objekt hat keine feste Reihenfolge; alphabetisch sortiert
        // ist das Ergebnis über Programmstarts hinweg gleich.
        for name in dependencies.keys.sorted() {
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
                                   limit: Int) -> [URL] {
        macroDirectoryPaths.flatMap { relativePath in
            xmlFiles(in: container.appendingPathComponent(relativePath, isDirectory: true),
                     fileManager: fileManager, limit: limit)
        }
    }

    /// Höchstens die `limit` alphabetisch ersten `*.xml` eines Ordners. Ein
    /// fehlender oder unlesbarer Ordner liefert eine leere Liste. Der Ordner
    /// wird lazy aufgezählt und nur eine begrenzte Auswahl gehalten und
    /// sortiert: Ein fremder Ordner mit sehr vielen Einträgen kann so weder
    /// Speicher noch Sortieraufwand jenseits des Quellenbudgets erzeugen.
    private static func xmlFiles(in directory: URL, fileManager: FileManager,
                                 limit: Int) -> [URL] {
        guard limit > 0 else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true }
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
        for case let entry as URL in enumerator
        where entry.pathExtension.lowercased() == "xml" {
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

    // MARK: - 4D.app

    /// Sucht in den übergebenen Programme-Ordnern bis Tiefe 2 nach Bundles,
    /// die genau „4D.app" heißen. Die Tiefe 2 ist nötig, weil 4D üblicherweise
    /// in einem Versionsordner liegt (`/Applications/4D v21/4D.app`). Der
    /// exakte Name ist Absicht: „4D Server.app" und „tool4d.app" bringen
    /// andere oder gar keine Makros mit.
    static func fourDApplicationBundles(in directories: [URL],
                                        fileManager: FileManager) -> [URL] {
        var found: [URL] = []
        var seenPaths = Set<String>()

        func scan(_ directory: URL, depth: Int) {
            guard depth <= 2, let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
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
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: resources, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }
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
