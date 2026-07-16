import Foundation
import Testing
@testable import Fastra

@Test("Terminalziel bevorzugt Projektroot vor aktiver Datei")
func terminalResolverPrefersProject() {
    let project = URL(fileURLWithPath: "/tmp/Projekt mit Leerzeichen")
    let file = URL(fileURLWithPath: "/tmp/anders/Grüße [x].txt")
    #expect(TerminalDirectoryResolver.resolve(projectURL: project, activeFileURL: file)
            == project.standardizedFileURL)
}

@Test("Terminalziel fällt ohne Projekt auf den Ordner der aktiven Datei zurück")
func terminalResolverUsesActiveFile() {
    let file = URL(fileURLWithPath: "/tmp/Sonder ! [x]/Grüße.txt")
    #expect(TerminalDirectoryResolver.resolve(projectURL: nil, activeFileURL: file)
            == file.deletingLastPathComponent().standardizedFileURL)
    #expect(TerminalDirectoryResolver.resolve(projectURL: nil, activeFileURL: nil) == nil)
}

@Test("Native Terminalöffnung übergibt die Ordner-URL unverändert ohne Shell")
func terminalLauncherUsesNativeURLs() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra Terminal ! Grüße [x] \(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let application = URL(fileURLWithPath: "/Applications/Terminal.app")
    let capture = TerminalOpenCapture()
    let launcher = ExternalTerminalLauncher(
        applicationLocator: { application },
        nativeOpen: { folder, app, completion in
            capture.store(directory: folder, application: app)
            completion(nil)
        }
    )

    let result = await withCheckedContinuation { continuation in
        launcher.open(directory: directory) { continuation.resume(returning: $0) }
    }
    guard case .success = result else {
        Issue.record("Native Öffnung schlug fehl: \(result)")
        return
    }
    #expect(capture.directory == directory)
    #expect(capture.application == application)
}

@Test("Fehlender Ordner und fehlende Terminal.app liefern sichtbare Fehlerwerte")
func terminalLauncherErrors() async {
    let missing = URL(fileURLWithPath: "/definitely/missing/\(UUID().uuidString)")
    let noDirectory = ExternalTerminalLauncher(applicationLocator: {
        URL(fileURLWithPath: "/Applications/Terminal.app")
    })
    let missingResult = await withCheckedContinuation { continuation in
        noDirectory.open(directory: missing) { continuation.resume(returning: $0) }
    }
    guard case .failure(let missingError) = missingResult else {
        Issue.record("Fehlender Ordner wurde nicht abgelehnt")
        return
    }
    #expect(missingError == .directoryUnavailable(missing.path))

    let existing = FileManager.default.temporaryDirectory
    let noTerminal = ExternalTerminalLauncher(applicationLocator: { nil })
    let terminalResult = await withCheckedContinuation { continuation in
        noTerminal.open(directory: existing) { continuation.resume(returning: $0) }
    }
    guard case .failure(let terminalError) = terminalResult else {
        Issue.record("Fehlende Terminal.app wurde nicht abgelehnt")
        return
    }
    #expect(terminalError == .terminalUnavailable)
}

@Test("Volume-Prüfung läuft abseits Main, NSWorkspace-Schritte laufen auf Main")
func terminalLauncherUsesExpectedThreads() async {
    let capture = TerminalThreadCapture()
    let directory = URL(fileURLWithPath: "/tmp/Fastra Thread Test", isDirectory: true)
    let launcher = ExternalTerminalLauncher(
        fileInspection: { url in
            capture.recordInspection(url: url, isMain: Thread.isMainThread)
            return true
        },
        applicationLocator: {
            capture.recordLocator(isMain: Thread.isMainThread)
            return URL(fileURLWithPath: "/Applications/Terminal.app")
        },
        nativeOpen: { folder, _, completion in
            capture.recordOpen(url: folder, isMain: Thread.isMainThread)
            completion(nil)
        }
    )
    let result = await withCheckedContinuation { continuation in
        launcher.open(directory: directory) { continuation.resume(returning: $0) }
    }
    guard case .success = result else { Issue.record("Terminaltest schlug fehl"); return }
    #expect(capture.inspectionMain == false)
    #expect(capture.locatorMain == true)
    #expect(capture.openMain == true)
    #expect(capture.inspectedURL == directory)
    #expect(capture.openedURL == directory)
}

@Test("Normale Datei und nativer Open-Fehler werden sichtbar abgelehnt")
func terminalLauncherRejectsFileAndOpenFailure() async throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-terminal-file-\(UUID().uuidString)")
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let application = URL(fileURLWithPath: "/Applications/Terminal.app")
    let fileResult = await withCheckedContinuation { continuation in
        ExternalTerminalLauncher(applicationLocator: { application })
            .open(directory: file) { continuation.resume(returning: $0) }
    }
    guard case .failure(let fileError) = fileResult else {
        Issue.record("Normale Datei wurde geöffnet"); return
    }
    #expect(fileError == .directoryUnavailable(file.path))

    let expected = "kontrollierter Open-Fehler"
    let openResult = await withCheckedContinuation { continuation in
        ExternalTerminalLauncher(
            fileInspection: { _ in true }, applicationLocator: { application },
            nativeOpen: { _, _, completion in
                completion(NSError(domain: "FastraTests", code: 7,
                                   userInfo: [NSLocalizedDescriptionKey: expected]))
            }
        ).open(directory: FileManager.default.temporaryDirectory) {
            continuation.resume(returning: $0)
        }
    }
    guard case .failure(let openError) = openResult else {
        Issue.record("Open-Fehler wurde verschluckt"); return
    }
    #expect(openError == .openFailed(expected))
}

private final class TerminalOpenCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDirectory: URL?
    private var storedApplication: URL?

    var directory: URL? { lock.withLock { storedDirectory } }
    var application: URL? { lock.withLock { storedApplication } }

    func store(directory: URL, application: URL) {
        lock.withLock {
            storedDirectory = directory
            storedApplication = application
        }
    }
}

private final class TerminalThreadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var inspectionMainValue: Bool?
    private var locatorMainValue: Bool?
    private var openMainValue: Bool?
    private var inspectedURLValue: URL?
    private var openedURLValue: URL?

    var inspectionMain: Bool? { lock.withLock { inspectionMainValue } }
    var locatorMain: Bool? { lock.withLock { locatorMainValue } }
    var openMain: Bool? { lock.withLock { openMainValue } }
    var inspectedURL: URL? { lock.withLock { inspectedURLValue } }
    var openedURL: URL? { lock.withLock { openedURLValue } }

    func recordInspection(url: URL, isMain: Bool) {
        lock.withLock { inspectedURLValue = url; inspectionMainValue = isMain }
    }
    func recordLocator(isMain: Bool) { lock.withLock { locatorMainValue = isMain } }
    func recordOpen(url: URL, isMain: Bool) {
        lock.withLock { openedURLValue = url; openMainValue = isMain }
    }
}
