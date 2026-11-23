// SelfTestLaunchCatalog.swift

/// Ausführbare Startbedingungen der Selbsttests, unabhängig von AppKit und
/// dem Ergebnis-/Aufräumvertrag des laufenden Tests.
struct SelfTestLaunchCatalog {
    typealias Action = () -> Void
    typealias MainActorAction = @MainActor () -> Void

    enum Route {
        case mainWindow(Action)
        case mainWindowAndSearch(Action)
        case workspace(Action)
        case mainQueue(Action)
        case background(Action)
        case mainActorTask(MainActorAction)
        case mainAfter(Double, Action)
        case workflowControlled(Action)

        var start: Start {
            switch self {
            case .mainWindow: return .mainWindow
            case .mainWindowAndSearch: return .mainWindowAndSearch
            case .workspace: return .workspace
            case .mainQueue: return .mainQueue
            case .background: return .background
            case .mainActorTask: return .mainActorTask
            case .mainAfter(let delay, _): return .mainAfter(delay)
            case .workflowControlled: return .workflowControlled
            }
        }
    }

    enum Start: Equatable {
        case mainWindow, mainWindowAndSearch, workspace, mainQueue, background
        case mainActorTask, mainAfter(Double), workflowControlled
    }

    struct Entry {
        let name: String
        let route: Route
    }

    struct Descriptor: Equatable {
        let name: String
        let start: Start
    }

    struct Driver {
        var waitForMainWindow: (@escaping Action) -> Void
        var openSearch: (@escaping Action) -> Void
        var waitForWorkspace: (@escaping Action) -> Void
        var mainQueue: (@escaping Action) -> Void
        var background: (@escaping Action) -> Void
        var mainActorTask: (@escaping MainActorAction) -> Void
        var mainAfter: (Double, @escaping Action) -> Void
    }

    enum RegistrationError: Error, Equatable {
        case duplicateName(String)
    }

    private let entries: [Entry]

    init(entries: [Entry]) throws {
        var names = Set<String>()
        for entry in entries {
            guard names.insert(entry.name).inserted else {
                throw RegistrationError.duplicateName(entry.name)
            }
        }
        self.entries = entries
    }

    var descriptors: [Descriptor] {
        entries.map { Descriptor(name: $0.name, start: $0.route.start) }
    }

    var knownNames: [String] { entries.map(\.name) }

    func unknownNameMessage(for name: String) -> String {
        "unbekannter Selbsttest-Name \"\(name)\" (bekannt: \(knownNames.joined(separator: ", ")))"
    }

    @discardableResult
    func start(named name: String, using driver: Driver) -> Bool {
        guard let entry = entries.first(where: { $0.name == name }) else { return false }
        switch entry.route {
        case .mainWindow(let action): driver.waitForMainWindow(action)
        case .mainWindowAndSearch(let action):
            driver.waitForMainWindow { driver.openSearch(action) }
        case .workspace(let action): driver.waitForWorkspace(action)
        case .mainQueue(let action): driver.mainQueue(action)
        case .background(let action): driver.background(action)
        case .mainActorTask(let action): driver.mainActorTask(action)
        case .mainAfter(let delay, let action): driver.mainAfter(delay, action)
        case .workflowControlled(let action): action()
        }
        return true
    }
}
