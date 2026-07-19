import Foundation
import CoreServices

/// Beobachtet einen Projektordner rekursiv über macOS FSEvents.
///
/// Anders als ein Render-seitiges `contentsOfDirectory` bemerkt FSEvents auch
/// Änderungen, die Terminal, Git oder ein anderes Programm in tiefen
/// Unterordnern vornehmen. Die kleine Latenz bündelt Speichervorgänge, die aus
/// mehreren atomaren Rename-/Write-Schritten bestehen, zu einem UI-Refresh.
final class ProjectFileWatcher: ObservableObject {
    @Published private(set) var generation = 0

    /// Der Dateibaum nutzt die veröffentlichte Generation zum Rendern. Andere
    /// langlebige Dienste, etwa der 4D-Methodenindex im Workspace, können
    /// denselben FSEvents-Strom unabhängig von einer sichtbaren Sidebar
    /// mitbekommen. Die Closure läuft immer auf der Main-Queue.
    var onRefresh: (() -> Void)?

    private let rootURL: URL
    private var stream: FSEventStreamRef?

    init(rootURL: URL) {
        self.rootURL = rootURL
        start()
    }

    deinit {
        stop()
    }

    /// Sofortiger Refresh für Fastra-eigene Dateiaktionen; externe Änderungen
    /// gelangen über den FSEvents-Callback auf denselben Pfad.
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        onRefresh?()
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectFileWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            // Der Stream hängt an der Main-Queue; Published-Änderungen bleiben
            // dadurch garantiert SwiftUI-konform.
            watcher.refresh()
        }
        let paths = [rootURL.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// Beendet den nativen Stream auch dann sofort, wenn der Besitzer vor
    /// dem nächsten ARC-Aufräumen zu einem anderen Projekt wechselt.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
