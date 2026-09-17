// SelfTestRunnerFixtures.swift
//
// Wegwerf-Ersatz für die echten Fastra-Einstellungen in Tests, die das echte
// `selftest.sh` fahren (`SelfTestPerformanceTests`, `ScreenshotRunnerTests`).

import Foundation

/// Wegwerf-Ersatz für die ECHTEN Fastra-Einstellungen und den echten Saved
/// State. `selftest.sh` sichert vor jedem Lauf die Produkt-Domain
/// `de.dm0.fastra` und den Saved-State-Ordner und stellt beide hinterher
/// wieder her. Bis 2026-09-17 taten das auch die Runner-Fixtures der
/// Unit-Tests: Ein Unit-Testlauf fasste damit Nutzereinstellungen an, und das
/// `defer` der Fixtures löschte die einzige Sicherung, wenn die
/// Wiederherstellung scheiterte (Review-Fund 2026-09-17). Jede Fixture lenkt
/// beides deshalb auf eine Test-Domain mit Präfix und UUID — die räumt der
/// Test-Defaults-Aufräumer auch nach einem Absturz ab — und auf einen Ordner
/// unter ihrem eigenen Sandbox-Elternordner. Der Runner selbst weist eine
/// Fixture ohne diese Umlenkung ab (`configure_product_state_overrides`), ein
/// vergessener Eintrag fällt also im Test auf, nicht erst am echten Zustand.
func throwawayProductDefaultsDomain() -> String {
    "FastraTests.RunnerFixture.\(UUID().uuidString)"
}

/// Der Ordner muss direkt unter dem Sandbox-Elternordner liegen — genau das
/// prüft der Runner. Er wird bewusst NICHT angelegt: Ohne Saved State gibt es
/// nichts zu sichern, und der Elternordner bleibt nach dem Lauf leer.
func throwawayProductSavedStateDirectory(in sandboxParent: URL) -> URL {
    sandboxParent.appendingPathComponent("product-saved-state", isDirectory: true)
}
