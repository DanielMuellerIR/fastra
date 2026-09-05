// MyersDiff.swift
//
// Eigener, kooperativ abbrechbarer Myers-Diff über zwei Ganzzahlfolgen.
//
// Warum nicht Foundations `CollectionDifference`? Dessen `difference(from:)`
// ist ein einzelner, nicht unterbrechbarer Aufruf: Nach Tab-/Fensterschluss
// oder einer neuen Anfrage rechnete ein alter Vergleich bis zum Ende weiter
// und belegte parallel zu neuen Läufen Rechenzeit und Speicher (Review
// 2026-08-29, Folgeauftrag 2026-09-05). Diese Fassung prüft in jeder
// Suchrunde die Abbruchquelle und gibt dann sofort auf.
//
// Der Algorithmus ist absichtlich derselbe wie in der Swift-Standardbibliothek
// (`stdlib/public/core/Diffing.swift`, Apache 2.0 mit Runtime Library
// Exception): die Linear-Space-Variante von Myers — Teile-und-herrsche über
// die „mittlere Schlange", vorwärts und rückwärts gleichzeitig gesucht.
// Gleiche Suchreihenfolge, gleiche Entscheidung bei Gleichstand: Nur so
// bleiben die Zeilen-Ausrichtung und damit alle vorhandenen Diff-Fixtures
// bytegleich; `FileDiffCancellationTests` belegt die Gleichheit gegen
// `CollectionDifference` mit Zufallsfolgen. Speicherbedarf: linear in der
// Summe beider Längen (zwei k-Vektoren), nicht quadratisch.

import Foundation

enum MyersDiff {

    /// Ergebnis: Offsets der entfernten Elemente in `old` und der eingefügten
    /// Elemente in `new`. Mehr braucht die Zeilen-Ausrichtung in `FileDiff`
    /// nicht — welche Zeile „umgezogen" ist, bestimmt sie selbst.
    struct Changes: Equatable {
        var removedOffsets: [Int] = []
        var insertedOffsets: [Int] = []
    }

    /// Berechnet den Diff. `isCancelled` wird vor jeder Suche nach einer
    /// mittleren Schlange und in jeder ihrer Tiefenrunden befragt; meldet es
    /// `true`, kommt `nil` zurück — nie ein Teilergebnis.
    static func changes(from old: [Int], to new: [Int],
                        isCancelled: () -> Bool) -> Changes? {
        let box = Box(left: 0, top: 0, right: old.count, bottom: new.count)
            .shrunk(old: old, new: new)
        var search = Search(size: box.size)
        guard let edits = search.findDifferences(in: box, old: old, new: new,
                                                 isCancelled: isCancelled) else {
            return nil
        }
        var changes = Changes()
        for edit in edits {
            switch edit {
            case .remove(let offset): changes.removedOffsets.append(offset)
            case .insert(let offset): changes.insertedOffsets.append(offset)
            }
        }
        // Der Algorithmus liefert die Änderungen nicht sortiert; für die
        // Ausrichtung ist das egal, aufsteigend liest sich im Test leichter.
        changes.removedOffsets.sort()
        changes.insertedOffsets.sort()
        return changes
    }

    /// Eine einzelne Änderung: Entfernung aus `old` oder Einfügung in `new`.
    private enum Edit {
        case remove(Int)
        case insert(Int)
    }

    /// Ein Rechteck des Editgraphen: `left..<right` in `old`,
    /// `top..<bottom` in `new`.
    private struct Box: Equatable {
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int

        var width: Int { right &- left }
        var height: Int { bottom &- top }
        var size: Int { width &+ height }
        var delta: Int { width &- height }
        var isEven: Bool { delta.isMultiple(of: 2) }
        var isOdd: Bool { !isEven }
        var maximumDepth: Int { (size &+ 1) / 2 }

        func cropped(toTopLeftOf limit: Box) -> Box {
            Box(left: left, top: top, right: limit.left, bottom: limit.top)
        }

        func cropped(toBottomRightOf limit: Box) -> Box {
            Box(left: limit.right, top: limit.bottom, right: right, bottom: bottom)
        }

        /// Gemeinsame Elemente an Anfang und Ende abziehen.
        func shrunk(old: [Int], new: [Int]) -> Box {
            var box = self
            while box.left < box.right, box.top < box.bottom,
                  old[box.left] == new[box.top] {
                box.left &+= 1
                box.top &+= 1
            }
            while box.right > box.left, box.bottom > box.top,
                  old[box.right - 1] == new[box.bottom - 1] {
                box.right &-= 1
                box.bottom &-= 1
            }
            return box
        }
    }

    /// Die beiden k-Vektoren (vorwärts/rückwärts) in einem Puffer; Indizes
    /// laufen von `-size` bis `size`.
    private struct Search {
        private var buffer: [Int]
        private let forwardOffset: Int
        private let backwardOffset: Int

        init(size: Int) {
            let range = size * 2 + 1
            buffer = [Int](repeating: 0, count: range * 2)
            forwardOffset = size
            backwardOffset = range + size
        }

        subscript(forward index: Int) -> Int {
            get { buffer[forwardOffset &+ index] }
            set { buffer[forwardOffset &+ index] = newValue }
        }

        subscript(backward index: Int) -> Int {
            get { buffer[backwardOffset &+ index] }
            set { buffer[backwardOffset &+ index] = newValue }
        }

        /// Teile-und-herrsche: mittlere Schlange finden, links davon sofort
        /// weiter, rechts davon auf den Stapel.
        mutating func findDifferences(in initial: Box, old: [Int], new: [Int],
                                      isCancelled: () -> Bool) -> [Edit]? {
            var result: [Edit] = []
            var stack: [Box] = []
            var current = initial
            while true {
                guard let (edit, snakeBox) = middleSnake(
                    in: current, old: old, new: new, isCancelled: isCancelled
                ) else {
                    return nil
                }
                if let edit { result.append(edit) }
                guard let snakeBox else {
                    guard let next = stack.popLast() else { return result }
                    current = next
                    continue
                }
                let headBox = current.cropped(toTopLeftOf: snakeBox).shrunk(old: old, new: new)
                let tailBox = current.cropped(toBottomRightOf: snakeBox).shrunk(old: old, new: new)
                current = headBox
                stack.append(tailBox)
            }
        }

        /// Sucht die mittlere Schlange des Rechtecks. Äußeres `nil` =
        /// abgebrochen; inneres `(edit, box)` wie in der Standardbibliothek.
        private mutating func middleSnake(in box: Box, old: [Int], new: [Int],
                                          isCancelled: () -> Bool) -> (Edit?, Box?)? {
            guard box.size > 1 else {
                if box.size == 0 {
                    return (nil, nil)
                } else if box.width == 1 {
                    return (.remove(box.left), nil)
                } else {
                    return (.insert(box.top), nil)
                }
            }
            self[forward: 1] = box.left
            self[backward: 1] = box.bottom

            for depth in 0...box.maximumDepth {
                // Jede Tiefenrunde kostet O(Rechteckgröße); hier ist der
                // Abbruch billig, und es liegt kein halber Zustand herum.
                if isCancelled() { return nil }
                if box.isOdd {
                    if let found = forwardSearch(in: box, depth: depth, old: old, new: new) {
                        return found
                    }
                    _ = backwardSearch(in: box, depth: depth, old: old, new: new)
                } else {
                    _ = forwardSearch(in: box, depth: depth, old: old, new: new)
                    if let found = backwardSearch(in: box, depth: depth, old: old, new: new) {
                        return found
                    }
                }
            }
            preconditionFailure("Myers-Diff: mittlere Schlange nicht gefunden")
        }

        private mutating func forwardSearch(in box: Box, depth: Int,
                                            old: [Int], new: [Int]) -> (Edit?, Box?)? {
            var k = depth
            while k >= -depth {
                var newRight: Int
                var newBottom: Int
                let newLeft: Int
                let newTop: Int
                let isInsertion: Bool
                let editIndex: Int

                if k == -depth
                    || (k != depth && self[forward: k - 1] < self[forward: k + 1]) {
                    newRight = self[forward: k + 1]
                    newLeft = newRight
                    newBottom = box.top + (newRight - box.left) - k
                    isInsertion = true
                    editIndex = newBottom - 1
                } else {
                    newLeft = self[forward: k - 1]
                    newRight = newLeft + 1
                    newBottom = box.top + (newRight - box.left) - k
                    isInsertion = false
                    editIndex = newLeft
                }
                newTop = (depth == 0 || newRight != newLeft) ? newBottom : newBottom - 1

                while newRight < box.right, newBottom < box.bottom,
                      old[newRight] == new[newBottom] {
                    newRight &+= 1
                    newBottom &+= 1
                }
                self[forward: k] = newRight

                if box.isOdd {
                    let c = k - box.delta
                    if c >= -(depth - 1), c <= depth - 1, newBottom >= self[backward: c] {
                        let edit: Edit = isInsertion ? .insert(editIndex) : .remove(editIndex)
                        return (edit, Box(left: newLeft, top: newTop,
                                          right: newRight, bottom: newBottom))
                    }
                }
                k -= 2
            }
            return nil
        }

        private mutating func backwardSearch(in box: Box, depth: Int,
                                             old: [Int], new: [Int]) -> (Edit?, Box?)? {
            var c = depth
            while c >= -depth {
                let k = c + box.delta
                var newLeft: Int
                var newTop: Int
                let newRight: Int
                let newBottom: Int
                let isInsertion: Bool
                let editIndex: Int

                if c == -depth
                    || (c != depth && self[backward: c - 1] > self[backward: c + 1]) {
                    newTop = self[backward: c + 1]
                    newBottom = newTop
                    newLeft = box.left + (newTop - box.top) + k
                    isInsertion = false
                    editIndex = newLeft
                } else {
                    newBottom = self[backward: c - 1]
                    newTop = newBottom - 1
                    newLeft = box.left + (newTop - box.top) + k
                    isInsertion = true
                    editIndex = newTop
                }
                newRight = (depth == 0 || newTop != newBottom) ? newLeft : newLeft + 1

                while newLeft > box.left, newTop > box.top,
                      old[newLeft - 1] == new[newTop - 1] {
                    newLeft &-= 1
                    newTop &-= 1
                }
                self[backward: c] = newTop

                if box.isEven {
                    if k >= -depth, k <= depth, newLeft <= self[forward: k] {
                        let edit: Edit = isInsertion ? .insert(editIndex) : .remove(editIndex)
                        return (edit, Box(left: newLeft, top: newTop,
                                          right: newRight, bottom: newBottom))
                    }
                }
                c -= 2
            }
            return nil
        }
    }
}
