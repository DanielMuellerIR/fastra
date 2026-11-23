import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite("Atomarer Datei-Commit")
struct AtomicFileCommitTests {
    @Test("Geerbte Allow-ACLs geben keinen Zugriff auf den privaten Cleanup-Bereich")
    func pendingCleanupRemovesInheritedAllowACLAndRejectsLaterACL() throws {
        let directory = try makeDirectory("pending-inherited-acl")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Bestehende ACL-Fixturemechanik: nur dieses eigene Tempverzeichnis
        // bekommt eine an neue Ordner vererbbare Everyone-Allow-ACL.
        func everyoneAllow(inheritable: Bool) throws -> acl_t {
            let flags = inheritable ? "allow,only_inherit,directory_inherit" : "allow"
            let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(flags):write\n"))
            do {
                var entry: acl_entry_t?
                try #require(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0)
                var permissions: acl_permset_t?
                try #require(acl_get_permset(try #require(entry), &permissions) == 0)
                let actualPermissions = try #require(permissions)
                for permission in [ACL_SEARCH, ACL_ADD_FILE, ACL_DELETE_CHILD] {
                    try #require(acl_add_perm(actualPermissions, permission) == 0)
                }
                return acl
            } catch {
                acl_free(UnsafeMutableRawPointer(acl))
                throw error
            }
        }
        let inherited = try everyoneAllow(inheritable: true)
        defer { acl_free(UnsafeMutableRawPointer(inherited)) }
        try #require(acl_set_file(directory.path, ACL_TYPE_EXTENDED, inherited) == 0)
        let control = directory.appendingPathComponent("inherited-control", isDirectory: true)
        try #require(mkdir(control.path, mode_t(0o700)) == 0)
        let controlACL = try #require(acl_get_file(control.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(controlACL)) }
        var allowedEntry: acl_entry_t?
        try #require(acl_get_entry(controlACL, Int32(ACL_FIRST_ENTRY.rawValue), &allowedEntry) == 0)
        let actualEntry = try #require(allowedEntry)
        var kind = ACL_UNDEFINED_TAG
        try #require(acl_get_tag_type(actualEntry, &kind) == 0)
        #expect(kind == ACL_EXTENDED_ALLOW)
        var permissions: acl_permset_t?
        try #require(acl_get_permset(actualEntry, &permissions) == 0)
        let actualPermissions = try #require(permissions)
        #expect(acl_get_perm_np(actualPermissions, ACL_SEARCH) == 1)
        #expect(acl_get_perm_np(actualPermissions, ACL_ADD_FILE) == 1)
        #expect(acl_get_perm_np(actualPermissions, ACL_DELETE_CHILD) == 1)
        var flags: acl_flagset_t?
        try #require(acl_get_flagset_np(UnsafeMutableRawPointer(actualEntry), &flags) == 0)
        #expect(acl_get_flag_np(try #require(flags), ACL_ENTRY_ONLY_INHERIT) == 0,
                "Die Kontroll-ACL muss anderen UIDs tatsächlich effektive Rechte geben")
        let source = directory.appendingPathComponent("prepared.tmp")
        let own = try ApplyPendingFile.prepare(Data("own".utf8), at: source)
        let work = try #require(own.cleanupDirectory)
        let descriptor = try work.openBound()
        defer { close(descriptor) }
        var info = stat()
        try #require(fstat(descriptor, &info) == 0)
        #expect(info.st_uid == getuid())
        #expect(info.st_mode & 0o777 == 0o700)
        if let actualACL = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(actualACL)) }
            var entry: acl_entry_t?
            #expect(acl_get_entry(actualACL, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1)
            #expect(errno == EINVAL)
        } else { #expect(errno == ENOENT) }
        // Bei Wiederaufnahme reicht 0700 nicht: Eine nachträglich eingetragene
        // Allow-ACL muss noch vor jedem Verschieben die Besitzgrenze schließen.
        let effective = try everyoneAllow(inheritable: false)
        defer { acl_free(UnsafeMutableRawPointer(effective)) }
        try #require(acl_set_fd_np(descriptor, effective, ACL_TYPE_EXTENDED) == 0)
        let before = try FileSnapshot.readSnapshotOnly(from: source)
        #expect(throws: AtomicFileCommit.Failure.self) { try own.remove() }
        #expect(try FileSnapshot.readSnapshotOnly(from: source) == before)
        #expect(!FileManager.default.fileExists(atPath: own.cleanupClaimURL!.path))
        let empty = try #require(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        try #require(acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0)
        try own.remove()
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: work.url.path))
        // Der Nutzordner und seine geerbte Kontroll-ACL werden nicht bereinigt.
        let stillInherited = try #require(acl_get_file(control.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(stillInherited)) }
        var stillAllowed: acl_entry_t?
        #expect(acl_get_entry(stillInherited, Int32(ACL_FIRST_ENTRY.rawValue), &stillAllowed) == 0)
    }

    @Test("Cleanup meldet Namens-/IO-Fehler statt einen vorhandenen Claim anzunehmen")
    func pendingCleanupReportsFailedSourceLookup() throws {
        let directory = try makeDirectory("pending-lookup-error")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("prepared.tmp")
        let own = try ApplyPendingFile.prepare(Data("own".utf8), at: source)
        let invalid = ApplyPendingFile(url: directory.appendingPathComponent(String(repeating: "x", count: 256)),
            snapshot: own.snapshot, cleanupDirectory: own.cleanupDirectory)
        #expect(invalid.cleanupClaimURL?.lastPathComponent == "prepared.claim")
        do {
            try invalid.remove()
            Issue.record("ENAMETOOLONG darf keinen vorhandenen Claim vortäuschen")
        } catch let error as POSIXError { #expect(error.code == .ENAMETOOLONG) }
        #expect(try FileSnapshot.readSnapshotOnly(from: source) == own.snapshot)
        #expect(!FileManager.default.fileExists(atPath: own.cleanupClaimURL!.path))
        try own.remove()
    }

    @Test("Anker-Cleanup erhält einen unterbrochenen eigenen Temp-Claim für dessen Retry")
    func pendingCleanupResumesSeparateOwnClaimsInEitherOrder() throws {
        let directory = try makeDirectory("pending-private-claim-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(".prepared.tmp")
        let file = try ApplyPendingFile.prepare(Data("own".utf8), at: source)
        let opened = try FileSnapshot.openRegularFile(at: source)
        defer { close(opened.descriptor) }
        let anchor = try ApplyPendingFile.retain(preparedURL: source,
            descriptor: opened.descriptor, snapshot: file.snapshot,
            cleanupDirectory: file.cleanupDirectory)
        let claim = try #require(file.cleanupClaimURL)
        try FileManager.default.moveItem(at: source, to: claim)
        try anchor.remove()
        #expect(try FileSnapshot.readSnapshotOnly(from: claim) == file.snapshot)
        try file.remove()
        #expect(!FileManager.default.fileExists(atPath: claim.path))
        #expect(!FileManager.default.fileExists(atPath: anchor.url.path))
        #expect(!FileManager.default.fileExists(atPath: file.cleanupDirectory!.url.path))
    }

    @Test("Cleanup bleibt am privaten FD, wenn dessen öffentlicher Ordnername ersetzt wird")
    func pendingCleanupIgnoresForeignReplacementOfWorkspaceName() throws {
        let directory = try makeDirectory("pending-private-directory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(".prepared.tmp")
        let file = try ApplyPendingFile.prepare(Data("own".utf8), at: source)
        let work = try #require(file.cleanupDirectory)
        let claim = try #require(file.cleanupClaimURL)
        let moved = directory.appendingPathComponent("moved-own-workspace", isDirectory: true)
        var foreign: FileSnapshot?
        do {
            try file.remove(afterClaim: { privateClaim in
                #expect(privateClaim == claim)
                #expect(privateClaim.deletingLastPathComponent() == work.url)
                try FileManager.default.moveItem(at: work.url, to: moved)
                try FileManager.default.createDirectory(at: work.url,
                    withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("foreign".utf8).write(to: claim)
                foreign = try FileSnapshot.readSnapshotOnly(from: claim)
            })
            Issue.record("Der ersetzte Arbeitsordner muss beim Abschluss sichtbar bleiben")
        } catch AtomicFileCommit.Failure.recoveryRequired {}
        let expectedForeign = try #require(foreign)
        #expect(try FileSnapshot.readSnapshotOnly(from: claim) == expectedForeign)
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent(claim.lastPathComponent).path),
                "Nur der über den eigenen dirFD gebundene Claim darf gelöscht werden")
        #expect(throws: AtomicFileCommit.Failure.self) { try file.remove() }
        #expect(try FileSnapshot.readSnapshotOnly(from: claim) == expectedForeign)
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test("Unbekannte Kinder im eigenen Cleanup-Bereich bleiben erhalten")
    func pendingCleanupPreservesUnknownPrivateChildren() throws {
        let directory = try makeDirectory("pending-private-unknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(".prepared.tmp")
        let file = try ApplyPendingFile.prepare(Data("own".utf8), at: source)
        let work = try #require(file.cleanupDirectory)
        let unknown = work.url.appendingPathComponent("unknown")
        try Data("foreign".utf8).write(to: unknown)
        let before = try FileSnapshot.readSnapshotOnly(from: unknown)
        #expect(throws: AtomicFileCommit.Failure.self) { try file.remove() }
        #expect(try FileSnapshot.readSnapshotOnly(from: unknown) == before)
        #expect(FileManager.default.fileExists(atPath: work.url.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Unterbrochener pending-Cleanup findet seinen privaten Claim wieder",
          arguments: [false, true])
    func pendingCleanupResumesClaimWithoutDeletingForeignObject(foreignClaim: Bool) throws {
        let directory = try makeDirectory("pending-cleanup-claim")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".own-pending.tmp")
        let owned = try ApplyPendingFile.prepare(Data("new".utf8), at: url)
        let claim = try #require(owned.cleanupClaimURL)
        try FileManager.default.moveItem(at: url, to: claim)
        if foreignClaim {
            try Data("new".utf8).write(to: claim, options: .atomic)
            let foreign = try FileSnapshot.readSnapshotOnly(from: claim)
            #expect(foreign.identity != owned.snapshot.identity)
            #expect(throws: AtomicFileCommit.Failure.self) { try owned.remove() }
            #expect(try FileSnapshot.readSnapshotOnly(from: claim) == foreign)
        } else {
            try owned.remove()
            #expect(!FileManager.default.fileExists(atPath: claim.path))
            try owned.remove()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Vorbereitungsfehler erreichen weder Retention noch Journal oder Tausch",
          arguments: [false, true])
    func preparationFailureStopsBeforeRetention(replacedPreparedFile: Bool) throws {
        let directory = try makeDirectory("preparation-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent("prepared.tmp")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let replacement = try FileSnapshot.readSnapshotOnly(from: prepared)
        if replacedPreparedFile {
            try FileManager.default.moveItem(
                at: prepared, to: directory.appendingPathComponent("original-prepared"))
            try Data("new".utf8).write(to: prepared)
        }
        let preparedBefore = try FileSnapshot.readSnapshotOnly(from: prepared)
        if replacedPreparedFile { #expect(preparedBefore.identity != replacement.identity) }
        let store = testRecoveryStore(in: directory)
        var retentionCalls = 0
        var beforeSwapCalls = 0
        var preparedReads = 0
        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target, withPreparedFile: prepared, expecting: expected,
                replacementContent: replacement, recoveryStore: store,
                retainPreparedFile: { _, _ in retentionCalls += 1 },
                beforeSwap: { _ in beforeSwapCalls += 1 },
                preparedSnapshotReader: { _, _, _ in
                    preparedReads += 1
                    throw POSIXError(.EIO)
                })
            Issue.record("Die fehlgeschlagene Vorbereitung darf keinen Commit ausführen")
        } catch AtomicFileCommit.Failure.conflictUnchanged {
            #expect(replacedPreparedFile)
        } catch let error as POSIXError {
            #expect(!replacedPreparedFile)
            #expect(error.code == .EIO)
            let context = error as NSError
            #expect(context.userInfo[NSFilePathErrorKey] as? String == prepared.path)
            #expect((context.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EIO))
            #expect(error.localizedDescription.contains(prepared.lastPathComponent))
            #expect(error.localizedDescription.contains(POSIXError(.EIO).localizedDescription))
        }
        #expect(preparedReads == (replacedPreparedFile ? 0 : 1))
        #expect(retentionCalls == 0)
        #expect(beforeSwapCalls == 0)
        #expect(try FileSnapshot.readSnapshotOnly(from: target) == expected)
        #expect(try FileSnapshot.readSnapshotOnly(from: prepared) == preparedBefore)
        #expect(try store.inspectPending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directoryURL.path),
                "Vor vollständiger Vorbereitung darf auch kein vorzeitig beendetes Journal entstehen")
    }

    @Test("Apply bindet pending vor dem Atomic-Journal an das geöffnete Ersatzobjekt")
    func pendingProofUsesBoundPreparedObject() throws {
        let directory = try makeDirectory("pending-bound-object")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent("prepared.tmp")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let store = testRecoveryStore(in: directory)
        var retained: ApplyPendingFile?
        var retainedDescriptor: Int32?
        let installed = try AtomicFileCommit.replaceExisting(
            at: target, withPreparedFile: prepared, expecting: expected,
            replacementContent: FileSnapshot(data: Data("new".utf8), identity: nil),
            recoveryStore: store,
            retainPreparedFile: { descriptor, snapshot in
                #expect(try store.inspectPending().isEmpty)
                #expect(!FileManager.default.fileExists(atPath: store.directoryURL.path))
                #expect(try FileSnapshot.readSnapshotOnly(from: target) == expected)
                retainedDescriptor = descriptor
                retained = try ApplyPendingFile.retain(preparedURL: prepared,
                    descriptor: descriptor, snapshot: snapshot)
                try retained?.synchronize()
            }, beforeSwap: { _ throws in
                #expect(retained?.isValid == true)
                #expect(retained?.snapshot == (try FileSnapshot.readSnapshotOnly(from: prepared)))
                #expect(try FileSnapshot.readSnapshotOnly(from: target) == expected)
                var info = stat()
                try #require(fstat(try #require(retainedDescriptor), &info) == 0)
                #expect(FileIdentity(stat: info) == retained?.snapshot.identity)
                let pending = try store.inspectPending()
                #expect(pending.count == 1)
                let journal = try #require(pending.first)
                #expect(journal.state == .beforeExchange)
                #expect(journal.targetURL == target)
                #expect(journal.preparedURL == prepared)
            })
        let anchor = try #require(retained)
        #expect(installed == anchor.snapshot)
        #expect(anchor.isValid)
        #expect(try FileSnapshot.readSnapshotOnly(from: target) == installed)
        #expect(try store.inspectPending().isEmpty)
        try anchor.remove()
        #expect(!FileManager.default.fileExists(atPath: anchor.url.path))
        #expect(try Data(contentsOf: target) == Data("new".utf8))
    }

    @Test("Bytegleicher Austausch der vorbereiteten Datei widerlegt die gebundene pending-Identität")
    func pendingProofRejectsChangedPreparedPath() throws {
        let directory = try makeDirectory("pending-prepared-replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent("prepared.tmp")
        let saved = directory.appendingPathComponent("saved-prepared")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        var retained: ApplyPendingFile?
        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target, withPreparedFile: prepared, expecting: expected,
                replacementContent: FileSnapshot(data: Data("new".utf8), identity: nil),
                recoveryStore: testRecoveryStore(in: directory),
                retainPreparedFile: { descriptor, snapshot in
                    retained = try ApplyPendingFile.retain(preparedURL: prepared,
                        descriptor: descriptor, snapshot: snapshot)
                    try FileManager.default.moveItem(at: prepared, to: saved)
                    try Data("new".utf8).write(to: prepared)
                })
            Issue.record("Ein fremdes Ersatzobjekt darf den gebundenen pending-Beleg nicht übernehmen")
        } catch AtomicFileCommit.Failure.conflictUnchanged {}
        let anchor = try #require(retained)
        #expect(anchor.isValid)
        #expect(try FileSnapshot.readSnapshotOnly(from: saved) == anchor.snapshot)
        #expect(try FileSnapshot.readSnapshotOnly(from: prepared).identity != anchor.snapshot.identity)
        #expect(try FileSnapshot.readSnapshotOnly(from: target) == expected)
        try anchor.remove()
    }

    @Test("Dokument-Recovery liest und bereinigt keine Nutzdateien anderer Journale")
    func documentInspectionDoesNotTouchOtherTargets() throws {
        let directory = try makeDirectory("target-filter")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = testRecoveryStore(in: directory)
        var targets: [URL] = []
        for index in 0..<2 {
            let target = directory.appendingPathComponent("target-\(index).md")
            let prepared = directory.appendingPathComponent("prepared-\(index).tmp")
            try Data("alt".utf8).write(to: target)
            try Data("neu".utf8).write(to: prepared)
            try store.begin(targetURL: target, preparedURL: prepared,
                targetStat: fileStat(target), preparedStat: fileStat(prepared),
                expectedContent: FileSnapshot.readSnapshotOnly(from: target),
                replacementContent: FileSnapshot.readSnapshotOnly(from: prepared))
            targets.append(target)
            if index == 1 { try FileManager.default.removeItem(at: prepared) }
        }
        var inspected: [URL] = []
        let pending = try store.inspectPending(for: targets[0], beforeInspectTarget: { inspected.append($0) })
        #expect(inspected == [targets[0]])
        #expect(pending.map(\.targetURL) == [targets[0]])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).filter { $0.hasSuffix(".json") }.count == 2,
                "Der erledigte fremde Eintrag wird erst bei dessen eigener Prüfung bereinigt")
    }

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
        #expect(item.concernsOpenedDocument(target))
        let copied = directory.appendingPathComponent("copy.md")
        try FileManager.default.copyItem(at: target, to: copied)
        #expect(!item.concernsOpenedDocument(copied))
        try FileManager.default.moveItem(at: target, to: directory.appendingPathComponent("moved.md"))
        try FileManager.default.copyItem(at: copied, to: target)
        let copiedAtOldPath = try #require(restartedStore.inspectPending().first)
        #expect(copiedAtOldPath.state == .changed)
        #expect(!copiedAtOldPath.concernsOpenedDocument(target))
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

    @Test("Fehlende erste Rücktauschbindung erhält beide Stände und das Journal")
    func initialRollbackBindingFailurePreservesJournal() throws {
        let directory = try makeDirectory("initial-rollback-binding")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        let tampered = Data("changed replacement with another size\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let originalIdentity = try #require(FileIdentity(url: target))
        let preparedIdentity = try #require(FileIdentity(url: prepared))
        let store = testRecoveryStore(in: directory)
        var afterSwapCalls = 0

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: store,
                beforeSwap: { _ in
                    // Ohne Retention und bekannte Ersatzidentität erreicht die
                    // Größenänderung erst die erste Bindung nach dem Swap.
                    try writeInPlace(tampered, to: prepared)
                    #expect(FileIdentity(url: prepared) == preparedIdentity)
                },
                afterSwap: { _, _ in afterSwapCalls += 1 })
            Issue.record("Die veränderte Ersatzgröße muss vor afterSwap Recovery verlangen")
        } catch let failure as AtomicFileCommit.Failure {
            guard case .recoveryRequired(let reportedTarget,
                                         let reportedDisplaced) = failure else {
                Issue.record("Erwartet war recoveryRequired, erhalten: \(failure)")
                return
            }
            #expect(reportedTarget == target)
            #expect(reportedDisplaced == prepared)
        }

        #expect(afterSwapCalls == 0)
        #expect(try Data(contentsOf: target) == tampered)
        #expect(FileIdentity(url: target) == preparedIdentity)
        #expect(try Data(contentsOf: prepared) == original)
        #expect(FileIdentity(url: prepared) == originalIdentity)
        #expect(try store.inspectPending().count == 1)
    }

    @Test("Journalfehler nach dem Cleanup lässt den erfolgreichen Commit bestehen")
    func journalFinishFailureAfterCleanupKeepsSuccessfulCommit() throws {
        let directory = try makeDirectory("journal-finish-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let movedJournalDirectory = directory.appendingPathComponent(
            "moved-recovery", isDirectory: true)
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        let blockedDirectory = Data("not a directory\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let preparedIdentity = try #require(FileIdentity(url: prepared))
        let store = testRecoveryStore(in: directory)
        let blockedJournalPath = URL(fileURLWithPath: store.directoryURL.path,
                                     isDirectory: false)
        var journalName: String?
        var journalBefore: FileSnapshot?

        let written = try AtomicFileCommit.replaceExisting(
            at: target,
            withPreparedFile: prepared,
            expecting: expected,
            replacementContent: FileSnapshot(data: replacement, identity: nil),
            recoveryStore: store,
            beforeCleanup: { _, displaced in
                #expect(try Data(contentsOf: displaced) == original)
                #expect(FileIdentity(url: displaced) == expected.identity)
                let names = try FileManager.default.contentsOfDirectory(
                    atPath: store.directoryURL.path)
                try #require(names.count == 1)
                let name = try #require(names.first)
                try #require(name.hasSuffix(".json"))
                journalName = name
                journalBefore = try FileSnapshot.readSnapshotOnly(
                    from: store.directoryURL.appendingPathComponent(name))
                // Beide Finishversuche treffen deterministisch eine Datei
                // statt des eigenen Journalordners, unabhängig von chmod/UID.
                try FileManager.default.moveItem(
                    at: store.directoryURL, to: movedJournalDirectory)
                try blockedDirectory.write(to: blockedJournalPath)
            })

        #expect(try Data(contentsOf: target) == replacement)
        #expect(FileIdentity(url: target) == preparedIdentity)
        #expect(written == FileSnapshot(data: replacement, at: target))
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        #expect(try Data(contentsOf: blockedJournalPath) == blockedDirectory)
        let name = try #require(journalName)
        let before = try #require(journalBefore)
        #expect(try FileSnapshot.readSnapshotOnly(
            from: movedJournalDirectory.appendingPathComponent(name)) == before)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: movedJournalDirectory.path) == [name])
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

    @Test("Statusänderung während der Metadatenkopie wird nur nach Inhaltsbeleg wiederholt", arguments: [0, 1, 2])
    func metadataChangeDuringCopyKeepsContentBoundary(_ change: Int) throws {
        let directory = try makeDirectory("metadata-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt"), prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8), replacement = Data("replacement\n".utf8), foreign = Data("fremder!\n".utf8)
        let attribute = "com.fastra.tests.metadata-retry"
        try original.write(to: target); try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        var copies = 0
        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target, withPreparedFile: prepared, expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil), recoveryStore: testRecoveryStore(in: directory),
                copyDisplacedMetadata: { source, destination in
                    do {
                        copies += 1
                        let result = fcopyfile(source, destination, nil, UInt32(COPYFILE_METADATA))
                        if copies == 1 || change == 1 {
                            try setExtendedAttribute(Data("Stand \(copies)".utf8), named: attribute, at: prepared)
                        }
                        if change == 2, copies == 1 {
                            let info = try fileStat(prepared)
                            try writeInPlace(foreign, to: prepared)
                            let times = [info.st_atimespec, info.st_mtimespec]
                            let descriptor = Darwin.open(prepared.path, O_RDONLY | O_CLOEXEC)
                            defer { Darwin.close(descriptor) }
                            #expect(times.withUnsafeBufferPointer { futimens(descriptor, $0.baseAddress) } == 0)
                        }
                        return result
                    } catch {
                        Issue.record("Metadaten-Fixture fehlgeschlagen: \(error)")
                        errno = EIO
                        return -1
                    }
                })
            #expect(change == 0)
        } catch let failure as AtomicFileCommit.Failure {
            #expect(change != 0, "Eine einmalige Statusänderung bei identischen Bytes darf Speichern nicht verhindern")
            if case .conflictRolledBack = failure {} else { Issue.record("Sicherer Rücktausch erwartet: \(failure)") }
        }
        #expect(copies == (change == 2 ? 1 : 2))
        #expect(try Data(contentsOf: target) == (change == 0 ? replacement : change == 2 ? foreign : original))
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        if change == 0 { #expect(try extendedAttribute(named: attribute, at: target) == Data("Stand 1".utf8)) }
        if change == 1 { #expect(try extendedAttribute(named: attribute, at: target) == Data("Stand 2".utf8)) }
    }

    @Test("Fehler vor der Nachprüfung tauscht mit der ersten gebundenen Version zurück")
    func afterSwapFailureUsesInitialRollbackVersion() throws {
        let directory = try makeDirectory("after-swap-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let expected = try FileSnapshot.readSnapshotOnly(from: target)
        let originalIdentity = try #require(FileIdentity(url: target))
        let store = testRecoveryStore(in: directory)
        var metadataCopies = 0

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: store,
                afterSwap: { installed, displaced in
                    #expect(try Data(contentsOf: installed) == replacement)
                    #expect(try Data(contentsOf: displaced) == original)
                    throw POSIXError(.EIO)
                },
                copyDisplacedMetadata: { source, destination in
                    metadataCopies += 1
                    return fcopyfile(source, destination, nil, UInt32(COPYFILE_METADATA))
                })
            Issue.record("Der Fehler vor der Nachprüfung muss gemeldet werden")
        } catch let error as POSIXError {
            #expect(error.code == .EIO)
        }

        #expect(metadataCopies == 0)
        #expect(try Data(contentsOf: target) == original)
        #expect(FileIdentity(url: target) == originalIdentity)
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        #expect(try store.inspectPending().isEmpty)
    }

    @Test("Lesefehler nach eigener Metadatenänderung schützt beide Inhaltsstände", arguments: [false, true])
    func finalReadFailureUsesCurrentRollbackVersion(_ foreignWrite: Bool) throws {
        let directory = try makeDirectory("final-read-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let prepared = directory.appendingPathComponent(".prepared.tmp")
        let original = Data("original\n".utf8), replacement = Data("replacement\n".utf8)
        let foreign = Data("FOREIGN!!!!\n".utf8)
        try original.write(to: target)
        try replacement.write(to: prepared)
        let store = testRecoveryStore(in: directory)
        var reads = 0

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target, withPreparedFile: prepared,
                expecting: FileSnapshot.readSnapshotOnly(from: target),
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: store,
                preparedSnapshotReader: { descriptor, info, limit in
                    reads += 1
                    if reads == 2 {
                        if foreignWrite {
                            // Gleiche Länge und zurückgesetzte mtime dürfen
                            // den Fremdstand beim Rücktausch nicht verbergen.
                            let count = foreign.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
                            #expect(count == foreign.count)
                            let times = [info.st_atimespec, info.st_mtimespec]
                            #expect(times.withUnsafeBufferPointer { futimens(descriptor, $0.baseAddress) } == 0)
                        }
                        throw POSIXError(.EIO)
                    }
                    return try FileSnapshot.readSnapshotOnly(descriptor: descriptor, fileStat: info, byteLimit: limit)
                })
            Issue.record("Der injizierte Lesefehler muss gemeldet werden")
        } catch let failure as AtomicFileCommit.Failure {
            #expect(foreignWrite, "Eigene Metadatenänderungen sind keine Fremdänderung: \(failure)")
            if case .recoveryRequired = failure {} else { Issue.record("Fremdstand muss erhalten bleiben") }
        } catch let error as POSIXError {
            #expect(!foreignWrite)
            #expect(error.code == .EIO)
        }
        if foreignWrite {
            #expect(try Data(contentsOf: target) == foreign)
            #expect(try Data(contentsOf: prepared) == original)
            #expect(try store.inspectPending().count == 1)
        } else {
            #expect(try Data(contentsOf: target) == original)
            #expect(!FileManager.default.fileExists(atPath: prepared.path))
            #expect(try store.inspectPending().isEmpty)
        }
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
        let store = testRecoveryStore(in: directory)

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: store,
                beforeCleanup: { _, displaced in
                    // Simulierter Fremdprozess: ersetzt den Temp-Namen genau
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
        #expect(try store.inspectPending().count == 1)
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
        let store = testRecoveryStore(in: directory)
        var displacedIdentityInHook: FileIdentity?

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
                recoveryStore: store,
                beforeCleanup: { _, displaced in
                    // Simulierter Fremdprozess mit offenem Deskriptor:
                    // schreibt in dieselbe verdrängte Inode, ohne den Namen
                    // zu ersetzen. Gerät und Inode bleiben gleich — die
                    // reine Identitätsprüfung sah darin keinen Konflikt und
                    // löschte den frischen Fremdstand mit.
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
        #expect(try store.inspectPending().count == 1)
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
        let url = testTemporaryDirectory().appendingPathComponent(
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
