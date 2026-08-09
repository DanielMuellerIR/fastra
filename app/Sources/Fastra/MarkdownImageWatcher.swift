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
// und der Ordner meldet das zuverlässig.

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
        let directories = Set(imageURLs.map {
            $0.deletingLastPathComponent().path
        })
        guard directories != watchedDirectories else { return }
        watchedDirectories = directories
        stop()
        guard !directories.isEmpty else { return }
        start(paths: Array(directories))
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
