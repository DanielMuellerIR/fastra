// SelfTestRunnerFixtures.swift
//
// Wegwerf-Ersatz für die echten Fastra-Einstellungen in Tests, die das echte
// `selftest.sh` fahren (`SelfTestPerformanceTests`, `ScreenshotRunnerTests`).

import Foundation

/// Runner-Fixtures ersetzen Produkt-Preferences und Saved State durch eine
/// Test-Domain mit Präfix/UUID und einen eigenen Sandbox-Ordner. So bleiben
/// Nutzereinstellungen auch bei fehlgeschlagener Wiederherstellung geschützt.
/// `configure_product_state_overrides` weist Fixtures ohne diese Umlenkung ab;
/// der Test-Defaults-Aufräumer entfernt die Domain auch nach einem Absturz.
func throwawayProductDefaultsDomain() -> String {
    "FastraTests.RunnerFixture.\(UUID().uuidString)"
}

/// Der Ordner muss direkt unter dem Sandbox-Elternordner liegen — genau das
/// prüft der Runner. Er wird bewusst nicht angelegt: Ohne Saved State gibt es
/// nichts zu sichern, und der Elternordner bleibt nach dem Lauf leer.
func throwawayProductSavedStateDirectory(in sandboxParent: URL) -> URL {
    sandboxParent.appendingPathComponent("product-saved-state", isDirectory: true)
}
