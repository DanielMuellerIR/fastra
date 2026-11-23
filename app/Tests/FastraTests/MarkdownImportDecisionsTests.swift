import Foundation
import Testing
@testable import Fastra

@Suite("Fensterlokale Markdownentscheidungen")
struct MarkdownImportDecisionsTests {
    private let source = URL(fileURLWithPath: "/tmp/import-decisions.rtf")
    private let format = MarkdownImportFormat(identifier: "rtf", fileExtensions: ["rtf"],
        isPackage: false, isAvailable: true, unavailableReason: nil)

    @Test("Datei- und Paketprovider bleiben getrennt und sehen aktuelle Eingaben")
    func providersRemainSeparateAndCurrent() {
        let decisions = MarkdownImportDecisions()
        #expect(decisions.fileChoiceProvider == nil)
        #expect(decisions.packageChoiceProvider == nil)
        var inputs: [URL] = []
        decisions.fileChoiceProvider = { url, format in
            inputs.append(url)
            #expect(format.identifier == "rtf")
            return .cancel
        }
        decisions.packageChoiceProvider = { _, _ in .openAsFolder }
        #expect(decisions.askFileChoice(for: source, format: format) == .cancel)
        #expect(decisions.askPackageChoice(for: source, format: format) == .openAsFolder)
        decisions.fileChoiceProvider = { _, _ in .convert }
        #expect(decisions.askFileChoice(for: source, format: format) == .convert)
        decisions.fileChoiceProvider = { _, _ in .openAsText }
        #expect(decisions.askFileChoice(for: source, format: format) == .openAsText)
        decisions.packageChoiceProvider = { _, _ in .convert }
        #expect(decisions.askPackageChoice(for: source, format: format) == .convert)
        decisions.packageChoiceProvider = { _, _ in .cancel }
        #expect(decisions.askPackageChoice(for: source, format: format) == .cancel)
        #expect(inputs == [source])
    }

    @Test("Cleanup eines Owners berührt die fremde Entscheidung nicht")
    func providerCleanupIsLocal() {
        let first = MarkdownImportDecisions(), second = MarkdownImportDecisions()
        first.fileChoiceProvider = { _, _ in .convert }
        second.fileChoiceProvider = { _, _ in .openAsText }
        first.packageChoiceProvider = { _, _ in .convert }
        second.packageChoiceProvider = { _, _ in .openAsFolder }
        first.fileChoiceProvider = nil
        first.packageChoiceProvider = nil
        #expect(second.askFileChoice(for: source, format: format) == .openAsText)
        #expect(second.askPackageChoice(for: source, format: format) == .openAsFolder)
    }
}
