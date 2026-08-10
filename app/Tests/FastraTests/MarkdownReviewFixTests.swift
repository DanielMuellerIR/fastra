// MarkdownReviewFixTests.swift
//
// Regressionstests zu den Markdown-Funden des Code-Reviews vom 2026-08-10:
//
//   • E2 — Renderanforderungen der Vorschau verdichten sich auf die jüngste,
//     statt eine Warteschlange überholter Vollläufe aufzubauen.
//   • E3 — Der Bildwächter beobachtet bei einem symbolischen Link BEIDE
//     Ordner: den des Links und den des aufgelösten Ziels.
//   • E5 — Anlegen des `images`-Ordners, Kopie und das Zurücknehmen eines
//     leer gebliebenen Ordners laufen unter demselben Ordner-Lock.
//
// Fund E1 (leere Vorschau, wenn vor der Erstnavigation getippt wird) und
// Fund E4 (fremder Umwandlungszustand in einem zweiten Fenster) sitzen in
// SwiftUI-/WebKit-Pfaden ohne fensterlosen Einstieg; sie werden von den
// Fenster-Selbsttests abgedeckt (siehe Bericht).

import Foundation
import Testing
@testable import Fastra

// MARK: - Helfer

/// Temporäres Arbeitsverzeichnis, das am Ende wieder verschwindet.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-mdreview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Sammelt die Completions der Vorschau-Renderläufe.
/// Der Zähler ist die eigentliche Aussage des Tests: Er zählt, wie oft
/// WIRKLICH gerendert wurde.
private final class RenderCollector {
    private let lock = NSLock()
    private var completions = 0
    private var latestHTML = ""
    private var resumed = false

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return completions
    }

    var lastHTML: String {
        lock.lock(); defer { lock.unlock() }
        return latestHTML
    }

    func record(html: String, sentinel: String,
                continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        completions += 1
        latestHTML = html
        let shouldResume = !resumed && html.contains(sentinel)
        if shouldResume { resumed = true }
        lock.unlock()
        // Fortsetzen erst außerhalb des Locks — `resume` darf genau einmal
        // laufen, deshalb die Merkvariable oben.
        if shouldResume { continuation.resume() }
    }
}

/// Merkt threadsicher, welcher der beiden parallelen Ablage-Vorgänge schon
/// fertig ist.
private final class StoreOutcomes {
    private let lock = NSLock()
    private var finished: Set<String> = []
    private var errors: [String: Error] = [:]

    func finish(_ name: String, error: Error?) {
        lock.lock()
        finished.insert(name)
        if let error { errors[name] = error }
        lock.unlock()
    }

    func isFinished(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return finished.contains(name)
    }

    func error(_ name: String) -> Error? {
        lock.lock(); defer { lock.unlock() }
        return errors[name]
    }
}

/// FileManager, der das Kopieren anhält, bis der Test es freigibt. Nur so
/// lässt sich beweisen, dass ein zweiter Drop in denselben Zielordner
/// wirklich wartet, statt daneben zu laufen.
private final class BlockingCopyFileManager: FileManager {
    let reachedCopy = DispatchSemaphore(value: 0)
    let mayFinishCopy = DispatchSemaphore(value: 0)

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        reachedCopy.signal()
        // Notbremse: Ein hängender Test wäre schlimmer als ein roter.
        _ = mayFinishCopy.wait(timeout: .now() + 10)
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

/// FileManager, dessen Kopie immer scheitert — für die Aufräumzusage.
private final class FailingCopyFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

// MARK: - E2: Verdichtung der Renderanforderungen

@Test("Vorschau-Rendern verdichtet sich auf die jüngste Anforderung")
func renderCoalescer_onlyLatestIsRendered() async {
    let coalescer = MarkdownRenderCoalescer()
    // Groß genug, dass ein Renderlauf messbar dauert — sonst könnte die
    // Render-Queue alle Anforderungen abarbeiten, bevor der Test sie
    // überhaupt vollständig angemeldet hat.
    let body = (0..<400)
        .map { "Zeile \($0) mit **Auszeichnung** und `Code`." }
        .joined(separator: "\n\n")
    // Die Eingaben ENTSTEHEN vor der Messung: Im Anmeldelauf soll nichts
    // außer der Anmeldung selbst Zeit kosten.
    let inputs = (0..<200).map { "# Titel\n\n\(body)\n\nAbschluss \($0)\n" }
    let sentinel = "Abschluss \(inputs.count - 1)"
    let collector = RenderCollector()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        for markdown in inputs {
            coalescer.render(markdown: markdown, documentURL: nil) { fragment in
                collector.record(html: fragment.html, sentinel: sentinel,
                                 continuation: continuation)
            }
        }
    }

    // Der jüngste Stand muss ankommen …
    #expect(collector.lastHTML.contains(sentinel))
    // … und die überholten Anforderungen dürfen gar nicht erst gerendert
    // werden. Vor der Korrektur lief jede einzelne: 200 Vollläufe.
    #expect(collector.count >= 1)
    #expect(collector.count <= 50,
            "Es liefen \(collector.count) Renderläufe für 200 Anforderungen — die Verdichtung greift nicht")
}

// MARK: - E3: Bildwächter und symbolische Links

@Test("Bildwächter beobachtet Link-Ordner UND Ziel-Ordner")
func imageWatcher_watchesLinkAndTargetDirectory() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let linkDirectory = root.appendingPathComponent("dokument")
    let targetDirectory = root.appendingPathComponent("bildablage")
    try FileManager.default.createDirectory(at: linkDirectory,
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetDirectory,
                                            withIntermediateDirectories: true)

    let target = targetDirectory.appendingPathComponent("echt.png")
    try Data("erstes Bild".utf8).write(to: target)
    let link = linkDirectory.appendingPathComponent("bild.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let directories = MarkdownImageWatcher.directoriesToWatch(for: [link])

    let expectedLinkDirectory = linkDirectory
        .resolvingSymlinksInPath().standardizedFileURL.path
    let expectedTargetDirectory = targetDirectory
        .resolvingSymlinksInPath().standardizedFileURL.path
    #expect(directories.contains(expectedLinkDirectory))
    // Genau dieser Ordner fehlte: Ein Austausch am Ziel erzeugte im Ordner
    // des Links kein Ereignis, die offene Vorschau blieb alt.
    #expect(directories.contains(expectedTargetDirectory))
    #expect(directories.count == 2)
}

@Test("Bildwächter: gewöhnliche Datei ergibt genau einen Ordner")
func imageWatcher_plainFileYieldsSingleDirectory() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let image = root.appendingPathComponent("bild.png")
    try Data("Bild".utf8).write(to: image)

    let directories = MarkdownImageWatcher.directoriesToWatch(for: [image])
    #expect(directories == [root.resolvingSymlinksInPath().standardizedFileURL.path])
}

// MARK: - E5: Ordner-Lock umfasst Anlegen, Kopie und Aufräumen

@Test("Zwei Drops in denselben neuen images-Ordner laufen nacheinander")
func imageStore_serializesDirectoryCreationAndCopy() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceDirectory = root.appendingPathComponent("quelle")
    try FileManager.default.createDirectory(at: sourceDirectory,
                                            withIntermediateDirectories: true)
    let document = root.appendingPathComponent("Notiz.md")
    try "# Notiz\n".write(to: document, atomically: true, encoding: .utf8)

    // Der Inhalt ist der Ablage gleichgültig; er unterscheidet sich nur,
    // damit der Dedup-Pfad nicht zufällig greift.
    let first = sourceDirectory.appendingPathComponent("eins.png")
    let second = sourceDirectory.appendingPathComponent("zwei.png")
    try Data("eins".utf8).write(to: first)
    try Data("zwei".utf8).write(to: second)

    let blocking = BlockingCopyFileManager()
    let outcomes = StoreOutcomes()

    DispatchQueue.global().async {
        do {
            _ = try MarkdownImageStore.storeImageFile(first, documentURL: document,
                                                      fileManager: blocking)
            outcomes.finish("erster", error: nil)
        } catch {
            outcomes.finish("erster", error: error)
        }
    }
    // Ab hier hat der erste Vorgang den `images`-Ordner angelegt und hängt
    // mitten im Kopieren.
    #expect(blocking.reachedCopy.wait(timeout: .now() + 10) == .success)

    let secondStarted = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        secondStarted.signal()
        do {
            _ = try MarkdownImageStore.storeImageFile(second, documentURL: document,
                                                      fileManager: .default)
            outcomes.finish("zweiter", error: nil)
        } catch {
            outcomes.finish("zweiter", error: error)
        }
    }
    // Ohne diesen Beweis könnte der Test grün sein, weil der zweite Vorgang
    // gar nicht erst losgelaufen ist.
    #expect(secondStarted.wait(timeout: .now() + 10) == .success)
    // Reichlich Zeit: Ohne Lock wäre der zweite Vorgang längst durch (er
    // kopiert nur wenige Bytes) — und genau dann könnte das `defer` des
    // ersten Vorgangs ihm den Zielordner unter den Füßen wegnehmen.
    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(outcomes.isFinished("zweiter") == false,
            "Der zweite Drop überholte den ersten — der Ordner-Lock umfasst Anlegen und Kopieren nicht")

    blocking.mayFinishCopy.signal()
    for _ in 0..<100 {
        if outcomes.isFinished("erster") && outcomes.isFinished("zweiter") { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    #expect(outcomes.isFinished("erster"))
    #expect(outcomes.isFinished("zweiter"))
    #expect(outcomes.error("erster") == nil)
    #expect(outcomes.error("zweiter") == nil)

    let images = root.appendingPathComponent("images")
    #expect(FileManager.default.fileExists(
        atPath: images.appendingPathComponent("eins.png").path))
    #expect(FileManager.default.fileExists(
        atPath: images.appendingPathComponent("zwei.png").path))
}

@Test("Gescheiterte Ablage nimmt nur den selbst angelegten leeren Ordner zurück")
func imageStore_removesOnlySelfCreatedEmptyDirectory() throws {
    // Fall 1: `images` gab es vorher nicht → nach dem Fehler ist es weg.
    let fresh = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: fresh) }
    let freshDocument = fresh.appendingPathComponent("Notiz.md")
    try "# Notiz\n".write(to: freshDocument, atomically: true, encoding: .utf8)
    let freshSource = fresh.appendingPathComponent("quelle.png")
    try Data("Bild".utf8).write(to: freshSource)

    #expect(throws: (any Error).self) {
        _ = try MarkdownImageStore.storeImageFile(
            freshSource, documentURL: freshDocument,
            fileManager: FailingCopyFileManager()
        )
    }
    #expect(FileManager.default.fileExists(
        atPath: fresh.appendingPathComponent("images").path) == false)

    // Fall 2: `images` war schon da → es bleibt samt Inhalt stehen.
    let existing = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: existing) }
    let existingDocument = existing.appendingPathComponent("Notiz.md")
    try "# Notiz\n".write(to: existingDocument, atomically: true, encoding: .utf8)
    let existingImages = existing.appendingPathComponent("images")
    try FileManager.default.createDirectory(at: existingImages,
                                            withIntermediateDirectories: true)
    let keeper = existingImages.appendingPathComponent("alt.png")
    try Data("alt".utf8).write(to: keeper)
    let existingSource = existing.appendingPathComponent("quelle.png")
    try Data("Bild".utf8).write(to: existingSource)

    #expect(throws: (any Error).self) {
        _ = try MarkdownImageStore.storeImageFile(
            existingSource, documentURL: existingDocument,
            fileManager: FailingCopyFileManager()
        )
    }
    #expect(FileManager.default.fileExists(atPath: keeper.path))
}
