// Tool4DDiscovery.swift
//
// tool4d-Ersteinrichtungshilfe (Etappe 4 Wunschpaket 2026-07c).
//
// Fastra bündelt tool4d NICHT, lädt nichts herunter und startet keine
// Installation (Produktgrundsatz: keine versteckten Netzwerkaktionen).
// Diese Datei findet lediglich ein vom Nutzer bereits installiertes tool4d
// an den bekannten Orten, liest die Version aus dem Bundle-Info.plist
// (OHNE das Programm auszuführen) und merkt sich den Fundort als Grundlage
// einer späteren Prüf-Integration (Etappe 8).

import Foundation
import AppKit

/// Pure, testbare Pfad-Suche nach einem installierten tool4d.
enum Tool4DDiscovery {

    /// Wo ein tool4d gefunden wurde — für die verständliche Anzeige.
    enum Source: Equatable {
        /// Verzeichnis aus der PATH-Umgebungsvariable.
        case path(directory: String)
        /// Ein Programme-Ordner (z. B. /Applications).
        case applications(directory: String)
        /// Der globalStorage der VS-Code-Extension „4D-Analyzer".
        case analyzerExtension
    }

    struct Finding: Equatable {
        /// Das ausführbare Binary (…/tool4d.app/Contents/MacOS/tool4d
        /// oder ein nacktes Binary aus dem PATH).
        let executableURL: URL
        /// Version aus dem App-Bundle-Info.plist; `nil` bei nacktem Binary.
        /// Wird bewusst NIE durch Ausführen ermittelt.
        let version: String?
        let source: Source
    }

    /// Standard-Ablage der 4D-Analyzer-Extension auf dem Mac (siehe
    /// docs/tool4d.de.md): …/tool4d/<version>/<build>/tool4d.app
    static var defaultAnalyzerStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/4D.4d-analyzer/tool4d")
    }

    /// Prüft die bekannten Orte in fester Reihenfolge: PATH, Programme-
    /// Ordner, 4D-Analyzer-Extension. Alle Quellen sind für Tests
    /// injizierbar — es braucht kein echtes tool4d.
    static func locate(
        environmentPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        applicationDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications"),
        ],
        analyzerStorage: URL = defaultAnalyzerStorage,
        fileManager: FileManager = .default
    ) -> Finding? {
        if let finding = locateInPATH(environmentPATH, fileManager: fileManager) {
            return finding
        }
        for directory in applicationDirectories {
            let app = directory.appendingPathComponent("tool4d.app")
            if let finding = findingFromBundle(app, source: .applications(directory: directory.path),
                                               fileManager: fileManager) {
                return finding
            }
        }
        return locateInAnalyzerStorage(analyzerStorage, fileManager: fileManager)
    }

    /// PATH-Suche: erstes Verzeichnis mit einer ausführbaren Datei
    /// namens `tool4d` gewinnt.
    private static func locateInPATH(_ path: String?,
                                     fileManager: FileManager) -> Finding? {
        guard let path, !path.isEmpty else { return nil }
        for directory in path.split(separator: ":").map(String.init) {
            guard !directory.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("tool4d")
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path,
                                         isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            // Liegt das Binary in einem tool4d.app-Bundle, lässt sich die
            // Version aus dessen Info.plist lesen.
            return Finding(executableURL: candidate,
                           version: bundleVersion(forExecutable: candidate),
                           source: .path(directory: directory))
        }
        return nil
    }

    /// tool4d.app-Bundle → Finding mit Version aus dem Info.plist.
    private static func findingFromBundle(_ appURL: URL, source: Source,
                                          fileManager: FileManager) -> Finding? {
        let executable = appURL.appendingPathComponent("Contents/MacOS/tool4d")
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return Finding(executableURL: executable,
                       version: bundleVersion(appURL: appURL),
                       source: source)
    }

    /// Ablage der 4D-Analyzer-Extension: tool4d/<version>/<build>/tool4d.app.
    /// Bei mehreren Versionen gewinnt die höchste (numerisch sortiert).
    private static func locateInAnalyzerStorage(_ storage: URL,
                                                fileManager: FileManager) -> Finding? {
        guard let versions = try? fileManager.contentsOfDirectory(
            at: storage, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let sorted = versions.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedDescending
        }
        for versionDirectory in sorted {
            guard let builds = try? fileManager.contentsOfDirectory(
                at: versionDirectory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            let sortedBuilds = builds.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedDescending
            }
            for buildDirectory in sortedBuilds {
                let app = buildDirectory.appendingPathComponent("tool4d.app")
                if let finding = findingFromBundle(app, source: .analyzerExtension,
                                                   fileManager: fileManager) {
                    return finding
                }
            }
        }
        return nil
    }

    /// Version eines tool4d.app-Bundles aus dessen Info.plist — reines
    /// Datei-Lesen, KEIN Programmstart.
    static func bundleVersion(appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any] else { return nil }
        return values["CFBundleShortVersionString"] as? String
            ?? values["CFBundleVersion"] as? String
    }

    /// Version für ein Binary, das in einem tool4d.app-Bundle liegen kann
    /// (…/tool4d.app/Contents/MacOS/tool4d) — sonst `nil`.
    static func bundleVersion(forExecutable executable: URL) -> String? {
        let components = executable.pathComponents
        guard let index = components.lastIndex(of: "tool4d.app"), index >= 1 else {
            return nil
        }
        let appPath = components[...index].joined(separator: "/")
            .replacingOccurrences(of: "//", with: "/")
        return bundleVersion(appURL: URL(fileURLWithPath: appPath))
    }
}

/// Nutzersichtbarer Teil der Einrichtungshilfe: Erst-Kontakt-Hinweis-Zustand,
/// „tool4d finden…"-Dialog und der gemerkte Fundort.
enum Tool4DAssist {
    /// Download-Seite von 4D (öffnet NUR auf Klick — nie automatisch).
    static let downloadPageURL = URL(string: "https://product-download.4d.com")!

    private static let hintShownKey = "fastra.tool4d.firstContactHintShown"
    private static let rememberedPathKey = "fastra.tool4d.executablePath"

    /// „Einmal pro Nutzer": erscheint nie wieder, sobald der Hinweis über
    /// einen der beiden Buttons quittiert wurde. Läuft über die isolierte
    /// Selbsttest-Suite, damit Tests das echte Flag nicht verbrauchen.
    static var firstContactHintShown: Bool {
        get { SelfTest.workspaceDefaults().bool(forKey: hintShownKey) }
        set { SelfTest.workspaceDefaults().set(newValue, forKey: hintShownKey) }
    }

    /// Trigger des Erst-Kontakt-Hinweises: `.4dm`-Datei oder `.4DProject`.
    static func triggersFirstContactHint(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext == "4dm" || ext == "4dproject"
    }

    /// Gemerkter Fundort für die sichtbare LSP-Dokumentprüfung. Der Finder
    /// selbst startet ihn nie; ausgeführt wird tool4d erst auf den bewussten
    /// Befehl „Dokument prüfen“ für ein passendes geöffnetes Projekt.
    static var rememberedExecutablePath: String? {
        get { SelfTest.workspaceDefaults().string(forKey: rememberedPathKey) }
        set { SelfTest.workspaceDefaults().set(newValue, forKey: rememberedPathKey) }
    }

    /// Liefert ausschließlich ein bereits vorhandenes, ausführbares tool4d.
    /// Ein manuell gemerkter Pfad gewinnt, danach greift dieselbe Discovery
    /// wie „Hilfe → tool4d finden…“. Damit startet die Prüfung nie eine
    /// unbekannte oder inzwischen gelöschte Installation.
    static func installedTool(fileManager: FileManager = .default) -> Tool4DDiscovery.Finding? {
        if let path = rememberedExecutablePath,
           fileManager.isExecutableFile(atPath: path) {
            let executable = URL(fileURLWithPath: path)
            return Tool4DDiscovery.Finding(
                executableURL: executable,
                version: Tool4DDiscovery.bundleVersion(forExecutable: executable),
                source: .path(directory: executable.deletingLastPathComponent().path)
            )
        }
        return Tool4DDiscovery.locate(fileManager: fileManager)
    }

    /// „Hilfe → tool4d finden…": sucht asynchron an den bekannten Orten und
    /// zeigt Fundort + Version bzw. die Bezugsquellen. Der gefundene Pfad
    /// wird gemerkt.
    static func runFinder() {
        Task.detached(priority: .userInitiated) {
            let finding = Tool4DDiscovery.locate()
            await MainActor.run { presentFinderResult(finding) }
        }
    }

    @MainActor
    private static func presentFinderResult(_ finding: Tool4DDiscovery.Finding?) {
        let alert = NSAlert()
        if let finding {
            rememberedExecutablePath = finding.executableURL.path
            alert.messageText = L10n.string("tool4d gefunden")
            alert.informativeText = L10n.format(
                "%@\n\nVersion: %@\nQuelle: %@\n\nFastra merkt sich diesen Fundort. tool4d startet erst bei „Dokument prüfen“ für ein passendes geöffnetes 4D-Projekt.",
                finding.executableURL.path,
                finding.version ?? L10n.string("unbekannt (Version steht nur in App-Bundles)"),
                sourceDescription(finding.source)
            )
            alert.addButton(withTitle: L10n.string("OK"))
            alert.addButton(withTitle: L10n.string("Im Finder zeigen"))
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([finding.executableURL])
            }
        } else {
            alert.messageText = L10n.string("Kein tool4d gefunden")
            alert.informativeText = L10n.string(
                "Fastra hat an den bekannten Orten gesucht: im PATH, in den Programme-Ordnern und in der Ablage der VS-Code-Extension „4D-Analyzer“.\n\ntool4d ist laut 4D frei und ohne Lizenz nutzbar. Du kannst es von der 4D-Download-Seite laden oder die VS-Code-Extension „4D-Analyzer“ installieren, die es automatisch mitbringt — Details in der Hilfe. Fastra selbst lädt nichts herunter."
            )
            alert.addButton(withTitle: L10n.string("OK"))
            alert.addButton(withTitle: L10n.string("Download-Seite öffnen"))
            alert.addButton(withTitle: L10n.string("Hilfe öffnen"))
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(downloadPageURL)
            } else if response == .alertThirdButtonReturn {
                HelpWindow.show(anchor: HelpSection.fourDTool.anchor())
            }
        }
    }

    /// Verständliche Quellen-Beschreibung für den Ergebnis-Dialog.
    static func sourceDescription(_ source: Tool4DDiscovery.Source) -> String {
        switch source {
        case .path(let directory):
            return L10n.format("PATH-Verzeichnis %@", directory)
        case .applications(let directory):
            return L10n.format("Programme-Ordner %@", directory)
        case .analyzerExtension:
            return L10n.string("VS-Code-Extension „4D-Analyzer“")
        }
    }
}
