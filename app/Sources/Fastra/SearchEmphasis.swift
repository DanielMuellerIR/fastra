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

    /// Trefferquelle des gerade sichtbaren Dokuments. Im Ordner-/Projekt-
    /// Scope stammen Ranges von der Platte; sie sind nur sicher, wenn der
    /// geöffnete Tab sauber ist und exakt dieselbe Dateibasis besitzt.
    struct Source: Equatable {
        let matches: [BufferSearch.Match]
        let totalMatches: Int
    }

    static func source(scope: Workspace.SearchScope,
                       activeTab: EditorTab?,
                       bufferMatches: [BufferSearch.Match],
                       bufferTotalMatches: Int,
                       folderResults: [FolderSearch.PerFileResult],
                       openResults: [OpenTabsSearch.TabHits]) -> Source? {
        guard let activeTab else { return nil }
        switch scope {
        case .file:
            return Source(matches: bufferMatches, totalMatches: bufferTotalMatches)
        case .open:
            guard let result = openResults.first(where: { $0.id == activeTab.id }) else {
                return nil
            }
            return Source(matches: result.matches, totalMatches: result.totalMatches)
        case .folder, .project:
            guard !activeTab.isDirty,
                  let url = activeTab.url?.canonicalFileURL,
                  let snapshot = activeTab.diskSnapshot,
                  let result = folderResults.first(where: {
                      $0.url.canonicalFileURL == url && $0.snapshot == snapshot
                  }) else {
                return nil
            }
            return Source(matches: result.matches, totalMatches: result.totalMatches)
        }
    }

    /// Pure Cap-Logik (unit-testbar): höchstens `cap` Ranges werden
    /// gezeichnet; `truncated` wird wahr, sobald die ECHTE Gesamtzahl der
    /// Treffer über dem Gezeichneten liegt.
    static func plan(matchRanges: [NSRange], totalMatches: Int,
                     cap: Int = SearchEmphasis.cap) -> Plan {
        let shown = Array(matchRanges.prefix(cap))
        return Plan(ranges: shown, truncated: totalMatches > shown.count)
    }

    /// Sichtbarkeitsbedingung (pure, unit-testbar): bei offener Suchmaske in
    /// der Text-Ansicht. Welcher Teil einer Mehrdateisuche ins aktive
    /// Dokument gehört, entscheidet `source` separat und dateibasis-sicher.
    static func shouldShow(scope: Workspace.SearchScope, dialogOpen: Bool,
                           viewMode: EditorViewMode) -> Bool {
        _ = scope
        return dialogOpen && viewMode == .text
    }

    /// Aktualitätsbedingung der RAM-Trefferbasis (pure, unit-testbar): Nach
    /// einem Edit oder Tabwechsel lässt der SearchRunner die Datei-/Geöffnet-
    /// Treffer absichtlich stehen (keine blinkende Trefferzahl), entzieht
    /// ihnen aber sofort die Freigabe (`visibleBufferResultsOptions = nil`).
    /// Ein verzögertes Nachzeichnen — Scroll-Relay, Editor-Remount — darf
    /// solche Bereiche dann nicht erneut zeichnen: Sie gehören zum alten
    /// Textstand und lägen im neuen Text an falschen Stellen
    /// (Review 2026-08-29). Ordner-/Projekt-Treffer sichert `source` bereits
    /// über Dirty-Zustand und Datei-Snapshot.
    static func bufferResultsAreCurrent(
        scope: Workspace.SearchScope,
        visibleBufferResultsOptions: SearchOptions?,
        currentOptions: SearchOptions
    ) -> Bool {
        switch scope {
        case .file, .open:
            return visibleBufferResultsOptions == currentOptions
        case .folder, .project:
            return true
        }
    }

    /// Räumt die Live-Trefferanzeige SOFORT beim ersten Textedit. Die
    /// Markierungen speichern ihre Bereiche statisch; nach einem Edit sind
    /// sie veraltet und zeichnen an falschen Stellen — bei einem
    /// geschrumpften Dokument sogar hinter dem Dokumentende (sichtbares
    /// „Chaos“ und Absturzursache im Crash-Report vom 2026-08-28). Der
    /// Beobachter läuft synchron auf dem Edit-Thread (Main), also garantiert
    /// VOR dem nächsten Zeichenzyklus; die gedrosselte Live-Suche setzt die
    /// Markierungen danach mit frischen Bereichen neu.
    final class EditGuard {
        private var token: NSObjectProtocol?

        init(textView: TextView) {
            token = NotificationCenter.default.addObserver(
                forName: TextView.textDidChangeNotification,
                object: textView, queue: nil
            ) { [weak textView] _ in
                guard let textView else { return }
                textView.emphasisManager?.removeEmphases(
                    for: SearchEmphasis.groupID
                )
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
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
