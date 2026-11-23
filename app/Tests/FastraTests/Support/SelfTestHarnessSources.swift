// Gemeinsame Quellenmenge für Harness-Wächter: Ein Dateiumzug darf keine
// Timer, defer-Anweisungen oder Tempzugriffe aus ihrer Reichweite entfernen.
import Foundation

struct SelfTestHarnessSource {
    let path: String
    let source: String
}

func selfTestHarnessSources(in appRoot: URL) throws -> [SelfTestHarnessSource] {
    let root = appRoot.appendingPathComponent("Sources/Fastra").resolvingSymlinksInPath()
    guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
    var sources: [SelfTestHarnessSource] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let name = url.lastPathComponent
        guard name.hasPrefix("SelfTest") || name.hasPrefix("SoakTest") else { continue }
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(name).path
        guard path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        sources.append(SelfTestHarnessSource(
            path: "Sources/Fastra/" + String(path.dropFirst(root.path.count + 1)),
            source: try String(contentsOf: url, encoding: .utf8)))
    }
    if let enumerationError { throw enumerationError }
    return sources.sorted { $0.path < $1.path }
}
