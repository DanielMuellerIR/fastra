// OpenTabsSearch.swift
//
// Suche über ALLE geöffneten Tabs (BBEdit: Multi-File-Search-Quelle
// „Open text documents", Handbuch 16.0.1 Kap. 7 S. 184) — der dritte
// Such-Scope „Geöffnet" neben „Datei" und „Ordner". Anders als die
// Ordner-Suche arbeitet dieser Scope rein IN-MEMORY: durchsucht wird der
// aktuelle Tab-Inhalt (auch ungespeicherte/dirty Tabs), nicht die Platte.
//
// Pure Logik ohne Workspace/UI — der SearchRunner reicht einen Snapshot
// der Tabs herein, zurück kommt ein fertiges Ergebnis pro Tab. Dadurch
// bleibt alles headless testbar (gleiches Muster wie BufferSearch).

import Foundation

enum OpenTabsSearch {
    /// Snapshot eines Tabs für die Suche — bewusst nur die drei Felder,
    /// die die Suche braucht (kein EditorTab: der trägt UI-Zustand wie
    /// `isLoading`, den die pure Logik nichts angeht).
    struct TabInput: Equatable {
        let id: UUID
        let title: String
        let content: String
    }

    /// Treffer EINES Tabs. `id` == Tab-ID → stabile SwiftUI-Identität für
    /// die Gruppen-Sections in der Trefferliste.
    struct TabHits: Identifiable, Equatable {
        let id: UUID
        let title: String
        let matches: [BufferSearch.Match]
        /// Wahrer Treffer-Count des Tabs (kann `matches.count` übersteigen,
        /// wenn der Gesamt-Cap griff — BufferSearch zählt immer alle).
        let totalMatches: Int

        var hasMatches: Bool { !matches.isEmpty || totalMatches > 0 }
    }

    /// Gesamtergebnis über alle Tabs — Vertrag analog `BufferSearch.SearchResult`.
    struct Result: Equatable {
        let perTab: [TabHits]
        let totalMatches: Int
        let wasCapped: Bool
        let invalidPatternMessage: String?

        static let empty = Result(perTab: [], totalMatches: 0,
                                  wasCapped: false, invalidPatternMessage: nil)
    }

    /// Durchsucht alle Tabs der Reihe nach. Der Materialisierungs-Cap
    /// (`maxTotal`) gilt GESAMT über alle Tabs — gezählt wird trotzdem
    /// alles (ehrlicher Count in Footer/Maske, keine stille Trunkierung).
    /// Tabs ohne Treffer erscheinen nicht im Ergebnis.
    static func find(tabs: [TabInput], options: SearchOptions,
                     maxTotal: Int = BufferSearch.defaultMaxMatches,
                     shouldCancel: () -> Bool = { false }) -> Result {
        guard !options.isEmpty else { return .empty }

        var perTab: [TabHits] = []
        var total = 0
        var materialized = 0
        for tab in tabs {
            if shouldCancel() { return .empty }
            // Budget: was vom Gesamt-Cap noch übrig ist. 0 ist erlaubt —
            // dann zählt BufferSearch nur noch (materialisiert nichts mehr).
            let budget = max(0, maxTotal - materialized)
            let r = BufferSearch.find(in: tab.content, options: options,
                                      maxMatches: budget,
                                      shouldCancel: shouldCancel)
            // Ungültiges Pattern ist tab-unabhängig → sofort mit der
            // Fehlermeldung raus (roter Streifen in der Maske).
            if let msg = r.invalidPatternMessage {
                return Result(perTab: [], totalMatches: 0,
                              wasCapped: false, invalidPatternMessage: msg)
            }
            guard r.totalMatches > 0 else { continue }
            perTab.append(TabHits(id: tab.id, title: tab.title,
                                  matches: r.matches, totalMatches: r.totalMatches))
            total += r.totalMatches
            materialized += r.matches.count
        }
        guard total > 0 else { return .empty }
        return Result(perTab: perTab, totalMatches: total,
                      wasCapped: total > materialized, invalidPatternMessage: nil)
    }

    /// „Alle ersetzen" über alle Tabs: liefert pro Tab-ID den NEUEN Inhalt —
    /// nur für Tabs, deren Inhalt sich tatsächlich ändert. Der Workspace
    /// wendet das Dictionary dann aufs Tab-Array an (dirty-Markierung,
    /// Editor-Reload). Rein in-memory, kein Disk-Write (Speichern via ⌘S).
    static func replaceAll(tabs: [TabInput], options: SearchOptions) -> [UUID: String] {
        var changed: [UUID: String] = [:]
        for tab in tabs {
            guard let replaced = BufferSearch.replaceAll(in: tab.content, options: options),
                  replaced != tab.content else { continue }
            changed[tab.id] = replaced
        }
        return changed
    }
}
