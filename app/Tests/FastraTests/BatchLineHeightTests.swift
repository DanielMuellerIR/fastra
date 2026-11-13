import Foundation
@testable import CodeEditTextView
import Testing

@Suite("Zeilenhöhen ohne erneuten Baumaufbau")
struct BatchLineHeightTests {
    private struct Row: Identifiable { let id: Int }

    @Test("Höhenabgleich erhält Knoten, Bereiche und Indexsuche bei neuen vertikalen Positionen")
    func transformsPreserveRangesAndPositionLookup() throws {
        for count in [0, 1, 2, 7, 256] {
            let storage = TextLineStorage<Row>()
            storage.build(from: (0..<count).map {
                .init(data: Row(id: $0), length: $0 + 1, height: CGFloat($0 % 3 + 1))
            }, estimatedLineHeight: 3)
            let root = storage.root
            for uniform in [true, false, true] {
                storage.fastraUpdateHeights { uniform ? 3 : CGFloat($0.id % 5 + 1) }
                #expect(storage.root === root)
                #expect(storage.count == count)
                #expect(storage.length == count * (count + 1) / 2)
                var y: CGFloat = 0, offset = 0
                for index in 0..<count {
                    let height: CGFloat = uniform ? 3 : CGFloat(index % 5 + 1)
                    let byIndex = try #require(storage.getLine(atIndex: index))
                    #expect(byIndex.data.id == index)
                    #expect(byIndex.range == NSRange(location: offset, length: index + 1))
                    #expect(byIndex.yPos == y && byIndex.height == height)
                    #expect(storage.getLine(atPosition: y + height / 2)?.data.id == index)
                    #expect(storage.getLine(atOffset: offset)?.data.id == index)
                    y += height; offset += index + 1
                }
                #expect(storage.height == y)
            }
        }
    }
}
