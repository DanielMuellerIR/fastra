// Tool4DDiscoveryTests.swift
//
// Unit-Tests der tool4d-Pfad-Discovery (Etappe 4 Wunschpaket 2026-07c) —
// komplett mit temporären Fixtures, es braucht KEIN echtes tool4d. Die
// Version stammt ausschließlich aus dem Info.plist des App-Bundles;
// ausgeführt wird nie etwas.

import Testing
import Foundation
@testable import Fastra

/// Baut ein tool4d.app-Fixture mit ausführbarem Binary und Info.plist.
@discardableResult
private func makeToolBundle(at appURL: URL, version: String?) throws -> URL {
    let fm = FileManager.default
    let macOS = appURL.appendingPathComponent("Contents/MacOS")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    let binary = macOS.appendingPathComponent("tool4d")
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    if let version {
        let plist: [String: Any] = ["CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    }
    return binary
}

private func makeScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-tool4d-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("PATH-Suche findet ein ausführbares tool4d, Ordner werden ignoriert")
func locateInPath() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bin = scratch.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let binary = bin.appendingPathComponent("tool4d")
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: binary.path)
    // Ein Ordner namens tool4d in einem früheren PATH-Eintrag zählt nicht.
    let decoy = scratch.appendingPathComponent("decoy")
    try FileManager.default.createDirectory(
        at: decoy.appendingPathComponent("tool4d"),
        withIntermediateDirectories: true
    )
    let finding = Tool4DDiscovery.locate(
        environmentPATH: "\(decoy.path):\(bin.path)",
        applicationDirectories: [],
        analyzerStorage: scratch.appendingPathComponent("kein-storage")
    )
    #expect(finding?.executableURL == binary)
    #expect(finding?.source == .path(directory: bin.path))
    // Nacktes Binary → keine Version (die stünde nur im App-Bundle).
    #expect(finding?.version == nil)
}

@Test("Programme-Ordner: tool4d.app mit Version aus dem Info.plist")
func locateInApplications() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let apps = scratch.appendingPathComponent("Applications")
    try makeToolBundle(at: apps.appendingPathComponent("tool4d.app"),
                       version: "20.4")
    let finding = Tool4DDiscovery.locate(
        environmentPATH: nil,
        applicationDirectories: [apps],
        analyzerStorage: scratch.appendingPathComponent("kein-storage")
    )
    #expect(finding?.version == "20.4")
    #expect(finding?.source == .applications(directory: apps.path))
    #expect(finding?.executableURL.path.hasSuffix("tool4d.app/Contents/MacOS/tool4d") == true)
}

@Test("Programme-Ordner: versionierter Bundle-Name wie ein echtes Nightly wird gefunden")
func locateVersionedBundleName() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let apps = scratch.appendingPathComponent("Applications")
    // So heißt ein real von 4D heruntergeladenes Nightly — NICHT "tool4d.app".
    try makeToolBundle(
        at: apps.appendingPathComponent("tool4d_v21_nightly_2026-08-05.app"),
        version: "21.1 build 21.100550"
    )
    // Fremde Apps im selben Ordner dürfen nicht stören.
    try makeToolBundle(at: apps.appendingPathComponent("GanzAndereApp.app"),
                       version: "9.9")
    let finding = Tool4DDiscovery.locate(
        environmentPATH: nil,
        applicationDirectories: [apps],
        analyzerStorage: scratch.appendingPathComponent("kein-storage")
    )
    #expect(finding?.version == "21.1 build 21.100550")
    #expect(finding?.source == .applications(directory: apps.path))
    #expect(finding?.executableURL.path
        .hasSuffix("tool4d_v21_nightly_2026-08-05.app/Contents/MacOS/tool4d") == true)
}

@Test("Programme-Ordner: bei mehreren tool4d-Bundles gewinnt die höchste Version, numerisch")
func locateHighestVersionAmongBundles() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let apps = scratch.appendingPathComponent("Applications")
    // "20.10" ist numerisch NEUER als "20.9" — lexikalisch wäre es umgekehrt.
    try makeToolBundle(at: apps.appendingPathComponent("tool4d.app"), version: "20.9")
    try makeToolBundle(at: apps.appendingPathComponent("tool4d_v20_r10.app"),
                       version: "20.10")
    // Ein Bundle ohne lesbare Version verliert gegen jedes mit Version.
    try makeToolBundle(at: apps.appendingPathComponent("tool4d_ohne_version.app"),
                       version: nil)
    let finding = Tool4DDiscovery.locate(
        environmentPATH: nil,
        applicationDirectories: [apps],
        analyzerStorage: scratch.appendingPathComponent("kein-storage")
    )
    #expect(finding?.version == "20.10")
}

@Test("Programme-Ordner: zweites Verzeichnis wird durchsucht und die höchste Version gewinnt ordnerübergreifend")
func locateAcrossApplicationDirectories() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let systemApps = scratch.appendingPathComponent("Applications")
    let userApps = scratch.appendingPathComponent("UserApplications")
    try makeToolBundle(at: systemApps.appendingPathComponent("tool4d_v20.app"),
                       version: "20.4")
    try makeToolBundle(at: userApps.appendingPathComponent("tool4d_v21.app"),
                       version: "21.0")
    let finding = Tool4DDiscovery.locate(
        environmentPATH: nil,
        applicationDirectories: [systemApps, userApps],
        analyzerStorage: scratch.appendingPathComponent("kein-storage")
    )
    #expect(finding?.version == "21.0")
    #expect(finding?.source == .applications(directory: userApps.path))
}

@Test("Analyzer-Storage: höchste Version gewinnt; ohne Binary kein Fund")
func locateInAnalyzerStorage() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let storage = scratch.appendingPathComponent("storage")
    // Zwei Versionen — 20.10 ist numerisch NEUER als 20.9
    // (localizedStandardCompare, nicht lexikalisch).
    try makeToolBundle(
        at: storage.appendingPathComponent("20.9/100089/tool4d.app"),
        version: "20.9"
    )
    try makeToolBundle(
        at: storage.appendingPathComponent("20.10/100200/tool4d.app"),
        version: "20.10"
    )
    // Eine leere Versions-Hülse darf den Fund nicht verhindern.
    try FileManager.default.createDirectory(
        at: storage.appendingPathComponent("21.0/leer"),
        withIntermediateDirectories: true
    )
    let finding = Tool4DDiscovery.locate(
        environmentPATH: nil,
        applicationDirectories: [],
        analyzerStorage: storage
    )
    #expect(finding?.version == "20.10")
    #expect(finding?.source == .analyzerExtension)
}

@Test("Reihenfolge: PATH gewinnt vor Programme-Ordner und Extension")
func locateOrder() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bin = scratch.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let pathBinary = bin.appendingPathComponent("tool4d")
    try Data("#!/bin/sh\n".utf8).write(to: pathBinary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: pathBinary.path)
    let apps = scratch.appendingPathComponent("Applications")
    try makeToolBundle(at: apps.appendingPathComponent("tool4d.app"), version: "20.4")
    let finding = Tool4DDiscovery.locate(
        environmentPATH: bin.path,
        applicationDirectories: [apps],
        analyzerStorage: scratch.appendingPathComponent("kein-storage")
    )
    #expect(finding?.executableURL == pathBinary)
}

@Test("Nichts installiert → nil (die UI erklärt dann die Bezugsquellen)")
func locateNothing() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let finding = Tool4DDiscovery.locate(
        environmentPATH: scratch.appendingPathComponent("leer").path,
        applicationDirectories: [scratch.appendingPathComponent("Applications")],
        analyzerStorage: scratch.appendingPathComponent("storage")
    )
    #expect(finding == nil)
}

@Test("Version aus Bundle-Pfad eines PATH-Binaries im tool4d.app")
func versionFromExecutableInsideBundle() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let binary = try makeToolBundle(
        at: scratch.appendingPathComponent("tool4d.app"), version: "20.5"
    )
    #expect(Tool4DDiscovery.bundleVersion(forExecutable: binary) == "20.5")
    // Binary außerhalb eines Bundles → keine Version.
    #expect(Tool4DDiscovery.bundleVersion(
        forExecutable: scratch.appendingPathComponent("tool4d")) == nil)
}

@Test("Version aus Bundle-Pfad auch bei versioniertem Bundle-Namen")
func versionFromExecutableInsideVersionedBundle() throws {
    // Dieselbe Namensregel wie die Programme-Ordner-Suche: Ein echtes
    // Nightly heißt „tool4d_v21….app". Über PATH gefunden oder als gemerkter
    // Pfad neu geladen, muss seine Version trotzdem lesbar sein — vorher
    // erkannte `bundleVersion(forExecutable:)` nur exakt „tool4d.app"
    // (Reviewfund 2026-08-18).
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let binary = try makeToolBundle(
        at: scratch.appendingPathComponent("tool4d_v21_nightly_2026-08-05.app"),
        version: "21.0"
    )
    #expect(Tool4DDiscovery.bundleVersion(forExecutable: binary) == "21.0")
    // Ein fremdes Bundle, das nur zufällig auf .app endet, zählt nicht.
    let foreign = try makeToolBundle(
        at: scratch.appendingPathComponent("anderes-werkzeug.app"), version: "9.9"
    )
    #expect(Tool4DDiscovery.bundleVersion(forExecutable: foreign) == nil)
}

@Test("Nur die echte Bundle-Struktur liefert eine Version — kein bloß übergeordnetes tool4d-Verzeichnis")
func versionRequiresRealBundleStructure() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Ein Verzeichnis, das nur WIE ein tool4d-Bundle heißt, mit einem Binary
    // an fremder Stelle: `tool4d-wrapper.app/bin/tool4d` ist NICHT das Binary
    // dieses Bundles — seine Info.plist-Version wäre eine fremde Angabe
    // (Reviewfund 2026-08-19).
    let wrapper = scratch.appendingPathComponent("tool4d-wrapper.app")
    let contents = wrapper.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(
        at: wrapper.appendingPathComponent("bin"),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": "7.7"]
    try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0
    ).write(to: contents.appendingPathComponent("Info.plist"))
    let strayBinary = wrapper.appendingPathComponent("bin/tool4d")
    try Data("#!/bin/sh\n".utf8).write(to: strayBinary)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: strayBinary.path)
    #expect(Tool4DDiscovery.bundleVersion(forExecutable: strayBinary) == nil)
}

@Test("Ein Symlink auf das Bundle-Binary (PATH-Eintrag) liefert die Bundle-Version")
func versionResolvesSymlinkedExecutable() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let binary = try makeToolBundle(
        at: scratch.appendingPathComponent("tool4d_v21.app"), version: "21.3"
    )
    // Typischer PATH-Eintrag: /usr/local/bin/tool4d → Bundle-Binary.
    let bin = scratch.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin,
                                            withIntermediateDirectories: true)
    let link = bin.appendingPathComponent("tool4d")
    try FileManager.default.createSymbolicLink(at: link,
                                               withDestinationURL: binary)
    #expect(Tool4DDiscovery.bundleVersion(forExecutable: link) == "21.3")
}

@Test("Erst-Kontakt-Trigger: .4dm und .4DProject, case-insensitiv")
func firstContactTrigger() {
    #expect(Tool4DAssist.triggersFirstContactHint(fileName: "Methode.4dm"))
    #expect(Tool4DAssist.triggersFirstContactHint(fileName: "Projekt.4DProject"))
    #expect(Tool4DAssist.triggersFirstContactHint(fileName: "projekt.4dproject"))
    #expect(!Tool4DAssist.triggersFirstContactHint(fileName: "Form.4DForm"))
    #expect(!Tool4DAssist.triggersFirstContactHint(fileName: "readme.md"))
    #expect(!Tool4DAssist.triggersFirstContactHint(fileName: "ohne-endung"))
}
