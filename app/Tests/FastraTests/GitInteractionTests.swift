import Foundation
import Testing
@testable import Fastra

@Suite("Fensterlokale Gitinteraktion")
@MainActor
struct GitInteractionTests {
    private let confirmation = GitMutationConfirmation(title: "test", explanation: "test",
                                                        confirmTitle: "test")

    @Test("Unterdrückte Entscheidungen behalten ihre unterschiedlichen Antworten")
    func suppressedDecisionsKeepTheirDefaults() {
        let interaction = GitInteraction()
        #expect(interaction.presentsDialogs)
        interaction.presentsDialogs = false
        #expect(interaction.confirmDiscard(name: "file", untracked: false))
        #expect(interaction.confirmDiscard(name: "file", untracked: true))
        #expect(interaction.confirmDiscard(count: 3, untrackedCount: 2))
        #expect(!interaction.defaultGitMutationConfirmation(confirmation))
        #expect(!interaction.defaultConfirmIntentionalConflictMarkers("file"))
        #expect(interaction.defaultGitIdentityPrompt(nil) == nil)
        #expect(!interaction.defaultGitBranchWorktreeBlock(.init(
            branch: "topic", worktree: "/tmp/absent-worktree", worktreeExists: false)))
        #expect(interaction.promptForPullStrategy() == .rebase)
        #expect(interaction.confirmPullWithLocalChanges())
        var choices: [GitFetchPromptChoice] = []
        interaction.promptForAutomaticFetch { choices.append($0) }
        #expect(choices == [.later])
    }

    @Test("Gitfehler behalten Ausgabepräfix und rohe Fehlermeldung")
    func errorsKeepTheirOutputContract() {
        var messages: [String] = []
        let interaction = GitInteraction(writeStandardError: { messages.append($0) })
        interaction.presentsDialogs = false
        interaction.presentGitError(label: "Fetch", result: GitResult(exitCode: 1,
            stdoutData: Data("stdout\n".utf8), stderrData: Data("raw stderr\n".utf8)))
        interaction.presentGitErrorText(label: "Pull", text: "verbatim\nsecond line")
        interaction.presentGitExecutionFailure(label: "silent", outcome: .cancelled)
        #expect(messages == ["GIT-ERROR [Fetch]: raw stderr\n",
                             "GIT-ERROR [Pull]: verbatim\nsecond line\n"])
    }

    @Test("Ein aufbewahrter Auto-Fetch-Anschluss antwortet nach Ownerabbau")
    func automaticFetchCompletionSurvivesOwnerRelease() {
        weak var owner: GitInteraction?
        let prompt: (@escaping (GitFetchPromptChoice) -> Void) -> Void
        do {
            let interaction = GitInteraction()
            interaction.presentsDialogs = false
            owner = interaction
            prompt = interaction.automaticFetchPromptHandler()
            var liveChoices: [GitFetchPromptChoice] = []
            prompt { liveChoices.append($0) }
            #expect(liveChoices == [.later])
        }
        #expect(owner == nil)
        var choices: [GitFetchPromptChoice] = []
        prompt { choices.append($0) }
        #expect(choices == [.windowUnavailable])
    }

    @Test("Workspaceowner und ihre Defaultbindungen bleiben unabhängig")
    func workspaceOwnersAreIndependent() {
        let firstSuite = "Fastra-Owners-First-\(UUID().uuidString)"
        let secondSuite = "Fastra-Owners-Second-\(UUID().uuidString)"
        let firstDefaults = testSuiteDefaults(named: firstSuite)
        let secondDefaults = testSuiteDefaults(named: secondSuite)
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }
        let first = Workspace(defaults: firstDefaults)
        let second = Workspace(defaults: secondDefaults)
        #expect(first.gitInteraction !== second.gitInteraction)
        #expect(first.markdownImportDecisions !== second.markdownImportDecisions)
        #expect(first.scrollRestoreDiagnostics !== second.scrollRestoreDiagnostics)
        first.gitInteraction.presentsDialogs = false
        #expect(second.gitInteraction.presentsDialogs)
        #expect(!first.gitMutationConfirmationHandler(confirmation))
        #expect(first.gitIdentityPromptHandler(nil) == nil)
        #expect(!first.confirmIntentionalConflictMarkersHandler("file"))
        first.markdownImportDecisions.fileChoiceProvider = { _, _ in .cancel }
        #expect(second.markdownImportDecisions.fileChoiceProvider == nil)
        var trace: [String] = []
        first.scrollRestoreDiagnostics.observer = { trace.append($0) }
        #expect(second.scrollRestoreDiagnostics.observer == nil)
        first.scrollRestoreDiagnostics.emit("first")
        #expect(trace == ["first"])
        first.scrollRestoreDiagnostics.observer = nil
    }

    @Test("Eine aufbewahrte Defaultbindung hält nur ihren Interaktionsbesitzer")
    func boundDefaultDoesNotRetainWorkspace() async throws {
        let suite = "Fastra-Owner-Lifetime-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        weak var weakWorkspace: Workspace?
        weak var weakInteraction: GitInteraction?
        var handler: ((GitMutationConfirmation) -> Bool)?
        do {
            let workspace = Workspace(defaults: defaults)
            workspace.gitInteraction.presentsDialogs = false
            weakWorkspace = workspace
            weakInteraction = workspace.gitInteraction
            handler = workspace.gitMutationConfirmationHandler
        }
        // Eine Momentaufnahme lebender Workspaces kann die Freigabe verzögern.
        try #require(await waitUntil(timeout: 1) { weakWorkspace == nil })
        #expect(weakInteraction != nil)
        #expect(handler?(confirmation) == false)
        handler = nil
        #expect(await waitUntil(timeout: 1) { weakInteraction == nil })
    }
}
