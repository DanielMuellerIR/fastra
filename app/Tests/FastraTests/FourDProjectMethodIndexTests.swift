// FourDProjectMethodIndexTests.swift
//
// Der Dateisystemteil des 4D-Highlightings bleibt bewusst klein und ohne
// SwiftUI testbar. Die Fixtures bilden nur den exportierten Methodenordner
// nach, niemals ein echtes Nutzerprojekt.

import Combine
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

@Test("Index-Ergebnis eines alten Projekts darf nicht übernommen werden")
func fourDMethodIndex_rejectsStaleProjectResult() {
    let first = URL(fileURLWithPath: "/tmp/fastra-4d-first")
    let second = URL(fileURLWithPath: "/tmp/fastra-4d-second")
    #expect(!FourDProjectMethodIndex.shouldApply(
        resultFor: first, generation: 4, currentRoot: second, currentGeneration: 4
    ))
    #expect(!FourDProjectMethodIndex.shouldApply(
        resultFor: first, generation: 4, currentRoot: first, currentGeneration: 5
    ))
    #expect(FourDProjectMethodIndex.shouldApply(
        resultFor: first, generation: 4, currentRoot: first, currentGeneration: 4
    ))
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
    let defaults = try #require(UserDefaults(suiteName: suiteName))
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
    let deliveryObservation = workspace.$fourDProjectMethodNames
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
