import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite("Atomarer Datei-Commit")
struct AtomicFileCommitTests {
    @Test("Der Nachprüfungszeitraum besitzt ein dauerhaftes Recovery-Journal")
    func postSwapWindowHasDurableRecoveryJournal() throws {
        let directory = try makeDirectory("journal-window")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery-journal", isDirectory: true)
        let recoveryStore = AtomicCommitRecovery.Store(
            directoryURL: recoveryDirectory)
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)

        _ = try AtomicFileCommit.replaceExisting(
            at: target,
            withPreparedFile: prepared,
            expecting: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil),
            recoveryStore: recoveryStore,
            afterSwap: { installed, displaced in
                let pending = try recoveryStore.inspectPending()
                #expect(pending.count == 1)
                let item = try #require(pending.first)
                #expect(item.state == .afterExchange)
                #expect(item.targetURL == installed)
                #expect(item.preparedURL == displaced)
                #expect(FileManager.default.fileExists(atPath: item.journalURL.path),
                        "Der Journal-Eintrag muss vor der Nachprüfung synchronisiert vorliegen")
                #expect(try fileStat(recoveryDirectory).st_mode & mode_t(0o777)
                        == mode_t(0o700))
                #expect(try fileStat(item.journalURL).st_mode & mode_t(0o777)
                        == mode_t(0o600))
            })

        #expect(try recoveryStore.inspectPending().isEmpty,
                "Erst der vollständig geprüfte Commit darf sein Journal entfernen")
        #expect(try Data(contentsOf: target) == replacement)
    }

    @Test("Ein beim Tausch abgebrochener Prozess hinterlässt eine eindeutige Zuordnung")
    func interruptedExchangeRemainsDiscoverableAfterRestart() throws {
        let directory = try makeDirectory("journal-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = AtomicCommitRecovery.Store(
            directoryURL: directory.appendingPathComponent(
                "recovery-journal", isDirectory: true))
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let replacementSnapshot = FileSnapshot(data: replacement, identity: nil)
        let targetStat = try fileStat(target)
        let preparedStat = try fileStat(prepared)

        _ = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: targetStat,
            preparedStat: preparedStat,
            expectedContent: expected,
            replacementContent: replacementSnapshot)
        try exchangeNames(target: target, prepared: prepared)

        // Eine neue Store-Instanz bildet den nächsten App-Start ab: Der
        // Prozessspeicher des schreibenden Laufs steht nicht mehr zur Verfügung.
        let restartedStore = AtomicCommitRecovery.Store(
            directoryURL: recoveryStore.directoryURL)
        let pending = try restartedStore.inspectPending()
        #expect(pending.count == 1)
        let item = try #require(pending.first)
        #expect(item.state == .afterExchange)
        #expect(item.targetURL == target)
        #expect(item.preparedURL == prepared)
        #expect(try Data(contentsOf: target) == replacement)
        #expect(try Data(contentsOf: prepared) == original)
        let warning = AppDelegate.atomicCommitRecoveryText(
            pending, journalDirectory: restartedStore.directoryURL)
        #expect(warning.contains(target.path))
        #expect(warning.contains(prepared.path))
        #expect(warning.contains(restartedStore.directoryURL.path))
    }

    @Test("Ein In-place-Write nach dem Abbruch gilt nicht als unveränderter Tausch")
    func changedContentAfterInterruptedExchangeIsReported() throws {
        let directory = try makeDirectory("journal-content-change")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = testRecoveryStore(in: directory)
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        _ = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: FileSnapshot.readSnapshotOnly(from: target),
            replacementContent: FileSnapshot(data: replacement, identity: nil))
        try exchangeNames(target: target, prepared: prepared)
        try writeInPlace(Data("REPLACEMENT\n".utf8), to: target)

        let pending = try recoveryStore.inspectPending()
        #expect(pending.count == 1)
        #expect(pending.first?.state == .changed)
        #expect(try Data(contentsOf: prepared) == original)
    }

    @Test("Der Journal-gebundene Cleanup-Name bleibt nach einem Abbruch auffindbar")
    func interruptedCleanupClaimRemainsDiscoverable() throws {
        let directory = try makeDirectory("journal-cleanup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = AtomicCommitRecovery.Store(
            directoryURL: directory.appendingPathComponent(
                "recovery-journal", isDirectory: true))
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let handle = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil))
        let claimed = directory.appendingPathComponent(handle.cleanupName)
        try FileManager.default.moveItem(at: prepared, to: claimed)

        let pending = try recoveryStore.inspectPending()
        #expect(pending.count == 1)
        let item = try #require(pending.first)
        #expect(item.state == .beforeExchange)
        #expect(item.preparedURL == claimed)
        #expect(try Data(contentsOf: claimed) == replacement)
    }

    @Test("Ein fremder Dateityp am Temp-Pfad verwirft das Journal nicht")
    func foreignSecondaryPathTypeKeepsJournal() throws {
        let directory = try makeDirectory("journal-foreign-type")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = AtomicCommitRecovery.Store(
            directoryURL: directory.appendingPathComponent(
                "recovery-journal", isDirectory: true))
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        _ = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil))
        try FileManager.default.removeItem(at: prepared)
        try FileManager.default.createSymbolicLink(
            at: prepared, withDestinationURL: target)

        let pending = try recoveryStore.inspectPending()
        let item = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(item.state == .changed)
        #expect(item.preparedURL == prepared)
        #expect(FileManager.default.fileExists(atPath: item.journalURL.path),
                "Ein Symlink darf nicht wie ein sicher bereinigter zweiter Pfad gelten")
    }

    @Test("Ein bereits bereinigter Tausch entfernt nur sein veraltetes Journal")
    func missingSecondaryPathPrunesStaleJournal() throws {
        let directory = try makeDirectory("journal-stale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = AtomicCommitRecovery.Store(
            directoryURL: directory.appendingPathComponent(
                "recovery-journal", isDirectory: true))
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        _ = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil))
        try FileManager.default.removeItem(at: prepared)

        #expect(try recoveryStore.inspectPending().isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(
            atPath: recoveryStore.directoryURL.path)
        #expect(!remaining.contains { $0.hasSuffix(".json") })
        #expect(try Data(contentsOf: target) == original,
                "Die Journal-Bereinigung darf den Zielpfad nicht verändern")
    }

    @Test("Fehlen Ziel und zweite Fassung, bleibt das letzte Journal erhalten")
    func missingTargetAndSecondaryKeepJournal() throws {
        let directory = try makeDirectory("journal-all-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = testRecoveryStore(in: directory)
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        _ = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: FileSnapshot.readSnapshotOnly(from: target),
            replacementContent: FileSnapshot(data: replacement, identity: nil))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.removeItem(at: prepared)

        let pending = try recoveryStore.inspectPending()
        let item = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(item.state == .missingTarget)
        #expect(item.preparedURL == nil)
        #expect(FileManager.default.fileExists(atPath: item.journalURL.path))
    }

    @Test("Ein fremder Zielstand ohne zweite Fassung verwirft das Journal nicht")
    func foreignTargetWithoutSecondaryKeepsJournal() throws {
        let directory = try makeDirectory("journal-foreign-target")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = testRecoveryStore(in: directory)
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        _ = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: FileSnapshot.readSnapshotOnly(from: target),
            replacementContent: FileSnapshot(data: replacement, identity: nil))
        try FileManager.default.removeItem(at: prepared)
        try FileManager.default.removeItem(at: target)
        try Data("fremd\n".utf8).write(to: target)

        let pending = try recoveryStore.inspectPending()
        let item = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(item.state == .changed)
        #expect(item.preparedURL == nil)
        #expect(FileManager.default.fileExists(atPath: item.journalURL.path))
    }

    @Test("Ein beschädigtes Journal bleibt sichtbar und unangetastet")
    func corruptJournalIsReportedAndPreserved() throws {
        let directory = try makeDirectory("journal-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery-journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoveryDirectory, withIntermediateDirectories: true)
        let journal = recoveryDirectory.appendingPathComponent(
            "00000000-0000-0000-0000-000000000000.json")
        try Data("kein json".utf8).write(to: journal)
        let recoveryStore = AtomicCommitRecovery.Store(
            directoryURL: recoveryDirectory)

        let pending = try recoveryStore.inspectPending()
        let item = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(item.state == .invalidJournal)
        #expect(item.journalURL == journal)
        #expect(try Data(contentsOf: journal) == Data("kein json".utf8))
    }

    @Test("Die Startprüfung meldet kein Journal eines noch laufenden Prozesses")
    func activeProcessJournalIsIgnoredByStartupInspection() throws {
        let directory = try makeDirectory("journal-active-process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryStore = AtomicCommitRecovery.Store(
            directoryURL: directory.appendingPathComponent(
                "recovery-journal", isDirectory: true))
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        _ = try recoveryStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil))

        #expect(try recoveryStore.inspectPending(
            includeActiveProcesses: false).isEmpty)
        #expect(try recoveryStore.inspectPending().count == 1,
                "Gezielte Diagnose muss auch Journale des Testprozesses lesen können")
    }

    @Test("Eine wiedervergebene PID gilt nicht als Besitzer eines alten Journals")
    func reusedProcessIDDoesNotHideJournal() throws {
        let directory = try makeDirectory("journal-reused-pid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery-journal", isDirectory: true)
        let writerStore = AtomicCommitRecovery.Store(
            directoryURL: recoveryDirectory,
            processStartToken: { _ in 111 })
        let replacement = Data("replacement\n".utf8)
        try Data("original\n".utf8).write(to: target)
        try replacement.write(to: prepared)
        _ = try writerStore.begin(
            targetURL: target,
            preparedURL: prepared,
            targetStat: fileStat(target),
            preparedStat: fileStat(prepared),
            expectedContent: FileSnapshot.readSnapshotOnly(from: target),
            replacementContent: FileSnapshot(data: replacement, identity: nil))

        let restartedStore = AtomicCommitRecovery.Store(
            directoryURL: recoveryDirectory,
            processStartToken: { _ in 222 })
        #expect(try restartedStore.inspectPending(
            includeActiveProcesses: false).count == 1)
    }

    @Test("Startprüfung entfernt nur Schreibfragmente beendeter Besitzer")
    func startupRemovesOnlyDeadWritingFragments() throws {
        let directory = try makeDirectory("journal-writing-fragments")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryDirectory = directory.appendingPathComponent(
            "recovery-journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoveryDirectory, withIntermediateDirectories: true)
        let active = recoveryDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).json.writing.111.7001")
        let dead = recoveryDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).json.writing.222.7002")
        let reused = recoveryDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).json.writing.333.7003")
        let malformed = recoveryDirectory.appendingPathComponent("alt.json.writing")
        for file in [active, dead, reused, malformed] {
            try Data("teilweise".utf8).write(to: file)
        }
        let store = AtomicCommitRecovery.Store(
            directoryURL: recoveryDirectory,
            processStartToken: { pid in
                switch pid {
                case 111: return 7001       // derselbe Besitzer lebt
                case 333: return 9003       // PID wurde wiedervergeben
                default: return nil         // Besitzer existiert nicht mehr
                }
            })

        #expect(try store.inspectPending().isEmpty)
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(!FileManager.default.fileExists(atPath: reused.path))
        #expect(FileManager.default.fileExists(atPath: malformed.path),
                "Ein ungebundener Fremdname bleibt zur Diagnose unangetastet")
    }

    @Test("Ein nicht schreibbares Journal stoppt den Commit vor dem Namenstausch")
    func journalFailureLeavesTargetUnchanged() throws {
        let directory = try makeDirectory("journal-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let recoveryPath = directory.appendingPathComponent("keine-map")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        // Eine reguläre Datei kann nicht als Journal-Verzeichnis dienen.
        try Data("belegt".utf8).write(to: recoveryPath)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        var reachedSwapHook = false

        #expect(throws: (any Error).self) {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: AtomicCommitRecovery.Store(
                    directoryURL: recoveryPath),
                beforeSwap: { _ in reachedSwapHook = true })
        }
        #expect(!reachedSwapHook)
        #expect(try Data(contentsOf: target) == original)
        #expect(try Data(contentsOf: prepared) == replacement)
    }

    @Test("Erfolgreicher Tausch erhält Metadaten und entfernt den Altstand")
    func successfulSwapPreservesMetadataAndCleansUp() throws {
        let directory = try makeDirectory("success")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("alt\n".utf8)
        let replacement = Data("neu\n".utf8)
        try original.write(to: target)
        let oldDate = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .modificationDate: oldDate],
            ofItemAtPath: target.path)
        let extendedAttributeName = "com.fastra.tests.atomic-commit"
        let extendedAttributeValue = Data("metadaten".utf8)
        try setExtendedAttribute(extendedAttributeValue,
                                 named: extendedAttributeName, at: target)
        try replacement.write(to: prepared)
        let replacementDate = try #require(
            FileManager.default.attributesOfItem(atPath: prepared.path)[.modificationDate]
                as? Date)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        var permissionsImmediatelyAfterSwap: Int?

        let written = try AtomicFileCommit.replaceExisting(
            at: target,
            withPreparedFile: prepared,
            expecting: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil),
            recoveryStore: testRecoveryStore(in: directory),
            afterSwap: { installed, _ in
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: installed.path)
                permissionsImmediatelyAfterSwap =
                    (attributes[.posixPermissions] as? NSNumber)?.intValue
            })

        #expect(try Data(contentsOf: target) == replacement)
        #expect(written == FileSnapshot(data: replacement, at: target))
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: target.path)[.posixPermissions] as? NSNumber
        #expect(permissionsImmediatelyAfterSwap == 0o640,
                "Die neue Inode darf nie kurz mit den Temp-Rechten sichtbar sein")
        #expect(permissions?.intValue == 0o640)
        let writtenDate = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate]
                as? Date)
        #expect(writtenDate == replacementDate)
        #expect(writtenDate != oldDate)
        #expect(try extendedAttribute(named: extendedAttributeName, at: target)
                == extendedAttributeValue)
    }

    @Test("Erfolgreicher Tausch liest den Ersatzinhalt nur zweimal vollständig")
    func successfulSwapAvoidsRedundantPreparedContentRead() throws {
        let directory = try makeDirectory("content-read-count")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data(repeating: 0x41, count: 64 * 1024)
        let replacement = Data(repeating: 0x42, count: 64 * 1024)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        var preparedContentReads = 0

        _ = try AtomicFileCommit.replaceExisting(
            at: target,
            withPreparedFile: prepared,
            expecting: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil),
            recoveryStore: testRecoveryStore(in: directory),
            preparedSnapshotReader: { descriptor, info, limit in
                preparedContentReads += 1
                return try FileSnapshot.readSnapshotOnly(
                    descriptor: descriptor, fileStat: info, byteLimit: limit)
            })

        #expect(preparedContentReads == 2,
                "Vorprüfung und Abschluss brauchen je einen Vollscan; die reine Inode-Bindung keinen dritten")
        #expect(try Data(contentsOf: target) == replacement)
    }

    @Test("Folgenlos gescheiterte Metadatenkopie tauscht den Ausgangsstand zurück")
    func metadataCopyFailureWithoutMutationRollsBackCleanly() throws {
        let directory = try makeDirectory("metadata-copy-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: testRecoveryStore(in: directory),
                copyDisplacedMetadata: { _, _ in
                    // Simuliert einen Datenträger, der die Metadaten ablehnt,
                    // ohne die vorbereitete Inode vorher teilweise zu ändern.
                    errno = EACCES
                    return -1
                })
            Issue.record("Die abgelehnte Metadatenkopie hätte fehlschlagen müssen")
        } catch let failure as AtomicFileCommit.Failure {
            if case .recoveryRequired = failure {
                Issue.record("Ein folgenloser Fehler darf keine manuelle Recovery verlangen")
            } else {
                Issue.record("Erwartet war der ursprüngliche POSIX-Fehler, erhalten: \(failure)")
            }
        } catch let error as POSIXError {
            #expect(error.code == .EACCES)
        }

        #expect(try Data(contentsOf: target) == original)
        #expect(!FileManager.default.fileExists(atPath: prepared.path),
                "Die eigene Ersatzdatei muss nach dem sicheren Rücktausch verschwinden")
    }

    @Test("In-place-Fremdwrite im Commit-Fenster wird zurückgetauscht")
    func inPlaceWriteAfterPreflightIsRolledBack() throws {
        let directory = try makeDirectory("in-place")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("alpha\n".utf8)
        let replacement = Data("lokal\n".utf8)
        let external = Data("omega\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let originalIdentity = FileIdentity(url: target)
        let originalDate = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate]
                as? Date)
        var hookIdentity: FileIdentity?

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: testRecoveryStore(in: directory),
                beforeSwap: { url in
                    try writeInPlace(external, to: url)
                    try FileManager.default.setAttributes(
                        [.modificationDate: originalDate], ofItemAtPath: url.path)
                    hookIdentity = FileIdentity(url: url)
                })
            Issue.record("Der In-place-Fremdwrite hätte den Commit stoppen müssen")
        } catch AtomicFileCommit.Failure.conflictRolledBack {
            // Erwartet: Der exakt verdrängte Fremdstand liegt wieder am Ziel.
        }

        #expect(hookIdentity == originalIdentity,
                "Der Test muss dieselbe Inode verändern, nicht den Pfad ersetzen")
        #expect(FileIdentity(url: target) == originalIdentity)
        #expect(try Data(contentsOf: target) == external)
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
    }

    @Test("Gleich große Manipulation der vorbereiteten Datei bleibt zur Recovery erhalten")
    func preparedFileTamperingRequiresRecovery() throws {
        let directory = try makeDirectory("prepared-tamper")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        let tampered = Data("manipulated\n".utf8)
        #expect(replacement.count == tampered.count)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let preparedDate = try #require(
            FileManager.default.attributesOfItem(atPath: prepared.path)[.modificationDate]
                as? Date)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: testRecoveryStore(in: directory),
                beforeSwap: { _ in
                    try writeInPlace(tampered, to: prepared)
                    try FileManager.default.setAttributes(
                        [.modificationDate: preparedDate], ofItemAtPath: prepared.path)
                })
            Issue.record("Die manipulierte Nachbardatei hätte abgelehnt werden müssen")
        } catch let failure as AtomicFileCommit.Failure {
            guard case .recoveryRequired = failure else {
                Issue.record("Erwartet war recoveryRequired, erhalten: \(failure)")
                return
            }
        }

        #expect(try Data(contentsOf: target) == tampered)
        #expect(try Data(contentsOf: prepared) == original)
    }

    @Test("In-place-Fremdwrite am installierten Ersatz bleibt zur Recovery erhalten")
    func installedReplacementTamperingRequiresRecovery() throws {
        let directory = try makeDirectory("installed-in-place")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        let external = Data("external!!!\n".utf8)
        #expect(replacement.count == external.count)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: testRecoveryStore(in: directory),
                afterSwap: { installed, _ in
                    let replacementDate = try #require(
                        FileManager.default.attributesOfItem(
                            atPath: installed.path
                        )[.modificationDate] as? Date
                    )
                    try writeInPlace(external, to: installed)
                    try FileManager.default.setAttributes(
                        [.modificationDate: replacementDate],
                        ofItemAtPath: installed.path
                    )
                }
            )
            Issue.record("Der fremd veränderte Ersatz hätte Recovery verlangen müssen")
        } catch let failure as AtomicFileCommit.Failure {
            guard case .recoveryRequired = failure else {
                Issue.record("Erwartet war recoveryRequired, erhalten: \(failure)")
                return
            }
        }

        #expect(try Data(contentsOf: target) == external,
                "Fastra darf die fremd veränderte installierte Inode nicht zurücktauschen")
        #expect(try Data(contentsOf: prepared) == original,
                "Der verdrängte Ausgangsstand muss daneben erhalten bleiben")
    }

    @Test("Fremd ersetzter Temp-Name im Aufräumfenster bleibt erhalten")
    func foreignReplacementInCleanupWindowIsPreserved() throws {
        let directory = try makeDirectory("cleanup-window")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        let foreign = Data("fremdstand\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: testRecoveryStore(in: directory),
                beforeCleanup: { _, displaced in
                    // Simulierter Fremdprozess: ersetzt den Temp-Namen GENAU
                    // zwischen der letzten Prüfung und dem Löschen durch einen
                    // eigenen neuen Stand. Vorher löschte `unlinkat` diesen
                    // Namen bedingungslos — der Fremdstand war weg.
                    try FileManager.default.removeItem(at: displaced)
                    try foreign.write(to: displaced)
                })
            Issue.record("Der fremd ersetzte Temp-Name hätte Recovery verlangen müssen")
        } catch let failure as AtomicFileCommit.Failure {
            guard case .recoveryRequired = failure else {
                Issue.record("Erwartet war recoveryRequired, erhalten: \(failure)")
                return
            }
        }

        #expect(try Data(contentsOf: target) == replacement,
                "Der bereits verifizierte Tausch selbst bleibt bestehen")
        #expect(try Data(contentsOf: prepared) == foreign,
                "Der fremde Stand darf beim Aufräumen nicht gelöscht werden")
    }

    @Test("In-place-Fremdwrite in die verdrängte Inode im Aufräumfenster bleibt erhalten")
    func inPlaceWriteIntoDisplacedInodeInCleanupWindowIsPreserved() throws {
        let directory = try makeDirectory("cleanup-in-place")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        let foreign = Data("fremdstand\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        var displacedIdentityInHook: FileIdentity?

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: testRecoveryStore(in: directory),
                beforeCleanup: { _, displaced in
                    // Simulierter Fremdprozess mit offenem Deskriptor:
                    // schreibt in DIESELBE verdrängte Inode, ohne den Namen
                    // zu ersetzen. Gerät und Inode bleiben gleich — die
                    // reine Identitätsprüfung sah darin keinen Konflikt und
                    // löschte den frischen Fremdstand mit (Review 2026-08-29).
                    displacedIdentityInHook = FileIdentity(url: displaced)
                    try writeInPlace(foreign, to: displaced)
                })
            Issue.record("Der In-place-Fremdwrite hätte Recovery verlangen müssen")
        } catch let failure as AtomicFileCommit.Failure {
            guard case .recoveryRequired = failure else {
                Issue.record("Erwartet war recoveryRequired, erhalten: \(failure)")
                return
            }
        }

        #expect(FileIdentity(url: prepared) == displacedIdentityInHook,
                "Der Test muss in-place schreiben, nicht den Namen ersetzen")
        #expect(try Data(contentsOf: target) == replacement,
                "Der bereits verifizierte Tausch selbst bleibt bestehen")
        #expect(try Data(contentsOf: prepared) == foreign,
                "Der In-place-Fremdstand darf beim Aufräumen nicht gelöscht werden")
    }

    @Test("Ziel und Nachbardatei dürfen nicht dieselbe Inode sein")
    func hardLinkedPreparedFileIsRejected() throws {
        let directory = try makeDirectory("hardlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        try original.write(to: target)
        try FileManager.default.linkItem(at: target, to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)

        #expect(throws: POSIXError.self) {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: original, identity: nil),
                recoveryStore: testRecoveryStore(in: directory))
        }
        #expect(try Data(contentsOf: target) == original)
        #expect(FileIdentity(url: target) == FileIdentity(url: prepared))
    }

    @Test("Unklarer Pfadstand nach dem Tausch verlangt Recovery")
    func missingInstalledPathAfterSwapRequiresRecovery() throws {
        let directory = try makeDirectory("recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let recoveryStore = testRecoveryStore(in: directory)

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: recoveryStore,
                afterSwap: { installed, _ in
                    try FileManager.default.removeItem(at: installed)
                })
            Issue.record("Der fehlende Zielpfad hätte Recovery verlangen müssen")
        } catch let failure as AtomicFileCommit.Failure {
            guard case .recoveryRequired(let reportedTarget,
                                         let reportedDisplaced) = failure else {
                Issue.record("Erwartet war recoveryRequired, erhalten: \(failure)")
                return
            }
            #expect(reportedTarget == target)
            #expect(reportedDisplaced == prepared)
        }

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: prepared) == original,
                "Der erreichbare Altstand darf bei unklarer Recovery nicht gelöscht werden")
        let pending = try recoveryStore.inspectPending()
        #expect(pending.count == 1)
        #expect(pending.first?.state == .missingTarget)
    }

    private func makeDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fastra-atomic-commit-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func writeInPlace(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor, base.advanced(by: written), rawBuffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw currentPOSIXError() }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private func fileStat(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw currentPOSIXError() }
        return info
    }

    private func testRecoveryStore(in directory: URL) -> AtomicCommitRecovery.Store {
        AtomicCommitRecovery.Store(directoryURL: directory.appendingPathComponent(
            "recovery-journal", isDirectory: true))
    }

    private func exchangeNames(target: URL, prepared: URL) throws {
        let directory = target.deletingLastPathComponent()
        let descriptor = Darwin.open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        let flags = UInt32(RENAME_SWAP)
            | UInt32(RENAME_NOFOLLOW_ANY)
            | UInt32(RENAME_RESOLVE_BENEATH)
        guard renameatx_np(
            descriptor, prepared.lastPathComponent,
            descriptor, target.lastPathComponent, flags) == 0,
              fsync(descriptor) == 0 else {
            throw currentPOSIXError()
        }
    }

    private func setExtendedAttribute(_ data: Data, named name: String,
                                      at url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw currentPOSIXError() }
    }

    private func extendedAttribute(named name: String, at url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { throw currentPOSIXError() }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard read == size else { throw currentPOSIXError() }
        return data
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
