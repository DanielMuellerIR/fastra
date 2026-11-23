import Foundation

/// Prozessweiter Einstellungsspeicher für alle Fenster und SwiftUI-Wrapper.
/// Die Auswahl erfolgt beim ersten Zugriff atomar; weitere Fenster leeren
/// eine isolierte Suite deshalb nicht erneut.
enum AppDefaults {
    static let launch = AppDefaultsLaunchConfiguration(
        environment: ProcessInfo.processInfo.environment,
        argumentDefaults: .standard
    )
    private static let owner = AppDefaultsStore(selection: launch.selection)

    static var store: UserDefaults {
        do { return try owner.store() }
        catch {
            // Ein fehlgeschlagener Isolationsauftrag darf niemals auf die
            // echten Nutzereinstellungen zurückfallen.
            FileHandle.standardError.write(Data(startupFailureOutput(
                for: error, requestedSelfTest: launch.requestedSelfTest
            ).utf8))
            exit(2)
        }
    }

    /// Auch Fehler vor dem Fensteraufbau gehören zum vorhandenen Ergebnis-
    /// protokoll. Ein nackter Exit 2 wäre für den Runner ein Prozessabbruch.
    static func startupFailureOutput(for error: Error, requestedSelfTest: String?) -> String {
        let message = "Einstellungen konnten nicht sicher isoliert werden: \(error)"
        guard let requestedSelfTest else { return message + "\n" }
        return "SELFTEST-RESULT v=1 test=\(requestedSelfTest) status=ENV\n"
            + "SELFTEST \(requestedSelfTest): Umgebungsproblem — \(message)\n"
    }

    static var isIsolated: Bool { launch.selection.isIsolated }
}

enum AppDefaultsSelection: Equatable {
    case standard
    case isolated(name: String, reset: Bool, cleanupAtExit: Bool, registryPath: String?,
                  requiresRunnerRegistry: Bool = false)

    var isIsolated: Bool {
        if case .isolated = self { return true }
        return false
    }
}

/// Verwendet die vorhandenen Suite-/Registry-Eingänge auch für eine normale
/// GUI-Sitzung. Der Suite-Auftrag allein startet keinen Selbsttestablauf.
struct AppDefaultsLaunchConfiguration {
    let requestedSelfTest: String?
    let selection: AppDefaultsSelection

    var isSelfTestRun: Bool { requestedSelfTest != nil }

    init(environment: [String: String], argumentDefaults: UserDefaults) {
        let name = environment["FASTRA_SELFTEST"].flatMap { $0.isEmpty ? nil : $0 }
            ?? argumentDefaults.string(forKey: "selftest").flatMap { $0.isEmpty ? nil : $0 }
        requestedSelfTest = name
        let explicitSuite = environment["FASTRA_SELFTEST_DEFAULTS_SUITE"]
        guard name != nil || explicitSuite != nil else {
            selection = .standard
            return
        }
        // Normale GUI-Profile gehören über alle App-Neustarts dem äußeren
        // Runner. Selbsttests beginnen dagegen frisch; nur Soak-Folgephasen
        // erhalten ihren Zustand bis zum abschließenden Runner-Cleanup.
        let isSoak = name?.hasPrefix("soak") ?? false
        selection = .isolated(
            name: explicitSuite ?? "Fastra-\(UUID().uuidString)",
            reset: name != nil && argumentDefaults.integer(forKey: "soakPhase") <= 1,
            cleanupAtExit: name != nil && !isSoak,
            registryPath: environment["FASTRA_TEST_DEFAULTS_REGISTRY"],
            requiresRunnerRegistry: name == nil
        )
    }
}

enum AppDefaultsError: Error, Equatable {
    case unsafeSuiteName
    case missingRunnerRegistry
    case suiteUnavailable
    case registrationFailed
}

/// Die Sperre schützt Auswahl, Registrierung und einmaliges Leeren gemeinsam.
/// Danach liefert jeder Thread dieselbe UserDefaults-Instanz; UserDefaults
/// selbst erlaubt gleichzeitige Lese-/Schreibzugriffe.
final class AppDefaultsStore {
    private let selection: AppDefaultsSelection
    private let standard: UserDefaults
    private let register: (String, String?) -> Bool
    private let installCleanup: () -> Void
    private let lock = NSLock()
    private var resolved: Result<UserDefaults, Error>?

    init(selection: AppDefaultsSelection,
         standard: UserDefaults = .standard,
         register: @escaping (String, String?) -> Bool = {
             TestDefaultsPurge.register($0, runnerRegistryPath: $1)
         },
         installCleanup: @escaping () -> Void = { AppDefaultsExitCleanup.install() }) {
        self.selection = selection
        self.standard = standard
        self.register = register
        self.installCleanup = installCleanup
    }

    func store() throws -> UserDefaults {
        try lock.withLock {
            if let resolved { return try resolved.get() }
            let result = Result { try resolve() }
            resolved = result
            return try result.get()
        }
    }

    private func resolve() throws -> UserDefaults {
        guard case let .isolated(name, reset, cleanupAtExit, registryPath, requiresRunnerRegistry) = selection else {
            return standard
        }
        guard TestDefaultsPurge.isTestDomain(name) else { throw AppDefaultsError.unsafeSuiteName }
        if requiresRunnerRegistry && (registryPath?.isEmpty ?? true) {
            throw AppDefaultsError.missingRunnerRegistry
        }
        // Registrierung vor jeder Suite-Erzeugung: Auch ein über mehrere
        // GUI-Starts erhaltenes Profil muss zuerst beim äußeren Runner stehen.
        if cleanupAtExit || requiresRunnerRegistry {
            guard register(name, registryPath) else { throw AppDefaultsError.registrationFailed }
        }
        if cleanupAtExit { installCleanup() }
        guard let defaults = UserDefaults(suiteName: name) else { throw AppDefaultsError.suiteUnavailable }
        if reset { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

private enum AppDefaultsExitCleanup {
    private static let installed: Void = {
        atexit { TestDefaultsPurge.purgeRegistered() }
    }()

    static func install() { _ = installed }
}
