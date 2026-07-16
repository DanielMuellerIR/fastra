import SwiftUI
import Foundation

/// Lädt genau eine Seite einer Datei in den Speicher. Seitenwechsel ersetzen
/// die vorherige `Data` vollständig; Speicherbedarf bleibt damit unabhängig
/// von der Dateigröße begrenzt.
final class FilePageModel: ObservableObject {
    @Published private(set) var pageIndex = 0
    @Published private(set) var data = Data()
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    let url: URL
    let totalBytes: UInt64
    let pageSize: Int

    var pageCount: Int {
        max(1, Int((totalBytes + UInt64(pageSize) - 1) / UInt64(pageSize)))
    }
    var offset: UInt64 { UInt64(pageIndex) * UInt64(pageSize) }

    init(url: URL, totalBytes: UInt64, pageSize: Int) {
        self.url = url
        self.totalBytes = totalBytes
        self.pageSize = pageSize
        load(page: 0)
    }

    func load(page requestedPage: Int) {
        let page = min(max(requestedPage, 0), pageCount - 1)
        pageIndex = page
        isLoading = true
        errorMessage = nil
        let offset = UInt64(page) * UInt64(pageSize)
        let count = Int(min(UInt64(pageSize), totalBytes > offset ? totalBytes - offset : 0))
        let url = self.url

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Data, Error> = Result {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: count) ?? Data()
            }
            await MainActor.run { [weak self] in
                guard let self, self.pageIndex == page else { return }
                self.isLoading = false
                switch result {
                case .success(let data): self.data = data
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
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
                     bom: Data) throws -> DecodedTextFilePage {
        guard pageSize > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let bomCount = min(totalBytes, UInt64(bom.count))
        let payloadBytes = totalBytes - bomCount
        let count = pageCount(totalBytes: totalBytes, bomCount: bom.count,
                              pageSize: pageSize)
        let page = min(max(pageIndex, 0), count - 1)
        let nominalStart = min(payloadBytes, UInt64(page) * UInt64(pageSize))
        let nominalEnd = min(payloadBytes, UInt64(page + 1) * UInt64(pageSize))

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = try alignedBoundary(nominalStart, payloadBytes: payloadBytes,
                                        bomCount: bomCount, encoding: encoding,
                                        handle: handle)
        let end = try alignedBoundary(nominalEnd, payloadBytes: payloadBytes,
                                      bomCount: bomCount, encoding: encoding,
                                      handle: handle)
        guard start <= end, end - start <= UInt64(pageSize + 4) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try readExactly(handle: handle, offset: bomCount + start,
                                   count: Int(end - start))
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
                                        handle: FileHandle) throws -> UInt64 {
        guard nominal > 0, nominal < payloadBytes else { return nominal }
        if encoding == .utf8 {
            var boundary = nominal
            // UTF-8 hat höchstens drei Fortsetzungsbytes. Mehr würden auf
            // beschädigte Daten deuten und dürfen keine unbeschränkte
            // rückwärts laufende Seek-Schleife auslösen.
            for _ in 0..<3 where boundary > 0 {
                let byte = try readExactly(handle: handle,
                                           offset: bomCount + boundary, count: 1)[0]
                guard byte & 0b1100_0000 == 0b1000_0000 else { return boundary }
                boundary -= 1
            }
            let first = try readExactly(handle: handle,
                                        offset: bomCount + boundary, count: 1)[0]
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
                                        bomCount: bomCount, encoding: encoding)
            let next = try codeUnit(handle: handle, payloadOffset: boundary,
                                    bomCount: bomCount, encoding: encoding)
            if (0xD800...0xDBFF).contains(previous),
               (0xDC00...0xDFFF).contains(next) {
                boundary -= 2
            }
            return boundary
        }
        // Die übrigen angebotenen Reopen-Encodings sind Single-Byte-Encodings.
        return nominal
    }

    private static func codeUnit(handle: FileHandle, payloadOffset: UInt64,
                                 bomCount: UInt64, encoding: String.Encoding) throws -> UInt16 {
        let bytes = try readExactly(handle: handle,
                                    offset: bomCount + payloadOffset, count: 2)
        if encoding == .utf16BigEndian {
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    private static func readExactly(handle: FileHandle, offset: UInt64,
                                    count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
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
    @Published private(set) var pageIndex = 0
    @Published private(set) var text = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    let url: URL
    let totalBytes: UInt64
    let pageSize: Int
    let encoding: String.Encoding
    let bom: Data

    var pageCount: Int {
        TextFilePageReader.pageCount(totalBytes: totalBytes, bomCount: bom.count,
                                     pageSize: pageSize)
    }

    init(url: URL, totalBytes: UInt64, pageSize: Int,
         encoding: String.Encoding, bom: Data) {
        self.url = url
        self.totalBytes = totalBytes
        self.pageSize = pageSize
        self.encoding = encoding
        self.bom = bom
        load(page: 0)
    }

    func load(page requestedPage: Int) {
        let page = min(max(requestedPage, 0), pageCount - 1)
        pageIndex = page
        isLoading = true
        errorMessage = nil
        let url = self.url
        let totalBytes = self.totalBytes
        let pageSize = self.pageSize
        let encoding = self.encoding
        let bom = self.bom

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try TextFilePageReader.read(
                    url: url, totalBytes: totalBytes, pageSize: pageSize,
                    pageIndex: page, encoding: encoding, bom: bom
                )
            }
            await MainActor.run { [weak self] in
                guard let self, self.pageIndex == page else { return }
                self.isLoading = false
                switch result {
                case .success(let page): self.text = page.text
                case .failure(let error):
                    self.text = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
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

    init(url: URL, fileSize: UInt64, encoding: String.Encoding, bom: Data) {
        _model = StateObject(wrappedValue: TextFilePageModel(
            url: url, totalBytes: fileSize, pageSize: 256 * 1024,
            encoding: encoding, bom: bom
        ))
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
/// durch Null-Byte-Probe hierher geroutet; Bearbeitung ist bewusst deaktiviert.
struct HexFileView: View {
    @StateObject private var model: FilePageModel
    @StateObject private var edits = HexEditSession()
    @State private var editingEnabled = false
    @State private var requestEditingConfirmation = false
    @State private var showsChangesPreview = false
    @State private var requestSaveConfirmation = false
    @State private var saveError: String?

    init(url: URL, fileSize: UInt64) {
        _model = StateObject(wrappedValue: FilePageModel(
            url: url, totalBytes: fileSize, pageSize: 16 * 256
        ))
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
        }
        .background(Theme.surfaceRaised)
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
        .alert("Speichern fehlgeschlagen", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(editingEnabled ? "Hex + ASCII · Bearbeitung aktiv" : "Hex + ASCII · schreibgeschützt", systemImage: "number")
                .fastraFont(.small).foregroundColor(editingEnabled ? Theme.diffRemovedFG : Theme.textSecondary)
            Spacer()
            if edits.hasChanges {
                Text("\(edits.preview.count) Byte geändert")
                    .fastraFont(.small).foregroundColor(Theme.diffRemovedFG)
                Button("Vorschau & Speichern…") { showsChangesPreview = true }
                Button("Verwerfen") { edits.discard() }
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
                set: { edits.editRow($0, data: model.data, baseOffset: model.offset, row: row) }
            ))
            .textFieldStyle(.plain)
            .fastraFont(.mono)
            .frame(width: CGFloat(count * 3 * 8))
            Text("|\(asciiRow(at: row))|")
                .fastraFont(.mono).foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 1)
    }

    private func hexLine(at row: Int) -> String {
        let end = min(row + 16, model.data.count)
        let bytes = Array(model.data[row..<end])
        let address = String(format: "%012llX", model.offset + UInt64(row))
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            .padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
        let ascii = String(bytes.map { byte in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        })
        return "\(address)  \(hex)  |\(ascii)|"
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
        do {
            try edits.save(to: model.url)
            model.load(page: model.pageIndex)
        } catch {
            saveError = error.localizedDescription
        }
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
