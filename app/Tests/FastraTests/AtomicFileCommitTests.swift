import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite("Atomarer Datei-Commit")
struct AtomicFileCommitTests {
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
                replacementContent: FileSnapshot(data: original, identity: nil))
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

        do {
            _ = try AtomicFileCommit.replaceExisting(
                at: target,
                withPreparedFile: prepared,
                expecting: expected,
                replacementContent: FileSnapshot(data: replacement, identity: nil),
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
