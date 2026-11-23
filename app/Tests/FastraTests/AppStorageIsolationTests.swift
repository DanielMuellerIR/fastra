// AppStorageIsolationTests.swift
//
// `@AppStorage` ohne `store:` liest `UserDefaults.standard` und umgeht die
// isolierte Suite aus `AppDefaults.store`. Die Quellprüfung erfasst
// alle Deklarationen, statt die Regel nur für einzelne Schlüssel zu testen.

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

/// Erfasst Deklarationen `@AppStorage(...)` und nachträgliche Wrapper-Neubauten
/// `_feld = AppStorage(...)` im Initializer. Auch ein Neubau muss den isolierten
/// `store:` erhalten. Erwähnungen in Kommentaren zählen nicht.
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
            // Argumentliste bis zur passenden schließenden Klammer. Einfach
            // bis zur ersten `)` zu lesen wäre falsch: Auch Argumente
            // können ihrerseits Funktionsaufrufe mit Klammern enthalten.
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
            !$0.arguments.contains("store: AppDefaults.store")
        }
        let report = offenders
            .map { "\($0.file):\($0.line) → @AppStorage(\($0.arguments))" }
            .joined(separator: "\n")
        #expect(offenders.isEmpty, """
            \(offenders.count) @AppStorage-Deklaration(en) ohne \
            `store: AppDefaults.store`. Sie lesen \
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
    /// Sitzungszustand.
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
                Aufruf mit `AppDefaults.store`.
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
