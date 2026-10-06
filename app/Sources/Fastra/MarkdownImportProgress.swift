import Foundation

struct MarkdownImportProgress: Equatable {
    enum Phase: String { case detectingInput, preparingOutput, converting, publishing, finished }
    enum Unit: String { case file, page, sheet, frame, slide, cell }
    let phase: Phase
    let unit: Unit?
    let completed: Int?
    let total: Int?

    var description: String {
        if let unit, let completed, let total {
            let format: String
            switch unit {
            case .file: format = L10n.string("Dateien: %lld von %lld")
            case .page: format = L10n.string("Seiten: %lld von %lld")
            case .sheet: format = L10n.string("Tabellenblätter: %lld von %lld")
            case .frame: format = L10n.string("Bilder: %lld von %lld")
            case .slide: format = L10n.string("Folien: %lld von %lld")
            case .cell: format = L10n.string("Zellen: %lld von %lld")
            }
            return String(format: format, Int64(completed), Int64(total))
        }
        switch phase {
        case .detectingInput: return L10n.string("Dokument wird erkannt …")
        case .preparingOutput: return L10n.string("Ausgabe wird vorbereitet …")
        case .converting: return L10n.string("Dokument wird umgewandelt …")
        case .publishing, .finished: return L10n.string("Ergebnis wird übernommen …")
        }
    }
}

/// Das bestehende CLI-Protokoll liefert LF-Zeilen auf stderr. Chunks dürfen
/// mitten im UTF-8-Zeichen enden; erst eine vollständige Zeile wird dekodiert.
/// Unbekannte Meldungen bleiben beim Runner als Fehlerausgabe erhalten.
struct MarkdownImportProgressParser {
    private let prefix: String
    private var pending = Data()
    private var discarding = false
    static let lineLimit = 16 * 1024

    init(sourceName: String) { prefix = "Progress: \(sourceName): " }

    mutating func consume(_ data: Data) -> MarkdownImportProgress? {
        var latest: MarkdownImportProgress?
        for byte in data {
            if byte == 10 {
                if !discarding, let line = String(data: pending, encoding: .utf8),
                   let value = decode(line) { latest = value }
                pending.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if pending.count < Self.lineLimit { pending.append(byte) }
                else { pending.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return latest
    }

    private func decode(_ line: String) -> MarkdownImportProgress? {
        guard line.hasPrefix(prefix) else { return nil }
        let fields = line.dropFirst(prefix.count).split(separator: " ")
        guard let first = fields.first,
              let phase = MarkdownImportProgress.Phase(rawValue: String(first)) else { return nil }
        if fields.count == 1 {
            return MarkdownImportProgress(phase: phase, unit: nil, completed: nil, total: nil)
        }
        guard fields.count == 3,
              let unit = MarkdownImportProgress.Unit(rawValue: String(fields[1])) else { return nil }
        let counts = fields[2].split(separator: "/", omittingEmptySubsequences: false)
        guard counts.count == 2, let completed = Int(counts[0]), let total = Int(counts[1]),
              total > 0, completed >= 0, completed <= total else { return nil }
        return MarkdownImportProgress(phase: phase, unit: unit, completed: completed, total: total)
    }
}
