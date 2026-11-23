import Foundation
import Testing
@testable import Fastra

struct SelfTestDiffExportTests {
    @Test("Fehlende oder leere Treiberkonfiguration ist ein Umgebungsproblem",
          arguments: [[:], ["FASTRA_DIFFEXPORT_INPUT_DIR": ""]] as [[String: String]])
    func missingInputDirectory(environment: [String: String]) {
        do {
            _ = try SelfTestDiffExport.inputDirectoryPath(environment: environment)
            Issue.record("Fehlende Treiberkonfiguration wurde angenommen")
        } catch {
            let diagnostic = error as NSError
            #expect(diagnostic.domain == "DiffExportSelfTest")
            #expect(diagnostic.code == 7)
            #expect(diagnostic.localizedDescription == "Speicherdialog benötigt den externen Tasten-Treiber")
            #expect(SelfTestDiffExport.outcome(for: error) == .environment)
        }
    }

    @Test("Nichtleere Treiberpfade bleiben unverändert",
          arguments: ["/tmp/diffexport-input", "/tmp/Überträge 🇩🇪", " \t\n", " relative path ", "beliebig/../nicht-vorhanden"])
    func nonemptyInputDirectory(path: String) throws {
        let actual = try SelfTestDiffExport.inputDirectoryPath(environment: ["FASTRA_DIFFEXPORT_INPUT_DIR": path])
        #expect(actual == path)
    }

    @Test("Andere Fehler bleiben Funktionsfehler",
          arguments: [NSError(domain: "DiffExportSelfTest", code: 2), NSError(domain: "OtherSelfTest", code: 7)])
    func otherErrors(error: NSError) {
        #expect(SelfTestDiffExport.outcome(for: error) == .fail)
    }
}
