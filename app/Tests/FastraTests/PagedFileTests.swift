import Darwin
import Foundation
import Testing
@testable import Fastra

private let textPageSize = 256 * 1024

/// Steuert drei Reader-Aufrufe ohne Zeitraten: Der erste Aufruf für Seite 0
/// bleibt stehen, bis ein neuerer Seite-0-Aufruf sein Ergebnis veröffentlicht
/// hat. So bildet der Test die Folge 0 → 1 → 0 deterministisch nach.
private final class SequencedPageReader: @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let thirdStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var invocation = 0

    func read(url: URL, offset: UInt64, count: Int) throws -> Data {
        lock.lock()
        invocation += 1
        let current = invocation
        lock.unlock()
        switch current {
        case 1:
            firstStarted.signal()
            releaseFirst.wait()
            firstFinished.signal()
            return Data(repeating: 0x11, count: count)
        case 2:
            secondStarted.signal()
            return Data(repeating: 0x22, count: count)
        default:
            thirdStarted.signal()
            return Data(repeating: 0x33, count: count)
        }
    }
}

/// Reader, dessen zweite Anfrage blockiert, bis der Test sie freigibt — für
/// die Prüfung des Zwischenzustands während eines langsamen Seitenwechsels.
private final class GateablePageReader: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var invocation = 0

    func read(url: URL, offset: UInt64, count: Int) throws -> Data {
        lock.lock()
        invocation += 1
        let current = invocation
        lock.unlock()
        if current == 1 { return Data(repeating: 0xAA, count: count) }
        release.wait()
        return Data(repeating: 0xBB, count: count)
    }
}

/// Reader, der ab der zweiten Anfrage nur noch Fehler liefert — für die
/// Prüfung des Fehlerwegs beim Seitenwechsel.
private final class FailingSecondPageReader: @unchecked Sendable {
    private let lock = NSLock()
    private var invocation = 0

    func read(url: URL, offset: UInt64, count: Int) throws -> Data {
        lock.lock()
        invocation += 1
        let current = invocation
        lock.unlock()
        if current == 1 { return Data(repeating: 0xAA, count: count) }
        throw CocoaError(.fileReadUnknown)
    }
}

private func temporaryPageFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-text-page-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}

private func decodedPages(url: URL, data: Data, encoding: String.Encoding,
                          bom: Data) throws -> [DecodedTextFilePage] {
    let count = TextFilePageReader.pageCount(
        totalBytes: UInt64(data.count), bomCount: bom.count, pageSize: textPageSize)
    return try (0..<count).map {
        try TextFilePageReader.read(
            url: url, totalBytes: UInt64(data.count), pageSize: textPageSize,
            pageIndex: $0, encoding: encoding, bom: bom
        )
    }
}

private func writeLargeUTF16File(encoding: String.Encoding, bom: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-large-utf16-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: url.path, contents: bom)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    let chunk = try #require("Zeile äöü 😀 — sicherer Abschnitt\n".data(using: encoding))
    let target = FileLoader.largeFileThreshold + UInt64(textPageSize) + 8192
    var written = UInt64(bom.count)
    while written <= target {
        try handle.write(contentsOf: chunk)
        written += UInt64(chunk.count)
    }
    return url
}

@Suite("Hex- und Abschnittsansicht")
struct PagedFileTests {
    @Test("Byte- und Textseiten weisen FIFO ab, statt beim Öffnen zu blockieren")
    func pageReadersRejectFIFO() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-page-fifo-\(UUID().uuidString)")
        #expect(mkfifo(url.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: FileSnapshotReadError.self) {
            try FilePageReader.read(url: url, offset: 0, count: 16)
        }
        #expect(throws: FileSnapshotReadError.self) {
            try TextFilePageReader.read(
                url: url, totalBytes: 16, pageSize: 16,
                pageIndex: 0, encoding: .utf8, bom: Data())
        }
    }

    @Test("Späte Antwort einer alten Seite überschreibt keinen neuen 0-1-0-Lauf")
    @MainActor
    func staleSamePageResultIsIgnored() async throws {
        let reader = SequencedPageReader()
        let model = FilePageModel(
            url: URL(fileURLWithPath: "/tmp/fastra-controlled-page"),
            totalBytes: 8, pageSize: 4, reader: reader.read)
        #expect(reader.firstStarted.wait(timeout: .now() + 5) == .success)

        model.load(page: 1)
        #expect(reader.secondStarted.wait(timeout: .now() + 5) == .success)
        model.load(page: 0)
        #expect(reader.thirdStarted.wait(timeout: .now() + 5) == .success)

        for _ in 0..<100 where model.data != Data(repeating: 0x33, count: 4) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.data == Data(repeating: 0x33, count: 4))

        reader.releaseFirst.signal()
        #expect(reader.firstFinished.wait(timeout: .now() + 5) == .success)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.data == Data(repeating: 0x33, count: 4))
    }

    @Test("Seitenmodell lädt nur die angeforderte Byte-Seite")
    @MainActor
    func loadsRequestedPage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-page-\(UUID().uuidString)")
        let bytes = Data(0..<32)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = FilePageModel(url: url, totalBytes: 32, pageSize: 8)
        model.load(page: 2)
        for _ in 0..<50 where model.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.pageCount == 4)
        #expect(model.offset == 16)
        #expect(model.data == Data(16..<24))
    }

    @Test("Auch eine inhaltsgleiche Nachbarseite meldet einen abgeschlossenen Ladevorgang")
    @MainActor
    func identicalNeighborPageCompletesLoad() async throws {
        // Datei aus lauter Nullbytes: Zwei Nachbarseiten sind byteidentisch,
        // `data` ändert sich beim Wechsel also nicht. Der Drucksnapshot der
        // Hex-Ansicht hängt deshalb am Ladezähler statt an einer
        // Datenänderung — sonst behielte er die alten Basisadressen
        // (Reviewfund 2026-08-18).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-zero-page-\(UUID().uuidString)")
        try Data(repeating: 0, count: 16).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = FilePageModel(url: url, totalBytes: 16, pageSize: 8)
        for _ in 0..<100 where model.completedLoadCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.completedLoadCount == 1)
        let firstPage = model.data

        model.load(page: 1)
        for _ in 0..<100 where model.completedLoadCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.completedLoadCount == 2)
        #expect(model.offset == 8)
        // Inhaltsgleich — und trotzdem als Abschluss gemeldet.
        #expect(model.data == firstPage)
    }

    @Test("Ein fehlgeschlagener Seitenwechsel leert die alten Bytes")
    @MainActor
    func failedLoadClearsData() async throws {
        let reader = FailingSecondPageReader()
        let model = FilePageModel(
            url: URL(fileURLWithPath: "/tmp/fastra-failing-page"),
            totalBytes: 8, pageSize: 4, reader: reader.read)
        for _ in 0..<100 where model.completedLoadCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.data == Data(repeating: 0xAA, count: 4))

        model.load(page: 1)
        for _ in 0..<100 where model.completedLoadCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.errorMessage != nil)
        // Die alten Bytes gehören zur VORIGEN Seite. Blieben sie stehen,
        // zeigte die Ansicht den Fehler, aber „Drucken" gäbe weiter den alten
        // Abschnitt aus (Reviewfund 2026-08-18).
        #expect(model.data.isEmpty)
    }

    @Test("Ein langsamer Seitenwechsel lässt keine alten Bytes unter neuen Adressen stehen")
    @MainActor
    func slowPageSwitchExposesNoStaleBytes() async throws {
        let reader = GateablePageReader()
        let model = FilePageModel(
            url: URL(fileURLWithPath: "/tmp/fastra-slow-page"),
            totalBytes: 8, pageSize: 4, reader: reader.read)
        for _ in 0..<100 where model.completedLoadCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.data == Data(repeating: 0xAA, count: 4))

        // Der Wechsel auf Seite 1 bleibt im blockierten Reader stehen. Das
        // Modell zeigt ab SOFORT den neuen Offset — die alten Bytes müssen
        // deshalb sofort weg sein: Sonst berechnete `editableRow` Adressen
        // der neuen Seite über Bytes der alten, und eine Bearbeitung in
        // diesem Fenster plante eine Änderung am falschen Offset mit dem
        // falschen Altwert (Reviewfund 2026-08-19).
        model.load(page: 1)
        #expect(model.pageIndex == 1)
        #expect(model.isLoading)
        #expect(model.data.isEmpty)

        // Ein Bearbeitungsversuch in genau diesem Zwischenzustand findet
        // keine Zeile vor und plant keine Änderung.
        var edits = HexEditSession()
        #expect(edits.textForRow(data: model.data, baseOffset: model.offset,
                                 row: 0) == "")
        edits.editRow("FF", data: model.data, baseOffset: model.offset, row: 0)
        #expect(edits.changes.isEmpty)

        reader.release.signal()
        for _ in 0..<100 where model.completedLoadCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.data == Data(repeating: 0xBB, count: 4))
    }

    @Test("UTF-8-Seiten teilen kein Mehrbytezeichen an der 256-KiB-Grenze")
    func utf8BoundariesAreScalarSafe() throws {
        var payload = Data(repeating: 0x61, count: textPageSize - 1)
        payload.append(try #require("😀".data(using: .utf8)))
        payload.append(Data(repeating: 0x62, count: textPageSize - 3))
        payload.append(try #require("ä Ende".data(using: .utf8)))
        let bom = Data([0xEF, 0xBB, 0xBF])
        var file = bom
        file.append(payload)
        let url = try temporaryPageFile(file)
        defer { try? FileManager.default.removeItem(at: url) }

        let pages = try decodedPages(url: url, data: file, encoding: .utf8, bom: bom)
        let expected = try #require(String(data: payload, encoding: .utf8))
        #expect(pages.map(\.text).joined() == expected)
        #expect(pages[0].fileRange.upperBound == pages[1].fileRange.lowerBound)
        #expect(pages.first?.fileRange.lowerBound == UInt64(bom.count))
        #expect(pages.last?.fileRange.upperBound == UInt64(file.count))
        #expect(pages.allSatisfy { !$0.text.contains("\u{FFFD}") && !$0.text.contains("\0") })
    }

    @Test("Ungültige UTF-8-Seite erzeugt keinen Ersatztext")
    func invalidUTF8FailsInsteadOfReplacing() throws {
        var data = Data(repeating: 0x61, count: textPageSize - 2)
        data.append(contentsOf: [0xF0, 0x80, 0x80, 0x80])
        let url = try temporaryPageFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try TextFilePageReader.read(
                url: url, totalBytes: UInt64(data.count), pageSize: textPageSize,
                pageIndex: 1, encoding: .utf8, bom: Data()
            )
        }
    }

    @Test("UTF-16 LE/BE-Seiten halten Codeunits und Surrogatpaare zusammen")
    func utf16BoundariesAreCodeUnitSafe() throws {
        let prefix = String(repeating: "A", count: textPageSize / 2 - 1)
        let text = prefix + "😀" + String(repeating: "B", count: textPageSize / 2) + " Ende"
        let variants: [(String.Encoding, Data)] = [
            (.utf16LittleEndian, Data()),
            (.utf16LittleEndian, Data([0xFF, 0xFE])),
            (.utf16BigEndian, Data()),
            (.utf16BigEndian, Data([0xFE, 0xFF]))
        ]
        for (encoding, bom) in variants {
            var file = bom
            file.append(try #require(text.data(using: encoding)))
            let url = try temporaryPageFile(file)
            let pages = try decodedPages(url: url, data: file,
                                         encoding: encoding, bom: bom)
            try? FileManager.default.removeItem(at: url)

            #expect(pages.map(\.text).joined() == text)
            #expect(pages.first?.fileRange.lowerBound == UInt64(bom.count))
            #expect(pages.last?.fileRange.upperBound == UInt64(file.count))
            for pair in zip(pages, pages.dropFirst()) {
                #expect(pair.0.fileRange.upperBound == pair.1.fileRange.lowerBound)
            }
            #expect(pages.allSatisfy {
                !$0.text.contains("\u{FFFD}") && !$0.text.contains("\0")
            })
        }
    }

    @Test("UTF-32 LE/BE-Seiten bleiben an Vierbyte-Codeunits ausgerichtet")
    func utf32BoundariesAreCodeUnitSafe() throws {
        let text = String(repeating: "A", count: textPageSize / 4 - 1)
            + "😀" + String(repeating: "B", count: textPageSize / 4) + " Ende"
        let variants: [(String.Encoding, Data)] = [
            (.utf32LittleEndian, Data([0xFF, 0xFE, 0x00, 0x00])),
            (.utf32BigEndian, Data([0x00, 0x00, 0xFE, 0xFF])),
        ]
        for (encoding, bom) in variants {
            var file = bom
            file.append(try #require(text.data(using: encoding)))
            let url = try temporaryPageFile(file)
            let pages = try decodedPages(url: url, data: file,
                                         encoding: encoding, bom: bom)
            try? FileManager.default.removeItem(at: url)
            #expect(pages.map(\.text).joined() == text)
            #expect(pages.first?.fileRange.lowerBound == UInt64(bom.count))
            #expect(pages.last?.fileRange.upperBound == UInt64(file.count))
            for pair in zip(pages, pages.dropFirst()) {
                #expect(pair.0.fileRange.upperBound == pair.1.fileRange.lowerBound)
                #expect((pair.0.fileRange.upperBound - UInt64(bom.count)).isMultiple(of: 4))
            }
        }
    }

    @Test("Echte große UTF-16-Dateien bleiben encoding-sicher abschnittsweise")
    func largeUTF16FilesRemainChunked() throws {
        let variants: [(String.Encoding, Data, Bool)] = [
            (.utf16LittleEndian, Data([0xFF, 0xFE]), false),
            (.utf16BigEndian, Data([0xFE, 0xFF]), false),
            (.utf16LittleEndian, Data(), true),
            (.utf16BigEndian, Data(), true)
        ]
        for (encoding, bom, needsExplicitReopen) in variants {
            let url = try writeLargeUTF16File(encoding: encoding, bom: bom)
            defer { try? FileManager.default.removeItem(at: url) }
            let size = try #require((try FileManager.default.attributesOfItem(
                atPath: url.path)[.size] as? NSNumber)?.uint64Value)
            #expect(size > FileLoader.largeFileThreshold)

            if needsExplicitReopen {
                let automatic = try FileLoader.load(url: url)
                #expect(automatic.displayMode == .hex)
            }
            let loaded = try FileLoader.load(
                url: url, forcedEncoding: needsExplicitReopen ? encoding : nil)
            #expect(loaded.displayMode == .chunkedText)
            #expect(loaded.content.isEmpty)
            #expect(loaded.encoding == encoding)
            #expect(loaded.bom == bom)

            let count = TextFilePageReader.pageCount(
                totalBytes: size, bomCount: bom.count, pageSize: textPageSize)
            for index in [0, 1, count - 1] {
                let page = try TextFilePageReader.read(
                    url: url, totalBytes: size, pageSize: textPageSize,
                    pageIndex: index, encoding: encoding, bom: bom)
                #expect(!page.text.contains("\u{FFFD}"))
                #expect(!page.text.contains("\0"))
            }
        }
    }

    @Test("Gutter ist nur im hinteren Fenster gedimmt")
    func gutterOpacity() {
        #expect(GutterDimming.opacity(windowIsKey: true) == 1)
        #expect(GutterDimming.opacity(windowIsKey: false) < 0.5)
    }
}
