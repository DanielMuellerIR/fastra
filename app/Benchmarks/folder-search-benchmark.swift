#!/usr/bin/env swift
// Reproduzierbarer Vergleich der Dateiermittlung im Folder-Scope.
// Aufruf aus app/: swift Benchmarks/folder-search-benchmark.swift
//
// Gemessen wird bewusst nur die Enumeration. Die eigentliche Dekodierung und
// Suche ist bei beiden Fastra-Pfaden identisch (FolderSearch.searchOneFile),
// deshalb wäre sie in einem Gesamtwert nur konstantes Rauschen.

import Foundation

struct CorpusSize {
    let name: String
    let files: Int
    let bytesPerFile: Int
}

let sizes = [
    CorpusSize(name: "klein", files: 200, bytesPerFile: 4 * 1024),
    CorpusSize(name: "mittel", files: 2_000, bytesPerFile: 4 * 1024),
    CorpusSize(name: "groß", files: 10_000, bytesPerFile: 4 * 1024),
]
let repetitions = 7
let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/Fastra/Resources/ripgrep/rg")

func legacyFiles(in root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    return enumerator.compactMap { item in
        guard let url = item as? URL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}

func ripgrepFiles(in root: URL) throws -> [URL] {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--files", "--null", "--no-ignore", "--glob", "!.git/**", root.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    // Auch im Benchmark während der Laufzeit leeren, sonst misst ein voller
    // Pipe-Puffer keinen Enumerator, sondern einen vermeidbaren Deadlock.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
    return data.split(separator: 0).compactMap {
        String(bytes: $0, encoding: .utf8).map(URL.init(fileURLWithPath:))
    }
}

func medianMilliseconds(_ action: () throws -> Int) rethrows -> (milliseconds: Double, count: Int) {
    var times: [Double] = []
    var count = 0
    _ = try action() // Aufwärmen: Dateisystem-Cache nicht als erster Messwert.
    for _ in 0..<repetitions {
        let start = DispatchTime.now().uptimeNanoseconds
        count = try action()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    return (times.sorted()[times.count / 2], count)
}

func makeCorpus(_ size: CorpusSize) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-rg-benchmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let payload = Data((String(repeating: "needle payload ", count: max(1, size.bytesPerFile / 15))).utf8)
    for index in 0..<size.files {
        let directory = root.appendingPathComponent("group-\(index / 100)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: directory.appendingPathComponent("entry-\(index).txt"))
    }
    return root
}

guard FileManager.default.isExecutableFile(atPath: executable.path) else {
    fputs("Fehlt: \(executable.path)\n", stderr)
    exit(2)
}

print("korpus\tdateien\tgröße_mib\tfilemanager_median_ms\tripgrep_median_ms\tbeschleunigung\tanzahl")
for size in sizes {
    let root = try makeCorpus(size)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = medianMilliseconds { legacyFiles(in: root).count }
    let ripgrep = try medianMilliseconds { try ripgrepFiles(in: root).count }
    precondition(legacy.count == ripgrep.count, "Pfade unterscheiden sich")
    let factor = legacy.milliseconds / ripgrep.milliseconds
    let mib = Double(size.files * size.bytesPerFile) / 1_048_576
    print("\(size.name)\t\(size.files)\t\(String(format: "%.1f", mib))\t\(String(format: "%.2f", legacy.milliseconds))\t\(String(format: "%.2f", ripgrep.milliseconds))\t\(String(format: "%.2fx", factor))\t\(legacy.count)")
}
