// SidebarVisibilityTests.swift
//
// Regeln der linken Seitenleiste (Änderungswunsch 2026-09-06): ohne
// geöffneten Ordner/Repo keine Seitenleiste — unabhängig von Tabs und
// Nutzerschalter; mit Projekt entscheidet der Schalter, eingehängt bleibt
// sie immer.

import Testing
@testable import Fastra

@Suite("Sichtbarkeit der Seitenleiste")
struct SidebarVisibilityTests {

    @Test("Ohne Projekt nie sichtbar, auch wenn der Nutzer sie eingeschaltet hat")
    func hiddenWithoutProject() {
        #expect(!SidebarVisibility.isVisible(userWantsSidebar: true, hasProject: false))
        #expect(!SidebarVisibility.isVisible(userWantsSidebar: false, hasProject: false))
        #expect(!SidebarVisibility.isMounted(hasProject: false))
        #expect(!SidebarVisibility.offersToggle(hasProject: false))
    }

    @Test("Mit Projekt entscheidet der Schalter; eingehängt bleibt sie immer")
    func togglesWithProject() {
        #expect(SidebarVisibility.isVisible(userWantsSidebar: true, hasProject: true))
        #expect(!SidebarVisibility.isVisible(userWantsSidebar: false, hasProject: true))
        #expect(SidebarVisibility.isMounted(hasProject: true))
        #expect(SidebarVisibility.offersToggle(hasProject: true))
    }
}
