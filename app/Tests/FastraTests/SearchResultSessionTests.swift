import AppKit
import Foundation
import Testing
@testable import Fastra

@Suite("Trefferbasis und verspätete Suchantworten")
@MainActor
struct SearchResultSessionTests {
    private func workspace(scope: Workspace.SearchScope = .file) -> Workspace {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-session-\(UUID().uuidString)"))
        bindSearchResultWindowForTesting(workspace)
        workspace.tabs = [EditorTab(title: "same.txt", path: "", content: "foo foo"),
                          EditorTab(title: "same.txt", path: "", content: "foo")]
        workspace.activeTabID = workspace.tabs[0].id
        workspace.scope = scope
        workspace.findPattern = "foo"
        workspace.replacePattern = "bar"
        workspace.useRegex = false
        workspace.showSearchDialog = true
        return workspace
    }

    private func bufferResult(_ workspace: Workspace) -> SearchResultPublication {
        .buffer(BufferSearch.find(in: workspace.activeTab?.content ?? "", options: workspace.currentSearchOptions))
    }

    @Test("Verspäteter echter Commit ändert weder neuen Lauf noch dessen Spinner", arguments: [false, true])
    func delayedCompletion(_ finishNew: Bool) throws {
        let workspace = workspace()
        let first = try #require(workspace.beginSearchResultRun())
        let old = bufferResult(workspace)
        workspace.replacePattern = "new"
        let second = try #require(workspace.beginSearchResultRun())
        let new = bufferResult(workspace)
        if finishNew { #expect(SearchRunner.publish(new, for: second, in: workspace)) }
        let state = workspace.searchResultState
        let matches = workspace.bufferMatches
        #expect(!SearchRunner.publish(old, for: first, in: workspace))
        #expect(workspace.searchResultState == state)
        #expect(workspace.bufferMatches == matches)
        #expect(workspace.bufferSearching == !finishNew)
    }

    @Test("Tab, Optionen und Quellen sperren alte Completions im selben Main-Durchlauf", arguments: [0, 1, 2])
    func inputTransition(_ kind: Int) throws {
        let workspace = workspace(scope: kind == 2 ? .folder : .file)
        let token = try #require(workspace.beginSearchResultRun())
        switch kind {
        case 0: workspace.activeTabID = workspace.tabs[1].id
        case 1: workspace.caseSensitive.toggle()
        default: workspace.recentSearchFolders = [SearchFolderEntry(path: "/fixture", enabled: true)]
        }
        #expect(!workspace.searchResultsAreCurrent)
        let state = workspace.searchResultState
        let result: SearchResultPublication = kind == 2 ? .folder(.empty) : bufferResult(workspace)
        #expect(!SearchRunner.publish(result, for: token, in: workspace))
        #expect(workspace.searchResultState == state)
        #expect(workspace.navMatches.isEmpty)
    }

    @Test("Suchmaske schließen verwirft auch einen verspäteten Spinner-Abschluss")
    func closeSearch() throws {
        let workspace = workspace()
        let token = try #require(workspace.beginSearchResultRun())
        let result = bufferResult(workspace)
        workspace.showSearchDialog = false
        #expect(!SearchRunner.publish(result, for: token, in: workspace))
        #expect(!workspace.bufferSearching)
        #expect(workspace.navMatches.isEmpty)
        #expect(workspace.searchApproval.ticket == nil)
    }

    @Test("Ein Geöffnet-Trefferwechsel erhält Basis, Ticket und Freigabe")
    func openTabNavigation() throws {
        let workspace = workspace(scope: .open)
        let token = try #require(workspace.beginSearchResultRun())
        let result = OpenTabsSearch.find(tabs: workspace.tabs.map {
            .init(id: $0.id, title: $0.title, content: $0.content)
        }, options: workspace.currentSearchOptions)
        #expect(SearchRunner.publish(.open(result), for: token, in: workspace))
        #expect(workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation))
        let ticket = try #require(workspace.searchApproval.ticket)
        workspace.activeTabID = workspace.tabs[1].id
        #expect(workspace.searchResultsAreCurrent)
        #expect(workspace.searchApproval.ticket == ticket)
        #expect(workspace.navMatches.count == 3)
    }

    @Test("Dokumentfenster-Schließen entwertet synchron; Hilfsfenster schließen erhält die Sitzung")
    func documentWindowBoundary() throws {
        let workspace = workspace()
        let document = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let search = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        search.identifier = SearchWindow.identifier
        document.isReleasedWhenClosed = false
        search.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: document)
        WorkspaceWindowRegistry.register(workspace, for: search)
        defer {
            WorkspaceWindowRegistry.unregister(search)
            WorkspaceWindowRegistry.unregister(document)
            search.close(); document.close()
        }
        let token = try #require(workspace.beginSearchResultRun())
        let result = bufferResult(workspace)
        WorkspaceWindowRegistry.unregister(search)
        #expect(SearchRunner.publish(result, for: token, in: workspace))
        let pending = try #require(workspace.beginSearchResultRun())
        WorkspaceWindowRegistry.unregister(document)
        #expect(!SearchRunner.publish(result, for: pending, in: workspace))
        #expect(workspace.searchResultState.phase == .closed)
        #expect(workspace.navMatches.isEmpty)
    }

    @Test("Ein anderes Fenster erhält keine Ergebnisse des ursprünglichen Workspace")
    func independentWindows() throws {
        let first = workspace(), second = workspace()
        let token = try #require(first.beginSearchResultRun())
        let result = bufferResult(first)
        let secondToken = try #require(second.beginSearchResultRun())
        #expect(!SearchRunner.publish(result, for: token, in: second))
        #expect(second.bufferSearching)
        #expect(SearchRunner.publish(result, for: token, in: first))
        #expect(first.navMatches.count == 2)
        #expect(SearchRunner.publish(bufferResult(second), for: secondToken, in: second))
        #expect(second.navMatches.count == 2)
    }

    @Test("Buffer-Eingaben starten keinen Spinner vor dem Worker und erhalten nur laufende Aktivität",
          arguments: [Workspace.SearchScope.file, .open], [false, true])
    func bufferDebounceSpinner(_ scope: Workspace.SearchScope, _ running: Bool) throws {
        let workspace = workspace(scope: scope)
        let token = try #require(workspace.beginSearchResultRun())
        if !running {
            let publication: SearchResultPublication
            if scope == .file { publication = bufferResult(workspace) }
            else {
                publication = .open(OpenTabsSearch.find(tabs: workspace.tabs.map {
                    .init(id: $0.id, title: $0.title, content: $0.content)
                }, options: workspace.currentSearchOptions))
            }
            #expect(SearchRunner.publish(publication, for: token, in: workspace))
        }
        workspace.caseSensitive.toggle()
        #expect(workspace.bufferSearching == running)
        #expect(!workspace.folderSearching)
        #expect(!workspace.folderNeedsSearch)
        #expect(!workspace.searchResultsAreCurrent)
    }

    @Test("Ein expliziter Ordnerauftrag ohne Quellen zeigt keinen laufenden Spinner")
    func emptyFolderSourcesSpinner() throws {
        let workspace = workspace(scope: .folder)
        workspace.recentSearchFolders = []
        _ = try #require(workspace.beginSearchResultRun())
        #expect(!workspace.bufferSearching)
        #expect(!workspace.folderSearching)
        #expect(!workspace.folderNeedsSearch)
    }

    @Test("Manipulierte Ergebnislisten erzeugen aus einem alten Ticket keine Schreibfreigabe")
    func visibleIDsMustMatch() throws {
        let workspace = workspace()
        let token = try #require(workspace.beginSearchResultRun())
        #expect(SearchRunner.publish(bufferResult(workspace), for: token, in: workspace))
        #expect(workspace.canApplyAllInActiveBuffer)
        workspace.bufferMatches = BufferSearch.find(in: "foo foo", options: workspace.currentSearchOptions).matches
        #expect(!workspace.searchResultsAreCurrent)
        #expect(!workspace.canApplyAllInActiveBuffer)
        #expect(!workspace.setAllSearchMatchesApproved(true, generation: workspace.searchApproval.generation))
    }
}
