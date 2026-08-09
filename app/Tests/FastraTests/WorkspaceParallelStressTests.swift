// WorkspaceParallelStressTests.swift
//
// Regressionstest gegen den parallelen Combine-Absturz vom 2026-08-09.
//
// Hintergrund: Combine legt das Verlags-Objekt (PublishedSubject) hinter
// jedem @Published-Feld erst beim ersten Zugriff an und tauscht dabei
// UNGESCHÜTZT den internen Feldspeicher aus. `Workspace.init` erreichte die
// Main-Queue, bevor diese Anlage abgeschlossen war — am frühesten über den
// initialen `rerun()`-Dispatch des SearchRunner, danach über die
// Kontextaktivierung von `Workspace.shared` (deren objectWillChange-Getter
// ALLE @Published-Felder einzeln verdrahtet). Der Main-Thread und der
// erzeugende Test-Thread konvertierten dann denselben Speicher
// gleichzeitig — beobachtet als SIGSEGV (os_unfair_lock auf NULL in
// PublishedSubject) und als Heap-Korruption mit Müll-Adressen in deinit,
// Subject-Sends und malloc. Der Schutz: `Workspace.init` wärmt alle
// Speicher vor (`_ = objectWillChange`), BEVOR der SearchRunner entsteht.
//
// Dieser Test stellt genau dieses Fenster nach: mehrere Threads erzeugen
// gleichzeitig Workspaces und schreiben sofort in bislang unberührte
// @Published-Felder, während der Main-Thread die aufgestauten
// Aktivierungen und Initial-Reruns abarbeitet. Der Prüfpunkt ist das
// Überleben des Prozesses; vor dem Fix stürzten hier rund 40 % der
// Läufe ab.

import Combine
import Foundation
import Testing
@testable import Fastra

@Test("Parallele Workspace-Erzeugung übersteht die Main-Thread-Kontextaktivierung")
func wsParallel_creationSurvivesContextActivation() async {
    // 8 gleichzeitige Erzeuger-Bahnen; jede baut nacheinander mehrere
    // Workspaces. Die Zahl ist ein Kompromiss: hoch genug, dass sich
    // Main-Queue-Aktivierungen und Erzeuger-Threads verlässlich
    // überlappen, klein genug für eine kurze Laufzeit.
    let lanes = 8
    let roundsPerLane = 40
    // Zum Eingrenzen von Hand: WSPAR_MODE=init|write|sub|full schaltet
    // Teile des Stress-Musters ab (Standard: full).
    let mode = ProcessInfo.processInfo.environment["WSPAR_MODE"] ?? "full"
    await withTaskGroup(of: Void.self) { group in
        for lane in 0..<lanes {
            group.addTask {
                for round in 0..<roundsPerLane {
                    let suiteName =
                        "fastra-test-wsparallel-\(lane)-\(round)-\(UUID().uuidString)"
                    let defaults = testSuiteDefaults(named: suiteName)
                    defer { defaults.removePersistentDomain(forName: suiteName) }
                    // Isolierte Suite => kein Identity-Resolver, kein
                    // Auto-Fetch; der Workspace bleibt ohne echte
                    // Git-/Datei-Seiteneffekte.
                    let workspace = Workspace(defaults: defaults)
                    // Erst-Zugriffe auf Felder, die der Init selbst nicht
                    // anfasst — genau hier kollidierte der erzeugende
                    // Thread mit dem objectWillChange-Durchlauf des
                    // Main-Threads. Die `$feld`-Abos lösen dieselbe
                    // Speicher-Anlage aus wie die Abos am Init-Ende und
                    // erhöhen die Zahl der riskanten Erstzugriffe.
                    var bag: [AnyCancellable] = []
                    if mode == "sub" || mode == "full" {
                        workspace.$gitLog.sink { _ in }.store(in: &bag)
                        workspace.$gitBranches.sink { _ in }.store(in: &bag)
                        workspace.$gitIdentity.sink { _ in }.store(in: &bag)
                        workspace.$sidebarNotice.sink { _ in }.store(in: &bag)
                        workspace.$recentProjects.sink { _ in }.store(in: &bag)
                        workspace.$gitConflictMarkerSizes.sink { _ in }.store(in: &bag)
                        workspace.$markdownPreviewWidth.sink { _ in }.store(in: &bag)
                        workspace.$showCompareFilesDialog.sink { _ in }.store(in: &bag)
                    }
                    if mode == "write" || mode == "full" {
                        workspace.findPattern = "stress-\(lane)-\(round)"
                        workspace.replacePattern = "ersatz"
                        workspace.commitMessage = "stress"
                        workspace.gitOperationState = .rebase
                        workspace.activeConflictIndex = round
                        workspace.showsConflictBase = true
                    }
                    bag.removeAll()
                    // Der Scope-Austritt gibt den Workspace auf DIESEM
                    // Thread frei — das deckt die zweite beobachtete
                    // Absturzstelle ab (Cancellable-Abbau im deinit,
                    // PublishedSubject.disassociate).
                }
            }
        }
        await group.waitForAll()
    }
    // Nach dem Sturm auf dem Main-Thread einen letzten Workspace anlegen:
    // Unser Block steht in der Main-Queue HINTER allen aufgestauten
    // Aktivierungen. Der Kontext muss danach auf genau diesen letzten
    // Workspace zeigen (Konvergenz-Invariante der Kontextaktivierung).
    await MainActor.run {
        let suiteName = "fastra-test-wsparallel-final-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let final = Workspace(defaults: defaults)
        #expect(ActiveDocumentContext.shared.workspace === final)
    }
}
