// SearchEmphasis.swift
//
// Live-Markierung aller Suchtreffer im aktiven Dokument (Etappe 2 Wunschpaket
// 2026-07b), BBEdit-Vorbild „Show matches“: Während die Suchmaske offen ist,
// zeigt der Editor alle Treffer der Live-Suche als flache, helle Markierungen.
//
// WICHTIG (Produktinvariante): Das ist reine ANZEIGE über den öffentlichen
// `EmphasisManager` des gepinnten CodeEditTextView. Kein Einfluss auf Undo,
// Dirty-Zustand, Ersetzen oder die Trefferbasis der Vorschau — die Layer
// leben ausschließlich im Darstellungs-Baum der TextView.

import AppKit
import CodeEditTextView

enum SearchEmphasis {
    /// Eigene Gruppen-ID im EmphasisManager — getrennt von CESEs eigenen
    /// Gruppen (FindPanel, Klammer-Hervorhebung), damit sich beide Welten
    /// niemals gegenseitig wegräumen.
    static let groupID = "fastra.search"

    /// Obergrenze der gleichzeitig gezeichneten Markierungen. Bewusst gleich
    /// dem Materialisierungs-Cap der Buffer-Suche — mehr Treffer liegen als
    /// Ranges ohnehin nicht vor. Beim Kappen zeigt die Suchmaske einen
    /// sichtbaren Hinweis (kein stilles Abschneiden, Leitplanke).
    static let cap = BufferSearch.defaultMaxMatches

    /// Ergebnis der puren Planung: was wird gezeichnet, wurde gekappt?
    struct Plan: Equatable {
        let ranges: [NSRange]
        let truncated: Bool
    }

    /// Pure Cap-Logik (unit-testbar): höchstens `cap` Ranges werden
    /// gezeichnet; `truncated` wird wahr, sobald die ECHTE Gesamtzahl der
    /// Treffer über dem Gezeichneten liegt.
    static func plan(matchRanges: [NSRange], totalMatches: Int,
                     cap: Int = SearchEmphasis.cap) -> Plan {
        let shown = Array(matchRanges.prefix(cap))
        return Plan(ranges: shown, truncated: totalMatches > shown.count)
    }

    /// Sichtbarkeitsbedingung (pure, unit-testbar): nur bei offener
    /// Suchmaske, nur im Datei-Scope (aktives Dokument) und nur in der
    /// Text-Ansicht. Ordner-/Projekt-/Geöffnet-Scope markieren weiterhin
    /// nur über die Trefferliste.
    static func shouldShow(scope: Workspace.SearchScope, dialogOpen: Bool,
                           viewMode: EditorViewMode) -> Bool {
        dialogOpen && scope == .file && viewMode == .text
    }

    /// Flache, helle Markierung im Stil der System-Suchhervorhebung.
    /// `.outline(fill:)` statt `.standard`, weil der Standard-Stil pro Layer
    /// eine Pop-Animation und einen Schatten mitbringt — bei bis zu 2 000
    /// Treffern wäre das visuelles Rauschen bei jedem Tipp-Debounce.
    /// Halbtransparent, damit der Text unter der Markierung lesbar bleibt.
    static func makeEmphases(for ranges: [NSRange]) -> [Emphasis] {
        let color = NSColor.findHighlightColor.withAlphaComponent(0.45)
        return ranges.map {
            Emphasis(range: $0, style: .outline(color: color, fill: true),
                     flash: false, inactive: false, selectInDocument: false)
        }
    }
}
