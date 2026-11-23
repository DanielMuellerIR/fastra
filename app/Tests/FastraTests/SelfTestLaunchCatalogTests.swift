import Testing
@testable import Fastra

private final class LaunchDriverProbe {
    typealias Action = SelfTestLaunchCatalog.Action
    var requests: [String] = []
    var mainWindow: [Action] = []
    var search: [Action] = []
    var workspace: [Action] = []
    var mainQueue: [Action] = []
    var background: [Action] = []
    var mainActor: [SelfTestLaunchCatalog.MainActorAction] = []
    var delayed: [(Double, Action)] = []

    var driver: SelfTestLaunchCatalog.Driver {
        .init(
            waitForMainWindow: { self.requests.append("mainWindow"); self.mainWindow.append($0) },
            openSearch: { self.requests.append("search"); self.search.append($0) },
            waitForWorkspace: { self.requests.append("workspace"); self.workspace.append($0) },
            mainQueue: { self.requests.append("mainQueue"); self.mainQueue.append($0) },
            background: { self.requests.append("background"); self.background.append($0) },
            mainActorTask: { self.requests.append("mainActor"); self.mainActor.append($0) },
            mainAfter: { self.requests.append("delay"); self.delayed.append(($0, $1)) }
        )
    }
}

@Suite("Ausführbarer Selbsttest-Startkatalog")
struct SelfTestLaunchCatalogTests {
    @Test("Registrierung und unbekannte Namen führen keine Aktion aus")
    func registrationAndUnknownLookupAreInert() throws {
        var first = 0
        var second = 0
        let catalog = try SelfTestLaunchCatalog(entries: [
            .init(name: "first", route: .workspace { first += 1 }),
            .init(name: "second", route: .mainQueue { second += 1 }),
        ])
        let probe = LaunchDriverProbe()
        #expect(catalog.knownNames == ["first", "second"])
        #expect(catalog.descriptors == [
            .init(name: "first", start: .workspace),
            .init(name: "second", start: .mainQueue),
        ])
        #expect(catalog.unknownNameMessage(for: "missing") ==
            "unbekannter Selbsttest-Name \"missing\" (bekannt: first, second)")
        #expect(!catalog.start(named: "missing", using: probe.driver))
        #expect(first == 0 && second == 0)
        #expect(probe.requests.isEmpty)
        #expect(catalog.start(named: "first", using: probe.driver))
        #expect(probe.requests == ["workspace"])
        #expect(first == 0 && second == 0)
        try #require(probe.workspace.count == 1)
        probe.workspace.removeFirst()()
        #expect(first == 1 && second == 0)
    }

    @Test("Doppelte Namen werden vor Benutzung abgewiesen")
    func duplicateNamesAreRejectedWithoutExecutingActions() {
        var executions = 0
        #expect(throws: SelfTestLaunchCatalog.RegistrationError.duplicateName("same")) {
            _ = try SelfTestLaunchCatalog(entries: [
                .init(name: "same", route: .workflowControlled { executions += 1 }),
                .init(name: "same", route: .mainQueue { executions += 1 }),
            ])
        }
        #expect(executions == 0)
    }

    @Test("Hauptfenster und Suchfenster geben den Body nacheinander frei")
    func searchRequiresMainWindowThenSearchWindow() throws {
        var executions = 0
        let catalog = try SelfTestLaunchCatalog(entries: [
            .init(name: "search", route: .mainWindowAndSearch { executions += 1 }),
        ])
        let probe = LaunchDriverProbe()
        #expect(catalog.start(named: "search", using: probe.driver))
        #expect(probe.requests == ["mainWindow"])
        #expect(probe.search.isEmpty && executions == 0)
        try #require(probe.mainWindow.count == 1)
        probe.mainWindow.removeFirst()()
        #expect(probe.requests == ["mainWindow", "search"])
        #expect(executions == 0)
        try #require(probe.search.count == 1)
        probe.search.removeFirst()()
        #expect(executions == 1)
    }

    @Test("Normale Hauptfensterroute wartet auf ihre eigene Freigabe")
    func mainWindowWaitsForRelease() throws {
        var executions = 0
        let catalog = try SelfTestLaunchCatalog(entries: [
            .init(name: "window", route: .mainWindow { executions += 1 }),
        ])
        let probe = LaunchDriverProbe()
        #expect(catalog.start(named: "window", using: probe.driver))
        #expect(probe.requests == ["mainWindow"])
        #expect(executions == 0)
        try #require(probe.mainWindow.count == 1)
        probe.mainWindow.removeFirst()()
        #expect(executions == 1)
    }

    @Test("Mainqueue, Hintergrund und Verzögerung bleiben getrennte Starts")
    func queueAndDelayRoutesUseTheirOwnDriverEntries() throws {
        var executions: [String] = []
        let catalog = try SelfTestLaunchCatalog(entries: [
            .init(name: "main", route: .mainQueue { executions.append("main") }),
            .init(name: "background", route: .background { executions.append("background") }),
            .init(name: "delayed", route: .mainAfter(2.5, { executions.append("delayed") })),
        ])
        let probe = LaunchDriverProbe()
        for name in catalog.knownNames { #expect(catalog.start(named: name, using: probe.driver)) }
        #expect(probe.requests == ["mainQueue", "background", "delay"])
        #expect(executions.isEmpty)
        try #require(probe.mainQueue.count == 1 && probe.background.count == 1 && probe.delayed.count == 1)
        #expect(probe.delayed[0].0 == 2.5)
        probe.background.removeFirst()()
        #expect(executions == ["background"])
        probe.mainQueue.removeFirst()()
        #expect(executions == ["background", "main"])
        probe.delayed.removeFirst().1()
        #expect(executions == ["background", "main", "delayed"])
    }

    @MainActor
    @Test("MainActor-Aktionen behalten ihren actorisolierten Treibereingang")
    func mainActorRouteWaitsForItsTypedRelease() throws {
        var executions = 0
        let catalog = try SelfTestLaunchCatalog(entries: [
            .init(name: "actor", route: .mainActorTask {
                MainActor.preconditionIsolated()
                executions += 1
            }),
        ])
        let probe = LaunchDriverProbe()
        #expect(catalog.start(named: "actor", using: probe.driver))
        #expect(probe.requests == ["mainActor"])
        #expect(executions == 0)
        try #require(probe.mainActor.count == 1)
        probe.mainActor.removeFirst()()
        #expect(executions == 1)
    }

    @Test("Ablaufgesteuerte Ausnahmen werden erst bei Auswahl ausgeführt")
    func workflowControlledExecutesOnlyItsSelectedAction() throws {
        var executions: [String] = []
        let catalog = try SelfTestLaunchCatalog(entries: [
            .init(name: "first", route: .workflowControlled { executions.append("first") }),
            .init(name: "second", route: .workflowControlled { executions.append("second") }),
        ])
        let probe = LaunchDriverProbe()
        #expect(executions.isEmpty)
        #expect(catalog.start(named: "second", using: probe.driver))
        #expect(executions == ["second"])
        #expect(probe.requests.isEmpty)
    }

    @Test("Die echte Registrierung erhält ihre fachlichen Startrouten")
    func actualRegistrationHasExpectedRoutes() throws {
        let descriptors = try SelfTest.launchDescriptors()
        func names(start: SelfTestLaunchCatalog.Start) -> Set<String> {
            Set(descriptors.filter { $0.start == start }.map(\.name))
        }
        #expect(names(start: .workspace) == [
            "filemodes", "search", "project", "git", "gitactions", "openscope", "selsearch", "wildcard",
        ])
        #expect(names(start: .mainQueue) == [
            "sessionrestore", "coldopen", "coldopenoff", "soakpasteboardrestore", "soakdefaultspurge",
            "replaceall", "macro4dengine", "tool4dlsp", "markdownimport", "localization", "windows",
        ])
        #expect(names(start: .mainWindowAndSearch) == [
            "cmdw", "fields", "searchoptions", "searchlayout", "searchapproval", "searchapprovalclose",
            "searchfocus", "dialoglayout", "projectinput", "pilldrop", "navmatch", "searchmark",
            "wildcardshot", "searchshot", "regexshot",
        ])
        #expect(names(start: .background) == ["searchperf", "projectperf"])
        #expect(names(start: .mainActorTask) == ["aboutshot"])
        #expect(names(start: .mainAfter(2.5)) == ["loadperf"])
        #expect(names(start: .workflowControlled) == ["updates", "controlhost"])
        #expect(names(start: .mainWindow).count == 132)
        #expect(descriptors.first { $0.name == "contrast" }?.start == .mainWindow)
        #expect(descriptors.first { $0.name == "print" }?.start == .mainWindow)
        #expect(descriptors.first { $0.name == "snippets" }?.start == .mainWindow)
        #expect(descriptors.first { $0.name == "snippetfiles" }?.start == .mainWindow)
        #expect(descriptors.first { $0.name == "markdowncollections" }?.start == .mainWindow)
        #expect(descriptors.first { $0.name == "markdownimportui" }?.start == .mainWindow)
    }
}
