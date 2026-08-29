import SwiftUI
import Darwin
import Foundation

/// Gemeinsamer kooperativer Abbruchpunkt der Seitenreader. Ein verworfener
/// Slider-Auftrag soll nicht nur sein Ergebnis verlieren, sondern vor dem
/// nächsten Seek/Read tatsächlich enden.
@inline(__always)
private func checkPageReadCancellation(
    _ shouldCancel: @Sendable () -> Bool
) throws {
    if shouldCancel() { throw CancellationError() }
}

/// Begrenzter Byte-Reader für die Hex-Ansicht. Er öffnet wie `FileLoader`
/// nichtblockierend und prüft den Typ am Deskriptor; ein nachträglich auf FIFO,
/// Socket oder Gerät umgebogener Pfad kann den Hintergrund-Task daher nicht
/// dauerhaft festhalten.
enum FilePageReader {
    static func read(url: URL, offset: UInt64, count: Int,
                     expectedTotalBytes: UInt64? = nil,
                     beforeFinalStat: (() throws -> Void)? = nil,
                     shouldCancel: @Sendable () -> Bool = { false }) throws -> Data {
        try checkPageReadCancellation(shouldCancel)
        guard count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let opened = try FileSnapshot.openRegularFile(at: url)
        defer { Darwin.close(opened.descriptor) }
        try checkPageReadCancellation(shouldCancel)
        guard opened.stat.st_size >= 0 else {
            throw FileSnapshotReadError.changedDuringRead
        }
        let openedBytes = UInt64(opened.stat.st_size)
        guard expectedTotalBytes == nil || expectedTotalBytes == openedBytes,
              offset <= openedBytes,
              UInt64(count) <= openedBytes - offset else {
            throw FileSnapshotReadError.changedDuringRead
        }
        let handle = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try checkPageReadCancellation(shouldCancel)
            let remaining = count - result.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                // Der beim Öffnen noch vorhandene Bereich ist inzwischen
                // kürzer geworden. Einen Teilabschnitt als Erfolg zu zeigen
                // würde alte Seitenmetadaten mit neuen Bytes vermischen.
                throw FileSnapshotReadError.changedDuringRead
            }
            result.append(chunk)
        }
        // Der Hook hält die Änderung zwischen Read und Schlussprüfung in
        // Regressionstests deterministisch. Produktaufrufe übergeben nichts.
        try checkPageReadCancellation(shouldCancel)
        try beforeFinalStat?()
        try checkPageReadCancellation(shouldCancel)
        var after = stat()
        guard fstat(opened.descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard FileSnapshot.describesSameOpenedVersion(opened.stat, after) else {
            throw FileSnapshotReadError.changedDuringRead
        }
        return result
    }
}

/// Meldet eine erkannte Fremdänderung verständlich; andere Systemfehler
/// behalten ihre von macOS lokalisierte Beschreibung.
private func pagedFileReadErrorDescription(_ error: Error) -> String {
    if let snapshotError = error as? FileSnapshotReadError,
       case .changedDuringRead = snapshotError {
        return L10n.string(
            "Die Datei wurde während des Lesens geändert. Lade sie über „Ablage“ > „Von Festplatte neu laden“ erneut.")
    }
    return error.localizedDescription
}

/// Lädt genau eine Seite einer Datei in den Speicher. Seitenwechsel ersetzen
/// die vorherige `Data` vollständig; Speicherbedarf bleibt damit unabhängig
/// von der Dateigröße begrenzt.
final class FilePageModel: ObservableObject {
    typealias Reader = @Sendable (
        URL, UInt64, Int, @Sendable () -> Bool
    ) throws -> Data

    @Published private(set) var pageIndex = 0
    @Published private(set) var data = Data()
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    /// Zählt abgeschlossene Ladevorgänge. Die Ansicht meldet ihren
    /// Drucksnapshot pro abgeschlossenem Ladevorgang statt pro Datenänderung:
    /// Zwei inhaltsgleiche Nachbarseiten ändern `data` nicht — Abschnitts-
    /// nummer und Hex-Basisadressen im Snapshot blieben sonst veraltet
    /// (Reviewfund 2026-08-18).
    @Published private(set) var completedLoadCount = 0

    let url: URL
    let totalBytes: UInt64
    let pageSize: Int
    private let reader: Reader
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?

    var pageCount: Int {
        max(1, Int((totalBytes + UInt64(pageSize) - 1) / UInt64(pageSize)))
    }
    var offset: UInt64 { UInt64(pageIndex) * UInt64(pageSize) }

    init(url: URL, totalBytes: UInt64, pageSize: Int, reader: Reader? = nil) {
        self.url = url
        self.totalBytes = totalBytes
        self.pageSize = pageSize
        // Der Standard-Reader bindet die beim Öffnen erfasste Gesamtgröße.
        self.reader = reader ?? { url, offset, count, shouldCancel in
            try FilePageReader.read(url: url, offset: offset, count: count,
                                    expectedTotalBytes: totalBytes,
                                    shouldCancel: shouldCancel)
        }
        load(page: 0)
    }

    func load(page requestedPage: Int) {
        loadTask?.cancel()
        let page = min(max(requestedPage, 0), pageCount - 1)
        pageIndex = page
        isLoading = true
        errorMessage = nil
        // Die alten Bytes gehören zur VORIGEN Seite, `offset` zeigt aber schon
        // auf die neue. Blieben sie bis zum Hintergrund-Abschluss stehen,
        // zeigte die Ansicht Adressen der neuen Seite mit Bytes der alten —
        // und eine Hex-Bearbeitung in diesem Fenster erzeugte eine Änderung
        // am falschen Offset mit dem falschen Altwert (Reviewfund 2026-08-19).
        // Leer heißt: Die Ansicht zeigt den Lade-Spinner, bearbeitbare Zeilen
        // existieren nicht.
        data = Data()
        let offset = UInt64(page) * UInt64(pageSize)
        let count = Int(min(UInt64(pageSize), totalBytes > offset ? totalBytes - offset : 0))
        let url = self.url
        let reader = self.reader
        loadGeneration &+= 1
        let generation = loadGeneration

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Data, Error> = Result {
                try reader(url, offset, count, { Task.isCancelled })
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.pageIndex == page,
                      self.loadGeneration == generation else { return }
                self.loadTask = nil
                self.isLoading = false
                switch result {
                case .success(let data):
                    self.data = data
                case .failure(let error):
                    // Die alten Bytes gehören zur VORIGEN Seite. Blieben sie
                    // stehen, zeigte die Ansicht zwar den Fehler, aber
                    // „Drucken" gäbe weiter den alten Abschnitt aus
                    // (Reviewfund 2026-08-18).
                    self.data = Data()
                    self.errorMessage = pagedFileReadErrorDescription(error)
                }
                self.completedLoadCount &+= 1
            }
        }
        loadTask = task
    }

    deinit {
        loadTask?.cancel()
    }
}

/// Ein streng dekodierter Abschnitt einer großen Textdatei. `fileRange` zeigt
/// die tatsächlich gelesenen Bytes inklusive BOM-Offset; benachbarte Seiten
/// schließen lückenlos aneinander an, können wegen Unicode-Grenzen aber wenige
/// Bytes von der nominalen 256-KiB-Grenze abweichen.
struct DecodedTextFilePage: Equatable {
    let text: String
    let fileRange: Range<UInt64>
}

/// Begrenzter Reader für große Textdateien. Er liest höchstens eine Seite plus
/// einzelne Grenz-Codeunits und niemals die vollständige Datei.
enum TextFilePageReader {
    static func pageCount(totalBytes: UInt64, bomCount: Int, pageSize: Int) -> Int {
        guard pageSize > 0 else { return 1 }
        let prefix = min(totalBytes, UInt64(max(0, bomCount)))
        let payloadBytes = totalBytes - prefix
        return max(1, Int((payloadBytes + UInt64(pageSize) - 1) / UInt64(pageSize)))
    }

    static func read(url: URL, totalBytes: UInt64, pageSize: Int,
                     pageIndex: Int, encoding: String.Encoding,
                     bom: Data,
                     beforeFinalStat: (() throws -> Void)? = nil,
                     shouldCancel: @Sendable () -> Bool = { false }) throws
        -> DecodedTextFilePage {
        try checkPageReadCancellation(shouldCancel)
        guard pageSize > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let bomCount = min(totalBytes, UInt64(bom.count))
        let payloadBytes = totalBytes - bomCount
        let count = pageCount(totalBytes: totalBytes, bomCount: bom.count,
                              pageSize: pageSize)
        let page = min(max(pageIndex, 0), count - 1)
        let nominalStart = min(payloadBytes, UInt64(page) * UInt64(pageSize))
        let nominalEnd = min(payloadBytes, UInt64(page + 1) * UInt64(pageSize))

        let opened = try FileSnapshot.openRegularFile(at: url)
        defer { Darwin.close(opened.descriptor) }
        try checkPageReadCancellation(shouldCancel)
        guard opened.stat.st_size >= 0,
              UInt64(opened.stat.st_size) == totalBytes else {
            throw FileSnapshotReadError.changedDuringRead
        }
        let handle = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
        let start = try alignedBoundary(nominalStart, payloadBytes: payloadBytes,
                                        bomCount: bomCount, encoding: encoding,
                                        handle: handle, shouldCancel: shouldCancel)
        let end = try alignedBoundary(nominalEnd, payloadBytes: payloadBytes,
                                      bomCount: bomCount, encoding: encoding,
                                      handle: handle, shouldCancel: shouldCancel)
        guard start <= end, end - start <= UInt64(pageSize + 4) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try readExactly(handle: handle, offset: bomCount + start,
                                   count: Int(end - start),
                                   shouldCancel: shouldCancel)
        try checkPageReadCancellation(shouldCancel)
        try beforeFinalStat?()
        try checkPageReadCancellation(shouldCancel)
        var after = stat()
        guard fstat(opened.descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard FileSnapshot.describesSameOpenedVersion(opened.stat, after) else {
            throw FileSnapshotReadError.changedDuringRead
        }
        try checkPageReadCancellation(shouldCancel)
        guard let text = String(data: data, encoding: encoding) else {
            // Kein Lossy-Fallback: Ein beschädigter oder falsch gewählter
            // Abschnitt muss sichtbar fehlschlagen, nicht U+FFFD erfinden.
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return DecodedTextFilePage(text: text,
                                   fileRange: (bomCount + start)..<(bomCount + end))
    }

    /// Verschiebt eine nominelle Grenze rückwärts auf den Anfang des dort
    /// getroffenen Unicode-Skalars. Dadurch gehört ein Grenzzeichen vollständig
    /// zur Folgeseite und alle Seiten lassen sich ohne Verlust rekonstruieren.
    private static func alignedBoundary(_ nominal: UInt64, payloadBytes: UInt64,
                                        bomCount: UInt64, encoding: String.Encoding,
                                        handle: FileHandle,
                                        shouldCancel: @Sendable () -> Bool) throws -> UInt64 {
        try checkPageReadCancellation(shouldCancel)
        guard nominal > 0, nominal < payloadBytes else { return nominal }
        if encoding == .utf8 {
            var boundary = nominal
            // UTF-8 hat höchstens drei Fortsetzungsbytes. Mehr würden auf
            // beschädigte Daten deuten und dürfen keine unbeschränkte
            // rückwärts laufende Seek-Schleife auslösen.
            for _ in 0..<3 where boundary > 0 {
                try checkPageReadCancellation(shouldCancel)
                let byte = try readExactly(handle: handle,
                                           offset: bomCount + boundary, count: 1,
                                           shouldCancel: shouldCancel)[0]
                guard byte & 0b1100_0000 == 0b1000_0000 else { return boundary }
                boundary -= 1
            }
            let first = try readExactly(handle: handle,
                                        offset: bomCount + boundary, count: 1,
                                        shouldCancel: shouldCancel)[0]
            guard first & 0b1100_0000 != 0b1000_0000 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return boundary
        }
        if encoding == .utf16LittleEndian || encoding == .utf16BigEndian
            || encoding == .utf16 {
            var boundary = nominal - nominal % 2
            guard boundary >= 2, boundary + 2 <= payloadBytes else { return boundary }
            let previous = try codeUnit(handle: handle, payloadOffset: boundary - 2,
                                        bomCount: bomCount, encoding: encoding,
                                        shouldCancel: shouldCancel)
            let next = try codeUnit(handle: handle, payloadOffset: boundary,
                                    bomCount: bomCount, encoding: encoding,
                                    shouldCancel: shouldCancel)
            if (0xD800...0xDBFF).contains(previous),
               (0xDC00...0xDFFF).contains(next) {
                boundary -= 2
            }
            return boundary
        }
        if encoding == .utf32LittleEndian || encoding == .utf32BigEndian
            || encoding == .utf32 {
            // UTF-32 besitzt feste Vierbyte-Codeunits; eine Seitengrenze auf
            // das vorherige Vielfache von vier genügt, Surrogatpaare gibt es
            // in dieser Kodierung nicht.
            return nominal - nominal % 4
        }
        // Die übrigen angebotenen Reopen-Encodings sind Single-Byte-Encodings.
        return nominal
    }

    private static func codeUnit(handle: FileHandle, payloadOffset: UInt64,
                                 bomCount: UInt64, encoding: String.Encoding,
                                 shouldCancel: @Sendable () -> Bool) throws -> UInt16 {
        let bytes = try readExactly(handle: handle,
                                    offset: bomCount + payloadOffset, count: 2,
                                    shouldCancel: shouldCancel)
        if encoding == .utf16BigEndian {
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    private static func readExactly(handle: FileHandle, offset: UInt64,
                                    count: Int,
                                    shouldCancel: @Sendable () -> Bool) throws -> Data {
        try checkPageReadCancellation(shouldCancel)
        try handle.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try checkPageReadCancellation(shouldCancel)
            let remaining = count - result.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(chunk)
        }
        return result
    }
}

/// Asynchrones UI-Modell über dem begrenzten, encoding-sicheren Reader.
final class TextFilePageModel: ObservableObject {
    typealias Reader = @Sendable (
        URL, UInt64, Int, Int, String.Encoding, Data,
        @Sendable () -> Bool
    ) throws -> DecodedTextFilePage

    @Published private(set) var pageIndex = 0
    @Published private(set) var text = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    /// Siehe `FilePageModel.completedLoadCount` — gleiche Begründung.
    @Published private(set) var completedLoadCount = 0

    let url: URL
    let totalBytes: UInt64
    let pageSize: Int
    let encoding: String.Encoding
    let bom: Data
    private let reader: Reader
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?

    var pageCount: Int {
        TextFilePageReader.pageCount(totalBytes: totalBytes, bomCount: bom.count,
                                     pageSize: pageSize)
    }

    init(url: URL, totalBytes: UInt64, pageSize: Int,
         encoding: String.Encoding, bom: Data, reader: Reader? = nil) {
        self.url = url
        self.totalBytes = totalBytes
        self.pageSize = pageSize
        self.encoding = encoding
        self.bom = bom
        self.reader = reader ?? {
            url, totalBytes, pageSize, pageIndex, encoding, bom, shouldCancel in
            try TextFilePageReader.read(
                url: url, totalBytes: totalBytes, pageSize: pageSize,
                pageIndex: pageIndex, encoding: encoding, bom: bom,
                shouldCancel: shouldCancel)
        }
        load(page: 0)
    }

    func load(page requestedPage: Int) {
        loadTask?.cancel()
        let page = min(max(requestedPage, 0), pageCount - 1)
        pageIndex = page
        isLoading = true
        errorMessage = nil
        // Wie in `FilePageModel.load`: Der alte Text gehört zur vorigen
        // Seite. Bis zum Abschluss zeigt die Ansicht den Spinner statt einer
        // Mischung aus neuer Abschnittsnummer und altem Inhalt.
        text = ""
        let url = self.url
        let totalBytes = self.totalBytes
        let pageSize = self.pageSize
        let encoding = self.encoding
        let bom = self.bom
        let reader = self.reader
        loadGeneration &+= 1
        let generation = loadGeneration

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try reader(url, totalBytes, pageSize, page, encoding, bom,
                           { Task.isCancelled })
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.pageIndex == page,
                      self.loadGeneration == generation else { return }
                self.loadTask = nil
                self.isLoading = false
                switch result {
                case .success(let page): self.text = page.text
                case .failure(let error):
                    self.text = ""
                    self.errorMessage = pagedFileReadErrorDescription(error)
                }
                self.completedLoadCount &+= 1
            }
        }
        loadTask = task
    }

    deinit {
        loadTask?.cancel()
    }
}

private struct FilePageNavigation: View {
    @ObservedObject var model: FilePageModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.load(page: 0) } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(model.pageIndex == 0)
            Button { model.load(page: model.pageIndex - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.pageIndex == 0)

            Slider(value: Binding(
                get: { Double(model.pageIndex) },
                set: { model.load(page: Int($0.rounded())) }
            ), in: 0...Double(max(1, model.pageCount - 1)), step: 1)

            Button { model.load(page: model.pageIndex + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.pageIndex >= model.pageCount - 1)
            Button { model.load(page: model.pageCount - 1) } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(model.pageIndex >= model.pageCount - 1)

            Text(verbatim: L10n.format("Abschnitt %ld / %ld",
                                       model.pageIndex + 1, model.pageCount))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surfaceSand.opacity(0.45))
    }
}

/// Read-only Textansicht für große Dateien. Es befindet sich stets höchstens
/// ein 256-KiB-Abschnitt im SwiftUI-Textbaum.
struct ChunkedTextFileView: View {
    @StateObject private var model: TextFilePageModel
    /// Meldet den sichtbaren Abschnitt nach außen — er ist die Druckvorlage.
    /// Eine große Datei liegt nie vollständig im Tab; ohne diese Meldung
    /// wüsste „Drucken" nicht, welches Stück gerade zu sehen ist.
    private let onVisiblePage: ((VisiblePrintPage?) -> Void)?

    init(url: URL, fileSize: UInt64, encoding: String.Encoding, bom: Data,
         onVisiblePage: ((VisiblePrintPage?) -> Void)? = nil) {
        _model = StateObject(wrappedValue: TextFilePageModel(
            url: url, totalBytes: fileSize, pageSize: 256 * 1024,
            encoding: encoding, bom: bom
        ))
        self.onVisiblePage = onVisiblePage
    }

    var body: some View {
        VStack(spacing: 0) {
            Label("Große Datei · abschnittsweise und schreibgeschützt",
                  systemImage: "doc.text.magnifyingglass")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .padding(.vertical, 5)
            Divider()
            content
            Divider()
            TextFilePageNavigation(model: model)
        }
        .background(Theme.surfaceRaised)
        .onAppear { reportVisiblePage() }
        // Pro abgeschlossenem Ladevorgang melden, nicht pro Textänderung:
        // Zwei inhaltsgleiche Nachbarabschnitte änderten `text` nicht, und
        // der Drucksnapshot behielte die alte Abschnittsnummer.
        .onChange(of: model.completedLoadCount) { _, _ in reportVisiblePage() }
        // Wie bei der Hex-Ansicht: Während eines Abschnittswechsels gibt es
        // keinen sichtbaren Abschnitt und damit auch keine Druckvorlage.
        .onChange(of: model.isLoading) { _, loading in
            if loading { onVisiblePage?(nil) }
        }
        .onDisappear { onVisiblePage?(nil) }
    }

    private func reportVisiblePage() {
        guard let onVisiblePage else { return }
        guard !model.text.isEmpty else { onVisiblePage(nil); return }
        onVisiblePage(VisiblePrintPage(url: model.url,
                                      pageIndex: model.pageIndex,
                                      pageCount: model.pageCount,
                                      text: model.text))
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.text.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            Text(error).foregroundColor(Theme.diffRemovedFG)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(model.text)
                    .fastraFont(.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct TextFilePageNavigation: View {
    @ObservedObject var model: TextFilePageModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.load(page: 0) } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(model.pageIndex == 0)
            Button { model.load(page: model.pageIndex - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.pageIndex == 0)

            Slider(value: Binding(
                get: { Double(model.pageIndex) },
                set: { model.load(page: Int($0.rounded())) }
            ), in: 0...Double(max(1, model.pageCount - 1)), step: 1)

            Button { model.load(page: model.pageIndex + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.pageIndex >= model.pageCount - 1)
            Button { model.load(page: model.pageCount - 1) } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(model.pageIndex >= model.pageCount - 1)

            Text(verbatim: L10n.format("Abschnitt %ld / %ld",
                                       model.pageIndex + 1, model.pageCount))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surfaceSand.opacity(0.45))
    }
}

/// Native, virtualisierte Hex+ASCII-Ansicht. Binärdateien werden automatisch
/// durch Null-Byte-Probe hierher geroutet; über den Ansichts-Umschalter ist
/// sie für jede Datei manuell erreichbar (Etappe 2 Wunschpaket 2026-07).
/// Bearbeitung ist Opt-in: erst nach ausdrücklicher Bestätigung, geschrieben
/// wird erst nach sichtbarer Änderungsvorschau und zweiter Bestätigung.
/// Wer nichts ändert, bekommt auch keinen Speicher-Zwang.
struct HexFileView: View {
    @StateObject private var model: FilePageModel
    /// Dokumentgebundener Zustand aus `EditorTab`. Eine lokale StateObject-
    /// Session ging beim Abbau dieser View verloren (Tab-/Ansichtswechsel).
    @Binding private var edits: HexEditSession
    @State private var editingEnabled = false
    @State private var requestEditingConfirmation = false
    @State private var showsChangesPreview = false
    @State private var requestSaveConfirmation = false
    /// Ein dirty Textpuffer und Byteänderungen am gespeicherten Stand dürfen
    /// nicht gleichzeitig entstehen: Beide hätten verschiedene Grundlagen.
    private let editingIsAllowed: Bool
    /// Schließen/⌘S kann den Nutzer in diesen sicheren Vorschaupfad leiten.
    private let requestSavePreview: Bool
    private let consumeSavePreviewRequest: (() -> Void)?
    private let beginSave: () -> HexSaveOperation?
    private let finishSave: (HexSaveOperation) -> Bool
    private let failSave: (HexSaveOperation, String) -> Void
    private let clearSaveError: () -> Void
    private let discardChanges: () -> Void
    private let editRow: (String, Data, UInt64, Int) -> Void
    private let undoChange: () -> Void
    private let redoChange: () -> Void
    /// Wird nach einem erfolgreichen Hex-Schreibvorgang aufgerufen — z. B.
    /// damit offene Text-Tabs derselben Datei den neuen Plattenstand über
    /// die Extern-Änderungs-Erkennung abgleichen können.
    private let onDidWrite: (() -> Void)?
    /// Meldet den sichtbaren Abzug nach außen — er ist die Druckvorlage
    /// (dieselbe Begründung wie bei `ChunkedTextFileView`).
    private let onVisiblePage: ((VisiblePrintPage?) -> Void)?

    init(url: URL, fileSize: UInt64,
         edits: Binding<HexEditSession>,
         editingIsAllowed: Bool = true,
         requestSavePreview: Bool = false,
         consumeSavePreviewRequest: (() -> Void)? = nil,
         beginSave: @escaping () -> HexSaveOperation?,
         finishSave: @escaping (HexSaveOperation) -> Bool,
         failSave: @escaping (HexSaveOperation, String) -> Void,
         clearSaveError: @escaping () -> Void,
         discardChanges: @escaping () -> Void,
         editRow: @escaping (String, Data, UInt64, Int) -> Void,
         undoChange: @escaping () -> Void,
         redoChange: @escaping () -> Void,
         onVisiblePage: ((VisiblePrintPage?) -> Void)? = nil,
         onDidWrite: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: FilePageModel(
            url: url, totalBytes: fileSize, pageSize: 16 * 256
        ))
        _edits = edits
        self.editingIsAllowed = editingIsAllowed
        self.requestSavePreview = requestSavePreview
        self.consumeSavePreviewRequest = consumeSavePreviewRequest
        self.beginSave = beginSave
        self.finishSave = finishSave
        self.failSave = failSave
        self.clearSaveError = clearSaveError
        self.discardChanges = discardChanges
        self.editRow = editRow
        self.undoChange = undoChange
        self.redoChange = redoChange
        self.onVisiblePage = onVisiblePage
        self.onDidWrite = onDidWrite
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading && model.data.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                Text(error).foregroundColor(Theme.diffRemovedFG)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(stride(from: 0, to: model.data.count, by: 16)), id: \.self) { row in
                            if editingEnabled {
                                editableRow(at: row)
                            } else {
                                Text(hexLine(at: row))
                                    .fastraFont(.mono)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(12)
                }
            }
            Divider()
            FilePageNavigation(model: model)
                .disabled(edits.isSaving)
        }
        .background(Theme.surfaceRaised)
        .onAppear {
            reportVisiblePage()
            presentRequestedSavePreviewIfNeeded()
        }
        // Pro abgeschlossenem Ladevorgang melden, nicht pro Datenänderung:
        // Zwei inhaltsgleiche Nachbarseiten (z. B. lauter Nullbytes) änderten
        // `data` nicht, und der Drucksnapshot behielte die alten Basisadressen.
        .onChange(of: model.completedLoadCount) { _, _ in reportVisiblePage() }
        // Während eines Seitenwechsels gibt es keinen sichtbaren Abzug — der
        // Bildschirm zeigt den Spinner. „Drucken" muss dann ehrlich ablehnen,
        // statt den zuletzt gemeldeten alten Abschnitt auszugeben.
        .onChange(of: model.isLoading) { _, loading in
            if loading { onVisiblePage?(nil) }
        }
        // Noch nicht gespeicherte Byte-Änderungen stehen auf dem Bildschirm —
        // dann müssen sie auch auf dem Ausdruck stehen.
        .onChange(of: edits.changeRevision) { _, _ in reportVisiblePage() }
        .onChange(of: requestSavePreview) { _, requested in
            if requested { presentRequestedSavePreviewIfNeeded() }
        }
        .onDisappear { onVisiblePage?(nil) }
        .alert("Hex-Bearbeitung erlauben?", isPresented: $requestEditingConfirmation) {
            Button("Abbrechen", role: .cancel) { }
            Button("Bearbeiten erlauben", role: .destructive) { editingEnabled = true }
        } message: {
            Text("Binärdateien können unbrauchbar werden. Fastra schreibt erst nach einer sichtbaren Änderungsvorschau und einer zweiten Bestätigung.")
        }
        .sheet(isPresented: $showsChangesPreview) {
            HexChangesPreview(changes: edits.preview) {
                showsChangesPreview = false
                requestSaveConfirmation = true
            }
        }
        .alert("Hex-Änderungen schreiben?", isPresented: $requestSaveConfirmation) {
            Button("Abbrechen", role: .cancel) { }
            Button("Änderungen schreiben", role: .destructive) { saveChanges() }
        } message: {
            Text("\(edits.preview.count) Byte-Änderungen werden atomar gespeichert. Die Originaldatei wird dabei ersetzt.")
        }
        .alert("Speichern fehlgeschlagen", isPresented: Binding(
            get: { edits.saveErrorMessage != nil },
            set: { if !$0 { clearSaveError() } }
        )) {
            Button("OK", role: .cancel) { clearSaveError() }
        } message: {
            Text(verbatim: edits.saveErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(editingEnabled ? "Hex + ASCII · Bearbeitung aktiv" : "Hex + ASCII · schreibgeschützt", systemImage: "number")
                .fastraFont(.small).foregroundColor(editingEnabled ? Theme.diffRemovedFG : Theme.textSecondary)
            if let message = edits.invalidRowMessage {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                    .fastraFont(.small)
                    .foregroundColor(Theme.diffRemovedFG)
                    .lineLimit(1)
            }
            Spacer()
            if edits.hasChanges || edits.canUndo || edits.canRedo {
                if edits.isSaving {
                    Text("Wird gespeichert …")
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                }
                if edits.hasChanges {
                    Text("\(edits.preview.count) Byte geändert")
                        .fastraFont(.small).foregroundColor(Theme.diffRemovedFG)
                }
                Button { undoChange() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!edits.canUndo || edits.isSaving || !editingIsAllowed)
                .help("Hex-Änderung rückgängig")
                .keyboardShortcut("z", modifiers: .command)
                Button { redoChange() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .disabled(!edits.canRedo || edits.isSaving || !editingIsAllowed)
                .help("Hex-Änderung wiederholen")
                .keyboardShortcut("z", modifiers: [.command, .shift])
                Button("Vorschau & Speichern…") { showsChangesPreview = true }
                    .disabled(edits.isSaving || !edits.hasChanges)
                Button("Verwerfen") { discardChanges() }
                    .disabled(edits.isSaving || !edits.hasChanges)
            }
            Toggle("Bearbeiten erlauben", isOn: Binding(
                get: { editingEnabled },
                set: { enabled in
                    if enabled && !editingEnabled { requestEditingConfirmation = true }
                    else if !enabled { editingEnabled = false }
                }
            ))
            .toggleStyle(.switch)
            .fastraFont(.small)
            .disabled(edits.isSaving || !editingIsAllowed)
            .help(editingIsAllowed
                  ? ""
                  : "Speichere oder verwirf zuerst die Änderungen im Texteditor.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func editableRow(at row: Int) -> some View {
        let count = min(16, model.data.count - row)
        return HStack(spacing: 8) {
            Text(String(format: "%012llX", model.offset + UInt64(row)))
                .fastraFont(.monoSmall).foregroundColor(Theme.textSecondary)
            TextField("", text: Binding(
                get: { edits.textForRow(data: model.data, baseOffset: model.offset, row: row) },
                set: { editRow($0, model.data, model.offset, row) }
            ))
            .textFieldStyle(.plain)
            .fastraFont(.mono)
            .frame(width: CGFloat(count * 3 * 8))
            .disabled(edits.isSaving || !editingIsAllowed)
            Text("|\(asciiRow(at: row))|")
                .fastraFont(.mono).foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 1)
    }

    private func hexLine(at row: Int) -> String {
        // Dieselbe Formatierung wie im Ausdruck (`HexDump`) UND dieselben
        // effektiven Bytes wie der Drucksnapshot: Auch nach dem Ausschalten
        // von „Bearbeiten erlauben" bleiben offene Änderungen sichtbar —
        // sonst druckte Fastra Bytes, die die schreibgeschützte Zeile nicht
        // zeigt (Reviewfund 2026-08-18). Byteweiser Overlay statt
        // `visiblePageData()`: Eine Vollkopie der Seite je Zeile wäre beim
        // Rendern unnötig teuer.
        let end = min(row + HexDump.bytesPerRow, model.data.count)
        let bytes = (row..<end).map { index in
            edits.changes[model.offset + UInt64(index)]?.newValue ?? model.data[index]
        }
        return HexDump.line(bytes: bytes, address: model.offset + UInt64(row))
    }

    /// Der geladene Abschnitt mit allen noch nicht gespeicherten Änderungen —
    /// genau der Stand, den die Ansicht zeigt.
    private func visiblePageData() -> Data {
        edits.applied(to: model.data, baseOffset: model.offset)
    }

    private func reportVisiblePage() {
        guard let onVisiblePage else { return }
        guard !model.data.isEmpty else { onVisiblePage(nil); return }
        onVisiblePage(VisiblePrintPage(
            url: model.url,
            pageIndex: model.pageIndex,
            pageCount: model.pageCount,
            text: HexDump.text(data: visiblePageData(), baseOffset: model.offset)
        ))
    }

    private func asciiRow(at row: Int) -> String {
        let end = min(row + 16, model.data.count)
        return String((row..<end).map { index in
            let offset = model.offset + UInt64(index)
            let byte = edits.changes[offset]?.newValue ?? model.data[index]
            return (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        })
    }

    private func saveChanges() {
        guard let operation = beginSave() else { return }
        let url = model.url
        Task {
            // Eine Binärdatei kann viele Gigabyte groß sein. Kopieren,
            // Altwert-Prüfung und fsync laufen deshalb nie auf dem UI-Thread.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try HexEditing.save(operation.changes, to: url) }
            }.value
            switch result {
            case .success:
                if finishSave(operation) {
                    model.load(page: model.pageIndex)
                    onDidWrite?()
                }
            case .failure(let error):
                failSave(operation, error.localizedDescription)
            }
        }
    }

    private func presentRequestedSavePreviewIfNeeded() {
        guard requestSavePreview else { return }
        consumeSavePreviewRequest?()
        guard edits.hasChanges else { return }
        showsChangesPreview = true
    }
}

/// Zeigt jede geplante Byte-Änderung, bevor die Datei ersetzt wird. So kann
/// der Nutzer auch bei großen Binärdateien gezielt prüfen, was geschrieben wird.
private struct HexChangesPreview: View {
    let changes: [HexByteChange]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hex-Änderungsvorschau").fastraFont(.headline)
            Text("Erst nach der folgenden Bestätigung schreibt Fastra diese \(changes.count) Bytes.")
                .fastraFont(.ui).foregroundColor(Theme.textSecondary)
            List(changes) { change in
                Text(change.description).fastraFont(.mono)
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Weiter zur Bestätigung", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 320)
    }
}
