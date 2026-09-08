import Foundation
import Testing

/// Lädt eine echte Shell-Funktion für kontrollierte Aufrufe im Test. So bleiben
/// die übrigen Startaktionen des Skripts (App, Preferences, Sandbox) inaktiv.
/// Die Runner verwenden für Funktionen einheitlich `name() {` und eine eigene
/// schließende Klammerzeile; diese Konvention wird nur hier ausgewertet.
func shellFunction(named name: String, in script: URL) throws -> String {
    let source = try String(contentsOf: script, encoding: .utf8)
    let start = try #require(source.range(of: "\n\(name)() {\n"))
    let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
    return String(source[start.lowerBound..<end.upperBound])
}
