import AppKit
import CodeEditTextView

// Fastra: Ein Ergebnis gehoert zu genau einer Textrevision. Syntaxprovider
// parsen unveraenderliche Snapshots; der Einrueckungsfallback liest nur
// revisionsgepruefte Zeilenbloecke auf Main.
@MainActor
final class LineFoldCalculator {
    weak var foldProvider: LineFoldProvider?
    weak var controller: TextViewController?
    let valueStream: AsyncStream<LineFoldStorage>
    private let continuation: AsyncStream<LineFoldStorage>.Continuation
    private var task: Task<Void, Never>?

    init(foldProvider: LineFoldProvider, controller: TextViewController,
         textChangedStream: AsyncStream<Void>) {
        self.foldProvider = foldProvider
        self.controller = controller
        (valueStream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        task = Task { [weak self] in
            for await _ in textChangedStream {
                guard !Task.isCancelled else { break }
                await self?.buildFoldsForDocument()
            }
        }
    }

    deinit { task?.cancel(); continuation.finish() }

    private func buildFoldsForDocument() async {
        guard let foldProvider else { return }
        let revision: UInt64
        let documentRange: NSRange
        var raw: [LineFoldStorage.RawFold] = []
        if let provider = foldProvider as? SnapshotLineFoldProvider {
            guard let snapshot = controller.map({ ($0.foldingRevision, $0.textView.textStorage.string,
                                                   $0.textView.documentRange) }) else { return }
            revision = snapshot.0
            documentRange = snapshot.2
            let regions = await provider.foldRegions(in: snapshot.1)
            guard !Task.isCancelled, revision == controller?.foldingRevision else { return }
            raw = regions.filter {
                $0.range.location >= 0 && $0.range.length > 0 && $0.range.upperBound <= documentRange.length
            }.map { .init(depth: $0.depth, range: $0.range.intRange) }
        } else {
            guard let controller, let textView = controller.textView else { return }
            revision = controller.foldingRevision
            documentRange = textView.documentRange
            var iterator = textView.layoutManager.lineStorage.makeIterator()
            var depth = 0
            var open: [Int: Int] = [:]
            var count = 0
            while revision == controller.foldingRevision, !Task.isCancelled, let line = iterator.next() {
                let events = foldProvider.foldLevelAtLine(lineNumber: line.index, lineRange: line.range,
                                                        previousDepth: depth, controller: controller)
                for event in events {
                    if event.depth > depth {
                        open[event.depth] = event.rangeIndice
                    } else if event.depth < depth {
                        for key in open.keys.filter({ $0 > event.depth }) {
                            if let start = open.removeValue(forKey: key), start < event.rangeIndice {
                                raw.append(.init(depth: key, range: start..<event.rangeIndice))
                            }
                        }
                    }
                    depth = event.depth
                }
                count += 1
                if count % 50 == 0 { await Task.yield() }
            }
            guard revision == controller.foldingRevision, !Task.isCancelled else { return }
            for (key, start) in open where start < documentRange.length {
                raw.append(.init(depth: key, range: start..<documentRange.length))
            }
        }
        // Prüfung, Attachments und Veröffentlichung ohne weiteren Actor-Wechsel.
        guard let controller, let textView = controller.textView,
              revision == controller.foldingRevision, !Task.isCancelled else { return }
        for box in textView.layoutManager.attachments.getAttachmentsOverlapping(documentRange) {
            guard let placeholder = box.attachment as? LineFoldPlaceholder else { continue }
            if let current = raw.first(where: { NSRange($0.range) == box.range }) {
                placeholder.fold = FoldRange(id: 0, depth: current.depth, range: current.range, isCollapsed: true)
            } else {
                // Geaenderter Header/Abschluss: kein versteckter verwaister Body.
                textView.layoutManager.attachments.remove(atOffset: box.range.location)
                textView.needsLayout = true
            }
        }
        let collapsed = textView.layoutManager.attachments.getAttachmentsOverlapping(documentRange)
            .compactMap { box -> LineFoldStorage.DepthStartPair? in
                guard let placeholder = box.attachment as? LineFoldPlaceholder else { return nil }
                return .init(depth: placeholder.fold.depth, start: box.range.location)
            }
        var storage = LineFoldStorage(documentLength: documentRange.length, folds: raw,
                                      collapsedRanges: Set(collapsed))
        storage.revision = revision
        continuation.yield(storage)
    }
}
