// SelfTestLaunchTests.swift
//
// Prüft die früh gesetzten, rein prozesslokalen UI-Fixtures der Shot-Tests.

import Testing
@testable import Fastra

@Test("Gitshot setzt die Änderungen-Sidebar vor dem Fensteraufbau")
func gitShot_preparesChangesSidebarEnvironment() {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: "gitshot") { key, value in
        captured.append((key, value))
    }

    #expect(captured.count == 1)
    #expect(captured.first?.0 == "FASTRA_SIDEBAR")
    #expect(captured.first?.1 == "changes")
}

@Test("Normale Starts setzen keine Shot-Sidebar")
func normalLaunch_doesNotPrepareSidebarEnvironment() {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: nil) { key, value in
        captured.append((key, value))
    }

    #expect(captured.isEmpty)
}
