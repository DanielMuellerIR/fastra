import Foundation
import Testing
@testable import Fastra

@Suite("Hex- und Abschnittsansicht")
struct PagedFileTests {
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

    @Test("Gutter ist nur im hinteren Fenster gedimmt")
    func gutterOpacity() {
        #expect(GutterDimming.opacity(windowIsKey: true) == 1)
        #expect(GutterDimming.opacity(windowIsKey: false) < 0.5)
    }
}
