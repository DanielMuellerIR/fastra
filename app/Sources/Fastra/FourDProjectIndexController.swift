// FourDProjectIndexController.swift
//
// Fensterlokale Koordination des 4D-Projektindex. Der Controller bündelt
// Projekt- und Komponentenmethoden in EINEM unveränderlichen Snapshot und
// besitzt alle kurzlebigen Ressourcen des Indexes: FSEvents-Watcher,
// Hintergrundscan und Debounce.

import Foundation

/// Ein gemeinsam gescannter Stand der Projekt- und Komponentenmethoden.
///
/// Alle Felder sind unveränderlich. Verbraucher können den Snapshot deshalb
/// einmal übernehmen und sehen garantiert keine Mischung aus zwei Scans.
struct FourDMethodIndexSnapshot: Equatable {
    let projectMethodNames: Set<String>
    let projectMethodDisplayNames: [String]
    let componentMethods: [String: FourDComponentMethod]
    let componentMethodDisplayNames: [String]

    static let empty = FourDMethodIndexSnapshot(
        projectMethodDisplayNames: [:], componentMethods: [:]
    )

    /// Baut die vier Verbrauchersichten aus den beiden gemeinsam gelesenen
    /// Quellen. Sortierung und Original-Schreibweise entsprechen dem bisher
    /// im Workspace aufgebauten Stand.
    init(projectMethodDisplayNames: [String: String],
         componentMethods: [String: FourDComponentMethod]) {
        projectMethodNames = Set(projectMethodDisplayNames.keys)
        self.projectMethodDisplayNames = projectMethodDisplayNames.values
            .sorted { $0.lowercased() < $1.lowercased() }
        self.componentMethods = componentMethods
        componentMethodDisplayNames = componentMethods.values
            .map(\.displayName)
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Projekt- und Komponentenmethoden werden in demselben Auftrag gelesen.
    /// So kann kein Projektmethodenstand aus Scan A neben Komponenten aus
    /// Scan B veröffentlicht werden.
    static func scan(projectURL: URL) -> FourDMethodIndexSnapshot {
        FourDMethodIndexSnapshot(
            projectMethodDisplayNames: FourDProjectMethodIndex
                .methodDisplayNames(in: projectURL),
            componentMethods: FourDComponentIndex.methods(in: projectURL)
        )
    }
}

/// Schmale Watcher-Oberfläche, damit der Controller ohne echten FSEvents-
/// Stream direkt auf Cancellation und veraltete Callbacks geprüft werden kann.
protocol FourDProjectWatching: AnyObject {
    var onRefresh: (() -> Void)? { get set }
    func stop()
}

/// Koordiniert den 4D-Index genau eines Fensters.
///
/// `Workspace` bleibt Besitzer von Projekt-URL und Projektgeneration. Der
/// Controller merkt sich nur die zu einem gestarteten Auftrag gehörenden
/// Werte und liefert sie mit jedem Snapshot zurück; der Workspace prüft sie
/// vor der Veröffentlichung noch einmal gegen seine Quellen der Wahrheit.
final class FourDProjectIndexController {
    typealias ScanProject = @Sendable (URL) -> FourDMethodIndexSnapshot
    typealias MakeWatcher = (URL) -> any FourDProjectWatching
    typealias SnapshotHandler = (
        _ projectURL: URL,
        _ projectGeneration: UInt64,
        _ snapshot: FourDMethodIndexSnapshot
    ) -> Void

    private let scanProject: ScanProject
    private let makeWatcher: MakeWatcher
    private let debounceNanoseconds: UInt64

    private var watcher: (any FourDProjectWatching)?
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var runningScanSessionID: UUID?
    private var pendingRescan = false
    private var rescanDebounceElapsed = false
    private var activeProjectURL: URL?
    private var activeProjectGeneration: UInt64?
    private var activeSessionID: UUID?
    private var snapshotHandler: SnapshotHandler?

    init(
        // Die explizite Closure ist als `@Sendable` kontextualisiert. Eine
        // nackte Referenz auf die synchrone statische Funktion erzeugt unter
        // Swift 6 dagegen eine Sendable-Warnung, obwohl sie nichts einfängt.
        scanProject: @escaping ScanProject = { projectURL in
            FourDMethodIndexSnapshot.scan(projectURL: projectURL)
        },
        makeWatcher: @escaping MakeWatcher = { ProjectFileWatcher(rootURL: $0) },
        debounceNanoseconds: UInt64 = 180_000_000
    ) {
        self.scanProject = scanProject
        self.makeWatcher = makeWatcher
        self.debounceNanoseconds = debounceNanoseconds
    }

    deinit {
        stop()
    }

    /// Startet Watcher und initialen Scan für genau einen Projektstand.
    /// Der Aufrufer leert seinen veröffentlichten Snapshot vor diesem Aufruf.
    func start(projectURL: URL, projectGeneration: UInt64,
               onSnapshot: @escaping SnapshotHandler) {
        stop()
        let root = projectURL.canonicalFileURL
        let sessionID = UUID()
        activeProjectURL = root
        activeProjectGeneration = projectGeneration
        activeSessionID = sessionID
        snapshotHandler = onSnapshot

        // Den Stream vor dem Scan installieren. Eine Änderung während des
        // initialen Lesens löst dadurch anschließend einen Debounce-Scan aus
        // und kann nicht zwischen Beobachtungsstart und Index fallen.
        let watcher = makeWatcher(root)
        watcher.onRefresh = { [weak self, weak watcher] in
            guard let self, let watcher,
                  self.watcher === watcher else { return }
            self.update(
                projectURL: root,
                projectGeneration: projectGeneration
            )
        }
        self.watcher = watcher
        startScan(projectURL: root, projectGeneration: projectGeneration,
                  sessionID: sessionID)
    }

    /// Beendet Watcher, Scan und Debounce sofort. Bereits auf einer
    /// Hintergrundqueue laufende Dateizugriffe dürfen fertig werden, ihr
    /// Ergebnis besitzt danach aber keine gültige Session mehr.
    func stop() {
        activeSessionID = nil
        activeProjectURL = nil
        activeProjectGeneration = nil
        snapshotHandler = nil
        scanTask?.cancel()
        scanTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        runningScanSessionID = nil
        pendingRescan = false
        rescanDebounceElapsed = false
        watcher?.onRefresh = nil
        watcher?.stop()
        watcher = nil
    }

    /// Meldet eine Änderung für genau den beobachteten Projektstand. Falsche
    /// Root- oder Generationswerte sind wirkungslos; dadurch bleibt auch ein
    /// bereits zugestellter Callback eines alten Watchers sicher.
    func update(projectURL: URL, projectGeneration: UInt64) {
        guard let sessionID = activeSessionID else { return }
        guard matches(root: projectURL, generation: projectGeneration,
                      sessionID: sessionID) else { return }
        // Die laufende synchrone Dateisystemsuche kann Task-Cancellation nicht
        // beobachten. Änderungen werden deshalb sofort als Folgescan gemerkt,
        // während der Debounce nur noch dessen frühesten Start bestimmt.
        pendingRescan = true
        rescanDebounceElapsed = false
        debounceTask?.cancel()
        let delay = debounceNanoseconds
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.matches(root: projectURL, generation: projectGeneration,
                               sessionID: sessionID) else { return }
            self.debounceTask = nil
            self.rescanDebounceElapsed = true
            self.startPendingScan(projectURL: projectURL,
                                  projectGeneration: projectGeneration,
                                  sessionID: sessionID)
        }
    }

    /// Liest beide Indexquellen abseits des Main-Actors und liefert nur den
    /// noch aktuellen, vollständigen Snapshot auf dem Main-Actor zurück.
    private func startScan(projectURL: URL, projectGeneration: UInt64,
                           sessionID: UUID) {
        // Ein synchroner Scan läuft trotz Task-Cancellation bis zum Ende. Pro
        // Projektsitzung darf deshalb nur einer aktiv sein; weitere Änderungen
        // werden von `startPendingScan` zu genau einem Folgelauf gebündelt.
        guard runningScanSessionID != sessionID else {
            pendingRescan = true
            return
        }
        runningScanSessionID = sessionID
        let scanProject = scanProject
        let scan = Task.detached(priority: .utility) {
            scanProject(projectURL)
        }
        scanTask = Task { @MainActor [weak self] in
            let snapshot = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard let self,
                  self.runningScanSessionID == sessionID else { return }
            self.scanTask = nil
            self.runningScanSessionID = nil
            guard !Task.isCancelled,
                  self.matches(root: projectURL, generation: projectGeneration,
                               sessionID: sessionID) else { return }
            // Hat sich während des Scans etwas geändert, ist sein Ergebnis
            // möglicherweise aus mehreren Plattenständen zusammengesetzt. Es
            // bleibt unsichtbar; nach Ablauf des Debounce folgt genau ein Scan.
            if self.pendingRescan {
                self.startPendingScan(projectURL: projectURL,
                                      projectGeneration: projectGeneration,
                                      sessionID: sessionID)
                return
            }
            self.snapshotHandler?(projectURL, projectGeneration, snapshot)
        }
    }

    /// Startet einen gemerkten Folgescan erst, wenn sowohl der vorherige Scan
    /// beendet als auch das Debounce-Fenster abgelaufen ist.
    private func startPendingScan(projectURL: URL, projectGeneration: UInt64,
                                  sessionID: UUID) {
        guard pendingRescan, rescanDebounceElapsed,
              runningScanSessionID == nil,
              matches(root: projectURL, generation: projectGeneration,
                      sessionID: sessionID) else { return }
        pendingRescan = false
        rescanDebounceElapsed = false
        startScan(projectURL: projectURL,
                  projectGeneration: projectGeneration,
                  sessionID: sessionID)
    }

    private func matches(root: URL, generation: UInt64,
                         sessionID: UUID) -> Bool {
        activeSessionID == sessionID
            && activeProjectGeneration == generation
            && activeProjectURL == root.canonicalFileURL
    }
}
