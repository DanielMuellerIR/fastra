import Foundation
import Darwin
import Testing
@testable import Fastra

@Suite("Vollständige POSIX-Pufferschreibvorgänge")
struct POSIXBufferWriterTests {
    @Test("Kurze Writes und EINTR übertragen jedes Byte genau einmal")
    func shortWrites() throws {
        let source: [UInt8] = [11, 22, 33, 44, 55, 66]
        var sink = ScriptedSink([.bytes(2), .failure(EINTR), .bytes(1), .bytes(3)])

        try source.withUnsafeBytes { bytes in
            try POSIXBufferWriter.writeAll(bytes, to: 47, write: { sink.write($0, $1, $2) })
        }

        #expect(sink.output == source)
        #expect(sink.descriptors == [47, 47, 47, 47])
        #expect(sink.offered == [source, [33, 44, 55, 66], [33, 44, 55, 66], [44, 55, 66]])
        #expect(sink.offsets == [0, 2, 2, 3])
        #expect(sink.counts == [6, 4, 4, 3])
    }

    @Test("EINTR wiederholt denselben vollständigen Rest und kann danach gelingen")
    func interruptedThenSuccessful() throws {
        let source: [UInt8] = [7, 8, 9]
        var sink = ScriptedSink([.failure(EINTR), .bytes(3)])

        try source.withUnsafeBytes { bytes in
            try POSIXBufferWriter.writeAll(bytes, to: 47, write: { sink.write($0, $1, $2) })
        }

        #expect(sink.output == source)
        #expect(sink.offered == [source, source])
        #expect(sink.offsets == [0, 0])
        #expect(sink.counts == [3, 3])
    }

    @Test("Ein leerer Puffer ruft den Writer nicht auf")
    func emptyBuffer() throws {
        var sink = ScriptedSink([])
        try POSIXBufferWriter.writeAll(
            UnsafeRawBufferPointer(start: nil, count: 0), to: 47,
            write: { sink.write($0, $1, $2) })

        #expect(sink.output.isEmpty)
        #expect(sink.offered.isEmpty)
        #expect(sink.counts.isEmpty)
    }

    @Test("Nullfortschritt meldet trotz altem EINTR sofort EIO")
    func zeroProgressIgnoresOldErrno() throws {
        let source: [UInt8] = [1, 2, 3]
        var sink = ScriptedSink([.failure(EINTR), .zeroWithStaleErrno(EINTR)])
        var mappedCodes: [Int32] = []

        #expect(throws: POSIXError(.EIO)) {
            try source.withUnsafeBytes { bytes in
                try POSIXBufferWriter.writeAll(bytes, to: 47, makeError: {
                    mappedCodes.append($0)
                    return NSError(domain: NSPOSIXErrorDomain, code: Int($0))
                }, write: { sink.write($0, $1, $2) })
            }
        }

        #expect(mappedCodes.isEmpty)
        #expect(sink.output.isEmpty)
        #expect(sink.offered == [source, source])
        #expect(sink.offsets == [0, 0])
        #expect(sink.counts == [3, 3])
    }

    @Test("Ein echter Fehler nach einem Präfix bleibt erhalten und beendet die Writes")
    func failureAfterPrefix() throws {
        let source: [UInt8] = [10, 20, 30, 40, 50]
        var sink = ScriptedSink([.bytes(2), .failure(ENOSPC)])

        #expect(throws: POSIXError(.ENOSPC)) {
            try source.withUnsafeBytes { bytes in
                try POSIXBufferWriter.writeAll(bytes, to: 47, write: { sink.write($0, $1, $2) })
            }
        }

        #expect(sink.output == [10, 20])
        #expect(sink.offered == [source, [30, 40, 50]])
        #expect(sink.offsets == [0, 2])
        #expect(sink.counts == [5, 3])
    }

    @Test("Die Fehlerabbildung erhält den gesicherten errno auch außerhalb von POSIXErrorCode")
    func preservesCallerErrorRepresentation() throws {
        let source: [UInt8] = [91]
        let code: Int32 = 32_767
        var sink = ScriptedSink([.failure(code)])
        var mappedCodes: [Int32] = []

        do {
            try source.withUnsafeBytes { bytes in
                try POSIXBufferWriter.writeAll(bytes, to: 47, makeError: { savedCode in
                    mappedCodes.append(savedCode)
                    errno = EINVAL
                    return NSError(domain: NSPOSIXErrorDomain, code: Int(savedCode))
                }, write: { sink.write($0, $1, $2) })
            }
            Issue.record("Der negative Write muss einen Fehler liefern")
        } catch {
            #expect((error as NSError).domain == NSPOSIXErrorDomain)
            #expect((error as NSError).code == Int(code))
        }

        #expect(mappedCodes == [code])
        #expect(sink.output.isEmpty)
        #expect(sink.offered == [source])
    }
}

private struct ScriptedSink {
    enum Response {
        case bytes(Int)
        case failure(Int32)
        case zeroWithStaleErrno(Int32)
    }

    let responses: [Response]
    var output: [UInt8] = []
    var offered: [[UInt8]] = []
    var descriptors: [Int32] = []
    var offsets: [Int] = []
    var counts: [Int] = []
    private var baseAddress: UnsafeRawPointer?

    init(_ responses: [Response]) {
        self.responses = responses
    }

    mutating func write(_ descriptor: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        let call = offered.count
        if baseAddress == nil { baseAddress = pointer }
        descriptors.append(descriptor)
        offsets.append(baseAddress!.distance(to: pointer))
        counts.append(count)
        let bytes = Array(UnsafeRawBufferPointer(start: pointer, count: count))
        offered.append(bytes)
        guard call < responses.count else {
            Issue.record("Unerwarteter zusätzlicher Write")
            errno = EIO
            return -1
        }
        switch responses[call] {
        case .bytes(let accepted):
            precondition(accepted <= count)
            output.append(contentsOf: bytes.prefix(accepted))
            return accepted
        case .failure(let code):
            errno = code
            return -1
        case .zeroWithStaleErrno(let code):
            errno = code
            return 0
        }
    }
}
