import AppKit
import Foundation

/// Fastras eigene, bewusst schmale Sitzungswiederherstellung.
///
/// Gespeichert werden ausschließlich Pfade bereits gesicherter Dokumente,
/// Projektordner, aktiver Tab und Fensterrahmen. Dokumentinhalt gehört
/// absichtlich NICHT zum Schema: Ein unbenanntes oder ungesichertes Dokument
/// kann dadurch weder versehentlich persistiert noch beim Start vorgetäuscht
/// werden.
enum SessionRestorationPreferences {
    static let enabledKey = "app.restoreLastSession"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

struct RestorableWindowFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: NSRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var rect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }

    /// Hält einen gespeicherten Rahmen auf einem aktuell vorhandenen Monitor.
    /// Fehlt der frühere Monitor, landet das Fenster zentriert auf dem
    /// Hauptbildschirm. Größe und Position werden sonst nur soweit begrenzt,
    /// wie es für eine vollständig erreichbare Titelleiste nötig ist.
    func visibleRect(in screenFrames: [NSRect]) -> NSRect {
        guard let firstScreen = screenFrames.first else {
            return rect
        }
        let intersections = screenFrames.map { ($0, $0.intersection(rect).area) }
        let bestIntersection = intersections.max { $0.1 < $1.1 }
        let intersectsAnyScreen = (bestIntersection?.1 ?? 0) > 0
        let target = intersectsAnyScreen
            ? (bestIntersection?.0 ?? firstScreen)
            : firstScreen
        let clampedWidth = min(max(width, MainWindowSizing.minimumWidth),
                               target.width)
        let clampedHeight = min(max(height, MainWindowSizing.minimumHeight),
                                target.height)
        if !intersectsAnyScreen {
            return NSRect(
                x: target.midX - clampedWidth / 2,
                y: target.midY - clampedHeight / 2,
                width: clampedWidth,
                height: clampedHeight
            )
        }

        return NSRect(
            x: min(max(x, target.minX), target.maxX - clampedWidth),
            y: min(max(y, target.minY), target.maxY - clampedHeight),
            width: clampedWidth,
            height: clampedHeight
        )
    }
}

private extension NSRect {
    var area: CGFloat {
        isNull ? 0 : max(0, width) * max(0, height)
    }
}

struct RestorableWindowState: Codable, Equatable {
    let projectPath: String?
    let documentPaths: [String]
    let activeDocumentPath: String?
    let frame: RestorableWindowFrame?

    /// Ein Fenster ist nur wiederherstellenswert, wenn es mindestens eine
    /// gespeicherte Datei zeigt. Ein reines Projekt-/Repo-Fenster OHNE offene
    /// Dateien wird bewusst NICHT gespeichert (Daniel-Befund 2026-07-20): Sonst
    /// käme beim nächsten Start statt des Willkommensbildschirms der zuletzt
    /// geöffnete Ordner mit einem leeren „Ohne Titel"-Tab zurück — und der
    /// Willkommensbildschirm wäre, einmal einen Ordner geöffnet, nie wieder
    /// erreichbar.
    var hasRestorableContent: Bool {
        !documentPaths.isEmpty
    }

    /// Entfernt beim Start inzwischen gelöschte oder zu Ordnern gewordene
    /// Ziele. So erzeugt ein veralteter Snapshot kein zusätzliches leeres
    /// Fenster. Der Store selbst bleibt unverändert und damit rein Codable.
    func availableState(fileManager: FileManager = .default)
        -> RestorableWindowState? {
        let availableProject: String? = projectPath.flatMap { path in
            let url = URL(fileURLWithPath: path).canonicalFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path,
                                         isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return url.path
        }
        var seenPaths = Set<String>()
        let availableDocuments = documentPaths.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path).canonicalFileURL
            var isDirectory: ObjCBool = false
            guard seenPaths.insert(url.path).inserted,
                  fileManager.fileExists(atPath: url.path,
                                         isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
            return url.path
        }
        let activePath = activeDocumentPath.map {
            URL(fileURLWithPath: $0).canonicalFileURL.path
        }
        let available = RestorableWindowState(
            projectPath: availableProject,
            documentPaths: availableDocuments,
            activeDocumentPath:
                availableDocuments.contains(activePath ?? "") ? activePath : nil,
            frame: frame
        )
        return available.hasRestorableContent ? available : nil
    }
}

struct RestorableSessionState: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let windows: [RestorableWindowState]

    init(windows: [RestorableWindowState]) {
        version = Self.currentVersion
        self.windows = windows.filter(\.hasRestorableContent)
    }
}

enum SessionStateStore {
    static let stateKey = "app.restorableSession.v1"

    static func load(from defaults: UserDefaults = .standard) -> RestorableSessionState? {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(RestorableSessionState.self,
                                                    from: data),
              state.version == RestorableSessionState.currentVersion else {
            return nil
        }
        return state
    }

    static func save(_ state: RestorableSessionState,
                     to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: stateKey)
    }
}

extension Workspace {
    /// Erzeugt den sicheren Persistenz-Snapshot dieses Fensters. Tabs ohne
    /// Datei-URL sowie generierte Git-/Vergleichsansichten werden ausgelassen.
    /// Auch bei einem dirty Datei-Tab wird nur dessen Pfad gespeichert, nie der
    /// ungesicherte Editorinhalt.
    func restorableWindowState(frame: NSRect?) -> RestorableWindowState? {
        var seenPaths = Set<String>()
        let paths = tabs.compactMap { tab -> String? in
            guard tab.gitKind == nil, tab.fileDiffRequest == nil,
                  let url = tab.url, url.isFileURL else {
                return nil
            }
            let path = url.canonicalFileURL.path
            return seenPaths.insert(path).inserted ? path : nil
        }
        let activePath = activeTab?.url?.canonicalFileURL.path
        let state = RestorableWindowState(
            projectPath: projectURL?.canonicalFileURL.path,
            documentPaths: paths,
            activeDocumentPath: paths.contains(activePath ?? "") ? activePath : nil,
            frame: frame.map(RestorableWindowFrame.init)
        )
        return state.hasRestorableContent ? state : nil
    }

    /// Stellt Projekt und gespeicherte Datei-Tabs wieder her. Fehlende Dateien
    /// werden vom vorhandenen asynchronen Ladepfad verworfen; ein unbenannter
    /// Dokumentinhalt wird weder angenommen noch erzeugt.
    func restore(_ state: RestorableWindowState,
                 completion: (() -> Void)? = nil) {
        var seenPaths = Set<String>()
        let documentURLs = state.documentPaths.compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path).canonicalFileURL
            guard seenPaths.insert(url.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path,
                                                 isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
            return url
        }
        guard !documentURLs.isEmpty else {
            // Die Dateien konnten zwischen Store-Vorprüfung und echtem Restore
            // verschwinden. Inzwischen im Startfenster erzeugte Inhalte oder
            // ein bewusst geöffnetes Projekt haben Vorrang und dürfen niemals
            // vom verspäteten Restore gelöscht werden. Nur der unberührte
            // Startzustand (ausschließlich frische leere Tabs) fällt auf
            // einen sauberen Start-Tab zurück.
            if projectURL == nil, tabs.allSatisfy({ $0.isPristineScratch }) {
                enterWelcomeState()
            }
            completion?()
            return
        }

        // Jeder neue Restore ersetzt einen älteren. Der Wert wird erst nach
        // dem Dateivorcheck gebunden, damit ein sofort leer verworfener Stand
        // keinen langlebigen asynchronen Zustand eröffnet.
        sessionRestoreGeneration &+= 1
        let restoreGeneration = sessionRestoreGeneration

        if let projectPath = state.projectPath {
            let projectURL = URL(fileURLWithPath: projectPath).canonicalFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: projectURL.path,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                openProject(at: projectURL,
                            invalidatingSessionRestore: false)
            }
        }

        var remaining = documentURLs.count
        for url in documentURLs {
            loadFile(at: url) { [weak self] _ in
                remaining -= 1
                guard remaining == 0 else { return }
                // Die Abschlussmeldung hängt NICHT an der Workspace-Lebenszeit:
                // Schließt jemand das Fenster, während die Loads laufen, muss
                // der wartende Aufrufer trotzdem sein Signal bekommen — sonst
                // bliebe z. B. die Restore-Kette der übrigen Fenster stehen
                // (Review 2026-08-02).
                defer { completion?() }
                guard let self else { return }
                // Während der Loads kann der Nutzer längst ein anderes
                // Projekt geöffnet haben. Dann gehört nur noch das Completion-
                // Signal zu diesem Restore, keine seiner Abschlussmutationen.
                guard self.sessionRestoreGeneration == restoreGeneration else {
                    return
                }
                var finalActiveTabID = self.activeTabID
                if let activePath = state.activeDocumentPath {
                    let canonicalActive = URL(fileURLWithPath: activePath)
                        .canonicalFileURL
                    if let tab = self.tabs.first(where: {
                        $0.url?.canonicalFileURL == canonicalActive
                    }) {
                        finalActiveTabID = tab.id
                    }
                }
                // Ein einzelner Load-Fehler setzt activeTabID auf seinen
                // früheren Platzhalter zurück. Erzeugt der sichere Lade-
                // Fallback dabei nur einen neuen, unberührten Scratch-Tab,
                // gilt der Restore trotzdem vollständig als gescheitert:
                // Projektkontext und Beobachter müssen dann ebenfalls weg.
                // Ein inzwischen vom Nutzer beschriebener Entwurf verhindert
                // den Welcome-Fallback weiterhin zuverlässig.
                if self.tabs.allSatisfy({ $0.isPristineScratch }) {
                    self.enterWelcomeState()
                } else {
                    if !self.tabs.contains(where: { $0.id == finalActiveTabID }) {
                        finalActiveTabID = self.tabs.first?.id
                    }
                    // Der endgültige Restore-Wechsel ist genauso stabil wie
                    // ein Nutzer-Klick. Dadurch folgt auch der Projekt- und
                    // Git-Kontext dem gespeicherten aktiven Tab, statt beim
                    // zuletzt fertig geladenen anderen Repository zu bleiben.
                    if let finalActiveTabID {
                        self.selectTab(id: finalActiveTabID)
                    }
                }
            }
        }

        // Die Lade-Platzhalter der Dateien stehen jetzt (synchron angehängt).
        // Den unberührten Start-Tab des Fensters deshalb SOFORT entfernen,
        // noch in diesem Runloop-Tick. Sonst blitzt er auf, bis der erste
        // asynchrone Ladevorgang ihn wegräumt (Daniel-Befund 2026-07-20).
        // Die Platzhalter (isLoading = true, mit URL) sind kein unberührter
        // leerer Tab und bleiben erhalten.
        if let active = activeTabID {
            tabs = Workspace.tabsRemovingEmptyScratch(tabs, keeping: active)
        }
    }
}

/// Einmaliges Gate zwischen SwiftUIs Workspace und dem dazugehörigen echten
/// Dokumentfenster. Identität statt Gleichheit verhindert, dass ein anderes
/// Fenster den noch ausstehenden Kaltstart-Restore übernimmt.
@MainActor
final class PrimaryWindowRestoreGate {
    private let expectedWorkspace: Workspace
    private var action: ((NSWindow) -> Void)?

    init(expectedWorkspace: Workspace,
         action: @escaping (NSWindow) -> Void) {
        self.expectedWorkspace = expectedWorkspace
        self.action = action
    }

    private func takeAction(for workspace: Workspace) -> ((NSWindow) -> Void)? {
        guard workspace === expectedWorkspace, let action else { return nil }
        // Vor dem Einplanen löschen: Auch ein reentrant neu aufgebauter
        // SwiftUI-Bridge-Knoten kann den Restore dann nicht doppelt starten.
        self.action = nil
        return action
    }

    /// Konsumiert den Restore genau einmal, führt ihn aber erst nach dem
    /// laufenden SwiftUI-/AppKit-View-Aufbau aus. `updateNSView` darf nicht
    /// synchron wieder ObservableObject-Zustand und neue Fenster erzeugen.
    func scheduleAction(for workspace: Workspace, window: NSWindow) -> Bool {
        guard let action = takeAction(for: workspace) else { return false }
        DispatchQueue.main.async {
            action(window)
        }
        return true
    }
}

/// Zählt die asynchronen Fenster-Restores herunter und meldet den Start erst
/// dann als abgeschlossen. Zusätzliche oder reentrante Completions bleiben
/// wirkungslos; der AppDelegate leert seinen Finder-Puffer genau einmal.
@MainActor
final class RestoreCompletionLatch {
    private var remaining: Int
    private var completion: (() -> Void)?

    init(count: Int, completion: @escaping () -> Void) {
        precondition(count > 0)
        remaining = count
        self.completion = completion
    }

    func finishOne() {
        guard remaining > 0 else { return }
        remaining -= 1
        guard remaining == 0, let completion else { return }
        self.completion = nil
        completion()
    }
}

/// Bindet den Codable-Store an den echten AppKit-Fenster-Lifecycle. Der
/// Coordinator ist Main-Actor-isoliert, weil NSWindow und Workspace UI-State
/// nur dort gelesen bzw. aufgebaut werden dürfen.
@MainActor
enum SessionRestorationCoordinator {
    private static var restoreWasScheduled = false
    /// Hält nur den einmaligen ausstehenden Aufruf, keinen globalen Observer.
    /// Ohne Zeitgrenze bleiben auch sehr langsame Kaltstarts vollständig.
    private static var primaryWindowGate: PrimaryWindowRestoreGate?

    static func captureCurrentSession(
        defaults: UserDefaults = .standard,
        windows: [NSWindow]? = nil
    ) {
        guard SessionRestorationPreferences.isEnabled(in: defaults) else {
            SessionStateStore.clear(in: defaults)
            return
        }
        // Beim interaktiven Beenden kann AppKit hintere Fenster bereits
        // unsichtbar schalten. Die Registry unterscheidet diese weiterhin
        // offenen Fenster von wirklich geschlossenen und verhindert so, dass
        // nur das Vorderfenster in der nächsten Sitzung übrig bleibt.
        let restorableWindows = windows
            ?? DocumentWindowController.restorableDocumentWindows()
        let states = restorableWindows.compactMap { window in
            WorkspaceWindowRegistry.workspace(for: window)?
                .restorableWindowState(frame: window.frame)
        }
        SessionStateStore.save(RestorableSessionState(windows: states),
                               to: defaults)
    }

    static func restoreLastSession(
        into primaryWorkspace: Workspace,
        defaults: UserDefaults = .standard,
        completion: @escaping () -> Void = {}
    ) {
        guard !restoreWasScheduled else {
            completion()
            return
        }
        restoreWasScheduled = true
        guard SessionRestorationPreferences.isEnabled(in: defaults),
              let session = SessionStateStore.load(from: defaults),
              !session.windows.isEmpty else {
            completion()
            return
        }
        let availableSession = RestorableSessionState(
            windows: session.windows.compactMap { $0.availableState() }
        )
        guard !availableSession.windows.isEmpty else {
            completion()
            return
        }
        let gate = PrimaryWindowRestoreGate(
            expectedWorkspace: primaryWorkspace
        ) { primaryWindow in
            restore(
                availableSession,
                into: primaryWorkspace,
                primaryWindow: primaryWindow,
                defaults: defaults,
                completion: completion
            )
        }
        primaryWindowGate = gate

        // Die Bridge kann schon vor applicationDidFinishLaunching registriert
        // worden sein. CommandTargeting filtert Such- und Hilfefenster aus.
        if let primaryWindow = CommandTargeting.registeredWindow(
            for: primaryWorkspace
        ) {
            documentWindowDidRegister(primaryWorkspace, window: primaryWindow)
        }
    }

    /// Ereigniseingang ausschließlich aus der Metadaten-Brücke eines echten
    /// Dokumentfensters. Suchfenster registrieren sich zwar ebenfalls in der
    /// Workspace-Registry, rufen diesen Pfad aber absichtlich nicht auf.
    static func documentWindowDidRegister(_ workspace: Workspace,
                                          window: NSWindow) {
        guard primaryWindowGate?.scheduleAction(
            for: workspace, window: window
        ) == true else {
            return
        }
        primaryWindowGate = nil
    }

    private static func restore(
        _ session: RestorableSessionState,
        into primaryWorkspace: Workspace,
        primaryWindow: NSWindow,
        defaults: UserDefaults,
        completion: @escaping () -> Void
    ) {
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        let primaryState = session.windows[0]
        if let frame = primaryState.frame?.visibleRect(in: screenFrames) {
            primaryWindow.setFrame(frame, display: true)
            DispatchQueue.main.async {
                primaryWindow.setFrame(frame, display: true)
            }
        }
        let latch = RestoreCompletionLatch(
            count: session.windows.count,
            completion: completion
        )
        primaryWorkspace.restore(primaryState, completion: latch.finishOne)

        // Von hinten nach vorn aufbauen. Danach kommt das ursprünglich
        // vorderste Hauptfenster wieder ganz nach vorn.
        for state in session.windows.dropFirst().reversed() {
            DocumentWindowController.openRestoredDocument(
                state, defaults: defaults, screenFrames: screenFrames,
                completion: latch.finishOne
            )
        }
        primaryWindow.makeKeyAndOrderFront(nil)
        Workspace.shared = primaryWorkspace
    }

}
