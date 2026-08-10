// MarkdownImageWatcher.swift
//
// Beobachtet die Elternordner der in der Markdown-Vorschau referenzierten
// Bilder über FSEvents (Roadmap „Nacharbeit aus dem Code-Review 2026-08-06").
// Hintergrund: Bei unverändertem Markdown kehrte die Vorschau-Aktualisierung
// zurück, bevor Bild-Adressen neu berechnet wurden — ein extern am gleichen
// Pfad ausgetauschtes Bild blieb deshalb unsichtbar alt, bis sich Markdown,
// Dokumentpfad oder Darstellungsstil änderten.
//
// Vorlage ist `ProjectFileWatcher`, aber mit MEHREREN Pfaden und ohne
// Projektbindung: Ein Markdown-Dokument darf Bilder aus beliebigen Ordnern
// referenzieren. Beobachtet werden die Elternordner (nicht die Dateien
// selbst) — ein atomarer Austausch ersetzt die Datei durch ein neues Objekt,
// und der Ordner meldet das zuverlässig. Bei einem symbolischen Link zählen
// beide Ordner: der des Links und der des aufgelösten Ziels (siehe
// `directoriesToWatch`).

import Foundation
import CoreServices

final class MarkdownImageWatcher {

    /// Läuft auf der Main-Queue, gebündelt durch die FSEvents-Latenz.
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private(set) var watchedDirectories: Set<String> = []

    deinit {
        stop()
    }

    /// Setzt die beobachteten Ordner auf die Elternordner der übergebenen
    /// Bild-Dateien. Eine unveränderte Menge lässt den laufenden Stream
    /// stehen (kein Neuaufbau bei jedem Tastendruck).
    func update(imageURLs: [URL]) {
        let directories = Self.directoriesToWatch(for: imageURLs)
        guard directories != watchedDirectories else { return }
        watchedDirectories = directories
        stop()
        guard !directories.isEmpty else { return }
        start(paths: Array(directories))
    }

    /// Die zu beobachtenden Ordner: zu jedem Bild der Elternordner des
    /// verlinkten Pfades UND der des symlink-aufgelösten Ziels.
    ///
    /// Der zweite Ordner ist nicht bloß Vorsicht: Vorschau-Ausgabe und
    /// Bild-Kennung (`MarkdownImages.imageToken`) lesen ausdrücklich das
    /// aufgelöste Ziel. Zeigt `bilder/foo.png` als symbolischer Link in einen
    /// anderen Ordner, dann tauscht ein externes Werkzeug die Datei DORT aus —
    /// im Ordner des Links passiert dabei nichts, es gibt also kein Ereignis
    /// und die offene Vorschau zeigte weiter das alte Bild
    /// (Code-Review 2026-08-10).
    ///
    /// Die Auflösung passiert bei jedem Aufruf neu, damit ein auf ein anderes
    /// Ziel umgehängter Link den neuen Zielordner mitbringt. Sie kostet je Bild
    /// zwei `realpath`-artige Zugriffe und läuft nur nach einem fertigen
    /// Renderlauf, der ohnehin jedes Bild einmal per `stat` anfasst.
    ///
    /// Wichtig ist die Reihenfolge der beiden Rechnungen: Für den Ordner des
    /// LINKS wird erst der Dateiname abgeschnitten und dann aufgelöst (sonst
    /// verschwände genau der Ordner, in dem der Link liegt); für den Ordner des
    /// ZIELS umgekehrt. Ist die Datei gar kein Link, ergeben beide Rechnungen
    /// denselben Pfad und die Menge bleibt einelementig.
    static func directoriesToWatch(for imageURLs: [URL]) -> Set<String> {
        var directories: Set<String> = []
        for url in imageURLs {
            let linkDirectory = url.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
            directories.insert(linkDirectory.path)
            let targetDirectory = url.resolvingSymlinksInPath().standardizedFileURL
                .deletingLastPathComponent()
            directories.insert(targetDirectory.path)
        }
        return directories
    }

    private func start(paths: [String]) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<MarkdownImageWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            // Stream hängt an der Main-Queue → Closure bleibt UI-sicher.
            watcher.onChange?()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
