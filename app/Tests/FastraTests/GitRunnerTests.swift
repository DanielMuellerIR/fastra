// GitRunnerTests.swift
//
// Tests für die git-Pfad-Auflösung (Projekt- & Git-Ausbau, Etappe 2).
// Der Prozess-Aufruf selbst wird end-to-end vom Selbsttest `git` abgedeckt;
// hier die reine, dialogsichere Auswahl-Logik.

import Foundation
import Testing
@testable import Fastra

/// FileManager-Stub, der nur die als „ausführbar" markierten Pfade bejaht.
private final class StubFileManager: FileManager {
    let executables: Set<String>
    init(executables: Set<String>) { self.executables = executables; super.init() }
    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}

@Test("Homebrew-git hat Vorrang vor CLT")
func gitPath_prefersHomebrew() {
    let fm = StubFileManager(executables: [
        "/opt/homebrew/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: nil, fileManager: fm)
    #expect(path == "/opt/homebrew/bin/git")
}

@Test("Nur CLT-git vorhanden → CLT-Pfad (nie /usr/bin/git-Stub)")
func gitPath_cltOnly() {
    let fm = StubFileManager(executables: ["/Library/Developer/CommandLineTools/usr/bin/git"])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: nil, fileManager: fm)
    #expect(path == "/Library/Developer/CommandLineTools/usr/bin/git")
}

@Test("Kein git → nil (Funktionen bleiben still weg)")
func gitPath_none() {
    let fm = StubFileManager(executables: [])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: nil, fileManager: fm)
    #expect(path == nil)
}

@Test("Xcode-only-Setup: git aus dem Developer-Ordner")
func gitPath_xcodeFallback() {
    let dev = "/Applications/Xcode.app/Contents/Developer"
    let fm = StubFileManager(executables: ["\(dev)/usr/bin/git"])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: dev, fileManager: fm)
    #expect(path == "\(dev)/usr/bin/git")
}

@Test("/usr/bin/git ist NIE ein Kandidat (Stub-Dialog-Vermeidung)")
func gitPath_neverUsrBinStub() {
    #expect(!GitRunner.candidatePaths.contains("/usr/bin/git"))
}
