import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fastra

@MainActor
private final class AppDefaultsMountedObservation {
    var renderedValue: Bool?
    var binding: Binding<Bool>?
}

@MainActor
private struct AppDefaultsMountedView: View {
    @AppStorage private var showMinimap: Bool
    let observation: AppDefaultsMountedObservation

    init(defaults: UserDefaults, observation: AppDefaultsMountedObservation) {
        _showMinimap = AppStorage(wrappedValue: false, "editor.showMinimap", store: defaults)
        self.observation = observation
    }

    var body: some View {
        Text(showMinimap ? "on" : "off")
            .onChange(of: showMinimap, initial: true) { _, value in
                // Nur der montierte SwiftUI-Lebenszyklus meldet Werte und
                // gibt die zu genau diesem Wrapper gehörende Bindung frei.
                observation.renderedValue = value
                observation.binding = $showMinimap
            }
    }
}

@Suite("Prozessweiter Einstellungsspeicher")
struct AppDefaultsTests {
    @Test("Ohne Isolationsauftrag bleibt der Produktstore unverändert")
    func normalLaunchUsesStandardDefaults() throws {
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        let launch = AppDefaultsLaunchConfiguration(environment: [:], argumentDefaults: arguments)
        #expect(launch.requestedSelfTest == nil)
        #expect(!launch.isSelfTestRun)
        #expect(launch.selection == .standard)
        let owner = AppDefaultsStore(selection: launch.selection)
        #expect(try owner.store() === UserDefaults.standard)
    }

    @Test("Explizite Suite isoliert die normale GUI ohne Selbsttestablauf")
    func explicitSuiteDoesNotRequestSelfTest() throws {
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        let suite = "FastraTests.gui.\(UUID().uuidString)"
        let registry = testTemporaryDirectory()
            .appendingPathComponent("fastra-defaults-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: registry) }
        let launch = AppDefaultsLaunchConfiguration(environment: [
            "FASTRA_SELFTEST_DEFAULTS_SUITE": suite,
            "FASTRA_TEST_DEFAULTS_REGISTRY": registry.path
        ], argumentDefaults: arguments)
        #expect(launch.requestedSelfTest == nil)
        #expect(!launch.isSelfTestRun)
        #expect(launch.selection.isIsolated)
        let productDomain = Bundle.main.bundleIdentifier ?? "Fastra"
        let before = UserDefaults.standard.persistentDomain(forName: productDomain) as NSDictionary?
        let owner = AppDefaultsStore(selection: launch.selection)
        let defaults = try owner.store()
        defaults.set("isolated GUI", forKey: "fastra.defaults.fixture")
        #expect(defaults !== UserDefaults.standard)
        #expect(defaults.persistentDomain(forName: suite)?["fastra.defaults.fixture"] as? String == "isolated GUI")
        #expect(UserDefaults.standard.persistentDomain(forName: productDomain) as NSDictionary? == before)
        #expect(try String(contentsOf: registry, encoding: .utf8) == suite + "\n")
        #expect(TestDefaultsPurge.isRegistered(suite))
        #expect(TestDefaultsPurge.purgeRegistered(only: suite).isEmpty)
    }

    @Test("Normale GUI-Neustarts erhalten ihr vom äußeren Runner besessenes Profil")
    func explicitGUIProfileSurvivesNewLaunchOwners() throws {
        let suite = "FastraTests.gui-restart.\(UUID().uuidString)"
        let registry = testTemporaryDirectory()
            .appendingPathComponent("fastra-defaults-restart-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: registry) }
        let environment = ["FASTRA_SELFTEST_DEFAULTS_SUITE": suite,
                           "FASTRA_TEST_DEFAULTS_REGISTRY": registry.path]
        var registrations = 0
        var cleanupInstallations = 0
        for phase in 1...2 {
            let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
            let launch = AppDefaultsLaunchConfiguration(environment: environment, argumentDefaults: arguments)
            #expect(launch.requestedSelfTest == nil)
            let owner = AppDefaultsStore(selection: launch.selection, register: { name, path in
                registrations += 1
                return TestDefaultsPurge.register(name, runnerRegistryPath: path)
            }, installCleanup: { cleanupInstallations += 1 })
            let defaults = try owner.store()
            #expect(registrations == phase)
            #expect(cleanupInstallations == 0)
            #expect(TestDefaultsPurge.isRegistered(suite))
            if phase == 1 {
                defaults.set("preserved across launches", forKey: "fastra.defaults.restart")
                #expect(defaults.synchronize())
            } else {
                #expect(defaults.persistentDomain(forName: suite)?["fastra.defaults.restart"] as? String
                        == "preserved across launches")
            }
            // Wiederholter Zugriff im selben Owner ist ein anderer Vertrag
            // als der oben eigens neu erzeugte Owner des nächsten Starts.
            #expect(try owner.store() === defaults)
            #expect(registrations == phase)
        }
        #expect(cleanupInstallations == 0)
        #expect(try String(contentsOf: registry, encoding: .utf8) == suite + "\n")
        #expect(TestDefaultsPurge.purgeRegistered(only: suite).isEmpty)
        #expect(!TestDefaultsPurge.isRegistered(suite))
        let remainingKeys = CFPreferencesCopyKeyList(
            suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        #expect(remainingKeys.map { CFArrayGetCount($0) == 0 } ?? true)
    }

    @Test("Normales GUI-Profil verlangt Registrierung auch ohne inneren Cleanup")
    func explicitGUIProfileRejectsMissingOrFailedRegistration() throws {
        let suite = "FastraTests.gui-unregistered.\(UUID().uuidString)"
        let seeded = testSuiteDefaults(named: suite)
        seeded.set("preserve existing profile", forKey: "sentinel")
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        let missingRegistry = AppDefaultsLaunchConfiguration(environment: [
            "FASTRA_SELFTEST_DEFAULTS_SUITE": suite
        ], argumentDefaults: arguments)
        #expect(throws: AppDefaultsError.missingRunnerRegistry) {
            try AppDefaultsStore(selection: missingRegistry.selection).store()
        }
        let failedRegistry = AppDefaultsLaunchConfiguration(environment: [
            "FASTRA_SELFTEST_DEFAULTS_SUITE": suite,
            "FASTRA_TEST_DEFAULTS_REGISTRY": "/unused"
        ], argumentDefaults: arguments)
        var registrationAttempts = 0
        var cleanupInstallations = 0
        let rejected = AppDefaultsStore(selection: failedRegistry.selection, register: { _, _ in
            registrationAttempts += 1
            return false
        }, installCleanup: { cleanupInstallations += 1 })
        #expect(throws: AppDefaultsError.registrationFailed) { try rejected.store() }
        #expect(throws: AppDefaultsError.registrationFailed) { try rejected.store() }
        #expect(registrationAttempts == 1)
        #expect(cleanupInstallations == 0)
        #expect(seeded.string(forKey: "sentinel") == "preserve existing profile")
    }

    @Test("Fehlerhafte Isolation fällt niemals auf den Produktstore zurück")
    func invalidIsolationFailsBeforeReset() throws {
        let suite = "FastraTests.failed.\(UUID().uuidString)"
        let seeded = testSuiteDefaults(named: suite)
        seeded.set("keep", forKey: "sentinel")
        let rejected = AppDefaultsStore(selection: .isolated(
            name: suite, reset: true, cleanupAtExit: true, registryPath: nil
        ), register: { _, _ in false })
        #expect(throws: AppDefaultsError.registrationFailed) { try rejected.store() }
        #expect(throws: AppDefaultsError.registrationFailed) { try rejected.store() }
        #expect(seeded.string(forKey: "sentinel") == "keep")
        let unsafe = AppDefaultsStore(selection: .isolated(
            name: "com.example.product", reset: true, cleanupAtExit: true, registryPath: nil
        ))
        #expect(throws: AppDefaultsError.unsafeSuiteName) { try unsafe.store() }
        let untracked = AppDefaultsStore(selection: .isolated(
            name: suite, reset: true, cleanupAtExit: true, registryPath: nil,
            requiresRunnerRegistry: true
        ))
        #expect(throws: AppDefaultsError.missingRunnerRegistry) { try untracked.store() }
        #expect(seeded.string(forKey: "sentinel") == "keep")
    }

    @Test("Leere und unsichere explizite Suiten bleiben ein Isolationsfehler")
    func malformedLaunchDoesNotBecomeNormalLaunch() throws {
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        for suite in ["", "../Fastra-\(UUID().uuidString)", "Fastra"] {
            let launch = AppDefaultsLaunchConfiguration(environment: [
                "FASTRA_SELFTEST_DEFAULTS_SUITE": suite,
                "FASTRA_TEST_DEFAULTS_REGISTRY": "/unused"
            ], argumentDefaults: arguments)
            #expect(launch.selection.isIsolated)
            #expect(throws: AppDefaultsError.unsafeSuiteName) {
                try AppDefaultsStore(selection: launch.selection).store()
            }
        }
    }

    @Test("Parallele erste Leser registrieren und leeren nur einmal")
    func concurrentAccessResolvesOneStore() throws {
        let suite = "FastraTests.concurrent.\(UUID().uuidString)"
        let seeded = testSuiteDefaults(named: suite)
        seeded.set(true, forKey: "old")
        var registrations = 0
        let owner = AppDefaultsStore(selection: .isolated(
            name: suite, reset: true, cleanupAtExit: true, registryPath: nil
        ), register: { _, _ in registrations += 1; return true }, installCleanup: {})
        let resultLock = NSLock()
        var instances: [UserDefaults] = []
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                let defaults = try owner.store()
                defaults.set(index, forKey: "reader-\(index)")
                resultLock.withLock { instances.append(defaults) }
            } catch { resultLock.withLock { failures += 1 } }
        }
        #expect(failures == 0)
        #expect(registrations == 1)
        let defaults = try owner.store()
        #expect(instances.count == 32)
        #expect(instances.allSatisfy { $0 === defaults })
        #expect(defaults.object(forKey: "old") == nil)
        for index in 0..<32 { #expect(defaults.object(forKey: "reader-\(index)") as? Int == index) }
    }

    @MainActor
    @Test("Weitere Fenster und AppStorage teilen den bereits beschriebenen Store")
    func workspaceAndAppStorageKeepSharedValues() async throws {
        let suite = "FastraTests.windows.\(UUID().uuidString)"
        _ = testSuiteDefaults(named: suite)
        let owner = AppDefaultsStore(selection: .isolated(
            name: suite, reset: true, cleanupAtExit: true, registryPath: nil
        ), installCleanup: {})
        func mount(defaults: UserDefaults, observation: AppDefaultsMountedObservation)
            -> (NSWindow, NSHostingView<AppDefaultsMountedView>) {
            let host = NSHostingView(rootView: AppDefaultsMountedView(
                defaults: defaults, observation: observation
            ))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.alphaValue = 0
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            return (window, host)
        }
        let first = Workspace(defaults: try owner.store())
        let firstObservation = AppDefaultsMountedObservation()
        let (firstWindow, firstHost) = mount(defaults: first.preferencesStore, observation: firstObservation)
        defer {
            firstObservation.binding = nil
            firstWindow.contentView = nil
            firstWindow.close()
        }
        try #require(await waitUntil(timeout: 5) {
            firstHost.layoutSubtreeIfNeeded()
            return firstObservation.renderedValue == false && firstObservation.binding != nil
        })
        let firstBinding = try #require(firstObservation.binding)
        firstBinding.wrappedValue = true
        try #require(await waitUntil(timeout: 5) {
            firstHost.layoutSubtreeIfNeeded()
            return firstObservation.renderedValue == true
        })
        #expect(first.preferencesStore.persistentDomain(forName: suite)?["editor.showMinimap"] as? Bool == true)

        // Der zweite Fensteraufbau darf die bereits beschriebene Suite nicht
        // leeren. Beide Hosts bleiben danach für beide Änderungsrichtungen montiert.
        let second = Workspace(defaults: try owner.store())
        let secondObservation = AppDefaultsMountedObservation()
        let (secondWindow, secondHost) = mount(defaults: second.preferencesStore, observation: secondObservation)
        defer {
            secondObservation.binding = nil
            secondWindow.contentView = nil
            secondWindow.close()
        }
        #expect(first.preferencesStore === second.preferencesStore)
        try #require(await waitUntil(timeout: 5) {
            firstHost.layoutSubtreeIfNeeded()
            secondHost.layoutSubtreeIfNeeded()
            return firstObservation.renderedValue == true && secondObservation.renderedValue == true
                && secondObservation.binding != nil
        })
        let secondBinding = try #require(secondObservation.binding)
        secondBinding.wrappedValue = false
        try #require(await waitUntil(timeout: 5) {
            firstHost.layoutSubtreeIfNeeded()
            secondHost.layoutSubtreeIfNeeded()
            return firstObservation.renderedValue == false && secondObservation.renderedValue == false
        })
        #expect(first.preferencesStore.persistentDomain(forName: suite)?["editor.showMinimap"] as? Bool == false)

        firstBinding.wrappedValue = true
        try #require(await waitUntil(timeout: 5) {
            firstHost.layoutSubtreeIfNeeded()
            secondHost.layoutSubtreeIfNeeded()
            return firstObservation.renderedValue == true && secondObservation.renderedValue == true
        })
        #expect(second.preferencesStore.persistentDomain(forName: suite)?["editor.showMinimap"] as? Bool == true)
    }

    @Test("Soak-Folgephasen erhalten Daten bis zum Runner-Janitor")
    func soakRelaunchPreservesState() throws {
        let suite = "FastraTests.soak.\(UUID().uuidString)"
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        _ = testSuiteDefaults(named: suite)
        let environment = ["FASTRA_SELFTEST": "soak", "FASTRA_SELFTEST_DEFAULTS_SUITE": suite]
        arguments.set(1, forKey: "soakPhase")
        let phase1 = AppDefaultsLaunchConfiguration(environment: environment, argumentDefaults: arguments)
        let first = try AppDefaultsStore(selection: phase1.selection,
                                        register: { _, _ in Issue.record("Soak vorzeitig registriert"); return false }).store()
        first.set("session from phase 1", forKey: "session")
        #expect(first.synchronize())
        arguments.set(2, forKey: "soakPhase")
        let phase2 = AppDefaultsLaunchConfiguration(environment: environment, argumentDefaults: arguments)
        let restored = try AppDefaultsStore(selection: phase2.selection,
                                           register: { _, _ in Issue.record("Soak vorzeitig registriert"); return false }).store()
        #expect(restored.string(forKey: "session") == "session from phase 1")
        #expect(TestDefaultsPurge.register(suite))
        #expect(TestDefaultsPurge.purgeRegistered(only: suite).isEmpty)
        #expect(restored.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    @Test("Argument- und Umgebungsaufrufe behalten denselben Selbsttestvertrag")
    func selfTestLaunchSelection() {
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        arguments.set("controlhost", forKey: "selftest")
        let argumentLaunch = AppDefaultsLaunchConfiguration(environment: [:], argumentDefaults: arguments)
        #expect(argumentLaunch.requestedSelfTest == "controlhost")
        #expect(argumentLaunch.isSelfTestRun)
        #expect(argumentLaunch.selection.isIsolated)
        let environmentLaunch = AppDefaultsLaunchConfiguration(
            environment: ["FASTRA_SELFTEST": "settings"], argumentDefaults: arguments)
        #expect(environmentLaunch.requestedSelfTest == "settings")
        #expect(environmentLaunch.isSelfTestRun)
        #expect(environmentLaunch.selection.isIsolated)
    }

    @Test("Leere Selbsttesteingänge bleiben ein normaler Start",
          arguments: [nil, ""] as [String?])
    func emptySelfTestInputsDoNotRequestHarness(_ environmentName: String?) {
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        arguments.set("", forKey: "selftest")
        let environment = environmentName.map { ["FASTRA_SELFTEST": $0] } ?? [:]
        let launch = AppDefaultsLaunchConfiguration(environment: environment, argumentDefaults: arguments)
        #expect(!launch.isSelfTestRun)
        #expect(launch.requestedSelfTest == nil)
        #expect(launch.selection == .standard)
    }

    @Test("Leere Umgebung erhält den Argumentauftrag auch für unbekannte Selbsttestnamen",
          arguments: ["controlhost", "unknown-selftest"])
    func emptyEnvironmentPreservesSelfTestArgument(_ name: String) {
        let arguments = testSuiteDefaults(named: "FastraTests.launch.\(UUID().uuidString)")
        arguments.set(name, forKey: "selftest")
        let launch = AppDefaultsLaunchConfiguration(
            environment: ["FASTRA_SELFTEST": ""], argumentDefaults: arguments)
        #expect(launch.isSelfTestRun)
        #expect(launch.requestedSelfTest == name)
        #expect(launch.selection.isIsolated)
    }
}
