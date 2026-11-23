import Darwin
import Foundation

extension FolderSearch {
    /// Die gelesene Textbasis enthält auch Dateien ohne sichtbare Treffer.
    struct SourceBasis: Equatable, Sendable {
        enum Failure: LocalizedError, Equatable {
            case changed
            case unavailable
            case limit
            case timedOut

            var errorDescription: String? {
                switch self {
                case .changed:
                    return L10n.string("Dateien oder Suchoptionen haben sich seit der sichtbaren Vorschau geändert. Starte die Suche erneut; es wurde nichts verändert.")
                case .unavailable:
                    return L10n.string("Die Suchquellen konnten nicht vollständig geprüft werden. Starte die Suche erneut. Es wurde nichts verändert.")
                case .limit:
                    return L10n.string("Die Prüfung der Suchquellen hat die Lesegrenze erreicht. Verfeinere die Suche. Es wurde nichts verändert.")
                case .timedOut:
                    return L10n.string("Die Prüfung der Suchquellen hat zu lange gedauert. Verfeinere die Suche. Es wurde nichts verändert.")
                }
            }
        }

        let selection: SourceSelection
        let textFiles: [URL: FileSnapshot]
        let scannedBytes: UInt64

        func validate(deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 60,
                      shouldCancel: @escaping @Sendable () -> Bool) throws {
            @Sendable func shouldStop() -> Bool {
                shouldCancel() || ProcessInfo.processInfo.systemUptime >= deadline
            }

            func check() throws {
                if shouldCancel() { throw CancellationError() }
                if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure.timedOut }
            }

            // Eine zusätzliche editierbare Datei darf klassifiziert werden.
            // Unbegrenzt neue Binärdateien könnten sonst den Prüflauf ausdehnen.
            var remaining = scannedBytes + FileLoader.largeFileThreshold
            var versions: [URL: stat] = [:]
            var verifiedTextCount = 0
            do {
                try selection.visitFiles(shouldCancel: shouldStop) { url in
                    try check()
                    let expected = textFiles[url]
                    let version: stat = try autoreleasepool {
                        let (descriptor, opened) = try FileSnapshot.openRegularFile(at: url)
                        defer { close(descriptor) }
                        if let expected, opened.st_size != expected.byteCount { throw Failure.changed }
                        let byteLimit = min(remaining, FileLoader.largeFileThreshold)
                        do {
                            if let expected {
                                let current = try FileSnapshot.readSnapshotOnly(
                                    descriptor: descriptor, fileStat: opened,
                                    byteLimit: byteLimit, isCancelled: shouldStop)
                                guard current == expected else { throw Failure.changed }
                                remaining -= UInt64(current.byteCount)
                                verifiedTextCount += 1
                            } else {
                                let current = try FileSnapshot.read(
                                    descriptor: descriptor, fileStat: opened,
                                    byteLimit: byteLimit, isCancelled: shouldStop)
                                remaining -= UInt64(current.snapshot.byteCount)
                                switch FolderSearch.classify(current.data) {
                                case .binary: break
                                case .text: throw Failure.changed
                                case .undecodable: throw Failure.unavailable
                                }
                            }
                        } catch FileSnapshotReadError.tooLarge {
                            throw Failure.limit
                        } catch FileSnapshotReadError.changedDuringRead {
                            throw Failure.changed
                        }
                        return opened
                    }
                    versions[url] = version
                    return true
                }
                try check()
                guard verifiedTextCount == textFiles.count else { throw Failure.changed }

                // Nach dem Lesen auch neue Pfade und einen Austausch während
                // des Lesens früher Kandidaten erkennen. Das Dateisystem bietet
                // keinen atomaren Snapshot der gesamten Auswahl.
                var candidateCount = 0
                try selection.visitFiles(shouldCancel: shouldStop) { url in
                    guard versions[url] != nil else { throw Failure.changed }
                    candidateCount += 1
                    return true
                }
                try check()
                guard candidateCount == versions.count else { throw Failure.changed }
                for (url, version) in versions {
                    try check()
                    var current = stat()
                    guard stat(url.path, &current) == 0,
                          FileSnapshot.describesSameOpenedVersion(version, current) else { throw Failure.changed }
                }
                try check()
            } catch {
                try check()
                switch error {
                case let failure as Failure: throw failure
                case SourceSelection.Failure.missingRoot: throw Failure.changed
                case RipgrepFileEnumerator.Failure.timedOut: throw Failure.timedOut
                case RipgrepFileEnumerator.Failure.outputLimit: throw Failure.limit
                default: throw Failure.unavailable
                }
            }
        }
    }
}
