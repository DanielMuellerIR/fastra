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
        if let projectPath = state.projectPath {
            let projectURL = URL(fileURLWithPath: projectPath).canonicalFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: projectURL.path,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                openProject(at: projectURL)
            }
        }

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
            completion?()
            return
        }

        var remaining = documentURLs.count
        for url in documentURLs {
            loadFile(at: url) { [weak self] _ in
                remaining -= 1
                guard remaining == 0, let self else { return }
                if let activePath = state.activeDocumentPath {
                    let canonicalActive = URL(fileURLWithPath: activePath)
                        .canonicalFileURL
                    if let tab = self.tabs.first(where: {
                        $0.url?.canonicalFileURL == canonicalActive
                    }) {
                        self.activeTabID = tab.id
                    }
                }
                completion?()
            }
        }

        // Die Lade-Platzhalter der Dateien stehen jetzt (synchron angehängt).
        // Den beim Projekt-Öffnen entstandenen leeren „Ohne Titel"-Tab bzw.
        // den Willkommen-Tab deshalb SOFORT entfernen, noch in diesem Runloop-
        // Tick. Sonst blitzt er auf, bis der erste asynchrone Ladevorgang ihn
        // wegräumt (Daniel-Befund 2026-07-20). Die Platzhalter (isLoading =
        // true, mit URL) sind kein leerer Scratch und bleiben erhalten.
        if let active = activeTabID {
            tabs = Workspace.tabsRemovingEmptyScratch(tabs, keeping: active)
        }
    }
}

/// Bindet den Codable-Store an den echten AppKit-Fenster-Lifecycle. Der
/// Coordinator ist Main-Actor-isoliert, weil NSWindow und Workspace UI-State
/// nur dort gelesen bzw. aufgebaut werden dürfen.
@MainActor
enum SessionRestorationCoordinator {
    private static var restoreWasScheduled = false

    static func captureCurrentSession(
        defaults: UserDefaults = .standard
    ) {
        guard SessionRestorationPreferences.isEnabled(in: defaults) else {
            SessionStateStore.clear(in: defaults)
            return
        }
        // Beim interaktiven Beenden kann AppKit hintere Fenster bereits
        // unsichtbar schalten. Die Registry unterscheidet diese weiterhin
        // offenen Fenster von wirklich geschlossenen und verhindert so, dass
        // nur das Vorderfenster in der nächsten Sitzung übrig bleibt.
        let windows = DocumentWindowController.restorableDocumentWindows()
        let states = windows.compactMap { window in
            WorkspaceWindowRegistry.workspace(for: window)?
                .restorableWindowState(frame: window.frame)
        }
        SessionStateStore.save(RestorableSessionState(windows: states),
                               to: defaults)
    }

    static func restoreLastSession(
        into primaryWorkspace: Workspace,
        defaults: UserDefaults = .standard
    ) {
        guard !restoreWasScheduled else { return }
        restoreWasScheduled = true
        guard SessionRestorationPreferences.isEnabled(in: defaults),
              let session = SessionStateStore.load(from: defaults),
              !session.windows.isEmpty else {
            return
        }
        let availableSession = RestorableSessionState(
            windows: session.windows.compactMap { $0.availableState() }
        )
        guard !availableSession.windows.isEmpty else { return }
        waitForPrimaryWindow(primaryWorkspace, session: availableSession,
                             defaults: defaults, remainingAttempts: 40)
    }

    private static func waitForPrimaryWindow(
        _ primaryWorkspace: Workspace,
        session: RestorableSessionState,
        defaults: UserDefaults,
        remainingAttempts: Int
    ) {
        guard let primaryWindow = DocumentWindowController
            .visibleDocumentWindows()
            .first(where: {
                WorkspaceWindowRegistry.workspace(for: $0) === primaryWorkspace
            }) else {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForPrimaryWindow(primaryWorkspace, session: session,
                                     defaults: defaults,
                                     remainingAttempts: remainingAttempts - 1)
            }
            return
        }

        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        let primaryState = session.windows[0]
        if let frame = primaryState.frame?.visibleRect(in: screenFrames) {
            primaryWindow.setFrame(frame, display: true)
            DispatchQueue.main.async {
                primaryWindow.setFrame(frame, display: true)
            }
        }
        primaryWorkspace.restore(primaryState)

        // Von hinten nach vorn aufbauen. Danach kommt das ursprünglich
        // vorderste Hauptfenster wieder ganz nach vorn.
        for state in session.windows.dropFirst().reversed() {
            DocumentWindowController.openRestoredDocument(
                state, defaults: defaults, screenFrames: screenFrames
            )
        }
        primaryWindow.makeKeyAndOrderFront(nil)
        Workspace.shared = primaryWorkspace
    }
}
