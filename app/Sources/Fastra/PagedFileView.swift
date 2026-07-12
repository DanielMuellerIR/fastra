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

            Text("Abschnitt \(model.pageIndex + 1) / \(model.pageCount)")
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
    @StateObject private var model: FilePageModel

    init(url: URL, fileSize: UInt64) {
        _model = StateObject(wrappedValue: FilePageModel(
            url: url, totalBytes: fileSize, pageSize: 256 * 1024
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
            FilePageNavigation(model: model)
        }
        .background(Theme.surfaceRaised)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.data.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            Text(error).foregroundColor(Theme.diffRemovedFG)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(String(decoding: model.data, as: UTF8.self))
                    .fastraFont(.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Native, virtualisierte Hex+ASCII-Ansicht. Binärdateien werden automatisch
/// durch Null-Byte-Probe hierher geroutet; Bearbeitung ist bewusst deaktiviert.
struct HexFileView: View {
    @StateObject private var model: FilePageModel

    init(url: URL, fileSize: UInt64) {
        _model = StateObject(wrappedValue: FilePageModel(
            url: url, totalBytes: fileSize, pageSize: 16 * 256
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            Label("Hex + ASCII · schreibgeschützt", systemImage: "number")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .padding(.vertical, 5)
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
                            Text(hexLine(at: row))
                                .fastraFont(.mono)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                }
            }
            Divider()
            FilePageNavigation(model: model)
        }
        .background(Theme.surfaceRaised)
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
}
