// FourDProjectMethodIndexTests.swift
//
// Der Dateisystemteil des 4D-Highlightings bleibt bewusst klein und ohne
// SwiftUI testbar. Die Fixtures bilden nur den exportierten Methodenordner
// nach, niemals ein echtes Nutzerprojekt.

import Combine
import Dispatch
import Foundation
import Testing
@testable import Fastra

@Test("Index liest 4dm-Dateinamen case-insensitiv aus dem Methodenordner")
func fourDMethodIndex_readsProjectMethods() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-4d-index-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let methods = root.appendingPathComponent("Project/Sources/Methods")
    try FileManager.default.createDirectory(at: methods, withIntermediateDirectories: true)
    try Data().write(to: methods.appendingPathComponent("Abr_init.4dm"))
    try Data().write(to: methods.appendingPathComponent("ABR_SUCHEN.4DM"))
    try Data().write(to: methods.appendingPathComponent("Notiz.txt"))

    #expect(FourDProjectMethodIndex.methodNames(in: root)
        == ["abr_init", "abr_suchen"])
}

@Test("Controller liefert den initialen Projekt- und Komponentenstand als einen Snapshot")
@MainActor
func fourDProjectIndexController_initialScan() async throws {
    let root = try makeFourDIndexProject(
        label: "initial",
        projectMethods: ["zeta", "Alpha"],
        componentMethods: ["Beta_Shared"]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let watchers = TestFourDWatcherFactory()
    let controller = FourDProjectIndexController(makeWatcher: watchers.make)
    defer { controller.stop() }
    var deliveries: [FourDMethodIndexSnapshot] = []
    var deliveredOnMainThread = false

    controller.start(projectURL: root, projectGeneration: 7) { _, generation, snapshot in
        #expect(generation == 7)
        deliveredOnMainThread = Thread.isMainThread
        deliveries.append(snapshot)
    }

    #expect(await waitUntil(timeout: 15) { deliveries.count == 1 })
    let snapshot = try #require(deliveries.last)
    #expect(snapshot.projectMethodNames == ["alpha", "zeta"])
    #expect(snapshot.projectMethodDisplayNames == ["Alpha", "zeta"])
    #expect(snapshot.componentMethodDisplayNames == ["Beta_Shared"])
    #expect(snapshot.componentMethods["beta_shared"]?.componentName == "Fixture")
    #expect(deliveredOnMainThread)
    #expect(watchers.created.count == 1)
}

@Test("Gebündelte Dateiänderungen erzeugen genau einen gemeinsamen Folgesnapshot")
@MainActor
func fourDProjectIndexController_debouncesBundledChanges() async throws {
    let root = try makeFourDIndexProject(
        label: "bundle",
        projectMethods: ["Start"],
        componentMethods: ["Component_Start"]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let scanner = CountingFourDScanner()
    let watchers = TestFourDWatcherFactory()
    let controller = FourDProjectIndexController(
        scanProject: { scanner.scan(root: $0) },
        makeWatcher: watchers.make,
        debounceNanoseconds: 20_000_000
    )
    defer { controller.stop() }
    var deliveries: [FourDMethodIndexSnapshot] = []
    controller.start(projectURL: root, projectGeneration: 1) { _, _, snapshot in
        deliveries.append(snapshot)
    }
    #expect(await waitUntil(timeout: 15) { deliveries.count == 1 })

    let projectMethods = root.appendingPathComponent("Project/Sources/Methods")
    let componentMethods = root.appendingPathComponent(
        "Components/Fixture.4dbase/Project/Sources/Methods"
    )
    try Data().write(to: projectMethods.appendingPathComponent("Nachtrag.4dm"))
    try sharedFourDSource.write(
        to: componentMethods.appendingPathComponent("Component_Nachtrag.4dm"),
        atomically: true,
        encoding: .utf8
    )
    let watcher = try #require(watchers.created.first)
    watcher.refresh()
    watcher.refresh()
    watcher.refresh()

    #expect(await waitUntil(timeout: 15) { deliveries.count == 2 })
    try await Task.sleep(nanoseconds: 80_000_000)
    #expect(scanner.count == 2)
    #expect(deliveries.count == 2)
    let snapshot = try #require(deliveries.last)
    #expect(snapshot.projectMethodNames.contains("nachtrag"))
    #expect(snapshot.componentMethods["component_nachtrag"] != nil)
}

@Test("Projektwechsel während eines Scans verwirft das alte Ergebnis")
@MainActor
func fourDProjectIndexController_switchDuringScan() async throws {
    let first = URL(fileURLWithPath: "/tmp/fastra-4d-first-\(UUID().uuidString)")
    let second = URL(fileURLWithPath: "/tmp/fastra-4d-second-\(UUID().uuidString)")
    let scanner = BlockingFourDScanner(blockedRoot: first)
    let watchers = TestFourDWatcherFactory()
    let controller = FourDProjectIndexController(
        scanProject: { scanner.scan(root: $0) },
        makeWatcher: watchers.make
    )
    defer {
        scanner.releaseBlockedScan()
        controller.stop()
    }
    var deliveredRoots: [URL] = []

    controller.start(projectURL: first, projectGeneration: 1) { root, _, _ in
        deliveredRoots.append(root)
    }
    #expect(await waitUntil(timeout: 15) { scanner.blockedScanStarted })
    controller.start(projectURL: second, projectGeneration: 2) { root, _, snapshot in
        #expect(snapshot.projectMethodNames == ["second"])
        deliveredRoots.append(root)
    }
    #expect(await waitUntil(timeout: 15) {
        deliveredRoots == [second.canonicalFileURL]
    })
    scanner.releaseBlockedScan()
    try await Task.sleep(nanoseconds: 60_000_000)
    #expect(deliveredRoots == [second.canonicalFileURL])
    #expect(watchers.created.first?.stopped == true)
}

@Test("Stoppen während Scan oder Debounce verhindert jede späte Lieferung")
@MainActor
func fourDProjectIndexController_stopCancelsScanAndDebounce() async throws {
    let blockedRoot = URL(fileURLWithPath: "/tmp/fastra-4d-stop-\(UUID().uuidString)")
    let blockedScanner = BlockingFourDScanner(blockedRoot: blockedRoot)
    let blockedWatchers = TestFourDWatcherFactory()
    let blockedController = FourDProjectIndexController(
        scanProject: { blockedScanner.scan(root: $0) },
        makeWatcher: blockedWatchers.make
    )
    var blockedDeliveries = 0
    blockedController.start(projectURL: blockedRoot, projectGeneration: 1) { _, _, _ in
        blockedDeliveries += 1
    }
    #expect(await waitUntil(timeout: 15) { blockedScanner.blockedScanStarted })
    blockedController.stop()
    blockedScanner.releaseBlockedScan()
    try await Task.sleep(nanoseconds: 60_000_000)
    #expect(blockedDeliveries == 0)
    #expect(blockedWatchers.created.first?.stopped == true)

    let debounceRoot = URL(fileURLWithPath: "/tmp/fastra-4d-debounce-\(UUID().uuidString)")
    let debounceScanner = CountingFourDScanner()
    let debounceWatchers = TestFourDWatcherFactory()
    let debounceController = FourDProjectIndexController(
        scanProject: { debounceScanner.scan(root: $0) },
        makeWatcher: debounceWatchers.make,
        debounceNanoseconds: 80_000_000
    )
    var debounceDeliveries = 0
    debounceController.start(projectURL: debounceRoot, projectGeneration: 1) { _, _, _ in
        debounceDeliveries += 1
    }
    #expect(await waitUntil(timeout: 15) { debounceDeliveries == 1 })
    let watcher = try #require(debounceWatchers.created.first)
    watcher.refresh()
    debounceController.stop()
    try await Task.sleep(nanoseconds: 120_000_000)
    #expect(debounceScanner.count == 1)
    #expect(debounceDeliveries == 1)
    #expect(watcher.stopped)
}

@Test("Veralteter Watcher-Callback kann das neue Projekt nicht aktualisieren")
@MainActor
func fourDProjectIndexController_rejectsStaleWatcherCallback() async throws {
    let first = URL(fileURLWithPath: "/tmp/fastra-4d-stale-first-\(UUID().uuidString)")
    let second = URL(fileURLWithPath: "/tmp/fastra-4d-stale-second-\(UUID().uuidString)")
    let scanner = CountingFourDScanner()
    let watchers = TestFourDWatcherFactory()
    let controller = FourDProjectIndexController(
        scanProject: { scanner.scan(root: $0) },
        makeWatcher: watchers.make,
        debounceNanoseconds: 20_000_000
    )
    defer { controller.stop() }
    var deliveredRoots: [URL] = []
    controller.start(projectURL: first, projectGeneration: 1) { root, _, _ in
        deliveredRoots.append(root)
    }
    #expect(await waitUntil(timeout: 15) { deliveredRoots.count == 1 })
    let staleCallback = try #require(watchers.created.first?.onRefresh)
    controller.start(projectURL: second, projectGeneration: 2) { root, _, _ in
        deliveredRoots.append(root)
    }
    #expect(await waitUntil(timeout: 15) { deliveredRoots.count == 2 })

    staleCallback()
    try await Task.sleep(nanoseconds: 70_000_000)
    #expect(scanner.count == 2)
    #expect(deliveredRoots == [first.canonicalFileURL, second.canonicalFileURL])

    let currentWatcher = try #require(watchers.created.last)
    currentWatcher.refresh()
    #expect(await waitUntil(timeout: 15) { deliveredRoots.count == 3 })
    #expect(deliveredRoots.last == second.canonicalFileURL)
}

@Test("Workspace hält den 4D-Methodenwatcher über Wechsel und Schließen hinweg korrekt")
@MainActor
func fourDMethodIndex_workspaceWatcherRefreshesAndStops() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fastra-4d-watch-\(UUID().uuidString)")
    let nextRoot = fm.temporaryDirectory.appendingPathComponent("fastra-4d-watch-next-\(UUID().uuidString)")
    let methods = root.appendingPathComponent("Project/Sources/Methods")
    let nextMethods = nextRoot.appendingPathComponent("Project/Sources/Methods")
    let suiteName = "fastra-4d-watch-defaults-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer {
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: nextRoot)
        defaults.removePersistentDomain(forName: suiteName)
    }
    try fm.createDirectory(at: methods, withIntermediateDirectories: true)
    try fm.createDirectory(at: nextMethods, withIntermediateDirectories: true)
    try Data().write(to: methods.appendingPathComponent("Start.4dm"))
    try Data().write(to: nextMethods.appendingPathComponent("Neu.4dm"))

    let workspace = Workspace(defaults: defaults)
    let deliveryRecorder = MainThreadDeliveryRecorder()
    let deliveryObservation = workspace.$fourDMethodIndexSnapshot
        .dropFirst()
        .sink { _ in deliveryRecorder.recordCurrentThread() }
    defer { withExtendedLifetime(deliveryObservation) {} }

    workspace.openProject(at: root)
    try await waitForFourDMethod("start", in: workspace)

    // Die Änderung passiert wie durch einen anderen Editor. Keine Sidebar
    // wird erzeugt; nur der dem Workspace gehörende Watcher darf den Index
    // deshalb nachziehen.
    try Data().write(to: methods.appendingPathComponent("Nachtrag.4dm"))
    try await waitForFourDMethod("nachtrag", in: workspace)

    workspace.openProject(at: nextRoot)
    try await waitForFourDMethod("neu", in: workspace)
    #expect(!workspace.fourDProjectMethodNames.contains("nachtrag"))

    workspace.closeProject()
    #expect(workspace.projectURL == nil)
    #expect(workspace.fourDProjectMethodNames.isEmpty)
    // Ein späteres Ereignis des gerade geschlossenen Projekts darf den
    // geleerten Zustand nicht wieder befüllen.
    try Data().write(to: nextMethods.appendingPathComponent("ZuSpaet.4dm"))
    try await Task.sleep(for: .milliseconds(450))
    #expect(workspace.fourDProjectMethodNames.isEmpty)
    #expect(deliveryRecorder.onlyObservedMainThread)
}

@Test("Zwei Workspaces halten vollständig unabhängige 4D-Projektindizes")
@MainActor
func fourDMethodIndex_twoWorkspacesStayIndependent() async throws {
    let firstRoot = try makeFourDIndexProject(
        label: "window-first", projectMethods: ["Nur_Eins"], componentMethods: []
    )
    let secondRoot = try makeFourDIndexProject(
        label: "window-second", projectMethods: ["Nur_Zwei"], componentMethods: []
    )
    let suite = "fastra-4d-windows-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer {
        try? FileManager.default.removeItem(at: firstRoot)
        try? FileManager.default.removeItem(at: secondRoot)
        defaults.removePersistentDomain(forName: suite)
    }
    let first = Workspace(defaults: defaults)
    let second = Workspace(defaults: defaults)
    defer {
        first.closeProject()
        second.closeProject()
    }

    first.openProject(at: firstRoot)
    second.openProject(at: secondRoot)
    #expect(await waitUntil(timeout: 15) {
        first.fourDProjectMethodNames.contains("nur_eins")
            && second.fourDProjectMethodNames.contains("nur_zwei")
    })
    #expect(!first.fourDProjectMethodNames.contains("nur_zwei"))
    #expect(!second.fourDProjectMethodNames.contains("nur_eins"))
}

@MainActor
private func waitForFourDMethod(_ name: String, in workspace: Workspace) async throws {
    for _ in 0..<60 {
        if workspace.fourDProjectMethodNames.contains(name) { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw FourDMethodIndexWaitError.methodMissing(name)
}

private enum FourDMethodIndexWaitError: Error {
    case methodMissing(String)
}

private let sharedFourDSource = "//%attributes = {\"shared\":true}\n"

private func makeFourDIndexProject(label: String,
                                   projectMethods: [String],
                                   componentMethods: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-4d-\(label)-\(UUID().uuidString)")
    let methods = root.appendingPathComponent("Project/Sources/Methods")
    let components = root.appendingPathComponent(
        "Components/Fixture.4dbase/Project/Sources/Methods"
    )
    try FileManager.default.createDirectory(at: methods, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: components, withIntermediateDirectories: true)
    for name in projectMethods {
        try Data().write(to: methods.appendingPathComponent("\(name).4dm"))
    }
    for name in componentMethods {
        try sharedFourDSource.write(
            to: components.appendingPathComponent("\(name).4dm"),
            atomically: true,
            encoding: .utf8
        )
    }
    return root
}

private final class TestFourDProjectWatcher: FourDProjectWatching {
    var onRefresh: (() -> Void)?
    private(set) var stopped = false

    func refresh() {
        onRefresh?()
    }

    func stop() {
        stopped = true
    }
}

private final class TestFourDWatcherFactory {
    private(set) var created: [TestFourDProjectWatcher] = []

    func make(rootURL: URL) -> any FourDProjectWatching {
        let watcher = TestFourDProjectWatcher()
        created.append(watcher)
        return watcher
    }
}

private final class CountingFourDScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var scanCount = 0

    var count: Int { lock.withLock { scanCount } }

    func scan(root: URL) -> FourDMethodIndexSnapshot {
        lock.withLock { scanCount += 1 }
        return FourDMethodIndexSnapshot.scan(projectURL: root)
    }
}

private final class BlockingFourDScanner: @unchecked Sendable {
    private let blockedPath: String
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    private var didRelease = false

    init(blockedRoot: URL) {
        blockedPath = blockedRoot.canonicalFileURL.path
    }

    var blockedScanStarted: Bool { lock.withLock { started } }

    func scan(root: URL) -> FourDMethodIndexSnapshot {
        if root.canonicalFileURL.path == blockedPath {
            lock.withLock { started = true }
            release.wait()
            return FourDMethodIndexSnapshot(
                projectMethodDisplayNames: ["first": "first"],
                componentMethods: [:]
            )
        }
        return FourDMethodIndexSnapshot(
            projectMethodDisplayNames: ["second": "second"],
            componentMethods: [:]
        )
    }

    func releaseBlockedScan() {
        let shouldRelease = lock.withLock { () -> Bool in
            guard !didRelease else { return false }
            didRelease = true
            return true
        }
        if shouldRelease { release.signal() }
    }
}

/// Der Recorder ist absichtlich gelockt: Bei einer Regression wird die
/// Combine-Closure gerade auf dem falschen Hintergrundthread aufgerufen.
private final class MainThreadDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observedBackgroundThread = false

    var onlyObservedMainThread: Bool {
        lock.withLock { !observedBackgroundThread }
    }

    func recordCurrentThread() {
        lock.withLock {
            observedBackgroundThread = observedBackgroundThread || !Thread.isMainThread
        }
    }
}
