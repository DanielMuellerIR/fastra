import AppKit
import SwiftUI
import FastraDiffProtocol

/// Nur der IPC-Worker greift auf den Eingang zu. Die Annahme und das Öffnen
/// laufen gemeinsam auf Main; ein Retry kann deshalb kein zweites Fenster bauen.
///
/// Endpunktname und Öffnen-Schritt sind injizierbar, damit die Annahmelogik
/// (Feldmenge, Idempotenz, Frist) headless im Unit-Test läuft — ohne Bundle
/// und ohne Fenster.
final class ExternalDiffService {
    static let shared = ExternalDiffService(
        endpoint: Bundle.main.bundleIdentifier.map { DiffProtocol.endpoint(bundleIdentifier: $0) },
        // `handle` ruft den Öffnen-Schritt ausschließlich innerhalb von
        // `DispatchQueue.main.sync` — dort IST Main der aktuelle Actor.
        open: { request in MainActor.assumeIsolated { ExternalDiffWindow.open(request) } })

    private let endpoint: String?
    private let open: (DiffWireRequest) -> Void
    private var server: DiffMessageServer?
    /// Nur vom seriellen IPC-Worker berührt.
    private var accepted: [UUID: DiffWireRequest] = [:]

    init(endpoint: String?, open: @escaping (DiffWireRequest) -> Void) {
        self.endpoint = endpoint
        self.open = open
    }

    /// `true`, solange diese Instanz den benannten Port wirklich hält.
    var isListening: Bool { server?.isListening == true }

    /// Idempotent: Ein zweiter Aufruf ohne Port versucht es erneut. Der Name
    /// kann beim ersten Mal vergeben sein, wenn eine andere Fastra-Instanz mit
    /// derselben Bundle-ID läuft (etwa Build im Repo-Root neben der
    /// installierten App). Ein portloses Server-Objekt wird NICHT behalten —
    /// sonst gäbe es nie einen zweiten Versuch, und nach dem Ende der anderen
    /// Instanz fände `fastra-diff` keinen Endpunkt mehr.
    func start() {
        guard server == nil, let endpoint else { return }
        let candidate = DiffMessageServer(name: endpoint) { [weak self] data in
            guard let self else {
                return (try? JSONEncoder().encode(DiffWireReply(code: DiffFailure.delivery.code))) ?? Data()
            }
            return self.handle(data)
        }
        guard candidate.isListening else {
            NSLog("Fastra: Diff-Endpunkt „%@“ ist bereits vergeben (zweite Instanz?) — erneuter Versuch beim nächsten Aktivieren.", endpoint)
            return
        }
        server = candidate
    }

    /// Verarbeitet eine rohe Anfrage und liefert die Antwort als Wire-Daten.
    /// Läuft auf dem IPC-Worker; nur der Öffnen-Schritt wechselt auf Main.
    func handle(_ data: Data) -> Data {
        let code: Int32
        do {
            // Unbekannte Wire-Felder werden genauso abgewiesen wie CLI-Optionen.
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == DiffWireRequest.wireKeys else { throw DiffFailure.unsupported }
            let request = try JSONDecoder().decode(DiffWireRequest.self, from: data)
            let now = Date().timeIntervalSince1970
            accepted = accepted.filter { $0.value.deadline + 60 > now }
            if let previous = accepted[request.id] {
                guard previous == request else { throw DiffFailure.delivery }
                code = 0
            } else {
                try request.validate()
                let opened = DispatchQueue.main.sync {
                    // Auch nach einer belegten Main-Queue darf kein verspätetes
                    // Fenster mehr entstehen, nachdem der Helfer aufgegeben hat.
                    guard request.deadline > Date().timeIntervalSince1970 else { return false }
                    open(request)
                    return true
                }
                guard opened else { throw DiffFailure.delivery }
                accepted[request.id] = request
                code = 0
            }
        } catch {
            code = (error as? DiffFailure)?.code ?? 6
        }
        return (try? JSONEncoder().encode(DiffWireReply(code: code))) ?? Data()
    }
}

@MainActor
final class ExternalDiffModel: ObservableObject {
    let request: FileDiffRequest
    @Published var document: FileDiffDocument?
    /// Die laufende Berechnung; das Fenster bricht sie beim Schließen ab.
    private var computation: Task<Void, Never>?

    /// `compute` ist nur für den deterministischen Abbruchtest injizierbar.
    init(_ request: DiffWireRequest,
         compute: @escaping (FileDiffRequest) throws -> FileDiffDocument = {
             try Workspace.computeFileDiffDocument(
                 request: $0, isCancelled: { Task.isCancelled })
         }) {
        self.request = FileDiffRequest(
            left: FileDiffSide(name: request.leftLabel, path: request.leftPath,
                               url: URL(fileURLWithPath: request.leftPath), text: nil),
            right: FileDiffSide(name: request.rightLabel, path: request.rightPath,
                                url: URL(fileURLWithPath: request.rightPath), text: nil),
            options: FileDiffOptions())
        let diffRequest = self.request
        computation = Task.detached(priority: .userInitiated) { [weak self] in
            // Abbruch kommt als `CancellationError` — kein Dokument, das noch
            // in ein geschlossenes Fenster fallen könnte. Jeder andere Fehler
            // wird angezeigt statt verschluckt (sonst bliebe der Spinner stehen).
            let document: FileDiffDocument
            do {
                document = try compute(diffRequest)
            } catch is CancellationError {
                return
            } catch {
                document = .failure(.failed(message: error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.document = document }
        }
    }

    /// Beendet die Berechnung; ein geschlossenes Fenster zeigt nichts mehr.
    func cancel() {
        computation?.cancel()
        computation = nil
    }

    deinit { computation?.cancel() }
}

/// Das externe Fenster enthält denselben FileDiffView wie ein interner Tab.
/// Es besitzt absichtlich keinen Workspace und keinen editierbaren Dateitab:
/// globale Dokumentbefehle finden hier kein Schreibziel, auch nicht dahinter.
@MainActor
final class ExternalDiffWindow: NSObject, NSWindowDelegate {
    private static var controllers: [UUID: ExternalDiffWindow] = [:]
    let model: ExternalDiffModel
    let window: NSWindow
    let requestID: UUID

    private init(_ request: DiffWireRequest) {
        requestID = request.id
        model = ExternalDiffModel(request)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.identifier = NSUserInterfaceItemIdentifier("Fastra.ExternalDiff.\(request.id)")
        window.title = L10n.format("Diff: %@ ↔ %@", request.leftLabel, request.rightLabel)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 940, height: 420)
        let hosting = NSHostingController(rootView:
            ExternalDiffView(model: model, focusDiff: request.focusDiff).fastraScalingRoot())
        // Wie bei Dokumentfenstern darf SwiftUIs fitting size die gewählte
        // Startgröße nicht nachträglich auf die Untergrenze verkleinern.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.center()
    }

    static func open(_ request: DiffWireRequest) {
        guard controllers[request.id] == nil else { return }
        let controller = ExternalDiffWindow(request)
        controllers[request.id] = controller
        if request.focusDiff {
            controller.window.makeKeyAndOrderFront(nil)
            controller.window.makeFirstResponder(controller.window.contentView)
        } else {
            controller.window.orderFront(nil)
        }
    }

    static func isExternalDiffWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix("Fastra.ExternalDiff.") == true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ActiveDocumentContext.shared.activate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        Self.controllers.removeValue(forKey: requestID)
    }

    // Zugriff auf die tatsächlich erzeugten Fenster für Integrationstests.
    static var openWindows: [ExternalDiffWindow] { Array(controllers.values) }
}

private struct ExternalDiffView: View {
    @ObservedObject var model: ExternalDiffModel
    let focusDiff: Bool
    @FocusState private var comparisonFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Schreibgeschützter Vergleich", systemImage: "lock")
                Spacer()
            }
            .fastraFont(.small)
            .padding(10)
            .background(Theme.surfaceBase)
            FileDiffView(request: model.request, document: model.document)
                .focusable()
                .focused($comparisonFocused)
                .onAppear { comparisonFocused = focusDiff }
        }
        .background(Theme.surfaceRaised)
    }
}
