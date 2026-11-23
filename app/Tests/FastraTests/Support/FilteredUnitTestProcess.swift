import Foundation
import Testing

/// Startet einen gezielten Test im unveränderten aktuellen Unit-Testhost.
func filteredUnitTestProcessInvocation(_ filter: String) throws -> (String, [String]) {
    let executable = try #require(CommandLine.arguments.first)
    var arguments = ["--testing-library", "swift-testing", "--filter", filter]
    // Xcodes Testhost braucht den vorhandenen Bundle-Pfad; Pflichtmarker im jeweiligen Test
    // verhindern zusätzlich, dass ein Lauf ohne ausgeführten Kindtest genügt.
    if let bundleIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
        try #require(CommandLine.arguments.indices.contains(bundleIndex + 1))
        arguments.insert(contentsOf: ["--test-bundle-path", CommandLine.arguments[bundleIndex + 1]], at: 0)
    }
    return (executable, arguments)
}
