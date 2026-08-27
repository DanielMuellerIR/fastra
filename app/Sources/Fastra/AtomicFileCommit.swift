// AtomicFileCommit.swift
//
// Gemeinsamer letzter Schreibschritt für Save, Apply, Undo und Hex. Darwin
// kennt kein bedingtes Rename nach dem Muster „nur wenn Ziel noch Snapshot X
// ist“. RENAME_SWAP hält den tatsächlich verdrängten Stand jedoch unter dem
// Temp-Namen fest. Fastra kann ihn deshalb nach dem atomaren Tausch prüfen und
// bei einem Konflikt zurücktauschen, solange beide Namen unverändert
// geblieben sind, statt einen unbekannten Stand blind zu löschen.

import Darwin
import Foundation

enum AtomicFileCommit {
    enum Failure: LocalizedError {
        /// Das Ziel wich schon vor dem Tausch vom erwarteten Snapshot ab.
        case conflictUnchanged
        /// Der Tausch traf einen neueren Stand; der Rücktausch war vollständig.
        case conflictRolledBack
        /// Das Volume besitzt keinen atomaren Namenstausch. Ein unsicherer
        /// Fallback würde gerade die zugesagte Fremdänderungsgrenze aufgeben.
        case unsupportedAtomicSwap
        /// Nach dem ersten Tausch hat sich einer der Namen erneut verändert.
        /// Beide erreichbaren Stände bleiben deshalb zur manuellen Klärung da.
        case recoveryRequired(target: URL, displaced: URL)

        var errorDescription: String? {
            switch self {
            case .conflictUnchanged, .conflictRolledBack:
                return L10n.string(
                    "Die Datei wurde während des Speicherns erneut geändert. Der Plattenstand blieb erhalten.")
            case .unsupportedAtomicSwap:
                return L10n.string(
                    "Der Datenträger unterstützt keinen sicheren atomaren Dateiaustausch. Die Datei wurde nicht geändert.")
            case .recoveryRequired(let target, let displaced):
                return L10n.format(
                    "Der Dateiaustausch konnte nach einer gleichzeitigen Fremdänderung nicht sicher zurückgesetzt werden. Prüfe „%@“ und „%@“; Fastra löscht in diesem Zustand keinen der beiden Pfade.",
                    target.path, displaced.path)
            }
        }

        var mustPreservePreparedPath: Bool {
            if case .recoveryRequired = self { return true }
            return false
        }
    }

    /// Tauscht eine fertig geschriebene Nachbardatei gegen ein vorhandenes
    /// Ziel. `replacementContent` beschreibt die Bytes der Nachbardatei; ihre
    /// Identität entsteht erst beim Öffnen im gebundenen Elternverzeichnis.
    /// `beforeSwap`, `afterSwap` und `beforeCleanup` sind ausschließlich
    /// deterministische Testpunkte; der Produktpfad übergibt sie nie.
    static func replaceExisting(
        at targetURL: URL,
        withPreparedFile preparedURL: URL,
        expecting expected: FileSnapshot,
        replacementContent: FileSnapshot,
        verifiedTargetStat: stat? = nil,
        beforeSwap: ((URL) throws -> Void)? = nil,
        afterSwap: ((URL, URL) throws -> Void)? = nil,
        beforeCleanup: ((URL, URL) throws -> Void)? = nil
    ) throws -> FileSnapshot {
        let targetDirectory = targetURL.deletingLastPathComponent().standardizedFileURL
        let preparedDirectory = preparedURL.deletingLastPathComponent().standardizedFileURL
        guard targetDirectory.path == preparedDirectory.path else {
            throw POSIXError(.EXDEV)
        }
        let targetName = targetURL.lastPathComponent
        let preparedName = preparedURL.lastPathComponent
        guard validChildName(targetName), validChildName(preparedName),
              targetName != preparedName else {
            throw POSIXError(.EINVAL)
        }

        let directoryFD = Darwin.open(
            targetDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(directoryFD) }

        let targetFD = openat(
            directoryFD, targetName,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard targetFD >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(targetFD) }

        let preparedFD = openat(
            directoryFD, preparedName, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard preparedFD >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(preparedFD) }

        var targetBefore = stat()
        var preparedBefore = stat()
        guard fstat(targetFD, &targetBefore) == 0,
              fstat(preparedFD, &preparedBefore) == 0 else {
            throw currentPOSIXError()
        }
        guard isRegular(targetBefore), isRegular(preparedBefore),
              targetBefore.st_dev == preparedBefore.st_dev,
              !sameIdentity(targetBefore, preparedBefore) else {
            throw POSIXError(.EINVAL)
        }

        // Der Hash entsteht am gebundenen Ziel-FD. Der Deskriptor bleibt bis
        // nach Tausch oder Rücktausch offen; ein atomarer Fremd-Replace kann
        // die geprüfte Inode deshalb nicht unter der Hand austauschen.
        if let verifiedTargetStat {
            guard sameVersion(verifiedTargetStat, targetBefore),
                  expected.identity == FileIdentity(stat: targetBefore),
                  expected.byteCount == Int(targetBefore.st_size) else {
                throw Failure.conflictUnchanged
            }
        } else {
            guard targetBefore.st_size == off_t(expected.byteCount),
                  let current = try? FileSnapshot.readSnapshotOnly(
                    descriptor: targetFD, fileStat: targetBefore,
                    byteLimit: UInt64(expected.byteCount)),
                  current == expected else {
                throw Failure.conflictUnchanged
            }
        }

        // Die neue Datei darf auch in der kurzen Zeit zwischen Tausch und
        // Nachprüfung keine großzügigeren Umask-Rechte sichtbar machen. Rechte,
        // ACLs und Extended Attributes deshalb schon jetzt übernehmen; nach
        // dem Tausch werden sie vom tatsächlich verdrängten Objekt aktualisiert.
        let preparedAccessTime = preparedBefore.st_atimespec
        let preparedModificationTime = preparedBefore.st_mtimespec
        guard fcopyfile(targetFD, preparedFD, nil,
                        UInt32(COPYFILE_METADATA)) == 0 else {
            throw currentPOSIXError()
        }
        let preparedTimes = [preparedAccessTime, preparedModificationTime]
        let restoredTimes = preparedTimes.withUnsafeBufferPointer { times in
            futimens(preparedFD, times.baseAddress)
        }
        guard restoredTimes == 0 else { throw currentPOSIXError() }
        var targetAfterMetadata = stat()
        guard fstat(targetFD, &targetAfterMetadata) == 0,
              fstat(preparedFD, &preparedBefore) == 0,
              sameVersion(targetBefore, targetAfterMetadata),
              preparedBefore.st_size == off_t(replacementContent.byteCount),
              let preparedSnapshot = try? FileSnapshot.readSnapshotOnly(
                descriptor: preparedFD, fileStat: preparedBefore,
                byteLimit: UInt64(replacementContent.byteCount)),
              preparedSnapshot.hasSameContent(as: replacementContent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try synchronizeFile(preparedFD)

        try beforeSwap?(targetURL)

        let flags = UInt32(RENAME_SWAP)
            | UInt32(RENAME_NOFOLLOW_ANY)
            | UInt32(RENAME_RESOLVE_BENEATH)
        guard renameatx_np(directoryFD, preparedName,
                           directoryFD, targetName, flags) == 0 else {
            if errno == ENOTSUP || errno == EINVAL || errno == ENOSYS {
                throw Failure.unsupportedAtomicSwap
            }
            throw currentPOSIXError()
        }
        // Der erste Tausch muss dauerhaft sein, bevor der verdrängte Name
        // später verschwindet. Der langsame Sync liegt bewusst VOR der letzten
        // Identitätsprüfung, damit danach kein breites Unlink-Rennfenster bleibt.
        guard fsync(directoryFD) == 0 else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }

        // Nach `rename` besitzt unsere vorbereitete Inode eine neue ctime.
        // Diesen unveränderten Stand binden wir VOR dem Test-Hook. Er ist die
        // einzige sichere Rücktauschbasis; eine spätere Momentaufnahme könnte
        // bereits die Version eines gleichzeitigen Fremd-Writes festhalten.
        var preparedRollbackVersion = stat()
        do {
            guard fstat(preparedFD, &preparedRollbackVersion) == 0 else {
                throw currentPOSIXError()
            }
            let preparedAtPath = try childStat(directoryFD, targetName)
            let installedSnapshot = try FileSnapshot.readSnapshotOnly(
                descriptor: preparedFD, fileStat: preparedRollbackVersion,
                byteLimit: UInt64(replacementContent.byteCount))
            guard sameIdentity(preparedAtPath, preparedRollbackVersion),
                  sameVersion(preparedAtPath, preparedRollbackVersion),
                  sameVersionAcrossRename(preparedBefore, preparedRollbackVersion),
                  installedSnapshot.hasSameContent(as: replacementContent) else {
                throw Failure.recoveryRequired(target: targetURL,
                                               displaced: preparedURL)
            }
        } catch {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        var canRollbackPrepared = true

        // Ab hier enthält der Temp-Name den tatsächlich verdrängten Zielstand.
        // Jede Validierungs- oder Metadatenpanne versucht zuerst den gebundenen
        // Rücktausch. Nur wenn dessen Vorbedingungen nicht mehr gelten, müssen
        // beide erreichbaren Pfade für die manuelle Klärung bestehen bleiben.
        do {
            try afterSwap?(targetURL, preparedURL)
            var preparedAfterSwap = stat()
            var displacedAfterSwap = stat()
            guard fstat(preparedFD, &preparedAfterSwap) == 0,
                  fstat(targetFD, &displacedAfterSwap) == 0 else {
                throw currentPOSIXError()
            }
            let targetAtPath = try childStat(directoryFD, targetName)
            let displacedAtPath = try childStat(directoryFD, preparedName)

            let installedPrepared = sameIdentity(targetAtPath, preparedAfterSwap)
                && sameVersion(preparedRollbackVersion, preparedAfterSwap)
                && sameVersion(targetAtPath, preparedAfterSwap)
            let displacedWasExpected = sameIdentity(displacedAtPath, targetBefore)
                && sameIdentity(displacedAtPath, displacedAfterSwap)

            guard installedPrepared, displacedWasExpected else {
                throw Failure.conflictRolledBack
            }

            // Metadaten erst vom TATSÄCHLICH verdrängten Dateiobjekt
            // übernehmen. Eine ACL-/Xattr-Änderung vor dem Tausch geht damit
            // nicht aufgrund eines früheren Kopierzeitpunkts verloren.
            let displacedBeforeMetadata = displacedAfterSwap
            // `fcopyfile` kann Metadaten teilweise schreiben und dann
            // scheitern. Während dieses Fensters gibt es keine belegte eigene
            // Version, die Fastra gefahrlos zurücktauschen und löschen dürfte.
            canRollbackPrepared = false
            guard fcopyfile(targetFD, preparedFD, nil,
                            UInt32(COPYFILE_METADATA)) == 0 else {
                throw currentPOSIXError()
            }
            let refreshedTimes = [preparedAccessTime, preparedModificationTime]
            let restoredTimes = refreshedTimes.withUnsafeBufferPointer { times in
                futimens(preparedFD, times.baseAddress)
            }
            guard restoredTimes == 0 else { throw currentPOSIXError() }
            try synchronizeFile(preparedFD)

            var displacedAfterMetadata = stat()
            var preparedAfterMetadata = stat()
            guard fstat(targetFD, &displacedAfterMetadata) == 0,
                  fstat(preparedFD, &preparedAfterMetadata) == 0,
                  sameVersion(displacedBeforeMetadata, displacedAfterMetadata),
                  isRegular(preparedAfterMetadata),
                  preparedAfterMetadata.st_size
                    == off_t(replacementContent.byteCount) else {
                throw Failure.conflictRolledBack
            }

            // Beide Inhalte werden am weiterhin gebundenen Deskriptor erneut
            // gehasht. So reicht weder ein zurückgesetztes mtime noch eine
            // gleich große Manipulation der Temp-Datei zum Durchrutschen.
            let displacedSnapshot = try FileSnapshot.readSnapshotOnly(
                descriptor: targetFD, fileStat: displacedAfterMetadata,
                byteLimit: UInt64(expected.byteCount))
            let installedSnapshot = try FileSnapshot.readSnapshotOnly(
                descriptor: preparedFD, fileStat: preparedAfterMetadata,
                byteLimit: UInt64(replacementContent.byteCount))
            guard installedSnapshot.hasSameContent(as: replacementContent) else {
                throw Failure.conflictRolledBack
            }
            preparedRollbackVersion = preparedAfterMetadata
            canRollbackPrepared = true
            guard displacedSnapshot == expected else {
                throw Failure.conflictRolledBack
            }

            var displacedFinal = stat()
            var preparedFinal = stat()
            let displacedPathFinal = try childStat(directoryFD, preparedName)
            let targetPathFinal = try childStat(directoryFD, targetName)
            guard fstat(targetFD, &displacedFinal) == 0,
                  fstat(preparedFD, &preparedFinal) == 0,
                  sameVersion(displacedAfterMetadata, displacedFinal),
                  sameVersion(preparedAfterMetadata, preparedFinal),
                  sameVersion(displacedPathFinal, displacedFinal),
                  sameVersion(targetPathFinal, preparedFinal) else {
                throw Failure.conflictRolledBack
            }

            // Erst nach belegtem Erfolg verschwindet die alte Fassung — und
            // auch dann nur, wenn der Temp-Name nachweislich noch auf die am
            // Deskriptor verifizierte verdrängte Inode zeigt (siehe
            // `unlinkVerifiedChild`). Ein im letzten Moment fremd ersetzter
            // Stand bleibt erhalten und wird als Recovery gemeldet.
            try beforeCleanup?(targetURL, preparedURL)
            try unlinkVerifiedChild(
                directoryFD: directoryFD, name: preparedName,
                verifiedFD: targetFD,
                targetURL: targetURL, preparedURL: preparedURL)
            _ = fsync(directoryFD)
            return FileSnapshot(
                sha256: replacementContent.sha256,
                byteCount: replacementContent.byteCount,
                identity: FileIdentity(stat: preparedFinal))
        } catch let failure as Failure {
            if case .recoveryRequired = failure { throw failure }
            guard canRollbackPrepared else {
                throw Failure.recoveryRequired(target: targetURL,
                                               displaced: preparedURL)
            }
            do {
                try rollbackSwap(
                    directoryFD: directoryFD,
                    targetName: targetName,
                    preparedName: preparedName,
                    preparedFD: preparedFD,
                    expectedPreparedVersion: preparedRollbackVersion,
                    replacementContent: replacementContent,
                    flags: flags,
                    targetURL: targetURL,
                    preparedURL: preparedURL)
            } catch let recovery as Failure {
                throw recovery
            }
            throw failure
        } catch {
            guard canRollbackPrepared else {
                throw Failure.recoveryRequired(target: targetURL,
                                               displaced: preparedURL)
            }
            do {
                try rollbackSwap(
                    directoryFD: directoryFD,
                    targetName: targetName,
                    preparedName: preparedName,
                    preparedFD: preparedFD,
                    expectedPreparedVersion: preparedRollbackVersion,
                    replacementContent: replacementContent,
                    flags: flags,
                    targetURL: targetURL,
                    preparedURL: preparedURL)
            } catch let recovery as Failure {
                throw recovery
            }
            throw error
        }
    }

    private static func rollbackSwap(
        directoryFD: Int32,
        targetName: String,
        preparedName: String,
        preparedFD: Int32,
        expectedPreparedVersion: stat,
        replacementContent: FileSnapshot,
        flags: UInt32,
        targetURL: URL,
        preparedURL: URL
    ) throws {
        var preparedVersion = stat()
        guard fstat(preparedFD, &preparedVersion) == 0,
              sameVersion(expectedPreparedVersion, preparedVersion),
              preparedVersion.st_size == off_t(replacementContent.byteCount),
              let preparedSnapshot = try? FileSnapshot.readSnapshotOnly(
                descriptor: preparedFD, fileStat: preparedVersion,
                byteLimit: UInt64(replacementContent.byteCount)),
              preparedSnapshot.hasSameContent(as: replacementContent) else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        let displacedFD = openat(
            directoryFD, preparedName,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard displacedFD >= 0 else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        defer { Darwin.close(displacedFD) }
        var displacedVersion = stat()
        guard fstat(displacedFD, &displacedVersion) == 0,
              isRegular(displacedVersion) else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        let targetNow: stat
        let displacedNow: stat
        do {
            targetNow = try childStat(directoryFD, targetName)
            displacedNow = try childStat(directoryFD, preparedName)
        } catch {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        guard sameIdentity(targetNow, preparedVersion),
              sameVersion(preparedVersion, targetNow),
              sameIdentity(displacedNow, displacedVersion),
              sameVersion(displacedVersion, displacedNow),
              !sameIdentity(preparedVersion, displacedVersion),
              renameatx_np(directoryFD, preparedName,
                           directoryFD, targetName, flags) == 0 else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        // Erst den Rücktausch dauerhaft machen, dann die Namen NOCHMALS
        // prüfen. So liegt kein langsamer Sync mehr zwischen der letzten
        // Bindungsprüfung und dem Löschen unserer vorbereiteten Inode.
        guard fsync(directoryFD) == 0 else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }

        let restoredTarget: stat
        let restoredPrepared: stat
        do {
            restoredTarget = try childStat(directoryFD, targetName)
            restoredPrepared = try childStat(directoryFD, preparedName)
        } catch {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        var preparedAfterRollback = stat()
        guard fstat(preparedFD, &preparedAfterRollback) == 0,
              sameIdentity(restoredTarget, displacedVersion),
              sameVersionAcrossRename(displacedVersion, restoredTarget),
              sameIdentity(restoredPrepared, preparedAfterRollback),
              sameVersionAcrossRename(expectedPreparedVersion,
                                      preparedAfterRollback) else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        // `sameVersionAcrossRename` blendet die vom Rücktausch selbst
        // geänderte ctime bewusst aus; ein Fremd-Write über einen offenen
        // Deskriptor mit zurückgesetzter mtime wäre daran nicht erkennbar.
        // Deshalb wird der Inhalt der eigenen Ersatz-Inode nach dem
        // Rücktausch am weiterhin gebundenen Deskriptor erneut gehasht,
        // bevor ihr Name verschwindet.
        guard let rolledBackSnapshot = try? FileSnapshot.readSnapshotOnly(
                descriptor: preparedFD, fileStat: preparedAfterRollback,
                byteLimit: UInt64(replacementContent.byteCount)),
              rolledBackSnapshot.hasSameContent(as: replacementContent) else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        try unlinkVerifiedChild(
            directoryFD: directoryFD, name: preparedName,
            verifiedFD: preparedFD,
            targetURL: targetURL, preparedURL: preparedURL)
        guard fsync(directoryFD) == 0 else { throw currentPOSIXError() }
    }

    /// Löscht den Verzeichniseintrag `name` nur, wenn er nachweislich auf die
    /// bereits am Deskriptor `verifiedFD` verifizierte Inode zeigt. POSIX
    /// kennt kein „unlink genau diese Inode": Ein bloßes fstatat-plus-unlinkat
    /// ließe ein Fenster, in dem ein Fremdprozess den Namen ersetzt und sein
    /// Stand mitgelöscht würde. Deshalb beansprucht zuerst ein atomares
    /// Rename den Eintrag unter einem zufälligen privaten Namen; DANACH wird
    /// die Bindung geprüft: Zeigt der beanspruchte Eintrag auf die
    /// verifizierte Inode, wird der private Name gelöscht. Zeigt er auf einen
    /// Fremdstand, wird dieser unter seinem ursprünglichen Namen
    /// zurückgestellt (oder, falls der schon neu belegt ist, unter dem
    /// privaten Namen erhalten) und `recoveryRequired` gemeldet.
    ///
    /// Ehrliche Restgrenze: Zwischen Prüfung und Löschen des PRIVATEN Namens
    /// bleibt ein theoretisches Fenster. Es ist aber nur für einen Prozess
    /// erreichbar, der das Verzeichnis aktiv nach dem zufälligen Namen
    /// absucht und ihn gezielt ersetzt — kein regulär gleichzeitig
    /// schreibender Prozess verwendet diesen Namen.
    private static func unlinkVerifiedChild(
        directoryFD: Int32,
        name: String,
        verifiedFD: Int32,
        targetURL: URL,
        preparedURL: URL
    ) throws {
        var verified = stat()
        guard fstat(verifiedFD, &verified) == 0 else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        let claimName = ".fastra-cleanup-" + UUID().uuidString
        // `RENAME_EXCL`: Der private Name darf nichts überschreiben.
        let claimFlags = UInt32(RENAME_EXCL)
            | UInt32(RENAME_NOFOLLOW_ANY)
            | UInt32(RENAME_RESOLVE_BENEATH)
        guard renameatx_np(directoryFD, name,
                           directoryFD, claimName, claimFlags) == 0 else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        let claimed: stat
        do {
            claimed = try childStat(directoryFD, claimName)
        } catch {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        let claimURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(claimName)
        guard sameIdentity(claimed, verified) else {
            // Ein Fremdprozess hat den Namen im letzten Moment ersetzt: Sein
            // Stand wird zurückgestellt statt gelöscht. Schlägt auch das
            // fehl (Name inzwischen neu belegt), bleibt er unter dem
            // privaten Namen erreichbar und wird im Fehler benannt.
            guard renameatx_np(directoryFD, claimName,
                               directoryFD, name, claimFlags) == 0 else {
                throw Failure.recoveryRequired(target: targetURL,
                                               displaced: claimURL)
            }
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: preparedURL)
        }
        guard unlinkat(directoryFD, claimName, 0) == 0 else {
            throw Failure.recoveryRequired(target: targetURL,
                                           displaced: claimURL)
        }
    }

    private static func childStat(_ directoryFD: Int32,
                                  _ name: String) throws -> stat {
        var info = stat()
        let result = name.withCString {
            fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw currentPOSIXError() }
        return info
    }

    private static func synchronizeFile(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let fullSyncError = errno
        guard fullSyncError == ENOTSUP || fullSyncError == EINVAL
                || fullSyncError == ENOTTY else {
            throw POSIXError(POSIXErrorCode(rawValue: fullSyncError) ?? .EIO)
        }
        guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        sameVersionAcrossRename(lhs, rhs)
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Rename ändert ctime selbst. Inhalt und alle übrigen für einen
    /// normalen Fremd-Write relevanten Felder müssen dagegen gleich bleiben.
    private static func sameVersionAcrossRename(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_flags == rhs.st_flags
    }

    private static func isRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
