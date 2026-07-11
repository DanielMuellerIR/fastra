import SwiftUI
import AppKit
import Combine

enum LineEnding: String, Equatable, CaseIterable, Identifiable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    var id: String { rawValue }

    /// Das tatsächliche Trennzeichen.
    var characters: String {
        switch self {
        case .lf:   return "\n"
        case .crlf: return "\r\n"
        case .cr:   return "\r"
        }
    }

    /// Menü-Beschriftung mit Plattform-Hinweis (BBEdit-Stil).
    var menuLabel: String {
        switch self {
        case .lf:   return "LF (Unix / macOS)"
        case .crlf: return "CRLF (Windows)"
        case .cr:   return "CR (klassisches Mac OS)"
        }
    }

    static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\r")   { return .cr }
        return .lf
    }

    /// Konvertiert ALLE Zeilenumbrüche in `text` einheitlich auf dieses
    /// Format. Erst auf LF normalisieren (CRLF/CR→LF), damit auch gemischte
    /// Eingaben sauber werden, dann auf das Ziel. Pure Funktion → testbar.
    /// Wird beim Speichern angewandt (`Workspace.write`), damit die im Footer
    /// gewählte Konvention wirklich auf der Platte landet — unabhängig davon,
    /// welche Umbrüche der Editor im Speicher hält.
    func converting(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        switch self {
        case .lf:   return normalized
        case .crlf: return normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr:   return normalized.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}

extension String.Encoding {
    /// Kurzname für die Footer-Anzeige.
    var displayName: String {
        switch self {
        case .utf8:                 return "UTF-8"
        case .utf16:                return "UTF-16"
        case .utf16BigEndian:       return "UTF-16 BE"
        case .utf16LittleEndian:    return "UTF-16 LE"
        case .utf32:                return "UTF-32"
        case .ascii:                return "ASCII"
        case .isoLatin1:            return "Latin-1"
        case .isoLatin2:            return "Latin-2"
        case .windowsCP1252:        return "Win-1252"
        case .macOSRoman:           return "Mac Roman"
        default:                    return "Unbekannt"
        }
    }
}

struct EditorTab: Identifiable, Hashable {
    let id: UUID
    var title: String
    var path: String
    var url: URL?
    var content: String
    var encoding: String.Encoding
    var lineEnding: LineEnding
    var hits: Int
    var isDirty: Bool
    /// `true`, während die Datei im Hintergrund geladen wird.
    /// Der Editor zeigt dann einen Lade-Spinner statt dem Inhalt
    /// (CESE-Falle: Inhalt kommt erst nach erfolgreicher Completion
    /// ins Tab → .id-Neuerzeugung läuft mit fertigem Inhalt).
    var isLoading: Bool
    /// Änderungsdatum der Datei auf der Platte, wie es beim letzten
    /// Laden/Speichern bekannt war. Basis der Extern-Änderungs-Erkennung
    /// (BBEdit „Reload from Disk"): weicht das echte Disk-Datum davon ab,
    /// wurde die Datei außerhalb von Fastra geändert. `nil` bei
    /// unbenannten Tabs.
    var diskModificationDate: Date?

    init(
        id: UUID = UUID(),
        title: String,
        path: String,
        url: URL? = nil,
        content: String = "",
        encoding: String.Encoding = .utf8,
        lineEnding: LineEnding = .lf,
        hits: Int = 0,
        isDirty: Bool = false,
        isLoading: Bool = false,
        diskModificationDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.url = url
        self.content = content
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hits = hits
        self.isDirty = isDirty
        self.isLoading = isLoading
        self.diskModificationDate = diskModificationDate
    }
}

/// Pure Entscheidungs-Logik der Extern-Änderungs-Erkennung (BBEdit
/// „Automatically refresh documents" / „Reload from Disk", Handbuch 16.0.1
/// Kap. 3 S. 59): Was passiert mit einem Tab, dessen Datei sich auf der
/// Platte geändert hat? Sauberer Tab → still neu laden (kein Datenverlust
/// möglich). Dirty Tab → Nutzer fragen (lokale Änderungen stehen gegen die
/// externen). Unbenannt/kein Vergleichsdatum/Datei weg → nichts tun.
enum ExternalChange {
    enum Action: Equatable {
        case none
        case reloadSilently
        case askUser
    }

    static func action(isDirty: Bool, knownDate: Date?, diskDate: Date?) -> Action {
        guard let known = knownDate, let disk = diskDate else { return .none }
        guard disk > known else { return .none }
        return isDirty ? .askUser : .reloadSilently
    }

    /// Aktuelles Änderungsdatum der Datei auf der Platte (`nil`, wenn die
    /// Datei nicht erreichbar ist — gelöscht, Volume weg, keine Rechte).
    static func diskModificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Nutzer-Entscheidung beim Schließen eines Tabs mit ungespeicherten Änderungen
/// (BBEdit-Stil). Siehe `Workspace.confirmCloseHandler` / `Workspace.closeTab`.
enum CloseConfirmation {
    case save        // sichern, dann schließen
    case dontSave    // ohne Sichern schließen (Änderungen verwerfen)
    case cancel      // Schließen abbrechen, Tab bleibt offen
}

final class Workspace: ObservableObject {
    @Published var tabs: [EditorTab]
    @Published var activeTabID: UUID?
    // Startet GESCHLOSSEN (Daniel 2026-06-22: „nicht mehr mit offenem Suchdialog
    // starten, das war nur zum Testen"). CMD+F / CMD+SHIFT+F öffnen sie. Die
    // fenster-abhängigen Selbsttests (cmdw/fields) öffnen sie jetzt selbst,
    // siehe SelfTest.openSearchThen.
    @Published var showSearchDialog: Bool = false
    @Published var findPattern: String = "([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+)\\.([a-zA-Z]{2,})"
    @Published var replacePattern: String = "[$1](mailto:$1@$2.$3)"
    @Published var livePreview: Bool = false
    @Published var scope: SearchScope = .folder

    // MARK: - Such-Optionen (Suchmasken-Konzept B.5)
    //
    // Default-Haltung: RegEx aus. Fastra ist „ein Editor mit RegEx-
    // Superkraft", nicht „ein RegEx-Tool, das auch suchen kann".
    // Beim ersten Öffnen dieses Prototyps starten wir trotzdem mit
    // RegEx=an, damit die Demo-Highlights direkt sichtbar sind —
    // sobald die echte Logik kommt, wechselt der Default auf `false`.
    @Published var useRegex: Bool = true
    @Published var caseSensitive: Bool = false
    @Published var wholeWord: Bool = false
    @Published var wrapAround: Bool = true

    /// Mini-Schalter „`*` wörtlich nehmen" (Feature J). Erscheint in der Maske
    /// nur, wenn RegEx aus ist und das Muster ein `*` enthält. Aus = `*` wirkt
    /// als Platzhalter (Default); an = `*` wird buchstäblich gesucht.
    @Published var treatWildcardLiterally: Bool = false

    // MARK: - „Nur in Auswahl" (BBEdit „Selected Text Only", K3)
    //
    // Wenn an, suchen/ersetzen Buffer-Operationen NUR innerhalb einer
    // EINGEFRORENEN Selektions-Range (`searchSelectionRange`), nicht der
    // live mitwandernden `selectionRange`. Sonst würde ein Treffer-Sprung
    // (der selbst eine Selektion setzt) den Such-Bereich auf diesen einen
    // Treffer zusammenschrumpfen. Der Snapshot wird beim Einschalten gesetzt.
    @Published var searchInSelectionOnly: Bool = false
    /// Eingefrorene Such-Selektion (UTF-16-NSRange) — Quelle der Wahrheit für
    /// „Nur in Auswahl". Wird beim Einschalten aus `selectionRange` kopiert.
    private(set) var searchSelectionRange: NSRange? = nil
    /// Such-Range, die die Engine tatsächlich nutzt: die eingefrorene
    /// Auswahl, falls „Nur in Auswahl" aktiv ist, sonst `nil` (ganzer Text).
    var activeSearchRange: NSRange? {
        searchInSelectionOnly ? searchSelectionRange : nil
    }

    // MARK: - Vorlagen-Auswahl
    /// ID der gerade ausgewählten Vorlage (`nil` = freier Suchausdruck,
    /// keine Vorlage). Die Patterns selbst leben in `BuiltInPatterns`.
    @Published var selectedTemplateID: String? = nil

    // MARK: - Cursor-Position (Footer-Anzeige)
    //
    // Wird vom `EditorView` aus `SourceEditorState.cursorPositions`
    // gespiegelt und im Footer (`StatusBarView`) als „Zeile / Spalte"
    // gezeigt. `nil` = kein Cursor (z.B. Editor ohne Fokus) → Footer
    // zeigt dann Platzhalter.
    @Published var cursorLine: Int? = nil
    @Published var cursorColumn: Int? = nil

    // MARK: - Aktuelle Editor-Selektion (UTF-16-NSRange)
    //
    // Vom `EditorView` gespiegelt (aus `SourceEditorState.cursorPositions`).
    // `nil` = kein zusammenhängend ausgewählter Bereich (nur Cursor). Dient
    // „Nur in Auswahl" (K3) und „Auswahl als Suchbegriff" (K5, ⌘E).
    @Published var selectionRange: NSRange? = nil

    // MARK: - Footer-Statistik (Zeichen / Wörter / Zeilen)
    //
    // Bei aktiver Selektion beziehen sich die Zahlen auf die Selektion,
    // sonst auf die ganze Datei (BBEdit-Verhalten). Die Berechnung läuft
    // asynchron auf einem Hintergrund-Thread, damit große Dateien die UI
    // nicht blockieren. `statsGeneration` verwirft veraltete Ergebnisse,
    // wenn währenddessen schon die nächste Berechnung gestartet wurde.
    @Published var documentStatsText: String = "— / — / —"
    /// `true`, wenn sich die aktuelle Statistik auf eine Selektion bezieht.
    @Published var statsIsSelection: Bool = false
    private var statsGeneration = 0

    // MARK: - Asynchrones Datei-Laden (v0.9)
    //
    // Jede `loadFile`-Anfrage bekommt eine Generation-Nummer (pro Tab-ID).
    // Wenn ein Tab geschlossen wird, bevor der Hintergrund-Task fertig ist,
    // erkennt der Guard das an der fehlenden ID und bricht ab — kein
    // Geister-Tab, kein falsches activeTabID.
    /// Aktuellste Lade-Generation pro Tab-UUID. Pattern analog zu
    /// `statsGeneration` in `recomputeDocumentStats`.
    private var loadGeneration: [UUID: Int] = [:]

    /// Stößt eine (asynchrone) Neuberechnung der Footer-Statistik an.
    /// - Parameters:
    ///   - fullText: Gesamter Editor-Inhalt.
    ///   - selectionNSRange: Selektion als `NSRange` (UTF-16-Offsets, wie
    ///     vom Editor geliefert) oder `nil`, wenn nur ein Cursor ohne
    ///     Auswahl steht → dann zählt die ganze Datei.
    func recomputeDocumentStats(fullText: String, selectionNSRange: NSRange?) {
        statsGeneration += 1
        let generation = statsGeneration

        // NSRange (UTF-16) in einen Swift-String-Bereich übersetzen. Bei
        // ungültigem/leerem Range zählt die ganze Datei.
        let selectedRange: Range<String.Index>? = {
            guard let ns = selectionNSRange, ns.length > 0 else { return nil }
            return Range(ns, in: fullText)
        }()
        let isSelection = selectedRange != nil

        // Eine eigenständige Kopie an den Hintergrund übergeben.
        let target = String(selectedRange.map { fullText[$0] } ?? fullText[...])

        DispatchQueue.global(qos: .userInitiated).async {
            let text = DocumentStats.format(DocumentStats.counts(of: target))

            DispatchQueue.main.async {
                // Veraltetes Ergebnis verwerfen.
                guard generation == self.statsGeneration else { return }
                self.documentStatsText = text
                self.statsIsSelection = isSelection
            }
        }
    }

    // MARK: - Sofort-Treffer in der Maske (jetzt echt, nicht mehr Demo)
    /// Echte Treffer im aktiven Buffer — gefüttert vom `SearchRunner`,
    /// gilt im Datei-Scope.
    @Published var bufferMatches: [BufferSearch.Match] = []
    /// ECHTE Gesamtzahl der Buffer-Treffer. Kann `bufferMatches.count`
    /// übersteigen, wenn der Cap (`BufferSearch.defaultMaxMatches`) griff —
    /// die Maske zeigt diese Zahl (ehrlicher Count wie BBEdits Statuszeile).
    @Published var bufferTotalMatches: Int = 0
    /// `true`, wenn die Buffer-Trefferliste durch den Cap gekürzt wurde.
    /// Die Maske zeigt dann einen dezenten Hinweis-Streifen.
    @Published var bufferResultsWereCapped: Bool = false
    /// `true`, solange die Buffer-Suche im Hintergrund läuft (großer Buffer
    /// + kurzes Pattern). Die Maske zeigt darauf basierend einen Spinner —
    /// die Suche blockiert NIE den Main-Thread (kein Beachball).
    @Published var bufferSearching: Bool = false
    /// Wenn das Find-Pattern syntaktisch ungültig ist, steht hier die
    /// erklärende Meldung. Die Maske zeigt sie als roten Hinweis-Streifen.
    @Published var searchError: String? = nil
    /// Index des aktiv im Detail-Bereich gezeigten Treffers.
    @Published var activeMatchIndex: Int = 0

    /// Zähler, der den Editor zu einer Neuerzeugung zwingt, wenn der aktive
    /// Buffer-Inhalt PROGRAMMATISCH geändert wurde (z.B. „Alle ersetzen" /
    /// Einzel-Ersetzen). Hintergrund: CodeEditSourceEditor liest den
    /// Binding-Text NUR EINMAL bei der Erzeugung und schiebt spätere
    /// Binding-Änderungen NICHT in die TextView zurück (Text fließt nur
    /// TextView → Binding, siehe EditorView). Ein In-Memory-Replace ändert
    /// daher zwar das Modell (und die Suche findet danach korrekt 0 Treffer),
    /// aber der Editor zeigt weiter den ALTEN Text — es sieht aus, als sei
    /// „nichts passiert". EditorView hängt diesen Zähler an die `.id` des
    /// Editors; jedes Hochzählen erzeugt den Editor mit dem frischen Inhalt
    /// neu — dieselbe bewährte Mechanik wie bei Tab-Wechsel und Datei-Reload.
    @Published var editorReloadNonce: Int = 0

    // MARK: - Folder-Scope-Ergebnisse
    /// Pro-Datei-Treffer im Ordner-Scope (gefüttert vom `SearchRunner`,
    /// asynchron via `Task.detached`).
    @Published var folderResults: [FolderSearch.PerFileResult] = []
    /// Summe aller Treffer über alle Dateien im Folder-Scope.
    @Published var folderTotalMatches: Int = 0
    /// `true`, solange die Folder-Suche im Hintergrund läuft. Die Maske
    /// zeigt darauf basierend einen Spinner oder „Suche läuft…"-Hinweis.
    @Published var folderSearching: Bool = false
    /// `true`, wenn im Ordner-Scope eine explizite Suche aussteht — die
    /// Eingaben haben sich geändert, aber Ordner werden NICHT live
    /// durchsucht (Konzept Abschnitt C). Die Maske zeigt dann statt
    /// „Keine Treffer." den Hinweis, „Suchen" zu klicken / Return zu
    /// drücken. Wird vom `SearchRunner` gesetzt/gelöscht.
    @Published var folderNeedsSearch: Bool = false
    /// `true`, wenn der letzte Ordner-Such-Lauf durch den Gesamt-Cap
    /// (`FolderSearch.find maxTotalMatches`) vorzeitig abgebrochen wurde.
    /// Die Maske zeigt dann einen dezenten Hinweis-Streifen, damit der
    /// Nutzer NICHT still-trunkierte Ergebnisse für vollständig hält.
    @Published var folderResultsWereCapped: Bool = false

    // MARK: Scope „Geöffnet" (BBEdit „Open text documents", Kap. 7 S. 184)

    /// Pro-Tab-Treffer im Geöffnet-Scope — Suche über ALLE offenen Tabs,
    /// rein in-memory (auch dirty/ungespeicherte Inhalte). Gefüttert vom
    /// `SearchRunner`, asynchron wie die Buffer-Suche.
    @Published var openResults: [OpenTabsSearch.TabHits] = []
    /// Wahre Treffer-Summe über alle Tabs (Cap-unabhängig).
    @Published var openTotalMatches: Int = 0
    /// `true`, wenn der Materialisierungs-Cap über alle Tabs griff —
    /// die Maske zeigt dann den orangen Hinweis-Streifen.
    @Published var openResultsWereCapped: Bool = false

    /// Wird in `init` aufgebaut und hält die Combine-Subscription am
    /// Leben. Sucht in `bufferMatches` neu, sobald sich Such-Inputs
    /// oder der aktive Buffer ändern.
    private var searchRunner: SearchRunner?

    /// Hält die Persistenz-Subscription für `recentSearchFolders` am
    /// Leben — schreibt jede Änderung zurück in UserDefaults.
    private var persistenceBag = Set<AnyCancellable>()

    /// Die in `init` injizierte UserDefaults-Suite — Selbsttests bekommen
    /// eine isolierte, Normalbetrieb `.standard`. ALLE Persistenz-Pfade
    /// des Workspace müssen über diese Suite laufen (siehe init-Kommentar).
    private let defaultsStore: UserDefaults

    /// Schwache Referenz auf den Workspace des gerade aktiven Dokumentfensters.
    /// Die In-App-Selbsttests verwenden denselben Hook. Seit mehrere
    /// Dokumentfenster möglich sind, setzen die Fenster-Brücken diesen Wert bei
    /// jedem Fokuswechsel neu; globale Menübefehle landen dadurch nicht im
    /// falschen Dokument.
    static weak var shared: Workspace?

    /// Alle noch lebenden Workspaces, ohne ihre Lebenszeit zu verlängern.
    /// AppDelegate braucht die Liste für ⌘Q und die Prüfung externer Änderungen:
    /// beide Vorgänge müssen jedes offene Dokumentfenster berücksichtigen.
    private static let liveWorkspaces = NSHashTable<Workspace>.weakObjects()
    /// Swift-Testing führt Workspace-Tests parallel aus. NSHashTable ist nicht
    /// threadsicher, daher jeden Registry-Zugriff kurz serialisieren.
    private static let liveWorkspacesLock = NSLock()

    static var allLive: [Workspace] {
        liveWorkspacesLock.lock()
        defer { liveWorkspacesLock.unlock() }
        return liveWorkspaces.allObjects
    }

    private static func registerLive(_ workspace: Workspace) {
        liveWorkspacesLock.lock()
        defer { liveWorkspacesLock.unlock() }
        liveWorkspaces.add(workspace)
    }

    init(defaults: UserDefaults = .standard) {
        // Die injizierten Defaults merken — ALLE Persistenz-Pfade des
        // Workspace müssen dieselbe Suite nutzen. Vorher schrieb der
        // recentSearchFolders-Sink hart in `.standard`: Selbsttest-Läufe
        // (isolierte Suite!) haben so ihre Temp-Ordner in die ECHTEN
        // Nutzer-Defaults gemüllt (Befund 2026-06-11, 16 Leichen).
        self.defaultsStore = defaults

        // Demo-Inhalt NUR beim allerersten Start (Interview-Erkenntnis 4:
        // leerer Start verhindert Einstieg — aber wer die App kennt, will
        // nicht bei jedem Start das Adressbuch-Demo wegklicken müssen).
        // `consumeFirstLaunch` setzt das UserDefaults-Flag gleich mit.
        if DemoData.consumeFirstLaunch(defaults: defaults) {
            let demo = EditorTab(
                title: "contacts.md",
                path: "Demo · noch nicht gespeichert",
                content: DemoData.editorContent(for: "contacts.md"),
                hits: 8
            )
            self.tabs = [demo]
            self.activeTabID = demo.id
            // Das vorbelegte E-Mail-Pattern (Property-Default oben) bleibt
            // beim ersten Start stehen — Demo-Text und Pattern gehören
            // als Paar zusammen.
            // Scope auf DATEI statt Ordner: das Demo-Pattern matcht im
            // Demo-Tab (Buffer). Im Ordner-Scope sähe ein neuer Nutzer
            // stattdessen „Kein Ordner ausgewählt." — genau der leere
            // Einstieg, den das Demo verhindern soll (Befund 2026-06-11).
            self.scope = .file
        } else {
            // Folgestarts: leerer, unbenannter Tab wie in einem normalen
            // Editor — und KEIN vorbelegtes Such-Pattern.
            let empty = EditorTab(
                title: "Ohne Titel",
                path: "noch nicht gespeichert"
            )
            self.tabs = [empty]
            self.activeTabID = empty.id
            self.findPattern = ""
            self.replacePattern = ""
        }
        self.searchRunner = SearchRunner(workspace: self)
        Workspace.registerLive(self)
        Workspace.shared = self

        // Recent-Folders aus DERSELBEN Suite laden, in die auch gespeichert
        // wird. Der Property-Default (`.standard` im Initializer) wird hier
        // bewusst überschrieben — Property-Initializer laufen VOR dem
        // init-Body und kennen `defaults` noch nicht.
        self.recentSearchFolders = RecentSearchFoldersStore.load(from: defaults)

        // Jede Änderung an der Recent-Folders-Liste in UserDefaults
        // schreiben. `dropFirst()` überspringt den Initial-Wert (das Setzen
        // direkt hier drüber zählt NICHT — der Sink wird erst danach
        // registriert), sonst würden wir gleich nach dem Init schon
        // (überflüssig) speichern. `defaults` capturen, damit Selbsttests
        // in ihrer isolierten Suite bleiben.
        $recentSearchFolders
            .dropFirst()
            .sink { entries in RecentSearchFoldersStore.save(entries, to: defaults) }
            .store(in: &persistenceBag)

        // Recent-Files (K2) und Such-Verlauf (K4) aus DERSELBEN Suite laden
        // und bei jeder Änderung zurückschreiben — gleiches Muster wie oben.
        self.recentFiles = RecentFilesStore.load(from: defaults)
        $recentFiles
            .dropFirst()
            .sink { paths in RecentFilesStore.save(paths, to: defaults) }
            .store(in: &persistenceBag)

        self.searchHistory = SearchHistoryStore.load(from: defaults)
        $searchHistory
            .dropFirst()
            .sink { entries in SearchHistoryStore.save(entries, to: defaults) }
            .store(in: &persistenceBag)

        // Beim KALTEN Start kann eine per Finder/CLI geöffnete Datei schon
        // VOR diesem init im AppDelegate gepuffert worden sein → jetzt, wo
        // `Workspace.shared` steht, dem AppDelegate signalisieren, dass es
        // gepufferte URLs ausliefern darf (K1). Bewusst über eine
        // Notification statt `NSApp.delegate` — in Unit-Tests gibt es keine
        // NSApplication, ein `NSApp`-Zugriff (implizit entpacktes Optional)
        // würde dort crashen. Der Post ist in Tests ein harmloses No-op
        // (kein Observer registriert).
        NotificationCenter.default.post(name: .fastraWorkspaceReady, object: nil)
    }

    var activeTab: EditorTab? {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs.first
    }

    private var activeTabIndex: Int? {
        guard let id = activeTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == id })
    }

    /// Schreibender Zugriff auf den Content der aktiven Tab — direkt als Binding fürs Editor-Field.
    var activeTabContent: Binding<String> {
        Binding(
            get: { self.activeTab?.content ?? "" },
            set: { newValue in
                guard let idx = self.activeTabIndex else { return }
                if self.tabs[idx].content != newValue {
                    self.tabs[idx].content = newValue
                    if !self.tabs[idx].isDirty {
                        self.tabs[idx].isDirty = true
                    }
                }
            }
        )
    }

    // MARK: Tab-Verwaltung

    func openNewTab() {
        let new = EditorTab(
            title: "untitled-\(tabs.count + 1).txt",
            path: "—",
            content: ""
        )
        tabs.append(new)
        activeTabID = new.id
    }

    /// BBEdit-Stil-Rückfrage beim Schließen eines Tabs mit ungespeicherten
    /// Änderungen: Sichern / Nicht sichern / Abbrechen. Standardmäßig ein echter
    /// `NSAlert`; in Tests injizierbar (kein Modal), damit der Schließen-Pfad
    /// prüfbar bleibt. Bekommt den Tab-Titel, liefert die Nutzer-Entscheidung.
    var confirmCloseHandler: (String) -> CloseConfirmation = Workspace.defaultCloseConfirmation

    /// Schließt das Dokumentfenster, nachdem der letzte Tab erfolgreich
    /// aufgelöst wurde. Die echte App setzt den Handler über
    /// `MainWindowTitleBridge`; Tests injizieren eine Zähl-Closure. Optional,
    /// damit reine Workspace-Tests auch ohne NSWindow funktionieren.
    var closeWindowHandler: (() -> Void)?

    /// Der echte Schließen-Dialog (BBEdit-Stil). Drei Knöpfe in macOS-Anordnung
    /// (rechts → links): Sichern (Default), Abbrechen, Nicht sichern.
    static func defaultCloseConfirmation(_ title: String) -> CloseConfirmation {
        let alert = NSAlert()
        // codereview-ok: „…“ (U+201E/U+201C) IST das korrekte deutsche Anführungszeichen-Paar; U+201D wäre englisch (2026-07-06)
        alert.messageText = "Möchten Sie die Änderungen an „\(title)“ sichern?"
        alert.informativeText = "Ihre Änderungen gehen verloren, wenn Sie sie nicht sichern."
        alert.addButton(withTitle: "Sichern")          // .alertFirstButtonReturn  (Default, rechts)
        alert.addButton(withTitle: "Abbrechen")        // .alertSecondButtonReturn (Mitte)
        alert.addButton(withTitle: "Nicht sichern")    // .alertThirdButtonReturn  (links)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default:                      return .cancel
        }
    }

    /// Darf der Tab geschlossen werden? Sauberer Tab → ja, OHNE Rückfrage (so
    /// schließt ein leeres/unverändertes Dokument wie bisher sofort). Dirty →
    /// fragt über `confirmCloseHandler`: „Nicht sichern" → ja (verwerfen),
    /// „Abbrechen" → nein, „Sichern" → erst sichern, dann ja — aber NUR, wenn das
    /// Sichern wirklich klappte. Ein abgebrochenes „Sichern unter…"-Panel oder ein
    /// Schreibfehler lässt `isDirty` true → wir geben false zurück, damit nichts
    /// ungesichert verloren geht.
    private func mayCloseTab(id: UUID) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else {
            return true
        }
        let tab = tabs[idx]
        // Ein unbenanntes Dokument ohne Inhalt hat nichts, was verloren gehen
        // könnte — selbst wenn es durch Tippen + Löschen noch `isDirty` ist.
        // Eine gespeicherte, nun leere Datei bleibt dagegen rückfragepflichtig:
        // dort würde Schließen das Löschen des bisherigen Disk-Inhalts verwerfen.
        let isEmptyUntitled = tab.url == nil && tab.content.isEmpty
        guard tab.isDirty && !isEmptyUntitled else {
            return true
        }
        switch confirmCloseHandler(tab.title) {
        case .dontSave:
            return true
        case .cancel:
            return false
        case .save:
            // saveActiveTab wirkt auf den AKTIVEN Tab → diesen kurz aktivieren.
            activeTabID = id
            saveActiveTab()
            // Erfolg = der Tab ist jetzt nicht mehr dirty (Panel/Schreiben ok).
            if let i = tabs.firstIndex(where: { $0.id == id }) { return !tabs[i].isDirty }
            return true
        }
    }

    /// Schließt den Tab mit `id` — bei ungespeicherten Änderungen erst nach der
    /// BBEdit-Rückfrage (`mayCloseTab`). Zentrale Schließen-Logik für ⌘W, das
    /// Tab-X und „Andere Tabs schließen". „Abbrechen" lässt alles unverändert.
    func closeTab(id: UUID) {
        // Der letzte Tab repräsentiert das Dokumentfenster selbst. Nach der
        // üblichen Sicherungsentscheidung nicht einen leeren Fensterrahmen
        // zurücklassen, sondern das Fenster schließen. Der gemeinsame Pfad
        // gilt für ⌘W und Tab-X.
        if tabs.count == 1, tabs[0].id == id {
            guard prepareToCloseWindow() else { return }
            closeWindowHandler?()
            return
        }

        let previousActive = activeTabID
        guard mayCloseTab(id: id) else { return }           // Abbrechen → Tab bleibt
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        // Aktiven Tab konsistent halten: war ein ANDERER Tab aktiv und existiert
        // noch, bleibt er aktiv (mayCloseTab kann activeTabID fürs Sichern kurz
        // umgesetzt haben); sonst den ersten verbleibenden aktivieren.
        if let prev = previousActive, prev != id, tabs.contains(where: { $0.id == prev }) {
            activeTabID = prev
        } else {
            activeTabID = tabs.first?.id
        }
    }

    func closeActiveTab() {
        guard let id = activeTabID else { return }
        closeTab(id: id)
    }

    /// Löst alle Tabs eines zu schließenden Dokumentfensters nach denselben
    /// Regeln wie ⌘W auf und entfernt sie erst, wenn keine Entscheidung mehr
    /// offen ist. Wird auch vom roten Schließen-Knopf zusätzlicher Fenster
    /// verwendet. `false` bedeutet: Nutzer hat abgebrochen, Fenster bleibt.
    func prepareToCloseWindow() -> Bool {
        let previousActive = activeTabID
        for id in tabs.map(\.id) {
            guard mayCloseTab(id: id) else {
                if let previousActive,
                   tabs.contains(where: { $0.id == previousActive }) {
                    activeTabID = previousActive
                }
                return false
            }
        }
        tabs.removeAll()
        activeTabID = nil
        return true
    }

    /// Schließt alle Tabs außer dem mit `id` (BBEdit „Close Others", K8).
    /// Der behaltene Tab wird aktiv. Bei nur einem Tab no-op. Vor dem Schließen
    /// wird pro Tab mit ungespeicherten Änderungen gefragt; „Abbrechen" bricht die
    /// GESAMTE Aktion ab (es wird dann kein Tab geschlossen).
    func closeOtherTabs(keeping id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        for otherID in tabs.map(\.id) where otherID != id {
            guard mayCloseTab(id: otherID) else { return }   // Abbrechen → alles bleibt
        }
        tabs.removeAll { $0.id != id }
        activeTabID = id
    }

    /// Vor dem App-Beenden (⌘Q): über JEDEN Tab mit ungespeicherten Änderungen die
    /// BBEdit-Rückfrage führen (Sichern / Nicht sichern / Abbrechen). Liefert
    /// `true`, wenn alle aufgelöst sind (gesichert oder bewusst verworfen) → die App
    /// darf enden; `false`, sobald der Nutzer einmal „Abbrechen" wählt oder ein
    /// „Sichern unter…" abbricht → Beenden abbrechen. Schließt KEINE Tabs (die App
    /// endet ohnehin) — entscheidend ist nur, dass nichts ungefragt verloren geht.
    /// Vom AppDelegate aus `applicationShouldTerminate` aufgerufen.
    func confirmCloseAllDirtyForQuit() -> Bool {
        // `mayCloseTab` setzt im „Sichern"-Zweig kurz `activeTabID` auf den
        // gerade gesicherten Tab um (saveActiveTab wirkt nur auf den AKTIVEN
        // Tab). Da diese Methode KEINE Tabs schließt, würde ein abgebrochenes
        // Beenden den ursprünglich aktiven Tab verlieren — der zuletzt
        // gesicherte bliebe aktiv. Deshalb wie `closeTab` den ursprünglich
        // aktiven Tab merken und am Ende wiederherstellen.
        let previousActive = activeTabID
        for id in tabs.map(\.id) {
            guard mayCloseTab(id: id) else {
                // Abgebrochen → ursprünglich aktiven Tab wiederherstellen, falls
                // er noch existiert (er wird hier ohnehin nie entfernt).
                if let prev = previousActive, tabs.contains(where: { $0.id == prev }) {
                    activeTabID = prev
                }
                return false
            }
        }
        // Alle aufgelöst → ursprünglich aktiven Tab wiederherstellen (das
        // kurze Umsetzen durchs Sichern soll nicht sichtbar nachwirken).
        if let prev = previousActive, tabs.contains(where: { $0.id == prev }) {
            activeTabID = prev
        }
        return true
    }

    // MARK: - Zeilenenden umschalten (K7)

    /// Setzt die Zeilenende-Konvention des aktiven Tabs. Der Inhalt wird NICHT
    /// sofort umgeschrieben (das überlebte die CESE-Binding-Reconcile-Falle
    /// nicht) — stattdessen konvertiert `write` beim Speichern. Der Tab wird
    /// als geändert markiert, damit klar ist, dass Speichern nötig ist.
    func setActiveLineEnding(_ ending: LineEnding) {
        guard let idx = activeTabIndex else { return }
        guard tabs[idx].lineEnding != ending else { return }
        tabs[idx].lineEnding = ending
        tabs[idx].isDirty = true
    }

    // MARK: - Neu öffnen mit Encoding (K6)

    /// Encodings, die das „Neu öffnen mit Encoding"-Menü anbietet. Bewusst
    /// die in der Praxis relevanten — keine erschöpfende Liste.
    static let reopenEncodings: [String.Encoding] = [
        .utf8, .utf16LittleEndian, .utf16BigEndian,
        .isoLatin1, .windowsCP1252, .macOSRoman, .ascii,
    ]

    /// Lädt den aktiven Tab erneut von der Platte, dekodiert dabei MIT dem
    /// gewählten Encoding (BBEdit „Reopen using Encoding"). Nur möglich, wenn
    /// der Tab eine Datei-URL hat. Bei ungespeicherten Änderungen wird vorher
    /// gewarnt (das Neu-Laden verwirft sie). Async + Generation-Guard wie
    /// `loadFile`/`reloadOpenTabs`; `isLoading`-Toggle erzwingt die Editor-
    /// Neuerzeugung, damit der neu dekodierte Inhalt sichtbar wird.
    func reopenActiveTab(withEncoding encoding: String.Encoding) {
        guard let idx = activeTabIndex, let url = tabs[idx].url else {
            NSSound.beep()   // unbenannter Tab → nichts zum Neu-Laden
            return
        }
        if tabs[idx].isDirty {
            let alert = NSAlert()
            alert.messageText = "Ungespeicherte Änderungen verwerfen?"
            // codereview-ok: „…“ (U+201E/U+201C) IST das korrekte deutsche Anführungszeichen-Paar; U+201D wäre englisch (2026-07-06)
            alert.informativeText = "„\(tabs[idx].title)“ wird mit \(encoding.displayName) neu von der Platte geladen. Deine ungespeicherten Änderungen gehen dabei verloren."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Neu laden")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let tabID = tabs[idx].id
        let generation = (loadGeneration[tabID] ?? 0) + 1
        loadGeneration[tabID] = generation
        tabs[idx].isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try FileLoader.load(url: url, forcedEncoding: encoding) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.loadGeneration[tabID] == generation,
                      let i = self.tabs.firstIndex(where: { $0.id == tabID }) else {
                    if !self.tabs.contains(where: { $0.id == tabID }) {
                        self.loadGeneration.removeValue(forKey: tabID)
                    }
                    return
                }
                self.loadGeneration.removeValue(forKey: tabID)
                switch result {
                case .success(let loaded):
                    self.tabs[i].content    = loaded.content
                    self.tabs[i].encoding   = loaded.encoding
                    self.tabs[i].lineEnding = loaded.lineEnding
                    self.tabs[i].isDirty    = false
                    self.tabs[i].isLoading  = false
                    self.tabs[i].diskModificationDate = ExternalChange.diskModificationDate(of: url)
                case .failure:
                    // Bytes passen nicht zum gewählten Encoding → Tab unverändert
                    // lassen (kein Datenverlust), Spinner aus, Hinweis zeigen.
                    self.tabs[i].isLoading = false
                    NSAlert.runWarning(title: "Neu öffnen fehlgeschlagen",
                        text: "Die Datei lässt sich nicht als \(encoding.displayName) lesen. Der bisherige Inhalt bleibt unverändert.")
                }
            }
        }
    }

    // MARK: Extern-Änderungs-Erkennung (BBEdit „Reload from Disk", Kap. 3 S. 59)

    /// Rückfrage bei extern geänderter Datei MIT lokalen ungespeicherten
    /// Änderungen. `true` = neu laden (lokale Änderungen verwerfen).
    /// Injizierbar für Tests (kein Modal) — Muster wie `confirmCloseHandler`.
    var externalReloadConfirmHandler: (String) -> Bool = Workspace.defaultExternalReloadConfirmation

    /// Der echte Dialog: warnend, Behalten ist der sichere Default-Weg
    /// über Abbrechen-Position — Datenverlust nur auf expliziten Klick.
    static func defaultExternalReloadConfirmation(_ title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "„\(title)“ wurde außerhalb von Fastra geändert."
        alert.informativeText = "Die Datei auf der Festplatte ist neuer, dieser Tab enthält aber ungespeicherte Änderungen. Neu laden verwirft deine Änderungen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Behalten")     // sicherer Default
        alert.addButton(withTitle: "Neu laden")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Prüft alle offenen Tabs gegen die Platte (Aufruf: App wird aktiv —
    /// der dominante Fall „woanders editiert, zurückgewechselt"; BBEdits
    /// „Automatically refresh documents"-Default). Sauber → still neu
    /// laden; dirty → Rückfrage. Bei „Behalten" wird das Basis-Datum
    /// nachgezogen, damit dieselbe externe Änderung nicht bei jedem
    /// App-Wechsel erneut fragt.
    func checkExternalChanges() {
        for idx in tabs.indices {
            let tab = tabs[idx]
            guard let url = tab.url, !tab.isLoading else { continue }
            let diskDate = ExternalChange.diskModificationDate(of: url)
            switch ExternalChange.action(isDirty: tab.isDirty,
                                         knownDate: tab.diskModificationDate,
                                         diskDate: diskDate) {
            case .none:
                continue
            case .reloadSilently:
                reloadTabFromDisk(id: tab.id)
            case .askUser:
                if externalReloadConfirmHandler(tab.title) {
                    reloadTabFromDisk(id: tab.id)
                } else {
                    tabs[idx].diskModificationDate = diskDate
                }
            }
        }
    }

    /// Lädt einen Tab frisch von der Platte (Menü „Von Festplatte neu
    /// laden" + stiller Auto-Reload). Gleiche Async-Mechanik wie
    /// `reopenActiveTab` (Generation-Guard, isLoading-Toggle für die
    /// Editor-Neuerzeugung), aber ohne Encoding-Zwang und ohne eigene
    /// Rückfrage — die trifft der Aufrufer.
    func reloadTabFromDisk(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }),
              let url = tabs[idx].url else {
            NSSound.beep()   // unbenannter Tab → nichts zum Neu-Laden
            return
        }
        let tabID = tabs[idx].id
        let generation = (loadGeneration[tabID] ?? 0) + 1
        loadGeneration[tabID] = generation
        tabs[idx].isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try FileLoader.load(url: url) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.loadGeneration[tabID] == generation,
                      let i = self.tabs.firstIndex(where: { $0.id == tabID }) else {
                    if !self.tabs.contains(where: { $0.id == tabID }) {
                        self.loadGeneration.removeValue(forKey: tabID)
                    }
                    return
                }
                self.loadGeneration.removeValue(forKey: tabID)
                switch result {
                case .success(let loaded):
                    self.tabs[i].content    = loaded.content
                    self.tabs[i].encoding   = loaded.encoding
                    self.tabs[i].lineEnding = loaded.lineEnding
                    self.tabs[i].isDirty    = false
                    self.tabs[i].isLoading  = false
                    self.tabs[i].diskModificationDate = ExternalChange.diskModificationDate(of: url)
                case .failure:
                    // Datei nicht (mehr) lesbar → Tab-Inhalt behalten, kein
                    // Datenverlust; Spinner aus. Kein Alert im Auto-Pfad —
                    // ein App-Wechsel darf keine Modal-Kaskade auslösen.
                    self.tabs[i].isLoading = false
                }
            }
        }
    }

    /// Menü-Einstieg „Ablage → Von Festplatte neu laden" (BBEdit „Reload
    /// from Disk"): lädt den AKTIVEN Tab neu; dirty → gleiche Rückfrage
    /// wie die automatische Erkennung.
    func reloadActiveTabFromDisk() {
        guard let idx = activeTabIndex, tabs[idx].url != nil else {
            NSSound.beep()
            return
        }
        if tabs[idx].isDirty, !externalReloadConfirmHandler(tabs[idx].title) { return }
        reloadTabFromDisk(id: tabs[idx].id)
    }

    // MARK: - Suchfelder tauschen (K9)

    /// Vertauscht Suchen- und Ersetzen-Feld (BBEdit „Swap"-Button).
    func swapFindReplace() {
        let tmp = findPattern
        findPattern = replacePattern
        replacePattern = tmp
    }

    // MARK: Datei-IO

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Datei zum Bearbeiten öffnen"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFile(at: url)
    }

    /// Entfernt „leere Notizzettel"-Tabs — außer dem Tab `keepID`. Ein Tab gilt
    /// als wertloser leerer Scratch, wenn er UNBENANNT (`url == nil`), LEER
    /// (`content.isEmpty`), NICHT geändert (`!isDirty`) und NICHT gerade am Laden
    /// (`!isLoading`) ist.
    ///
    /// BBEdit-Verhalten (Daniel-Befund 2026-06-22): Öffnet man eine Datei,
    /// während das leere unbenannte Start-Dokument offen ist, wird dieses
    /// abgeräumt — es ist wertlos. Getippter/„dirty" Inhalt bleibt dagegen IMMER
    /// erhalten (BBEdits „Rescuing Untitled"). Pure Funktion → unit-testbar.
    static func tabsRemovingEmptyScratch(_ tabs: [EditorTab], keeping keepID: UUID) -> [EditorTab] {
        tabs.filter { tab in
            if tab.id == keepID { return true }
            let isEmptyScratch = tab.url == nil && tab.content.isEmpty
                && !tab.isDirty && !tab.isLoading
            return !isEmptyScratch
        }
    }

    /// Lädt eine Datei asynchron in einen neuen Tab und kehrt sofort zurück.
    ///
    /// - Parameter url: Datei-URL; muss eine reguläre Datei sein.
    /// - Parameter completion: Optionaler Callback, der auf dem Main-Thread
    ///   aufgerufen wird. `true` = Inhalt steht im Tab (Datei war schon offen
    ///   oder Laden erfolgreich). `false` = Laden fehlgeschlagen, Platzhalter
    ///   wurde entfernt.
    ///
    /// Ablauf:
    /// 1. Dedup: Datei schon offen → aktiv schalten, completion(true) sofort.
    /// 2. Platzhalter-Tab anlegen (`isLoading = true`), activeTabID setzen.
    /// 3. Hintergrund-Task (Task.detached) → `FileLoader.load(url:)`.
    /// 4. Zurück auf Main: Generation + Tab-Existenz prüfen, Inhalt setzen,
    ///    `isLoading = false`, completion(true).
    ///    Bei Fehler: Beep, Platzhalter entfernen, vorherige activeTabID
    ///    wiederherstellen, completion(false).
    func loadFile(at url: URL, completion: ((Bool) -> Void)? = nil) {
        // ── (1) Dedup ──────────────────────────────────────────────────────
        // Wenn die Datei schon als Tab offen ist, nur aktivieren — kein zweiter Tab.
        if let existingIdx = tabs.firstIndex(where: { $0.url == url }) {
            activeTabID = tabs[existingIdx].id
            noteRecentFile(url)
            completion?(true)
            return
        }

        // ── (2) Platzhalter-Tab anlegen ───────────────────────────────────
        // Der Tab ist sofort in der Tab-Leiste sichtbar (isLoading = true →
        // Spinner statt Editor). Dadurch fühlt sich die App sofort reaktiv an,
        // auch bei großen Dateien.
        let previousActiveTabID = activeTabID
        let placeholder = EditorTab(
            title: url.lastPathComponent,
            path: url.deletingLastPathComponent().path,
            url: url,
            content: "",
            isDirty: false,
            isLoading: true
        )
        tabs.append(placeholder)
        activeTabID = placeholder.id

        // ── (3) Generation hochzählen ─────────────────────────────────────
        // Ermöglicht es, einen abgebrochenen Load zu erkennen (Tab schon
        // gelöscht, oder inzwischen ein neuerer Load für dieselbe ID gestartet).
        let tabID = placeholder.id
        let generation = (loadGeneration[tabID] ?? 0) + 1
        loadGeneration[tabID] = generation

        // ── (4) Hintergrund-Task starten ──────────────────────────────────
        // [weak self]: Workspace darf verschwinden (z.B. Preview), ohne Leak.
        Task.detached(priority: .userInitiated) { [weak self] in
            // I/O im Hintergrund — blockiert NICHT den Main-Thread.
            let loadResult = Result { try FileLoader.load(url: url) }

            // Zurück auf den Main-Thread für alle UI-/Model-Mutationen.
            await MainActor.run { [weak self] in
                guard let self else { return }

                // ── Generation-Guard ──────────────────────────────────────
                // Wenn der Tab inzwischen geschlossen wurde (`loadGeneration`
                // hat keine Eintrags-ID mehr) ODER eine neue Generation für
                // diese ID gestartet wurde → dieses Ergebnis verwerfen.
                guard self.loadGeneration[tabID] == generation,
                      self.tabs.contains(where: { $0.id == tabID }) else {
                    // Platzhalter kann weg sein (Nutzer hat Tab während des
                    // Ladens geschlossen) — kein Fehler, einfach still beenden.
                    // Aufräumen: Ist der Tab weg, kommt seine UUID nie wieder
                    // → Generation-Eintrag entfernen, sonst bliebe er für
                    // immer im Dictionary. (Bei bloß veralteter Generation
                    // bleibt der Eintrag — er gehört dem neueren Ladevorgang.)
                    if !self.tabs.contains(where: { $0.id == tabID }) {
                        self.loadGeneration.removeValue(forKey: tabID)
                    }
                    completion?(false)
                    return
                }

                // Eintrags-ID verbraucht → aus dem Dictionary entfernen.
                self.loadGeneration.removeValue(forKey: tabID)

                switch loadResult {
                case .success(let loaded):
                    // ── Erfolg ────────────────────────────────────────────
                    // Inhalt in den Platzhalter-Tab schreiben und isLoading
                    // auf false setzen. Der EditorView reagiert darauf:
                    // isLoading-Kippen → `.id(activeTab.id)` erzeugt den
                    // SourceEditor NEU → makeNSViewController läuft mit
                    // fertigem Inhalt (CESE-Falle umgangen).
                    guard let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else {
                        completion?(false)
                        return
                    }
                    self.tabs[idx].content    = loaded.content
                    self.tabs[idx].encoding   = loaded.encoding
                    self.tabs[idx].lineEnding = loaded.lineEnding
                    // Basis-Datum für die Extern-Änderungs-Erkennung merken.
                    self.tabs[idx].diskModificationDate = ExternalChange.diskModificationDate(of: url)
                    self.tabs[idx].isDirty    = false
                    self.tabs[idx].isLoading  = false
                    // BBEdit-Verhalten: das leere unbenannte Start-/Scratch-
                    // Dokument abräumen, sobald eine echte Datei geladen ist
                    // (der gerade geladene Tab bleibt erhalten).
                    self.tabs = Workspace.tabsRemovingEmptyScratch(self.tabs, keeping: tabID)
                    self.noteRecentFile(url)
                    completion?(true)

                case .failure:
                    // ── Fehler ────────────────────────────────────────────
                    // Platzhalter entfernen und früheren Tab reaktivieren.
                    NSSound.beep()
                    self.tabs.removeAll { $0.id == tabID }
                    self.activeTabID = previousActiveTabID
                    completion?(false)
                }
            }
        }
    }

    func saveActiveTab() {
        guard let idx = activeTabIndex else { return }
        if let url = tabs[idx].url {
            write(tab: tabs[idx], to: url)
        } else {
            saveActiveTabAs()
        }
    }

    func saveActiveTabAs() {
        guard let idx = activeTabIndex else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = tabs[idx].title
        panel.message = "Datei speichern unter…"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(tab: tabs[idx], to: url)
        tabs[idx].url = url
        tabs[idx].title = url.lastPathComponent
        tabs[idx].path = url.deletingLastPathComponent().path
    }

    private func write(tab: EditorTab, to url: URL) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        do {
            // Zeilenenden auf die gewählte Konvention bringen (K7) — der Editor
            // hält intern u.U. andere Umbrüche; maßgeblich ist die im Footer
            // gewählte `lineEnding`. converting() normalisiert auch gemischte.
            let out = tab.lineEnding.converting(tab.content)
            try out.write(to: url, atomically: true, encoding: tab.encoding)
            tabs[idx].isDirty = false
            // Unser eigener Write ist keine „externe" Änderung — Basis-Datum
            // nachziehen, sonst schlüge die Erkennung beim nächsten
            // App-Wechsel auf die selbst geschriebene Datei an.
            tabs[idx].diskModificationDate = ExternalChange.diskModificationDate(of: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Zuletzt benutzte Dateien (K2)

    /// Merkt sich eine gerade geöffnete Datei oben in `recentFiles`
    /// (Persistenz läuft automatisch über den Combine-Sink in `init`).
    func noteRecentFile(_ url: URL) {
        recentFiles = RecentFilesStore.prepending(url.path, to: recentFiles)
    }

    // MARK: - Such-Verlauf (K4)

    /// Nimmt das aktuelle Find-/Replace-Paar in den Verlauf auf. An diskreten
    /// Such-Aktionen aufgerufen (Treffer-Navigation, Ersetzen, Ordner-Suche) —
    /// NICHT bei jedem Tastendruck. Leerer Find-String wird ignoriert (Logik
    /// im Store). Dedup + Cap erledigt `SearchHistoryStore.prepending`.
    func recordSearchHistory() {
        let entry = SearchHistoryEntry(find: findPattern, replace: replacePattern)
        searchHistory = SearchHistoryStore.prepending(entry, to: searchHistory)
    }

    /// Übernimmt einen Verlaufs-Eintrag in die Suchfelder (Popup-Auswahl).
    func applyHistoryEntry(_ entry: SearchHistoryEntry) {
        findPattern = entry.find
        replacePattern = entry.replace
    }

    // MARK: - Auswahl-bezogene Suche (K3 / K5)

    /// `true`, wenn die Selektion mehr als eine Zeile umspannt. Pure Logik —
    /// steuert das Auto-Einschalten von „Nur in Auswahl" beim Öffnen der
    /// Maske (BBEdit-Verhalten: bei einer Block-Selektion plausibel, bei
    /// einer Wort-Selektion eher nicht — dann will man global suchen).
    static func selectionIsMultiline(text: String, range: NSRange) -> Bool {
        let ns = text as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return false }
        return ns.substring(with: range).contains(where: { $0 == "\n" || $0 == "\r" })
    }

    /// Schaltet „Nur in Auswahl" und friert dabei die aktuelle Selektion als
    /// Such-Bereich ein (bzw. löst sie beim Ausschalten wieder). Setzt/löst
    /// `searchSelectionRange` — die UI-Toggle nutzt diesen Pfad. Der einzige
    /// andere Pfad, der die Range berührt, ist `adjustSearchSelectionRange`
    /// (führt sie beim Ersetzen um die Längenänderung mit).
    func setSearchInSelectionOnly(_ on: Bool) {
        if on {
            searchSelectionRange = selectionRange
            searchInSelectionOnly = (selectionRange != nil)
        } else {
            searchInSelectionOnly = false
            searchSelectionRange = nil
        }
    }

    /// Führt die eingefrorene Such-Selektion bei einem Ersetzen um die
    /// Längenänderung mit. Ohne das driftet die Range: ein kürzerer Ersatz
    /// ließe sie über das ursprüngliche Auswahl-Ende hinausragen (Treffer
    /// AUSSERHALB der Auswahl tauchten auf), ein längerer verkürzte den
    /// erfassten Bereich (Treffer am Ende fehlten). Die Location bleibt — der
    /// ersetzte Treffer liegt innerhalb der Auswahl, nur deren Ende wandert.
    /// No-op, wenn „Nur in Auswahl" aus ist.
    private func adjustSearchSelectionRange(lengthDelta delta: Int) {
        guard searchInSelectionOnly, let r = searchSelectionRange else { return }
        searchSelectionRange = NSRange(location: r.location,
                                       length: max(0, r.length + delta))
    }

    /// Beim Öffnen der Maske auswerten: liegt eine MEHRZEILIGE Selektion vor,
    /// „Nur in Auswahl" automatisch einschalten + einfrieren; sonst neutral
    /// ausschalten. So muss der Block-Such-Fall nichts klicken, der Normalfall
    /// bleibt unbeeinflusst.
    func captureSelectionForSearch() {
        if let range = selectionRange,
           Workspace.selectionIsMultiline(text: activeTab?.content ?? "", range: range) {
            setSearchInSelectionOnly(true)
        } else {
            setSearchInSelectionOnly(false)
        }
    }

    /// „Auswahl als Suchbegriff" (⌘E, BBEdit „Use Selection for Find", K5):
    /// übernimmt den aktuell im Editor selektierten Text als Find-Pattern,
    /// OHNE sofort zu suchen. Keine Selektion → nichts tun (Beep).
    func useSelectionForFind() {
        guard let range = selectionRange, range.length > 0 else {
            NSSound.beep()
            return
        }
        let ns = (activeTab?.content ?? "") as NSString
        guard NSMaxRange(range) <= ns.length else { NSSound.beep(); return }
        findPattern = ns.substring(with: range)
    }

    // MARK: Suche

    /// Such-Scope. „Projekt" wurde nach v1.1+ verschoben — Definition
    /// noch offen (vermutlich gespeichertes Datei-Set + Filter), gehört
    /// nicht in v1.0.
    enum SearchScope: String, CaseIterable, Identifiable {
        case file    = "Datei"
        case open    = "Geöffnet"
        case folder  = "Ordner"
        var id: String { rawValue }
    }

    // MARK: - Ordner-Quellen (Sichtbar nur bei scope == .folder)

    /// Zuletzt für die Suche verwendete Ordner. Beim Init aus
    /// UserDefaults geladen; bei jeder Änderung automatisch zurück
    /// in UserDefaults geschrieben (Combine-Sink in init).
    // Startet leer und wird im init-Body aus der INJIZIERTEN Defaults-Suite
    // geladen (Property-Initializer kennen den init-Parameter noch nicht).
    // Vorher stand hier ein Load aus `.standard` — Selbsttests lasen damit
    // die echte Nutzer-Ordnerliste statt ihrer isolierten Suite.
    @Published var recentSearchFolders: [SearchFolderEntry] = []

    /// Zuletzt geöffnete Dateien (BBEdit „Open Recent", K2). Pfade,
    /// most-recently-first. Im init aus der injizierten Defaults-Suite
    /// geladen, per Combine-Sink zurückgeschrieben.
    @Published var recentFiles: [String] = []

    /// Such-Verlauf (BBEdit „Search History", K4). Find-/Replace-Paare,
    /// most-recently-first. Persistenz wie `recentFiles`.
    @Published var searchHistory: [SearchHistoryEntry] = []

    /// Tilde-expandierte URLs aller aktivierten Ordner — direkter
    /// Input für `FolderSearch.find`.
    var enabledSearchFolderURLs: [URL] {
        recentSearchFolders.filter(\.enabled).map(\.url)
    }

    /// Öffnet einen NSOpenPanel zur Ordner-Auswahl und hängt das Ergebnis
    /// oben an die Recent-Folders-Liste (aktiviert). Persistenz läuft
    /// automatisch über den Combine-Sink in `init`.
    func addSearchFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Ordner zum Durchsuchen auswählen"
        guard panel.runModal() == .OK else { return }
        recentSearchFolders = Workspace.prependingFolders(panel.urls.map(\.path),
                                                          to: recentSearchFolders)
    }

    /// Reine Logik fürs Hinzufügen von Ordnern: jeder neue Pfad landet
    /// oben und aktiviert; ein bereits vorhandener Eintrag (gleicher
    /// tilde-expandierter Pfad) wird nach oben verschoben statt dupliziert.
    /// Die Reihenfolge der Auswahl bleibt erhalten (erster ganz oben).
    /// Getrennt vom NSOpenPanel, damit unit-testbar.
    static func prependingFolders(_ newPaths: [String],
                                  to existing: [SearchFolderEntry]) -> [SearchFolderEntry] {
        var result = existing
        // Rückwärts einfügen, damit die erste Auswahl am Ende ganz oben steht.
        for path in newPaths.reversed() {
            let normalized = (path as NSString).expandingTildeInPath
            result.removeAll { ($0.path as NSString).expandingTildeInPath == normalized }
            result.insert(SearchFolderEntry(path: path, enabled: true), at: 0)
        }
        return result
    }

    /// Navigations-Ziel für CMD+G und die Chevron-Buttons in der Maske.
    /// Im Folder-Scope trägt jeder Eintrag die zugehörige Datei-URL,
    /// damit die Navigation beim Wechsel über Datei-Grenzen automatisch
    /// die richtige Datei in den Editor lädt.
    struct NavMatch: Identifiable, Equatable {
        let id: UUID
        let url: URL?
        /// Ziel-Tab im Geöffnet-Scope: Die Navigation aktiviert diesen Tab
        /// statt eine Datei zu laden (auch ungespeicherte Tabs erreichbar).
        let tabID: UUID?
        let match: BufferSearch.Match

        init(id: UUID, url: URL?, tabID: UUID? = nil, match: BufferSearch.Match) {
            self.id = id
            self.url = url
            self.tabID = tabID
            self.match = match
        }
    }

    var navMatches: [NavMatch] {
        if scope == .folder {
            return folderResults.flatMap { pf in
                pf.matches.map { NavMatch(id: $0.id, url: pf.url, match: $0) }
            }
        }
        if scope == .open {
            return openResults.flatMap { th in
                th.matches.map { NavMatch(id: $0.id, url: nil, tabID: th.id, match: $0) }
            }
        }
        return bufferMatches.map { NavMatch(id: $0.id, url: nil, match: $0) }
    }

    /// Dateityp-Filter im Ordner-Modus.
    @Published var fileTypeFilter: FileTypeFilter = .knownText

    // MARK: - Apply-Session-Tracking (für Undo-UI)
    /// Letzte ausgeführte Folder-Apply-Session. UI bietet darauf
    /// basierend „Rückgängig"-Aktion an.
    @Published var lastApplySession: ApplySession? = nil

    /// Schwellwert (in Bytes), ab dem der Folder-Apply einen
    /// Bestätigungsdialog zeigt. AGENTS.md: > 200 MB.
    static let folderApplyWarnBytes: Int = 200 * 1024 * 1024

    /// Convenience: aktuelle Such-Optionen aus den Workspace-Feldern.
    var currentSearchOptions: SearchOptions {
        SearchOptions(find: findPattern,
                      replace: replacePattern,
                      isRegex: useRegex,
                      caseSensitive: caseSensitive,
                      wholeWord: wholeWord,
                      treatWildcardLiterally: treatWildcardLiterally)
    }

    /// Wendet den aktuellen Search/Replace-Plan auf alle Dateien des
    /// Folder-Scopes an (atomisch pro Datei, mit Undo-Backup unter
    /// `~/Library/Application Support/Fastra/undo/`). Zeigt bei >200 MB
    /// Gesamt-Plan-Umfang einen Bestätigungsdialog.
    ///
    /// Geöffnete Tabs der betroffenen Dateien werden nach dem Apply
    /// neu von der Platte geladen (sonst zeigt der Editor noch den
    /// alten Inhalt).
    @discardableResult
    func applyAllInFolder() -> Bool {
        guard scope == .folder,
              searchError == nil,
              !folderResults.isEmpty else { return false }
        let urls = folderResults.filter { !$0.matches.isEmpty }.map(\.url)
        guard !urls.isEmpty else { return false }
        recordSearchHistory()
        let plan = ApplyEngine.plan(files: urls, options: currentSearchOptions)

        // Schwellen-Warnung. Wir summieren die ORIGINAL-Bytes (das ist,
        // was wir effektiv anfassen) — neuer Inhalt kann ohnehin nur
        // dann größer werden, wenn das Replace länger ist als der Find.
        let totalBytes = plan.files.reduce(0) { $0 + $1.originalBytes.count }
        if totalBytes > Workspace.folderApplyWarnBytes {
            let alert = NSAlert()
            alert.messageText = "Große Replace-Operation"
            alert.informativeText = "Insgesamt \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)) in \(plan.changedFiles.count) Dateien. Trotzdem ausführen?"
            alert.addButton(withTitle: "Ausführen")
            alert.addButton(withTitle: "Abbrechen")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        do {
            let session = try ApplyEngine.apply(plan: plan)
            lastApplySession = session
            reloadOpenTabs(for: session.entries.map { URL(fileURLWithPath: $0.originalPath) })
            return true
        } catch ApplyError.planNotApplyable(let msg) {
            NSAlert.runWarning(title: "Apply abgelehnt", text: msg)
            return false
        } catch ApplyError.backupFailed(let msg) {
            NSAlert.runWarning(title: "Backup fehlgeschlagen", text: "Es wurde nichts verändert.\n\n\(msg)")
            return false
        } catch ApplyError.writeFailed(let session, let msg) {
            lastApplySession = session
            NSAlert.runWarning(title: "Apply teilweise fehlgeschlagen",
                               text: "\(msg)\n\nBereits geschriebene Dateien können über die Rückgängig-Aktion zurückgespielt werden.")
            reloadOpenTabs(for: session.entries.map { URL(fileURLWithPath: $0.originalPath) })
            return false
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Macht die letzte Folder-Apply-Session bit-exakt rückgängig.
    @discardableResult
    func undoLastFolderApply() -> Bool {
        guard let session = lastApplySession else { return false }
        do {
            try ApplyEngine.undo(session)
            reloadOpenTabs(for: session.entries.map { URL(fileURLWithPath: $0.originalPath) })
            lastApplySession = nil
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Lädt geöffnete Tabs neu von der Platte, wenn ihre URL in der
    /// übergebenen Liste vorkommt. Anwendung: nach Folder-Apply zeigen
    /// die offenen Editoren sonst noch den Vor-Apply-Inhalt.
    ///
    /// Der Reload läuft jetzt asynchron via `FileLoader` + Generation-Guard
    /// (analog zu `loadFile`) — kein Main-Thread-Block beim Nachladen.
    /// Hinweis: Die CESE-Falle (Editor übernimmt Binding-Änderungen nicht,
    /// Inhalt kommt nur via Neuerzeugung) gilt auch hier. `isLoading` wird
    /// kurz auf `true` gesetzt und dann auf `false`, damit `.id(activeTab.id)`
    /// eine Neuerzeugung auslöst und der frische Inhalt wirklich sichtbar wird.
    private func reloadOpenTabs(for changedURLs: [URL]) {
        let changed = Set(changedURLs.map(\.path))
        // Snapshot der zu reloadenden Tab-IDs + URLs aufnehmen — die
        // Schleife muss nicht auf dem aktuellen `tabs`-Array laufen.
        let toReload: [(id: UUID, url: URL)] = tabs.compactMap { tab in
            guard let url = tab.url, changed.contains(url.path) else { return nil }
            return (id: tab.id, url: url)
        }
        for (tabID, url) in toReload {
            // Generation hochzählen, damit ein paralleles `loadFile` auf
            // dieselbe Datei das Ergebnis des reloadOpenTabs überschreiben kann
            // (oder umgekehrt — der spätere Guard entscheidet).
            let generation = (loadGeneration[tabID] ?? 0) + 1
            loadGeneration[tabID] = generation

            // Lade-Spinner einschalten, damit CESE den Editor neu erzeugt.
            if let idx = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[idx].isLoading = true
            }

            Task.detached(priority: .userInitiated) { [weak self] in
                let loadResult = Result { try FileLoader.load(url: url) }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.loadGeneration[tabID] == generation,
                          let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else {
                        // Tab während des Reloads geschlossen → Generation-
                        // Eintrag aufräumen (UUID kommt nie wieder). Bei bloß
                        // veralteter Generation bleibt er (gehört dem neueren
                        // Ladevorgang).
                        if !self.tabs.contains(where: { $0.id == tabID }) {
                            self.loadGeneration.removeValue(forKey: tabID)
                        }
                        return
                    }
                    self.loadGeneration.removeValue(forKey: tabID)
                    if case .success(let loaded) = loadResult {
                        self.tabs[idx].content    = loaded.content
                        self.tabs[idx].encoding   = loaded.encoding
                        self.tabs[idx].lineEnding = loaded.lineEnding
                        self.tabs[idx].isDirty    = false
                        self.tabs[idx].isLoading  = false
                    } else {
                        // Reload fehlgeschlagen: isLoading zurücksetzen,
                        // aber alten Inhalt NICHT löschen (besser veralteter
                        // Inhalt als leere Anzeige).
                        self.tabs[idx].isLoading = false
                    }
                }
            }
        }
    }

    /// Ersetzt alle aktuell gefundenen Treffer im aktiven Buffer durch
    /// ihre Replacement-Texte. NUR im Speicher — keine Disk-Writes, kein
    /// Apply-Backup (das ist die Schiene für die Ordner-Suche). Speichern
    /// erfolgt wie gewohnt über CMD+S; das markiert den Tab als dirty.
    func applyAllInActiveBuffer() {
        // `bufferTotalMatches` statt `bufferMatches.count` als Gate: bei
        // gekappter Liste gibt es mehr Treffer als materialisiert sind.
        guard bufferTotalMatches > 0, searchError == nil else { return }
        recordSearchHistory()
        let text = activeTabContent.wrappedValue
        // Voll-Replace über den ganzen Text (bzw. die eingefrorene Auswahl bei
        // „Nur in Auswahl") — ersetzt ALLE Treffer, auch die jenseits des
        // Listen-Caps (sonst blieben gekappte Treffer stehen).
        guard let replaced = BufferSearch.replaceAll(in: text, options: currentSearchOptions,
                                                     searchRange: activeSearchRange),
              replaced != text else { return }
        activeTabContent.wrappedValue = replaced
        // Editor zur Neuerzeugung zwingen, sonst zeigt CodeEditSourceEditor
        // weiter den Vor-Replace-Text (Binding-Änderungen fließen NICHT zurück
        // in die TextView). Ohne das wirkt „Alle ersetzen" folgenlos, obwohl
        // das Modell korrekt ersetzt wurde (siehe `editorReloadNonce`).
        editorReloadNonce += 1
        // „Nur in Auswahl": eingefrorene Range um die Gesamt-Längenänderung
        // aller ersetzten Treffer mitführen, damit der (async) Re-Find des
        // SearchRunners den richtigen Bereich nimmt.
        adjustSearchSelectionRange(lengthDelta: (replaced as NSString).length - (text as NSString).length)
        // SearchRunner reagiert auf die tabs-Änderung und sucht neu.
        // Nach Apply gibt es typischerweise 0 Treffer (Pattern matched
        // den eingefügten Replace-Text nicht mehr); activeMatchIndex
        // wird vom Runner auf 0 geclampt.
    }

    /// „Alle ersetzen" im Geöffnet-Scope: ersetzt ALLE Treffer in ALLEN
    /// offenen Tabs — rein in-memory (kein Disk-Write, kein Apply-Backup;
    /// Speichern wie gewohnt via ⌘S pro Tab). Geänderte Tabs werden dirty
    /// markiert, der sichtbare Editor per Reload-Nonce neu erzeugt (CESE
    /// übernimmt Binding-Änderungen nicht — gleiche Falle wie im
    /// Buffer-Pfad). Liefert die Anzahl geänderter Tabs (Testbarkeit).
    @discardableResult
    func applyAllInOpenTabs() -> Int {
        guard openTotalMatches > 0, searchError == nil else { return 0 }
        recordSearchHistory()
        let inputs = tabs.filter { !$0.isLoading }.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title, content: $0.content)
        }
        let changed = OpenTabsSearch.replaceAll(tabs: inputs, options: currentSearchOptions)
        guard !changed.isEmpty else { return 0 }
        for idx in tabs.indices {
            guard let newContent = changed[tabs[idx].id] else { continue }
            tabs[idx].content = newContent
            tabs[idx].isDirty = true
        }
        editorReloadNonce += 1
        // SearchRunner sucht durch die tabs-Änderung automatisch neu.
        return changed.count
    }

    /// Ersetzt NUR den aktuell aktiven Treffer im aktiven Buffer und rückt
    /// zum nachfolgenden Treffer vor — die BBEdit-„Replace"-Semantik
    /// (ein Treffer ersetzen, dann zum nächsten springen).
    ///
    /// Nur Datei-/Geöffnet-Scope (in-memory). Einzel-Ersetzen im Ordner-
    /// Scope schreibt auf die Platte und kommt erst mit dem persistenten
    /// Ergebnis-Fenster (Schritt 2); deshalb hier bewusst ausgeklammert.
    func replaceActiveMatch() {
        guard scope != .folder, searchError == nil,
              activeMatchIndex < bufferMatches.count else { return }
        recordSearchHistory()
        let match = bufferMatches[activeMatchIndex]
        let text = activeTabContent.wrappedValue
        // applyReplacements ist pur und kann eine Ein-Treffer-Liste
        // splicen — kein Sonderpfad nötig.
        let replaced = BufferSearch.applyReplacements(in: text, matches: [match])
        guard replaced != text else { return }
        activeTabContent.wrappedValue = replaced
        // Editor neu erzeugen (siehe `editorReloadNonce` / applyAllInActiveBuffer):
        // sonst bliebe der ersetzte Treffer im sichtbaren Text unverändert.
        // Der Treffer-Sprung unten läuft async (`focusEditorForVisibleJump`)
        // und greift den frisch erzeugten Editor → bleibt sichtbar.
        editorReloadNonce += 1

        // „Nur in Auswahl": eingefrorene Range um die Längenänderung des
        // ersetzten Treffers mitführen, BEVOR der Re-Find unten sie nutzt
        // (sonst sucht er in einem verschobenen Bereich). Bei genau einem
        // ersetzten Treffer ist die Gesamt-Längenänderung exakt dessen Delta.
        adjustSearchSelectionRange(lengthDelta: (replaced as NSString).length - (text as NSString).length)

        // Synchron neu suchen, damit bufferMatches + der Sprung unten SOFORT
        // stimmen. Die Live-Such-Pipeline läuft seit v0.10 async — der
        // debounced Async-Runner käme erst 120 ms später und der Sprung
        // zielte auf eine veraltete Liste. Einzel-Ersetzen ist eine bewusste
        // Einzelaktion (nicht Live-Tippen), daher ist ein synchroner Lauf
        // hier vertretbar (BBEdit-„Replace & Find Again"-Semantik). Der
        // Combine-Trigger der tabs-Änderung stößt zusätzlich einen
        // redundanten, gleichwertigen Async-Lauf an.
        let result = BufferSearch.find(in: replaced, options: currentSearchOptions,
                                       searchRange: activeSearchRange)
        bufferMatches = result.matches
        bufferTotalMatches = result.totalMatches
        bufferResultsWereCapped = result.wasCapped
        searchError = result.invalidPatternMessage
        if activeMatchIndex >= result.matches.count {
            activeMatchIndex = max(0, result.matches.count - 1)
        }

        // activeMatchIndex bleibt unverändert: der ersetzte Treffer ist
        // aus der Liste verschwunden, also rückt der frühere Nachfolger
        // genau auf diesen Index nach. Der Clamp oben fängt den Fall ab,
        // dass der letzte Treffer ersetzt wurde. Dann zum Nachrück-Treffer
        // springen — analog zu navigateMatch in ContentView.
        guard activeMatchIndex < bufferMatches.count else { return }
        let target = bufferMatches[activeMatchIndex]
        NotificationCenter.default.postMatchJump(target)
    }

    /// Stößt die explizite Ordner-Suche an („Suchen"-Klick / Return in der
    /// Maske). Der Ordner-Scope wird bewusst NICHT live durchsucht
    /// (Konzept Abschnitt C) — dies ist der einzige Auslöser dafür.
    func runFolderSearchNow() {
        recordSearchHistory()
        searchRunner?.runFolderSearch()
    }

    /// Trefferliste als LF-getrennten String ins Clipboard kopieren —
    /// „Treffer kopieren"-Button. Roh, ohne Dedup; Dedup + andere
    /// Trennzeichen kommen erst mit dem Extrahieren-Dialog in v1.1+.
    /// Im Folder-Scope werden Treffer aus allen Dateien zusammengezogen.
    func copyHitsToClipboard() {
        let texts = navMatches.map(\.match.matchText)
        let joined = texts.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    /// BBEdit „Extract" (Handbuch 16.0.1, S. 168/193): alle Treffer in ein
    /// NEUES unbenanntes Dokument extrahieren, ein Treffer pro Zeile. Mit
    /// gefülltem Ersetzen-Feld wird jeder Treffer erst transformiert
    /// (`$1`-Backrefs, `\U`-Case-Operatoren, Wildcard-Pillen) — leer heißt
    /// „roh extrahieren". Liefert `true`, wenn ein Tab entstanden ist
    /// (Testbarkeit); bei 0 Treffern passiert nichts.
    ///
    /// Buffer-Scope: Die Treffer werden UNGEKAPPT frisch erhoben — die
    /// Live-Liste materialisiert nur die ersten 2000, Extract soll aber
    /// alle liefern (keine stille Trunkierung). Folder-Scope: nutzt die
    /// materialisierten Ergebnisse; deren Cap zeigt die Maske bereits als
    /// orangen Hinweis an.
    @discardableResult
    func extractHitsToNewTab() -> Bool {
        let matches: [BufferSearch.Match]
        if scope == .folder || scope == .open {
            // Materialisierte Multi-Quellen-Treffer (Ordner bzw. offene
            // Tabs) — deren Cap zeigt die Maske bereits als Hinweis an.
            matches = navMatches.map(\.match)
        } else {
            let text = activeTabContent.wrappedValue
            matches = BufferSearch.find(in: text, options: currentSearchOptions,
                                        maxMatches: Int.max,
                                        searchRange: activeSearchRange).matches
        }
        guard !matches.isEmpty else { return false }
        recordSearchHistory()
        let content = HitExtraction.content(matches: matches,
                                            useReplacement: !replacePattern.isEmpty)
        // Neues unbenanntes Dokument mit dem Extrakt — dirty, damit die
        // Schließen-Rückfrage greift (Inhalt existiert nur im Speicher).
        let tab = EditorTab(title: "untitled-\(tabs.count + 1).txt",
                            path: "—", content: content, isDirty: true)
        tabs.append(tab)
        activeTabID = tab.id
        return true
    }
}

/// Ein Ordner in der „Recent Folders"-Liste der erweiterten Suchmaske.
/// `id` ist nur zur SwiftUI-Identifikation gedacht und wird NICHT
/// persistiert (UUID würde sonst pro App-Start „neu" wirken). Beim Laden
/// aus UserDefaults wird die UUID frisch generiert.
struct SearchFolderEntry: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var path: String
    var enabled: Bool

    enum CodingKeys: String, CodingKey { case path, enabled }

    init(id: UUID = UUID(), path: String, enabled: Bool) {
        self.id = id
        self.path = path
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.path = try c.decode(String.self, forKey: .path)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
    }

    /// Tilde-expandierte Datei-URL für die tatsächliche Suche.
    var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

extension NSAlert {
    /// Kurzer Helfer für nicht-modale Fehler-/Warn-Hinweise mit einem
    /// einzelnen OK-Button. Vermeidet die Boilerplate-Wiederholung an
    /// fünf verschiedenen Stellen.
    static func runWarning(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

/// Verwaltet die Persistenz der Recent-Folders-Liste in UserDefaults.
/// In Tests austauschbar, indem ein eigener `UserDefaults`-Suite-Name
/// übergeben wird.
enum RecentSearchFoldersStore {
    static let key = "fastra.recentSearchFolders"

    /// Default-Liste, wenn noch nichts gespeichert wurde.
    static let defaults: [SearchFolderEntry] = [
        SearchFolderEntry(path: "~/Documents/Fastra-Demo", enabled: true),
        SearchFolderEntry(path: "~/Documents/Notizen", enabled: false),
        SearchFolderEntry(path: "~/Projekte/Newsletter", enabled: false),
    ]

    static func load(from defaults: UserDefaults = .standard) -> [SearchFolderEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([SearchFolderEntry].self, from: data) else {
            return Self.defaults
        }
        return entries
    }

    static func save(_ entries: [SearchFolderEntry], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Dateityp-Filter im Ordner-Modus.
enum FileTypeFilter: String, CaseIterable, Identifiable {
    case knownText = "Bekannte Textformate"
    case all       = "Alle Dateien"
    var id: String { rawValue }
}
