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

/// Sammelt alle echten `@AppStorage(...)`-Deklarationen. Erwähnungen in
/// Kommentaren (dort steht `@AppStorage` ohne öffnende Klammer) zählen nicht.
private func collectAppStorageDeclarations() throws -> [AppStorageDeclaration] {
    let files = try FileManager.default.subpathsOfDirectory(atPath: sourcesURL.path)
        .filter { $0.hasSuffix(".swift") }
        .sorted()
    var found: [AppStorageDeclaration] = []
    for relativePath in files {
        let text = try String(contentsOf: sourcesURL.appendingPathComponent(relativePath),
                              encoding: .utf8)
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            guard let range = line.range(of: "@AppStorage(") else { continue }
            // Argumentliste bis zur PASSENDEN schließenden Klammer. Einfach
            // bis zur ersten `)` zu lesen wäre falsch: `store:
            // SelfTest.workspaceDefaults()` bringt selbst ein Klammerpaar mit.
            // Alle heutigen Fundstellen schließen auf derselben Zeile; bliebe
            // eine offen, fiele sie hier als Rest ohne `store:` auf und damit
            // im Test.
            var depth = 1
            var arguments = ""
            for character in line[range.upperBound...] {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                arguments.append(character)
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
