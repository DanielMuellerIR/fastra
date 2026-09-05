import AppKit
import SwiftUI
import FastraDiffProtocol

/// Nur der IPC-Worker greift auf den Eingang zu. Die Annahme und das Öffnen
/// laufen gemeinsam auf Main; ein Retry kann deshalb kein zweites Fenster bauen.
final class ExternalDiffService {
    static let shared = ExternalDiffService()
    private var server: DiffMessageServer?
    private var accepted: [UUID: DiffWireRequest] = [:]

    func start() {
        guard server == nil, let identifier = Bundle.main.bundleIdentifier else { return }
        server = DiffMessageServer(name: DiffProtocol.endpoint(bundleIdentifier: identifier)) { [weak self] data in
            let code: Int32
            do {
                guard let self else { throw DiffFailure.delivery }
                // Unbekannte Wire-Optionen werden genauso abgewiesen wie CLI-Optionen.
                let keys: Set<String> = ["version", "id", "deadline", "leftPath", "rightPath",
                                         "leftLabel", "rightLabel", "readOnly", "focusDiff"]
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(object.keys) == keys else { throw DiffFailure.unsupported }
                let request = try JSONDecoder().decode(DiffWireRequest.self, from: data)
                let now = Date().timeIntervalSince1970
                self.accepted = self.accepted.filter { $0.value.deadline + 60 > now }
                if let previous = self.accepted[request.id] {
                    guard previous == request else { throw DiffFailure.delivery }
                    code = 0
                } else {
                    try request.validate()
                    let opened = DispatchQueue.main.sync {
                        // Auch nach einer belegten Main-Queue darf kein verspätetes
                        // Fenster mehr entstehen, nachdem der Helfer aufgegeben hat.
                        guard request.deadline > Date().timeIntervalSince1970 else { return false }
                        ExternalDiffWindow.open(request)
                        return true
                    }
                    guard opened else { throw DiffFailure.delivery }
                    self.accepted[request.id] = request
                    code = 0
                }
            } catch {
                code = (error as? DiffFailure)?.code ?? 6
            }
            return (try? JSONEncoder().encode(DiffWireReply(code: code))) ?? Data()
        }
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
            // in ein geschlossenes Fenster fallen könnte.
            guard let document = try? compute(diffRequest), !Task.isCancelled else {
                return
            }
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
