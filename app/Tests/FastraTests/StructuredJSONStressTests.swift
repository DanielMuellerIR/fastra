import AppKit
import CodeEditTextView
import Foundation
import Testing
@testable import Fastra

/// Zwei verschachtelte Teilobjekte mit Arrays und langen, rein künstlichen Werten.
enum StructuredJSONFixture {
    static func compact(minimumBytes: Int) -> String {
        let payload = String(repeating: "A7qZ09_-?mN4xB", count: 2500)
        let object = "{\"request\":{\"items\":[{\"payload\":\"\(payload)\",\"sequence\":1}]},\"response\":{\"items\":[{\"payload\":\"\(payload)\",\"sequence\":2}]}}"
        let count = max(1, (minimumBytes + object.utf8.count) / (object.utf8.count + 1))
        return "[" + Array(repeating: object, count: count).joined(separator: ",") + "]"
    }
}

@Suite("Große strukturierte JSON-Dokumente", .serialized)
struct StructuredJSONStressTests {
    @Test("100 MB werden vollständig geladen, formatiert und verlustfrei minifiziert")
    func serialRunnerIntegration_loadAndFormat100MB() throws {
        let source = StructuredJSONFixture.compact(minimumBytes: 100_000_000)
        #expect(source.utf8.count >= 100_000_000)
        #expect(!source.contains("\n"))
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("array.txt")
        try Data(source.utf8).write(to: url)
        let clock = ContinuousClock()
        let start = clock.now
        let loaded = try FileLoader.load(url: url, largeFileThreshold: FileLoader.editableFileThreshold)
        let loadDuration = start.duration(to: clock.now)
        #expect(loaded.content == source)
        #expect(loaded.displayMode == .text)
        #expect(loadDuration < .seconds(10))
        let formatStart = clock.now
        let formatted = try DocumentFormatter.format(source, fileExtension: "json")
        let formatDuration = formatStart.duration(to: clock.now)
        #expect(formatted.contains("\n"))
        #expect(try DocumentFormatter.minify(formatted, fileExtension: "json") == source)
        print("JSON-STRESS bytes=\(source.utf8.count) load=\(loadDuration) format=\(formatDuration)")
    }
}
