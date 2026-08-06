// AppStorageIsolationTests.swift
//
// Wächter über eine Isolierungsregel, die man einer einzelnen Zeile nicht
// ansieht: `@AppStorage("key")` OHNE `store:` liest immer
// `UserDefaults.standard`, also die ECHTEN App-Einstellungen des Nutzers.
// `SelfTest.workspaceDefaults()` isoliert Selbsttests zwar in einer eigenen
// Suite — an einem `@AppStorage` ohne `store:` läuft diese Isolierung
// aber vorbei.
//
// Realer Befund 2026-07-27: `editor.sidebarVisible = false` (im normalen
// Betrieb ausgeblendete Seitenleiste) ließ den Selbsttest-Prozess die
// gesamte Seitenleiste nicht aufbauen. `gitstagefolder` und `gitpushbutton`
// fielen reproduzierbar aus und meldeten fehlende SwiftUI-Marker bzw. ein
// leeres Push-Ziel — ohne jeden Produktfehler. Der Test prüft deshalb die
// Quelle selbst, nicht bloß einen einzelnen Schlüssel.

import Foundation
import Testing

/// Quellverzeichnis, robust aus der Testdatei-Position abgeleitet
/// (app/Tests/FastraTests/… → app/Sources/Fastra).
private let sourcesURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("Sources")
    .appendingPathComponent("Fastra")

/// Eine `@AppStorage(...)`-Deklaration mit Fundstelle.
private struct AppStorageDeclaration {
    let file: String
    let line: Int
    let arguments: String
}

/// Sammelt alle echten `AppStorage(...)`-Stellen. Erfasst werden zwei
/// Schreibweisen:
///
/// * die Deklaration `@AppStorage(...)`, und
/// * der nachträgliche Neubau `_feld = AppStorage(...)` in einem `init()`.
///
/// Die zweite Form ist die gefährlichere: Sie ERSETZT einen korrekt
/// deklarierten Wrapper und verlor dabei bis 2026-08-02 in `SettingsView` das
/// `store:` — sechs Git-Einstellungen liefen dadurch trotz Isolierung gegen die
/// echten Nutzer-Defaults (Review 2026-08-02). Erwähnungen in Kommentaren
/// (dort steht `@AppStorage` ohne öffnende Klammer) zählen nicht.
private func collectAppStorageDeclarations() throws -> [AppStorageDeclaration] {
    let files = try FileManager.default.subpathsOfDirectory(atPath: sourcesURL.path)
        .filter { $0.hasSuffix(".swift") }
        .sorted()
    var found: [AppStorageDeclaration] = []
    for relativePath in files {
        let text = try String(contentsOf: sourcesURL.appendingPathComponent(relativePath),
                              encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let range = line.range(of: "@AppStorage(") ?? line.range(of: "= AppStorage(")
            guard let range else { continue }
            // Argumentliste bis zur PASSENDEN schließenden Klammer. Einfach
            // bis zur ersten `)` zu lesen wäre falsch: `store:
            // SelfTest.workspaceDefaults()` bringt selbst ein Klammerpaar mit.
            // Die Liste darf sich über mehrere Zeilen erstrecken — genau so
            // stehen die im `init()` neu gebauten Wrapper da. Bräche der
            // Scanner am Zeilenende ab, sähe er dort eine leere Argumentliste
            // und meldete einen Fehlalarm statt der echten Lage.
            var depth = 1
            var arguments = ""
            var cursor = index
            collect: while cursor < lines.count {
                let rest = cursor == index
                    ? String(lines[cursor][range.upperBound...])
                    : lines[cursor]
                for character in rest {
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        depth -= 1
                        if depth == 0 { break collect }
                    }
                    arguments.append(character)
                }
                arguments.append("\n")
                cursor += 1
            }
            found.append(AppStorageDeclaration(file: relativePath,
                                               line: index + 1,
                                               arguments: arguments))
        }
    }
    return found
}

@Suite("AppStorage-Isolierung")
struct AppStorageIsolationTests {
    /// Kern der Regel: ohne ausdrückliches `store:` greift die
    /// Selbsttest-Isolierung nicht, und eine beliebige echte Einstellung des
    /// Nutzers kann Fenster-Selbsttests kippen.
    @Test("Jede @AppStorage-Deklaration nutzt die isolierbare Suite")
    func everyAppStorageDeclarationPassesTheIsolatableStore() throws {
        let declarations = try collectAppStorageDeclarations()
        let offenders = declarations.filter {
            !$0.arguments.contains("store: SelfTest.workspaceDefaults()")
        }
        let report = offenders
            .map { "\($0.file):\($0.line) → @AppStorage(\($0.arguments))" }
            .joined(separator: "\n")
        #expect(offenders.isEmpty, """
            \(offenders.count) @AppStorage-Deklaration(en) ohne \
            `store: SelfTest.workspaceDefaults()`. Sie lesen \
            UserDefaults.standard und hebeln die Selbsttest-Isolierung aus:
            \(report)
            """)
    }

    /// Dieselbe Lücke an anderer Stelle: Nicht jeder Speicher hängt an
    /// `@AppStorage`. `SoftWrapProfileStore`, `AppearanceSetting.current` und
    /// `SessionStateStore.clear` haben `UserDefaults.standard` als Vorgabe.
    /// Ohne ausdrückliches Argument las und schrieb ein Einstellungs-
    /// Selbsttest damit die echten Nutzerdaten — und löschte beim Abschalten
    /// der Sitzungswiederherstellung sogar den echten wiederherstellbaren
    /// Sitzungszustand (Review 2026-08-06).
    @Test("SettingsView reicht die isolierbare Suite auch an eigene Speicher weiter")
    func settingsViewPassesTheIsolatableStoreEverywhere() throws {
        let text = try String(
            contentsOf: sourcesURL.appendingPathComponent("SettingsView.swift"),
            encoding: .utf8)
        for call in ["SoftWrapProfileStore()", "AppearanceSetting.current()",
                     "SessionStateStore.clear()"] {
            #expect(!text.contains(call), """
                `\(call)` in SettingsView.swift greift auf UserDefaults.standard \
                zu und hebelt die Selbsttest-Isolierung aus. Erwartet wird der \
                Aufruf mit `SelfTest.workspaceDefaults()`.
                """)
        }
    }

    /// Schützt den Wächter selbst: findet der Scanner nichts mehr (z. B. weil
    /// sich die Schreibweise ändert), bliebe der Test oben stumm grün.
    @Test("Der Quell-Scanner findet überhaupt Deklarationen")
    func scannerFindsDeclarations() throws {
        let declarations = try collectAppStorageDeclarations()
        #expect(declarations.count >= 20, """
            Nur \(declarations.count) @AppStorage-Fundstellen — der Scanner \
            greift vermutlich nicht mehr.
            """)
    }
}
