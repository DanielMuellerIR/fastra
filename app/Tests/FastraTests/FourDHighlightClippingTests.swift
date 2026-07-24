// FourDHighlightClippingTests.swift
//
// CESEs StyledRangeContainer verlangt Highlight-Bereiche INNERHALB des
// angefragten Chunks und verwirft alles, was davor beginnt. Der 4D-Provider
// muss seine gecachten Token deshalb zuschneiden — sonst verliert z. B. ein
// langer /* … */-Kommentar hinter einer Editposition seine Farbe.

import Foundation
import Testing
import CodeEditSourceEditor
@testable import Fastra

@Test("Token, das vor dem Chunk beginnt, wird auf den Chunk zugeschnitten")
func clipsTokenStartingBeforeChunk() {
    let comment = HighlightRange(
        range: NSRange(location: 100, length: 900), capture: .comment
    )
    let clipped = FourDHighlightProvider.clippedRanges(
        [comment], to: NSRange(location: 400, length: 300)
    )
    #expect(clipped.count == 1)
    #expect(clipped[0].range == NSRange(location: 400, length: 300))
    #expect(clipped[0].capture == .comment)
}

@Test("Token außerhalb des Chunks entfällt, Token innerhalb bleibt exakt")
func dropsOutsideKeepsInside() {
    let outside = HighlightRange(
        range: NSRange(location: 0, length: 50), capture: .string
    )
    let inside = HighlightRange(
        range: NSRange(location: 210, length: 20), capture: .keyword
    )
    let clipped = FourDHighlightProvider.clippedRanges(
        [outside, inside], to: NSRange(location: 200, length: 100)
    )
    #expect(clipped.count == 1)
    #expect(clipped[0].range == NSRange(location: 210, length: 20))
    #expect(clipped[0].capture == .keyword)
}

@Test("Token, das hinter dem Chunkende weiterläuft, endet am Chunkende")
func clipsTokenEndingAfterChunk() {
    let comment = HighlightRange(
        range: NSRange(location: 250, length: 500), capture: .comment
    )
    let clipped = FourDHighlightProvider.clippedRanges(
        [comment], to: NSRange(location: 200, length: 100)
    )
    #expect(clipped.count == 1)
    #expect(clipped[0].range == NSRange(location: 250, length: 50))
}
