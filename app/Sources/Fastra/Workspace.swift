import SwiftUI
import AppKit
import Combine
import CodeEditLanguages

extension Notification.Name {
    /// Ein Projektwechsel darf keine Diagnose des alten Projektkontexts mehr
    /// im Hintergrund behalten. Tool4d hört darauf und beendet seinen kurzen
    /// LSP-Lauf, bevor neue Projekt-URLs sichtbar werden.
    static let fastraProjectContextWillChange = Notification.Name("fastraProjectContextWillChange")
}

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
        case .utf32BigEndian:       return "UTF-32 BE"
        case .utf32LittleEndian:    return "UTF-32 LE"
        case .utf32:                return "UTF-32"
        case .ascii:                return "ASCII"
        case .isoLatin1:            return "Latin-1"
        case .isoLatin2:            return "Latin-2"
        case .windowsCP1252:        return "Win-1252"
        case .macOSRoman:           return "Mac Roman"
        default:                    return L10n.string("Unbekannt")
        }
    }
}

struct EditorTab: Identifiable, Hashable {
    let id: UUID
    var title: String
    var path: String
    var url: URL?
    var content: String {
        didSet { contentRevision &+= 1 }
    }
    /// Monotone Inhaltsgeneration. Property-Observer erfasst auch direkte
    /// Test-/Hilfspfade; modale Save-Dialoge und asynchrone Reloads dürfen
    /// nur auf exakt derselben Generation abschließen.
    private(set) var contentRevision: UInt64 = 0
    var encoding: String.Encoding
    var bom: Data
    var lineEnding: LineEnding
    var displayMode: EditorDisplayMode
    var fileSize: UInt64
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
    /// Exakte Byte-/Identitätsbasis des letzten Ladens oder Speicherns. Der
    /// Save-Pfad vergleicht sie unmittelbar vor dem Write und verlässt sich
    /// damit nicht auf die begrenzte Auflösung eines Änderungsdatums.
    var diskSnapshot: FileSnapshot?
    /// Art eines Git-Text-Tabs (Etappe 2): `.log` / `.diff` / `.commit`.
    /// `nil` = normale, editierbare Datei. Git-Tabs sind read-only, haben
    /// `url == nil` und werden nicht gespeichert.
    var gitKind: GitTabKind?
    /// Strukturierter Side-by-side-Diff. `nil` bei normalen Dateien sowie beim
    /// kompatiblen Unified-Fallback für Verlauf/Commit-Metadaten.
    var gitDiffRequest: GitDiffRequest?
    var gitDiffDocument: GitDiffDocument?
    /// Jede neue Ladung desselben Diff-Tabs erhöht diesen Wert. Nur die
    /// Completion derselben Generation darf den Tab noch verändern.
    var gitDiffLoadGeneration: UInt64
    /// Auftrag eines Datei-Vergleichs-Tabs (Etappe 1 Wunschpaket 2026-07c).
    /// `nil` = normaler Tab. Vergleichs-Tabs sind wie Git-Tabs read-only,
    /// haben `url == nil` und werden nicht gespeichert.
    var fileDiffRequest: FileDiffRequest?
    /// Fertig berechneter Vergleich (Ergebnis ODER erklärte Grenze).
    /// `nil` = Berechnung läuft noch (Ansicht zeigt einen Spinner).
    var fileDiffDocument: FileDiffDocument?
    /// Jede Neuberechnung desselben Vergleichs-Tabs erhöht diesen Wert.
    /// Nur die Completion derselben Generation darf den Tab noch verändern
    /// (gleiches Muster wie `gitDiffLoadGeneration`).
    var fileDiffLoadGeneration: UInt64
    /// `true`, wenn dieser Tab der Willkommen-Tab ist (zeigt statt des Editors
    /// die Willkommensseite und trägt in der Leiste „Willkommen"). Bleibt ein
    /// eigener Tab bestehen, bis er geschlossen wird — ⌘T/„Neue Datei" legen
    /// DANEBEN einen echten Editor-Tab an, statt diesen umzubenennen (Daniel-
    /// Wunsch 2026-07-12). Beim Öffnen einer Datei/eines Projekts wird er
    /// abgeräumt bzw. in ein normales leeres Dokument umgewandelt.
    var isWelcome: Bool
    /// Vom Nutzer gewählte Ansicht (Text/Vorschau/Hex, Etappe 2 Wunschpaket
    /// 2026-07). `nil` = automatischer Standard nach Dateityp
    /// (`ViewModeRouting.defaultMode`). Nicht persistiert.
    var viewMode: EditorViewMode?
    /// Manuell gewählte Editor-Sprache (Etappe 3 Wunschpaket 2026-07) —
    /// das Sicherheitsventil gegen Fehlerkennung. Gewinnt IMMER (vor Endung
    /// und Inhalts-Erkennung) und beendet die Automatik für diesen Tab.
    /// `nil` = automatisch.
    var languageOverride: CodeLanguage?
    /// Manuell gewählte EIGEN-Sprache (Registry-ID, derzeit nur 4D; Etappe 3
    /// Wunschpaket 2026-07b) — aktiviert Provider + Theme unabhängig von der
    /// Dateiendung. Höchstens eines von `languageOverride`/dieser ID ist
    /// gesetzt (die Setter halten die Invariante). `nil` = automatisch.
    var customLanguageOverrideID: String?
    /// Ergebnis der inhaltsbasierten Erkennung für ungespeicherte,
    /// endungslose Tabs. Wird nur wirksam, solange weder URL-Endung noch
    /// manuelle Wahl greifen; Hysterese liegt im Erkennungspfad.
    var contentDetectedLanguage: CodeLanguage?
    /// UI-unabhängige Identität des inhaltlich erkannten Formats. Die
    /// Grammatik allein reicht nicht: erkanntes XML nutzt z. B. die
    /// HTML-Grammatik, muss aber das XML-Profil und den XML-Namen behalten.
    var contentDetectedFormat: ContentLanguageDetection.Format?

    init(
        id: UUID = UUID(),
        title: String,
        path: String,
        url: URL? = nil,
        content: String = "",
        encoding: String.Encoding = .utf8,
        bom: Data = Data(),
        lineEnding: LineEnding = .lf,
        displayMode: EditorDisplayMode = .text,
        fileSize: UInt64 = 0,
        hits: Int = 0,
        isDirty: Bool = false,
        isLoading: Bool = false,
        diskModificationDate: Date? = nil,
        diskSnapshot: FileSnapshot? = nil,
        gitKind: GitTabKind? = nil,
        gitDiffRequest: GitDiffRequest? = nil,
        gitDiffDocument: GitDiffDocument? = nil,
        gitDiffLoadGeneration: UInt64 = 0,
        fileDiffRequest: FileDiffRequest? = nil,
        fileDiffDocument: FileDiffDocument? = nil,
        fileDiffLoadGeneration: UInt64 = 0,
        isWelcome: Bool = false,
        viewMode: EditorViewMode? = nil
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.url = url
        self.content = content
        self.contentRevision = 0
        self.encoding = encoding
        self.bom = bom
        self.lineEnding = lineEnding
        self.displayMode = displayMode
        self.fileSize = fileSize
        self.hits = hits
        self.isDirty = isDirty
        self.isLoading = isLoading
        self.diskModificationDate = diskModificationDate
        self.diskSnapshot = diskSnapshot
        self.gitKind = gitKind
        self.gitDiffRequest = gitDiffRequest
        self.gitDiffDocument = gitDiffDocument
        self.gitDiffLoadGeneration = gitDiffLoadGeneration
        self.fileDiffRequest = fileDiffRequest
        self.fileDiffDocument = fileDiffDocument
        self.fileDiffLoadGeneration = fileDiffLoadGeneration
        self.isWelcome = isWelcome
        self.viewMode = viewMode
    }

    /// Nur normale, vollständig geladene Textdokumente können als Paar für
    /// „Dateien vergleichen…“ markiert werden. Willkommen-, Git-, Diff-,
    /// Hex- und Abschnitts-Tabs bleiben gewöhnliche einzelne Tabs.
    var isEligibleForFileComparison: Bool {
        gitKind == nil && fileDiffRequest == nil && !isWelcome
            && !isLoading && displayMode == .text
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

private enum CoordinatedSaveError: Error {
    case targetChanged
    case tabChanged
    case tabChangedAfterWrite
}

enum ExpectedFileState: Equatable {
    case absent
    case present(FileSnapshot)
}

/// Friert den Zielzustand genau während der NSSavePanel-Validierung ein.
/// Entsteht danach eine Datei am vorher freien Pfad, erkennt der exklusive
/// Create-Pfad sie als Konflikt; eine nie bestätigte Datei wird nicht ersetzt.
private final class SavePanelStateCapture: NSObject, NSOpenSavePanelDelegate {
    private(set) var expectedState: ExpectedFileState?

    func panel(_ sender: Any, validate url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            expectedState = .present(try FileSnapshot.read(from: url).snapshot)
        } else {
            expectedState = .absent
        }
    }
}

/// Nutzer-Entscheidung beim Schließen eines Tabs mit ungespeicherten Änderungen
/// (BBEdit-Stil). Siehe `Workspace.confirmCloseHandler` / `Workspace.closeTab`.
enum CloseConfirmation {
    case save        // sichern, dann schließen
    case dontSave    // ohne Sichern schließen (Änderungen verwerfen)
    case cancel      // Schließen abbrechen, Tab bleibt offen
}

private struct GitDiffLoadLease {
    let generation: UInt64
    let lease: GitCancelling
}

/// Startwerte und UserDefaults-Schlüssel der ziehbaren Fensterbreiten. Die
/// Werte sind PRO FENSTER veränderlich (siehe `Workspace.sidebarWidth`); der
/// gespeicherte Wert dient nur als Startbreite neuer Fenster. Die Schlüssel
/// bleiben identisch zur früheren `@AppStorage`-Fassung, damit bereits
/// gespeicherte Nutzerbreiten weiter gelten.
enum SidebarLayout {
    static let defaultSidebarWidth: Double = 200
    static let defaultPreviewWidth: Double = 420
    static let sidebarWidthKey = "editor.sidebarWidth"
    static let previewWidthKey = "markdown.previewWidth"
}

final class Workspace: ObservableObject {
    typealias LanguageDetectionScheduler = (@escaping @Sendable () -> Void) -> Void

    private final class FolderApplyProgressRelay: @unchecked Sendable {
        private weak var workspace: Workspace?
        private let generation: Int

        init(workspace: Workspace, generation: Int) {
            self.workspace = workspace
            self.generation = generation
        }

        func report(_ progress: ApplyTransaction.Progress) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let workspace = self.workspace,
                      workspace.folderApplyGeneration == self.generation,
                      workspace.folderApplying else { return }
                workspace.folderApplyProgressText = L10n.format(
                    "Ordner-Apply: %@ (%ld/%ld)", progress.fileName,
                    progress.completedFiles, progress.totalFiles)
            }
        }
    }

    @Published var tabs: [EditorTab]
    /// Zweiter, schwächer markierter Tab einer Vergleichsauswahl. Der aktive
    /// Tab bleibt dabei unverändert die eindeutige Quelle für Editor und Menüs.
    @Published private(set) var comparisonTabID: UUID? = nil
    @Published var activeTabID: UUID? {
        didSet {
            // Jeder echte Tabwechsel ist eine normale Einzelauswahl. Nur der
            // ausdrückliche Shift-Pfad lässt den aktiven Tab stehen und setzt
            // stattdessen `comparisonTabID`.
            if oldValue != activeTabID {
                comparisonTabID = nil
            }
        }
    }
    // MARK: - Projekt-Zustand (Projekt- & Git-Ausbau, Etappe 1)
    /// Wurzelordner des aktuell geladenen Projekts — steuert die
    /// Dateibaum-Seitenleiste. `nil` = kein Projekt geladen (flache
    /// „GEÖFFNET"-Seitenleiste wie bisher). Nur die optionale, sichere
    /// Sitzungswiederherstellung persistiert den Pfad; der Workspace selbst
    /// bleibt frei von implizitem Startzustand.
    @Published var projectURL: URL?
    /// In der Projekt-Seitenleiste zuletzt angeklickter Ordner (Etappe 1
    /// Wunschpaket 2026-07). Dient dem Save-Dialog als Vorschlagsordner;
    /// ein Klick auf eine Datei hebt die Ordner-Markierung wieder auf.
    /// Nicht persistiert; Projektwechsel setzt zurück.
    @Published var selectedFileTreeFolder: URL?
    /// Kurzlebiger, nicht-modaler Hinweis in der Projekt-Seitenleiste —
    /// z. B. „Seitenleiste zeigt jetzt …“ nach dem automatischen
    /// Ordnerwechsel. Blendet sich nach wenigen Sekunden selbst aus.
    @Published var sidebarNotice: String?
    /// Breite der linken Seitenleiste in Punkten. Bewusst PRO FENSTER (nicht
    /// prozessweit über `@AppStorage`): Der Splitter darf nur das eigene
    /// Fenster verändern, nicht alle offenen gleichzeitig verschieben
    /// (Daniel-Befund 2026-07-20). Der zuletzt gezogene Wert wird dennoch in
    /// UserDefaults gemerkt und dient als Startbreite NEUER Fenster. Das
    /// Klemmen auf einen sinnvollen Bereich erledigt die Editor-Ansicht.
    @Published var sidebarWidth: Double = SidebarLayout.defaultSidebarWidth
    /// Breite der rechten Markdown-Vorschau in Punkten. Gleiche Begründung wie
    /// `sidebarWidth`: pro Fenster ziehbar, aber der letzte Wert seedet neue
    /// Fenster. Vorher teilte auch dieser Splitter alle Fenster (identischer
    /// Befund wie die Seitenleiste).
    @Published var markdownPreviewWidth: Double = SidebarLayout.defaultPreviewWidth
    /// Dateinamens-Filter der Projekt-Seitenleiste (Etappe 3 Wunschpaket
    /// 2026-07c). Leer = kein Filter. Projektwechsel setzt zurück.
    @Published var fileTreeFilterQuery: String = ""
    /// Bekannte 4D-Projektmethoden für den sichtbaren `.4dm`-Editor. Der
    /// Index wird beim Projektwechsel nebenläufig aufgebaut; bis dahin bleibt
    /// die Menge leer und unbekannte Namen sind weiterhin Prozessvariablen.
    @Published private(set) var fourDProjectMethodNames = Set<String>()
    /// Merkt sich den jeweils letzten Hinweis, damit ein verzögertes
    /// Ausblenden niemals einen NEUEREN Hinweis wegräumt.
    private var sidebarNoticeToken = UUID()
    /// Zuletzt benutzte Projekte für den Willkommensbildschirm. Wird
    /// automatisch gepflegt: explizit geöffnete Ordner und erkannte
    /// Git-Repositories geöffneter Dateien (Persistenz via Combine-Sink
    /// in `init`, Muster recentFiles).
    @Published var recentProjects: [ProjectEntry] = []
    /// Git-Status des aktuellen Projekts (Etappe 2). `nil` = kein Projekt,
    /// kein Repo oder git nicht installiert → keine Git-Anzeige. Asynchron
    /// über `refreshGitStatus()` gefüllt.
    @Published var gitStatus: GitStatusSummary?
    /// Atomarer, gemeinsam revidierter Zustand aller Git-Oberflächen.
    @Published var gitRepositorySnapshot: GitRepositorySnapshot?
    /// Commit-Historie des aktuellen Projekts für den Graph-Tab (Phase 3).
    /// Leer = kein Repo/keine Commits oder noch nicht geladen. Asynchron über
    /// `refreshGitLog()` gefüllt.
    @Published var gitLog: [GitCommit] = []
    /// Lokale Branches für die Auswahl in der Projekt-Seitenleiste.
    @Published var gitBranches: [GitBranch] = []
    /// Kurzlebige, nicht-modale Rückmeldung erfolgreicher Git-Aktionen.
    @Published var gitFeedback: GitActionFeedback?
    /// Sicher über `git rev-parse --git-path …` erkannter laufender Vorgang.
    /// Der Wert ist nur eine UI-Hilfe; jede Mutation prüft ihn im exklusiven
    /// Repository-Slot unmittelbar vor der Ausführung erneut.
    @Published var gitOperationState: GitOperationState?
    /// Lokal und global getrennt gelesene Commit-Identität des Projekts.
    @Published var gitIdentity: GitIdentitySnapshot?
    /// Aktuell fokussierter Markerblock im normalen Editor.
    @Published var activeConflictIndex: Int = 0
    @Published var showsConflictBase: Bool = false
    /// Von Git pfadspezifisch aufgelöste `conflict-marker-size`-Werte.
    @Published var gitConflictMarkerSizes: [Data: Int] = [:]
    /// Git-eigene Attributklassifikation offener Konfliktpfade. Ein fehlender
    /// oder laufender Befund ist absichtlich kein impliziter Text-Fallback.
    @Published var gitConflictInspections: [Data: GitConflictInspection] = [:]
    /// Commit-Botschaft des Änderungen-Tabs (VS-Code-artiges Eingabefeld). Pro
    /// Fenster; nach erfolgreichem Commit geleert.
    @Published var commitMessage: String = ""
    // Startet GESCHLOSSEN (Daniel 2026-06-22: „nicht mehr mit offenem Suchdialog
    // starten, das war nur zum Testen"). CMD+F / CMD+SHIFT+F öffnen sie. Die
    // fenster-abhängigen Selbsttests (cmdw/fields) öffnen sie jetzt selbst,
    // siehe SelfTest.openSearchThen.
    @Published var showSearchDialog: Bool = false
    /// Öffnet den Dialog „Dateien vergleichen…" (Etappe 1 Wunschpaket
    /// 2026-07c) als Sheet auf dem Hauptfenster.
    @Published var showCompareFilesDialog: Bool = false
    /// Geordnete Vorbelegung für den nächsten Vergleichsdialog. Die Reihenfolge
    /// folgt der sichtbaren Tab-Leiste, nicht der Klickreihenfolge.
    @Published private(set) var compareDialogPrefillTabIDs: [UUID] = []
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
    @Published var selectionRange: NSRange? = nil {
        // Absichtlich auch bei nil → nil erhöhen: Ein Cursorwechsel besitzt
        // keine nichtleere `selectionRange`, ist für verzögertes Einfügen aber
        // trotzdem ein Zielwechsel.
        didSet { selectionRevision &+= 1 }
    }
    private(set) var selectionRevision: Int = 0

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
    /// Planung/Backup/Apply einer bestätigten Ordner-Vorschau laufen im
    /// Hintergrund. Der Suchdialog zeigt Status und eine Abbruchaktion.
    @Published var folderApplying: Bool = false
    @Published var folderApplyProgressText: String? = nil
    private var folderApplyTask: Task<Void, Never>?
    private var folderApplyGeneration = 0

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
    /// Gemeinsame Quelle für formatspezifischen Soft Wrap. Der Store ist
    /// injizierbar und bleibt dadurch mit isolierten Defaults unit-testbar.
    let softWrapProfiles: SoftWrapProfileStore
    let gitPreferencesStore: GitPreferencesStore
    let gitOperationsCoordinator: GitOperationsCoordinator
    let gitRepositoryStore: GitRepositoryStore
    private var gitRepositoryObservation: GitRepositoryObservation?
    private let gitRepositoryIdentityResolver: GitRepositoryIdentityResolving?
    private let gitAutoFetchController: GitAutoFetchController?
    private let terminalOpener: TerminalOpening
    private let terminalDirectoryResolver: TerminalDirectoryResolving
    private var gitDiffLoadLeases: [UUID: GitDiffLoadLease] = [:]
    private var gitIdentityResolution: GitCancelling?
    var gitOperationStateInspection: GitCancelling?
    var gitIdentityInspection: GitCancelling?
    var gitConflictInspectionLease: GitCancelling?
    var gitConflictInspectionRequestIDs: [Data: UUID] = [:]
    private var gitAutoFetchObservation: GitRepositoryObservation?
    /// Laufender, kleiner Verzeichnis-Scan für 4D-Projektmethoden. Ein neuer
    /// Projektwechsel ersetzt ihn; zusätzlich schützt `projectGeneration`
    /// gegen ein Ergebnis, das erst nach dem Wechsel zurückkehrt.
    private var fourDProjectMethodIndexTask: Task<Void, Never>?
    /// FSEvents können beim Speichern mehrere Einträge liefern. Dieses kurze
    /// Debounce bündelt sie zu genau einem neuen Methodenindex-Scan.
    private var fourDProjectMethodIndexRefreshTask: Task<Void, Never>?
    /// Der Watcher gehört zum Workspace, nicht zu einem sichtbaren
    /// Sidebar-Tab. Sonst blieben Projektmethoden beim Wechsel zu Changes
    /// oder Graph veraltet, obwohl der Editor weiterhin 4D-Dateien zeigt.
    private var fourDProjectMethodWatcher: ProjectFileWatcher?
    /// Erhöht sich bei jedem Projektwechsel. Asynchrone Aktionsketten binden
    /// sich an diesen Wert und können nie in ein später geöffnetes Repo laufen.
    private(set) var projectGeneration: UInt64 = 0

    /// In Tests injizierbar; der Produktpfad postet an den sichtbaren nativen
    /// Editor und läuft damit durch dessen Undo-Manager.
    var conflictTextReplacementHandler: ConflictTextReplacementHandler = ConflictEditorBridge.post
    var confirmIntentionalConflictMarkersHandler: (String) -> Bool = Workspace.defaultConfirmIntentionalConflictMarkers
    var gitMutationConfirmationHandler: (GitMutationConfirmation) -> Bool = Workspace.defaultGitMutationConfirmation
    var gitIdentityPromptHandler: (GitIdentitySnapshot?) -> GitIdentityConfiguration? = Workspace.defaultGitIdentityPrompt
    var gitBranchNamePromptHandler: (String?) -> String? = Workspace.defaultGitBranchNamePrompt

    /// Schwache Referenz auf den Workspace des gerade aktiven Dokumentfensters.
    /// Die In-App-Selbsttests verwenden denselben Hook. Seit mehrere
    /// Dokumentfenster möglich sind, setzen die Fenster-Brücken diesen Wert bei
    /// jedem Fokuswechsel neu; globale Menübefehle landen dadurch nicht im
    /// falschen Dokument.
    static weak var shared: Workspace? {
        didSet {
            ActiveDocumentContext.shared.activate(shared)
        }
    }

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

    init(defaults: UserDefaults = .standard,
         softWrapProfiles: SoftWrapProfileStore? = nil,
         gitOperationsCoordinator: GitOperationsCoordinator = .shared,
         gitRepositoryStore: GitRepositoryStore? = nil,
         gitRepositoryIdentityResolver: GitRepositoryIdentityResolving? = nil,
         gitAutoFetchController: GitAutoFetchController? = nil,
         terminalOpener: TerminalOpening = ExternalTerminalLauncher(),
         terminalDirectoryResolver: TerminalDirectoryResolving = DefaultTerminalDirectoryResolver(),
         scheduleLanguageDetectionWork: @escaping LanguageDetectionScheduler = {
             DispatchQueue.global(qos: .utility).async(execute: $0)
         },
         deliverLanguageDetectionResult: @escaping LanguageDetectionScheduler = {
             DispatchQueue.main.async(execute: $0)
         }) {
        // Die injizierten Defaults merken — ALLE Persistenz-Pfade des
        // Workspace müssen dieselbe Suite nutzen. Vorher schrieb der
        // recentSearchFolders-Sink hart in `.standard`: Selbsttest-Läufe
        // (isolierte Suite!) haben so ihre Temp-Ordner in die ECHTEN
        // Nutzer-Defaults gemüllt (Befund 2026-06-11, 16 Leichen).
        self.defaultsStore = defaults
        self.softWrapProfiles = softWrapProfiles
            ?? SoftWrapProfileStore(defaults: defaults)
        self.gitPreferencesStore = GitPreferencesStore(defaults: defaults)
        self.gitOperationsCoordinator = gitOperationsCoordinator
        self.terminalOpener = terminalOpener
        self.terminalDirectoryResolver = terminalDirectoryResolver
        self.scheduleLanguageDetectionWork = scheduleLanguageDetectionWork
        self.deliverLanguageDetectionResult = deliverLanguageDetectionResult
        if let gitRepositoryStore {
            self.gitRepositoryStore = gitRepositoryStore
        } else if gitOperationsCoordinator === GitOperationsCoordinator.shared {
            self.gitRepositoryStore = .shared
        } else {
            self.gitRepositoryStore = GitRepositoryStore(
                executor: GitRunnerExecutor(), coordinator: gitOperationsCoordinator
            )
        }
        if gitOperationsCoordinator === GitOperationsCoordinator.shared {
            // Isolierte Test-Suites dürfen weder echte Standard-Defaults noch
            // den appweiten Scheduler berühren. Tests können beide Bausteine
            // gezielt injizieren; der normale App-Pfad nutzt `.standard`.
            let usesApplicationDefaults = defaults === UserDefaults.standard
            self.gitRepositoryIdentityResolver = gitRepositoryIdentityResolver
                ?? (usesApplicationDefaults ? GitRepositoryIdentityResolver() : nil)
            self.gitAutoFetchController = gitAutoFetchController
                ?? (usesApplicationDefaults ? .shared : nil)
        } else {
            self.gitRepositoryIdentityResolver = gitRepositoryIdentityResolver
            self.gitAutoFetchController = gitAutoFetchController
        }

        // Auch eine vollständig frische Installation startet ausschließlich
        // mit dem erklärenden Willkommen-Zustand. Ein automatisch geöffnetes
        // Musterdokument wirkt wie eine fremde Datei und untergräbt bei einem
        // lokalen Editor das Vertrauen in die Herkunft der angezeigten Daten.
        let welcome = EditorTab(
            title: Workspace.untitledBaseName,
            path: L10n.string("noch nicht gespeichert"),
            isWelcome: true
        )
        self.tabs = [welcome]
        self.activeTabID = welcome.id
        self.findPattern = ""
        self.replacePattern = ""
        self.searchRunner = SearchRunner(workspace: self)
        Workspace.registerLive(self)
        Workspace.shared = self

        // Store-Änderungen müssen alle Views dieses Workspace neu zeichnen:
        // Der Editor reconciled dadurch `wrapLines`, Footer und Menüstatus
        // lesen gleichzeitig denselben neuen Wert.
        self.softWrapProfiles.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &persistenceBag)

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

        // Seitenleisten-/Vorschau-Breite pro Fenster (Daniel-Befund 2026-07-20):
        // aus DERSELBEN Suite laden, in die auch gespeichert wird. Der
        // gespeicherte Wert ist nur die Startbreite dieses frisch geöffneten
        // Fensters; das Ziehen wirkt danach lokal und verschiebt keine anderen
        // Fenster mehr. `object(forKey:)` unterscheidet „nie gesetzt" (→
        // Standardbreite) von einem echten gespeicherten Wert.
        self.sidebarWidth = (defaults.object(forKey: SidebarLayout.sidebarWidthKey)
            as? Double) ?? SidebarLayout.defaultSidebarWidth
        self.markdownPreviewWidth = (defaults.object(forKey: SidebarLayout.previewWidthKey)
            as? Double) ?? SidebarLayout.defaultPreviewWidth
        // `dropFirst()` überspringt den gerade gesetzten Startwert, sonst
        // schriebe der Sink direkt nach dem Init überflüssig zurück. `defaults`
        // capturen hält Selbsttests in ihrer isolierten Suite.
        $sidebarWidth
            .dropFirst()
            .sink { width in defaults.set(width, forKey: SidebarLayout.sidebarWidthKey) }
            .store(in: &persistenceBag)
        $markdownPreviewWidth
            .dropFirst()
            .sink { width in defaults.set(width, forKey: SidebarLayout.previewWidthKey) }
            .store(in: &persistenceBag)

        // Recent-Files (K2) und Such-Verlauf (K4) aus DERSELBEN Suite laden
        // und bei jeder Änderung zurückschreiben — gleiches Muster wie oben.
        self.recentFiles = RecentFilesStore.load(from: defaults)
        $recentFiles
            .dropFirst()
            .sink { paths in RecentFilesStore.save(paths, to: defaults) }
            .store(in: &persistenceBag)

        // Zuletzt benutzte Projekte (Willkommensbildschirm) — gleiches Muster.
        self.recentProjects = ProjectStore.load(from: defaults)
        $recentProjects
            .dropFirst()
            .sink { entries in ProjectStore.save(entries, to: defaults) }
            .store(in: &persistenceBag)

        self.searchHistory = SearchHistoryStore.load(from: defaults)
        $searchHistory
            .dropFirst()
            .sink { entries in SearchHistoryStore.save(entries, to: defaults) }
            .store(in: &persistenceBag)

        NotificationCenter.default.publisher(for: .fastraGitIdentityChanged)
            .sink { [weak self] notification in
                guard let self,
                      let notice = notification.object as? GitIdentityChangeNotice else { return }
                // Lokale Identitäten betreffen nur Fenster desselben Repositories;
                // globale Werte können dagegen in jedem offenen Projekt greifen.
                if let repositoryKey = self.currentGitActionContext?.repositoryKey,
                   notice.applies(to: repositoryKey) {
                    self.refreshGitIdentity(force: true)
                }
            }
            .store(in: &persistenceBag)

        // Die Konfiguration wird erst beim Öffnen eines konkreten Projekts
        // geladen. Danach schreibt jede UI-Änderung unter dessen Pfad zurück.
        $projectSearchConfiguration
            .dropFirst()
            .sink { [weak self] config in
                guard let root = self?.projectURL else { return }
                ProjectSearchStore.save(config, for: root, defaults: defaults)
            }
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

    /// Genau zwei gültige Dokument-Tabs in ihrer sichtbaren Links-nach-rechts-
    /// Reihenfolge. Ein veralteter Zustand nach externen Modelländerungen wird
    /// hier nie als gültiges Paar ausgegeben.
    var selectedComparisonTabIDs: [UUID]? {
        guard let activeTabID,
              let comparisonTabID,
              activeTabID != comparisonTabID else {
            return nil
        }
        let selected = Set([activeTabID, comparisonTabID])
        let ordered = tabs.filter {
            selected.contains($0.id) && $0.isEligibleForFileComparison
        }.map(\.id)
        return ordered.count == 2 ? ordered : nil
    }

    /// Eine einzige Formatauflösung für Footer, Editor und Formatprofil.
    var activeDocumentFormat: DocumentFormat {
        DocumentFormatResolver.resolve(tab: activeTab)
    }

    var softWrapEnabled: Bool {
        softWrapProfiles.isEnabled(for: activeDocumentFormat.id)
    }

    var softWrapHasOverride: Bool {
        softWrapProfiles.hasOverride(for: activeDocumentFormat.id)
    }

    var softWrapTarget: SoftWrapTarget {
        softWrapProfiles.target(for: activeDocumentFormat.id)
    }

    var softWrapFixedColumn: Int {
        softWrapProfiles.fixedColumn(for: activeDocumentFormat.id)
    }

    var pageGuideColumn: Int {
        softWrapProfiles.pageGuideColumn
    }

    var showPageGuide: Bool {
        softWrapProfiles.showPageGuide
    }

    /// `nil` bedeutet das bisherige Umbruchziel Fensterbreite.
    var effectiveSoftWrapColumn: Int? {
        switch softWrapTarget {
        case .window: nil
        case .pageGuide: pageGuideColumn
        case .fixedColumn: softWrapFixedColumn
        }
    }

    func setSoftWrapEnabled(_ enabled: Bool) {
        softWrapProfiles.setEnabled(enabled, for: activeDocumentFormat.id)
    }

    func toggleSoftWrap() {
        softWrapProfiles.toggle(for: activeDocumentFormat.id)
    }

    func selectSoftWrapTarget(_ target: SoftWrapTarget) {
        softWrapProfiles.selectTarget(target, for: activeDocumentFormat.id)
    }

    func setSoftWrapFixedColumn(_ column: Int) {
        softWrapProfiles.setFixedColumn(column, for: activeDocumentFormat.id)
    }

    func setPageGuideColumn(_ column: Int) {
        softWrapProfiles.setPageGuideColumn(column)
    }

    func setShowPageGuide(_ show: Bool) {
        softWrapProfiles.setShowPageGuide(show)
    }

    func togglePageGuide() {
        setShowPageGuide(!showPageGuide)
    }

    func resetSoftWrapToFactoryDefault() {
        softWrapProfiles.resetToFactoryDefault(for: activeDocumentFormat.id)
    }

    /// Ziel des globalen Menübefehls. Ein Projekt hat Vorrang; ohne Projekt
    /// dient nur eine echte aktive Datei als Quelle.
    var terminalDirectory: URL? {
        terminalDirectoryResolver.resolve(projectURL: projectURL,
                                          activeFileURL: activeTab?.url)
    }

    var terminalUnavailableReason: String {
        terminalDirectory == nil
            ? L10n.string("Öffne zuerst ein Projekt oder eine gespeicherte Datei.") : ""
    }

    func openTerminal(at explicitDirectory: URL? = nil) {
        guard let directory = explicitDirectory?.standardizedFileURL ?? terminalDirectory else {
            NSAlert.runWarning(title: L10n.string("Terminal konnte nicht geöffnet werden"),
                               text: TerminalOpenError.noDirectory.localizedDescription)
            return
        }
        terminalOpener.open(directory: directory) { result in
            guard case .failure(let error) = result else { return }
            DispatchQueue.main.async {
                NSAlert.runWarning(title: L10n.string("Terminal konnte nicht geöffnet werden"),
                                   text: error.localizedDescription)
            }
        }
    }

    /// Basisname für unbenannte Dokumente aus derselben Lokalisierung wie die
    /// übrige Oberfläche (analog zu TextEdit).
    static var untitledBaseName: String {
        L10n.string("Ohne Titel")
    }

    /// Titel für einen neuen unbenannten Tab an 1-basierter `position`. macOS-
    /// Konvention: der erste unbenannte Tab trägt nur den Basisnamen, weitere
    /// bekommen eine laufende Nummer („Ohne Titel", „Ohne Titel 2", …).
    static func untitledName(position: Int) -> String {
        position <= 1 ? untitledBaseName : "\(untitledBaseName) \(position)"
    }

    /// `true`, wenn dieses Fenster gerade den Willkommensbildschirm zeigt —
    /// nämlich genau dann, wenn der AKTIVE Tab der Willkommen-Tab ist. Andere
    /// Tabs (auch leere) zeigen den Editor. Tab-Beschriftung („Willkommen"),
    /// Fenstertitel (Version+Datum statt Dateiname) und die Editor-/Welcome-
    /// Umschaltung in `ContentView` greifen auf dieselbe Wahrheit zu.
    var isWelcomeScreen: Bool {
        WelcomeLogic.shouldShow(activeTab: activeTab)
    }

    /// Wandelt einen etwaigen Willkommen-Tab in ein normales leeres Dokument um
    /// (zeigt dann den Editor statt der Willkommensseite). Für „Ordner öffnen"
    /// und für ⌘N-Fenster, die neben einem bereits offenen Fenster entstehen.
    func dismissWelcomeTab() {
        for idx in tabs.indices where tabs[idx].isWelcome {
            tabs[idx].isWelcome = false
        }
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
                    let oldLength = self.tabs[idx].content.count
                    self.tabs[idx].content = newValue
                    if !self.tabs[idx].isDirty {
                        self.tabs[idx].isDirty = true
                    }
                    // Inhaltsbasierte Spracherkennung (Etappe 3): reagiert
                    // nur bei geeigneten Tabs; Block-Einfügungen sofort,
                    // Tippen debounced. Kostet hier nur den Längenvergleich.
                    self.scheduleLanguageDetection(tabID: self.tabs[idx].id,
                                                   oldLength: oldLength,
                                                   newLength: newValue.count)
                }
            }
        )
    }

    // MARK: Tab-Verwaltung

    /// Gemeinsamer Klickpfad der Tab-Leiste. Normaler Klick aktiviert genau
    /// einen Tab. Shift-Klick setzt oder ersetzt den zweiten Vergleichstab,
    /// ohne den aktuellen Editor umzuschalten; erneuter Shift-Klick auf einen
    /// der beiden Tabs hebt nur die Paarwahl auf.
    func selectTab(id: UUID, extendingComparison: Bool = false) {
        guard let candidate = tabs.first(where: { $0.id == id }) else { return }

        if extendingComparison,
           let activeTabID,
           let active = tabs.first(where: { $0.id == activeTabID }),
           active.isEligibleForFileComparison,
           candidate.isEligibleForFileComparison {
            if id == activeTabID || id == comparisonTabID {
                comparisonTabID = nil
            } else {
                comparisonTabID = id
            }
            return
        }

        comparisonTabID = nil
        activeTabID = id
    }

    /// Öffnet den Vergleichsdialog mit optionaler, bereits validierter
    /// Tab-Vorbelegung. Der globale Menübefehl übergibt keine IDs.
    func presentCompareFilesDialog(prefillingTabIDs: [UUID] = []) {
        let eligible = Set(tabs.filter(\.isEligibleForFileComparison).map(\.id))
        let unique = prefillingTabIDs.reduce(into: [UUID]()) { result, id in
            if eligible.contains(id), !result.contains(id) {
                result.append(id)
            }
        }
        compareDialogPrefillTabIDs = Array(unique.prefix(2))
        showCompareFilesDialog = true
    }

    /// Kontextmenü-Aktion eines markierten Tabs. Der angeklickte Tab muss zu
    /// demselben gültigen Paar gehören; so kann ein Rechtsklick auf einen
    /// unmarkierten Nachbartab keine unerwarteten Quellen übernehmen.
    @discardableResult
    func presentComparisonForSelectedTabs(contextTabID: UUID) -> Bool {
        guard let pair = selectedComparisonTabIDs,
              pair.contains(contextTabID) else {
            return false
        }
        presentCompareFilesDialog(prefillingTabIDs: pair)
        return true
    }

    func openNewTab() {
        let new = EditorTab(
            title: Workspace.untitledName(position: tabs.count + 1),
            path: "—",
            content: ""
        )
        tabs.append(new)
        activeTabID = new.id
        // Kein Willkommen-Dismiss: ein etwaiger Willkommen-Tab bleibt als
        // eigener Tab erhalten. Der neue Tab ist NICHT `isWelcome` → er zeigt
        // sofort den Editor, während wir hineinspringen (Daniel-Wunsch
        // 2026-07-12: „Willkommen stehen lassen, in den zweiten Tab springen").
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
        alert.messageText = L10n.format("Möchten Sie die Änderungen an „%@“ sichern?", title)
        alert.informativeText = L10n.string("Ihre Änderungen gehen verloren, wenn Sie sie nicht sichern.")
        alert.addButton(withTitle: L10n.string("Sichern"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        alert.addButton(withTitle: L10n.string("Nicht sichern"))
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
        cancelGitDiffLoad(tabID: id)
        tabs.remove(at: idx)
        if comparisonTabID == id {
            comparisonTabID = nil
        }
        // Aktiven Tab konsistent halten: war ein ANDERER Tab aktiv und existiert
        // noch, bleibt er aktiv (mayCloseTab kann activeTabID fürs Sichern kurz
        // umgesetzt haben); sonst den ersten verbleibenden aktivieren.
        if let prev = previousActive, prev != id, tabs.contains(where: { $0.id == prev }) {
            activeTabID = prev
        } else {
            activeTabID = tabs.first?.id
        }
        // Etappe 1 (Wunschpaket 2026-07): Gehören die verbliebenen Dateien
        // alle zu einem anderen Ordner, folgt die Seitenleiste — sichtbar,
        // nie während einer aktiven Such-/Ersetzungsvorschau.
        switchProjectAfterTabCloseIfNeeded()
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
        cancelAllGitDiffLoads()
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
        for removedID in tabs.map(\.id) where removedID != id {
            cancelGitDiffLoad(tabID: removedID)
        }
        tabs.removeAll { $0.id != id }
        comparisonTabID = nil
        activeTabID = id
        // Gleiche Seitenleisten-Folge wie beim einzelnen Schließen (Etappe 1).
        switchProjectAfterTabCloseIfNeeded()
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
        .utf32LittleEndian, .utf32BigEndian,
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
            alert.messageText = L10n.string("Ungespeicherte Änderungen verwerfen?")
            // codereview-ok: „…“ (U+201E/U+201C) IST das korrekte deutsche Anführungszeichen-Paar; U+201D wäre englisch (2026-07-06)
            alert.informativeText = L10n.format(
                "„%@“ wird mit %@ neu von der Platte geladen. Deine ungespeicherten Änderungen gehen dabei verloren.",
                tabs[idx].title, encoding.displayName
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("Neu laden"))
            alert.addButton(withTitle: L10n.string("Abbrechen"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let tabID = tabs[idx].id
        let originalRevision = tabs[idx].contentRevision
        let originalDiskSnapshot = tabs[idx].diskSnapshot
        let generation = (loadGeneration[tabID] ?? 0) + 1
        loadGeneration[tabID] = generation
        tabs[idx].isLoading = true

        let loader = reopenFileLoader
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try loader(url, encoding) }
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
                    guard self.tabs[i].contentRevision == originalRevision,
                          self.tabs[i].diskSnapshot == originalDiskSnapshot else {
                        self.tabs[i].isLoading = false
                        return
                    }
                    self.tabs[i].content    = loaded.content
                    self.tabs[i].encoding   = loaded.encoding
                    self.tabs[i].bom        = loaded.bom
                    self.tabs[i].lineEnding = loaded.lineEnding
                    self.tabs[i].displayMode = loaded.displayMode
                    self.tabs[i].fileSize = loaded.fileSize
                    self.tabs[i].isDirty    = false
                    self.tabs[i].isLoading  = false
                    self.tabs[i].diskModificationDate = ExternalChange.diskModificationDate(of: url)
                    self.tabs[i].diskSnapshot = loaded.diskSnapshot
                case .failure:
                    // Bytes passen nicht zum gewählten Encoding → Tab unverändert
                    // lassen (kein Datenverlust), Spinner aus, Hinweis zeigen.
                    self.tabs[i].isLoading = false
                    NSAlert.runWarning(title: L10n.string("Neu öffnen fehlgeschlagen"),
                        text: L10n.format("Die Datei lässt sich nicht als %@ lesen. Der bisherige Inhalt bleibt unverändert.", encoding.displayName))
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
        alert.messageText = L10n.format("„%@“ wurde außerhalb von Fastra geändert.", title)
        alert.informativeText = L10n.string("Die Datei auf der Festplatte ist neuer, dieser Tab enthält aber ungespeicherte Änderungen. Neu laden verwirft deine Änderungen.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Behalten"))
        alert.addButton(withTitle: L10n.string("Neu laden"))
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
        let originalRevision = tabs[idx].contentRevision
        let originalDiskSnapshot = tabs[idx].diskSnapshot
        let generation = (loadGeneration[tabID] ?? 0) + 1
        loadGeneration[tabID] = generation
        tabs[idx].isLoading = true

        let loader = reloadFileLoader
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try loader(url) }
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
                    guard self.tabs[i].contentRevision == originalRevision,
                          self.tabs[i].diskSnapshot == originalDiskSnapshot else {
                        self.tabs[i].isLoading = false
                        return
                    }
                    self.tabs[i].content    = loaded.content
                    self.tabs[i].encoding   = loaded.encoding
                    self.tabs[i].bom        = loaded.bom
                    self.tabs[i].lineEnding = loaded.lineEnding
                    self.tabs[i].displayMode = loaded.displayMode
                    self.tabs[i].fileSize = loaded.fileSize
                    self.tabs[i].isDirty    = false
                    self.tabs[i].isLoading  = false
                    self.tabs[i].diskModificationDate = ExternalChange.diskModificationDate(of: url)
                    self.tabs[i].diskSnapshot = loaded.diskSnapshot
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
        // Ordner ebenfalls wählbar (Daniel-Wunsch 2026-07-12): ein gewählter
        // Ordner wird wie über den Willkommensbildschirm als Projekt geladen
        // (Git-Erkennung inklusive), eine Datei landet in einem Tab.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Datei oder Ordner öffnen")
        panel.prompt = L10n.string("Öffnen")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFileOrFolder(at: url)
    }

    /// Öffnet die gewählte URL passend: Ordner → als Projekt laden (Dateibaum +
    /// Git wie über den Willkommensbildschirm), Datei → in einen Tab. Gemeinsamer
    /// Einstieg für ⌘O.
    func openFileOrFolder(at url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            // Nicht mehr vorhanden → loadFile durchlaufen lassen, das meldet den Fehler.
            loadFile(at: url)
            return
        }
        if isDir.boolValue {
            openProject(at: url)
        } else {
            loadFile(at: url)
        }
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
        // URL-Form vereinheitlichen: dieselbe Datei kommt je nach Quelle in
        // verschiedenen Formen an — programmatisch gebaut `/var/…`, aus
        // Verzeichnis-Listings (Projektbaum!) und NSOpenPanel dagegen
        // `/private/var/…`. Ohne Normalisierung scheitern Tab-Dedup und
        // Aktiv-Markierung im Projektbaum an `/var` ≠ `/private/var`
        // (Befund Screenshot 2026-07-12).
        let url = url.canonicalFileURL
        // ── (1) Dedup ──────────────────────────────────────────────────────
        // Wenn die Datei schon als Tab offen ist, nur aktivieren — kein zweiter Tab.
        if let existingIdx = tabs.firstIndex(where: { $0.url == url }) {
            activeTabID = tabs[existingIdx].id
            noteRecentFile(url)
            openParentFolderIfProjectMissing(for: url)
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
                    self.tabs[idx].bom        = loaded.bom
                    self.tabs[idx].lineEnding = loaded.lineEnding
                    self.tabs[idx].displayMode = loaded.displayMode
                    self.tabs[idx].fileSize = loaded.fileSize
                    // Basis-Datum für die Extern-Änderungs-Erkennung merken.
                    self.tabs[idx].diskModificationDate = ExternalChange.diskModificationDate(of: url)
                    self.tabs[idx].diskSnapshot = loaded.diskSnapshot
                    self.tabs[idx].isDirty    = false
                    self.tabs[idx].isLoading  = false
                    // BBEdit-Verhalten: das leere unbenannte Start-/Scratch-
                    // Dokument abräumen, sobald eine echte Datei geladen ist
                    // (der gerade geladene Tab bleibt erhalten).
                    self.tabs = Workspace.tabsRemovingEmptyScratch(self.tabs, keeping: tabID)
                    self.noteRecentFile(url)
                    self.openParentFolderIfProjectMissing(for: url)
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
        // Git-Text-Tabs (Verlauf/Diff) und Datei-Vergleichs-Tabs sind
        // read-only — ⌘S tut nichts.
        if tabs[idx].gitKind != nil || tabs[idx].fileDiffRequest != nil { return }
        // Abschnitts- und Hex-Views halten absichtlich keinen vollständigen
        // editierbaren Buffer; Speichern wäre daher eine Trunkierungsgefahr.
        guard tabs[idx].displayMode == .text else { NSSound.beep(); return }
        guard !tabs[idx].isLoading else { NSSound.beep(); return }
        if let url = tabs[idx].url {
            _ = write(tab: tabs[idx], to: url)
        } else {
            saveActiveTabAs()
        }
    }

    func saveActiveTabAs() {
        guard let idx = activeTabIndex else { return }
        let tabID = tabs[idx].id
        // Read-only Git- und Vergleichs-Tabs lassen sich nicht „speichern unter".
        if tabs[idx].gitKind != nil || tabs[idx].fileDiffRequest != nil { return }
        guard tabs[idx].displayMode == .text else { NSSound.beep(); return }
        guard !tabs[idx].isLoading else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let stateCapture = SavePanelStateCapture()
        panel.delegate = stateCapture
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = tabs[idx].title
        panel.message = L10n.string("Datei speichern unter…")
        // Vorschlagsordner (Etappe 1 Wunschpaket 2026-07): markierter
        // Seitenleisten-Ordner vor Projektordner; existiert keiner (mehr),
        // bleibt das Systemverhalten des Panels unangetastet.
        if let directory = Self.suggestedSaveDirectory(
            selectedFolder: usableDirectory(selectedFileTreeFolder),
            projectURL: usableDirectory(projectURL)
        ) {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let expectedState = stateCapture.expectedState,
              let currentIndex = tabs.firstIndex(where: { $0.id == tabID }),
              write(tab: tabs[currentIndex], to: url,
                    expectedTargetState: expectedState),
              let savedIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[savedIndex].url = url
        tabs[savedIndex].title = url.lastPathComponent
        tabs[savedIndex].path = url.deletingLastPathComponent().path
    }

    /// Rückfrage bei einem Save-Ziel, das nicht mehr dem geladenen Snapshot
    /// entspricht. `true` erlaubt genau den gerade beobachteten Fremdstand zu
    /// überschreiben; eine weitere Änderung danach bricht trotzdem ab.
    var saveConflictConfirmHandler: (String) -> Bool = Workspace.defaultSaveConflictConfirmation
    /// Deterministischer Testpunkt nach Temp-Write, aber vor Koordination.
    var saveBeforeCoordinateHandler: ((URL) -> Void)? = nil
    var saveSafetyWarningHandler: (String, String) -> Void = { title, text in
        NSAlert.runWarning(title: title, text: text)
    }

    static func defaultSaveConflictConfirmation(_ title: String) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { defaultSaveConflictConfirmation(title) }
        }
        let alert = NSAlert()
        alert.messageText = L10n.format("„%@“ wurde außerhalb von Fastra geändert.", title)
        alert.informativeText = L10n.string("Speichern würde den neueren Plattenstand überschreiben. Prüfe die Änderungen oder speichere nur nach bewusster Bestätigung.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        alert.addButton(withTitle: L10n.string("Trotzdem speichern"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    @discardableResult
    func write(tab: EditorTab, to url: URL) -> Bool {
        write(tab: tab, to: url, expectedTargetState: nil)
    }

    @discardableResult
    func write(tab: EditorTab, to url: URL,
               expectedTargetState: ExpectedFileState?) -> Bool {
        guard tabs.contains(where: { $0.id == tab.id }) else { return false }
        do {
            guard !tab.isLoading else { throw CoordinatedSaveError.tabChanged }
            let capturedRevision = tab.contentRevision
            func tabStillMatches() -> Bool {
                guard let currentIndex = tabs.firstIndex(where: { $0.id == tab.id }) else {
                    return false
                }
                let current = tabs[currentIndex]
                return !current.isLoading
                    && current.contentRevision == capturedRevision
                    && current.content == tab.content
                    && current.encoding == tab.encoding
                    && current.bom == tab.bom
                    && current.lineEnding == tab.lineEnding
                    && current.diskSnapshot == tab.diskSnapshot
                    && current.url?.canonicalFileURL.path == tab.url?.canonicalFileURL.path
            }
            // Zeilenenden auf die gewählte Konvention bringen (K7) — der Editor
            // hält intern u.U. andere Umbrüche; maßgeblich ist die im Footer
            // gewählte `lineEnding`. converting() normalisiert auch gemischte.
            guard let out = FileLoader.encodedData(
                content: tab.content, encoding: tab.encoding,
                bom: tab.bom, lineEnding: tab.lineEnding
            ) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            let fm = FileManager.default
            let targetExists = fm.fileExists(atPath: url.path)
            let observedState: ExpectedFileState
            if targetExists {
                observedState = .present(try FileSnapshot.read(from: url).snapshot)
            } else {
                observedState = .absent
            }
            if let expectedTargetState,
               expectedTargetState != observedState {
                throw CoordinatedSaveError.targetChanged
            }
            let sameDocument = tab.url?.canonicalFileURL.path == url.canonicalFileURL.path
            let loadedState: ExpectedFileState = tab.diskSnapshot.map(ExpectedFileState.present)
                ?? .absent
            if sameDocument, observedState != loadedState {
                guard saveConflictConfirmHandler(tab.title) else {
                    return false
                }
                // Ein modaler Alert pumpt die Main-Runloop. Hat sich der Tab
                // dabei geändert, darf die vorher kodierte Kopie nicht mehr
                // geschrieben oder der neuere Inhalt clean gesetzt werden.
                guard tabStillMatches() else { throw CoordinatedSaveError.tabChanged }
            }

            // Temp-Datei im Zielordner zuerst vollständig vorbereiten. Erst
            // danach folgt die letzte Zustandsprüfung und der kurze atomare
            // Replace/Create-Schritt.
            let tmpURL = url.deletingLastPathComponent().appendingPathComponent(
                ".fastra-save-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: tmpURL) }
            try out.write(to: tmpURL, options: .atomic)
            saveBeforeCoordinateHandler?(url)
            guard tabStillMatches() else { throw CoordinatedSaveError.tabChanged }

            var coordinationError: NSError?
            var writeError: Error?
            var writtenSnapshot: FileSnapshot?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            let finalExpectedState = expectedTargetState ?? observedState
            let coordinationOptions: NSFileCoordinator.WritingOptions = targetExists
                ? .forReplacing : []
            coordinator.coordinate(writingItemAt: url, options: coordinationOptions,
                                   error: &coordinationError) { coordinatedURL in
                do {
                    switch finalExpectedState {
                    case .present(let expectedBeforeWrite):
                        let immediatelyBefore = try FileSnapshot.read(from: coordinatedURL)
                        guard immediatelyBefore.snapshot == expectedBeforeWrite else {
                            throw CoordinatedSaveError.targetChanged
                        }
                        _ = try fm.replaceItemAt(coordinatedURL, withItemAt: tmpURL)
                    case .absent:
                        guard !fm.fileExists(atPath: coordinatedURL.path) else {
                            throw CoordinatedSaveError.targetChanged
                        }
                        // moveItem ist ein exklusives Create: entsteht nach
                        // dem Check doch noch ein Ziel, schlägt es fehl, statt
                        // den fremden Stand zu überschreiben.
                        try fm.moveItem(at: tmpURL, to: coordinatedURL)
                    }
                    writtenSnapshot = FileSnapshot(data: out, at: coordinatedURL)
                } catch {
                    writeError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
            guard let writtenSnapshot else { throw CoordinatedSaveError.targetChanged }
            guard tabStillMatches() else {
                // Der gespeicherte Snapshot ist real, aber neuere In-Memory-
                // Änderungen bleiben ausdrücklich dirty und erhalten.
                if let currentIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
                    tabs[currentIndex].diskSnapshot = writtenSnapshot
                    tabs[currentIndex].diskModificationDate = ExternalChange.diskModificationDate(of: url)
                    tabs[currentIndex].isDirty = true
                }
                throw CoordinatedSaveError.tabChangedAfterWrite
            }
            guard let finalIndex = tabs.firstIndex(where: { $0.id == tab.id }) else {
                throw CoordinatedSaveError.tabChangedAfterWrite
            }
            tabs[finalIndex].isDirty = false
            // Unser eigener Write ist keine „externe" Änderung — Basis-Datum
            // nachziehen, sonst schlüge die Erkennung beim nächsten
            // App-Wechsel auf die selbst geschriebene Datei an.
            tabs[finalIndex].diskModificationDate = ExternalChange.diskModificationDate(of: url)
            tabs[finalIndex].diskSnapshot = writtenSnapshot
            // Speichern kann den Git-Status geändert haben (Datei jetzt „M").
            refreshGitStatus()
            return true
        } catch {
            if case CoordinatedSaveError.targetChanged = error {
                saveSafetyWarningHandler(
                    L10n.string("Speichern abgebrochen"),
                    L10n.string("Die Datei wurde während des Speicherns erneut geändert. Der Plattenstand blieb erhalten."))
            } else if case CoordinatedSaveError.tabChanged = error {
                saveSafetyWarningHandler(
                    L10n.string("Speichern abgebrochen"),
                    L10n.string("Der Editorinhalt hat sich während der Rückfrage geändert. Die neueren Änderungen bleiben ungespeichert erhalten."))
            } else if case CoordinatedSaveError.tabChangedAfterWrite = error {
                saveSafetyWarningHandler(
                    L10n.string("Neuere Änderungen noch ungespeichert"),
                    L10n.string("Während des Speicherns kamen weitere Editoränderungen hinzu. Sie bleiben im Tab erhalten und müssen erneut gespeichert werden."))
            } else {
                NSAlert(error: error).runModal()
            }
            return false
        }
    }

    // MARK: - Zuletzt benutzte Dateien (K2)

    /// Merkt sich eine gerade geöffnete Datei oben in `recentFiles`
    /// (Persistenz läuft automatisch über den Combine-Sink in `init`).
    /// Liegt die Datei in einem Git-Repository, wird dessen Wurzelordner
    /// nebenbei still als Projekt gemerkt (Projekt- & Git-Ausbau: Repos
    /// merken sich „standardmäßig", ohne Rückfrage, ohne Meldung).
    func noteRecentFile(_ url: URL) {
        recentFiles = RecentFilesStore.prepending(url.path, to: recentFiles)
        if let root = ProjectStore.repositoryRoot(for: url) {
            noteRecentProject(root)
        }
    }

    // MARK: - Projekte (Projekt- & Git-Ausbau, Etappe 1)

    /// Merkt sich einen Projekt-Ordner oben in `recentProjects` — nur die
    /// Liste, lädt NICHT das Projekt (Persistenz via Combine-Sink in `init`).
    func noteRecentProject(_ url: URL) {
        recentProjects = ProjectStore.prepending(url.path, to: recentProjects)
    }

    // MARK: - Etappe-1-UX (Wunschpaket 2026-07)

    /// Einzeldatei geöffnet, aber kein Ordner in der Seitenleiste? Dann einen
    /// passenden Ordner als Projekt zeigen, damit die Seitenleiste nie
    /// grundlos leer bleibt. Der Editor-Fokus bleibt auf der Datei
    /// (`openProject` erhält den aktiven Tab), fremde offene Tabs bleiben
    /// ausdrücklich bestehen. Mit bereits offenem Ordner: no-op.
    private func openParentFolderIfProjectMissing(for url: URL) {
        guard projectURL == nil else { return }
        guard let folder = usableDirectory(Self.autoProjectFolder(for: url)) else { return }
        openProject(at: folder, keepingUnrelatedTabs: true)
    }

    /// Wählt den Ordner für das AUTOMATISCHE Projekt-Öffnen (Etappe 1
    /// Wunschpaket 2026-07b): Liegt die Datei in einem Git-Repository, ist
    /// dessen Wurzelordner das Ziel — so passen Seitenleisten-Anzeige und
    /// Git-Funktionen (die den Root ohnehin selbst finden) zusammen. Ohne
    /// Repo bleibt es beim unmittelbaren Elternordner. Gilt bewusst NUR für
    /// diesen Auto-Pfad: Wer explizit einen Unterordner als Projekt öffnet,
    /// behält ihn. Pure Funktion → unit-testbar.
    static func autoProjectFolder(for url: URL,
                                  fileManager: FileManager = .default) -> URL? {
        if let root = ProjectStore.repositoryRoot(for: url, fileManager: fileManager) {
            return root
        }
        return url.deletingLastPathComponent()
    }

    // MARK: - Inhaltsbasierte Spracherkennung (Etappe 3 Wunschpaket 2026-07)

    /// Laufende Debounce-Arbeit je Tab — ein neuer Tastendruck ersetzt die
    /// noch wartende Analyse (klassischer Debounce).
    private var languageDetectionWork: [UUID: DispatchWorkItem] = [:]
    /// Inhaltslänge zur Zeit der letzten Analyse je Tab (Drossel-Basis).
    private var languageDetectionAnalyzedLength: [UUID: Int] = [:]
    /// Produktion analysiert im Hintergrund und übernimmt auf dem Main-Thread.
    /// Tests injizieren synchrone Scheduler und brauchen dadurch keine
    /// zeitabhängigen Polling-Schleifen für denselben Zustandsübergang.
    private let scheduleLanguageDetectionWork: LanguageDetectionScheduler
    private let deliverLanguageDetectionResult: LanguageDetectionScheduler

    /// Nur ungespeicherte Tabs ohne Dateiendung, ohne manuelle Sprachwahl
    /// und ohne Sonderrolle (Git/Willkommen) nehmen an der Automatik teil.
    /// Nach dem Speichern gewinnt die Endung; manuelle Wahl gewinnt immer.
    static func isEligibleForContentDetection(_ tab: EditorTab) -> Bool {
        tab.url == nil && !tab.isWelcome && tab.gitKind == nil
            && tab.fileDiffRequest == nil
            && tab.languageOverride == nil
            && tab.customLanguageOverrideID == nil
            && (tab.title as NSString).pathExtension.isEmpty
    }

    /// Entscheidet über sofortige/verzögerte Analyse (pure Logik in
    /// `ContentLanguageDetection.trigger`) und plant sie entsprechend ein.
    func scheduleLanguageDetection(tabID: UUID, oldLength: Int, newLength: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              Self.isEligibleForContentDetection(tabs[idx]) else { return }
        switch ContentLanguageDetection.trigger(
            oldLength: oldLength, newLength: newLength,
            lastAnalyzedLength: languageDetectionAnalyzedLength[tabID]
        ) {
        case .none:
            return
        case .immediate:
            languageDetectionWork[tabID]?.cancel()
            performLanguageDetection(tabID: tabID)
        case .debounced:
            languageDetectionWork[tabID]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.performLanguageDetection(tabID: tabID)
            }
            languageDetectionWork[tabID] = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + ContentLanguageDetection.debounceInterval,
                execute: work
            )
        }
    }

    /// Analysiert die ersten ~64 KB auf einem Hintergrund-Thread und wendet
    /// das Ergebnis mit Hysterese an. Bei normalem Tippen entsteht praktisch
    /// keine Last: Der Aufruf kommt nur nach Debounce + Drossel hierher.
    private func performLanguageDetection(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              Self.isEligibleForContentDetection(tabs[idx]) else { return }
        let sample = String(tabs[idx].content
            .prefix(ContentLanguageDetection.analysisCharacterLimit))
        let totalLength = tabs[idx].content.count
        languageDetectionAnalyzedLength[tabID] = totalLength

        let deliver = deliverLanguageDetectionResult
        scheduleLanguageDetectionWork { [weak self] in
            let format = ContentLanguageDetection.detect(in: sample)
            // Kein Format erkannt → Shebang-/Modeline-Erkennung des Editors
            // (bislang ungenutzter Upstream-Pfad; erkennt z. B. „#!/bin/bash").
            var language: CodeLanguage?
            if let format {
                language = Self.grammarForDetectedFormat(format)
            } else {
                let fallback = CodeLanguage.detectLanguageFrom(
                    // Bewusst ohne Endung: Es zählt allein der Inhalt.
                    url: URL(fileURLWithPath: "unbenannt"),
                    prefixBuffer: String(sample.prefix(512)),
                    suffixBuffer: nil
                )
                if fallback.id != .plainText {
                    language = fallback
                }
            }
            let detectedLanguage = language
            deliver { [weak self] in
                guard let self,
                      let i = self.tabs.firstIndex(where: { $0.id == tabID }),
                      Self.isEligibleForContentDetection(self.tabs[i]) else { return }
                // Hysterese über den Grammatik-Vergleich: `nil` (nichts
                // erkannt) lässt eine bestehende Erkennung stehen.
                let current = self.tabs[i].contentDetectedLanguage
                let currentFormat = self.tabs[i].contentDetectedFormat
                guard let detectedLanguage,
                      detectedLanguage != current || format != currentFormat else { return }
                self.tabs[i].contentDetectedLanguage = detectedLanguage
                self.tabs[i].contentDetectedFormat = format
            }
        }
    }

    /// Grammatik-Zuordnung der erkannten Formate. XML nutzt bewusst die
    /// HTML-Grammatik — CodeEditLanguages bündelt keine eigene XML-Grammatik
    /// (gleiche Entscheidung wie beim Endungs-Mapping in `EditorView`).
    static func grammarForDetectedFormat(
        _ format: ContentLanguageDetection.Format
    ) -> CodeLanguage {
        DocumentFormatResolver.format(for: format).grammar
    }

    /// Manuelle Sprachwahl (Footer-Menü). `nil` = zurück auf Automatik —
    /// die Erkennung darf danach wieder laufen.
    func setLanguageOverride(_ language: CodeLanguage?) {
        guard let idx = activeTabIndex else { return }
        // Eine Grammatik-Wahl (oder „Automatisch“) verlässt eine zuvor
        // manuell gewählte Eigen-Sprache. Deren Provider hängt an der
        // Editor-Instanz → Remount über den bestehenden Reload-Mechanismus.
        if tabs[idx].customLanguageOverrideID != nil {
            tabs[idx].customLanguageOverrideID = nil
            editorReloadNonce += 1
        }
        tabs[idx].languageOverride = language
        if language != nil {
            // Manuelle Wahl beendet die Automatik: wartende Analyse abräumen.
            languageDetectionWork[tabs[idx].id]?.cancel()
            languageDetectionWork.removeValue(forKey: tabs[idx].id)
        } else {
            // Zurück auf Automatik → direkt neu analysieren.
            scheduleLanguageDetection(tabID: tabs[idx].id,
                                      oldLength: 0,
                                      newLength: tabs[idx].content.count)
        }
    }

    /// Manuelle Wahl einer EIGEN-Sprache aus der Registry (derzeit 4D):
    /// aktiviert Provider + Theme unabhängig von der Dateiendung. Die
    /// Endungs-Automatik bleibt unangetastet; „Automatisch“ oder eine
    /// Grammatik-Wahl (`setLanguageOverride`) verlassen die Eigen-Sprache
    /// wieder. Der Provider wird beim Editor-Aufbau verdrahtet — deshalb
    /// derselbe Remount-Weg wie beim programmatischen Buffer-Replace.
    func setCustomLanguageOverride(_ language: CustomLanguage) {
        guard let idx = activeTabIndex else { return }
        guard tabs[idx].customLanguageOverrideID != language.id else { return }
        tabs[idx].customLanguageOverrideID = language.id
        tabs[idx].languageOverride = nil
        languageDetectionWork[tabs[idx].id]?.cancel()
        languageDetectionWork.removeValue(forKey: tabs[idx].id)
        editorReloadNonce += 1
    }

    // MARK: - XPath-Navigation (Etappe 5 Wunschpaket 2026-07)

    /// Dateitypen mit XPath-Leiste (XML-artige Quelltexte).
    static let xpathExtensions: Set<String> = [
        "xml", "xsd", "xsl", "xslt", "plist", "svg", "4dcatalog", "4dsettings",
    ]

    /// XPath ist für den aktiven Tab verfügbar, wenn der Dateityp XML-artig
    /// ist UND gerade der Quelltext sichtbar ist (SVG-Vorschau z. B. nicht —
    /// gesprungen wird im Text).
    var activeTabSupportsXPath: Bool {
        guard let tab = activeTab, tab.gitKind == nil, tab.fileDiffRequest == nil,
              !tab.isWelcome else {
            return false
        }
        let name = tab.url?.lastPathComponent ?? tab.title
        guard Self.xpathExtensions.contains(
            (name as NSString).pathExtension.lowercased()
        ) else { return false }
        return activeViewMode == .text
    }

    // MARK: - Ansichts-Umschalter (Etappe 2 Wunschpaket 2026-07)

    /// Verfügbare Ansichten des aktiven Tabs (Umschalter + Menüpunkte).
    /// Git-Ansichten, Datei-Vergleiche und der Willkommen-Tab haben keinen
    /// Umschalter.
    var availableViewModes: [EditorViewMode] {
        guard let tab = activeTab, tab.gitKind == nil, tab.fileDiffRequest == nil,
              !tab.isWelcome else { return [] }
        return ViewModeRouting.availableModes(
            fileExtension: tab.url?.pathExtension,
            loadedDisplayMode: tab.displayMode,
            hasURL: tab.url != nil
        )
    }

    /// Effektive Ansicht des aktiven Tabs (manuelle Wahl vor Standard).
    var activeViewMode: EditorViewMode {
        guard let tab = activeTab else { return .text }
        return ViewModeRouting.effectiveMode(
            chosen: tab.viewMode,
            fileExtension: tab.url?.pathExtension,
            loadedDisplayMode: tab.displayMode,
            hasURL: tab.url != nil
        )
    }

    /// Setzt die Ansicht des aktiven Tabs — nur wenn sie für die Datei
    /// verfügbar ist (Menüpunkte können auf nicht passende Tabs treffen).
    func setViewMode(_ mode: EditorViewMode) {
        guard let idx = activeTabIndex, availableViewModes.contains(mode) else {
            NSSound.beep()
            return
        }
        tabs[idx].viewMode = mode
    }

    /// Vorschlagsordner für den Save-Dialog: der in der Seitenleiste
    /// markierte Ordner gewinnt vor dem Projektordner; ohne beides `nil`
    /// (= Systemverhalten). Pure Funktion → unit-testbar.
    static func suggestedSaveDirectory(selectedFolder: URL?,
                                       projectURL: URL?) -> URL? {
        selectedFolder ?? projectURL
    }

    /// Nur ein noch existierender Ordner taugt als Panel-Vorschlag —
    /// gelöschte oder zu Dateien gewordene Pfade fallen still heraus.
    private func usableDirectory(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    /// Zeigt einen kurzlebigen, nicht-modalen Hinweis in der Seitenleiste.
    /// Ein Token verhindert, dass das verzögerte Ausblenden einen später
    /// gesetzten, neueren Hinweis mit wegräumt.
    func showSidebarNotice(_ message: String) {
        sidebarNotice = message
        let token = UUID()
        sidebarNoticeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.sidebarNoticeToken == token else { return }
            self.sidebarNotice = nil
        }
    }

    /// Entschärfter Ordnerwechsel nach Tab-Schließen (Etappe 1): Gehört kein
    /// verbliebener Datei-Tab mehr zum offenen Projekt und liegen ALLE
    /// verbliebenen Datei-Tabs unter dem Ordner der ersten Datei, ist dieser
    /// Ordner das neue Seitenleisten-Ziel. Konservative Bedingungen:
    /// - Suche/Ersetzungsvorschau offen → nie wechseln (der Suchbereich darf
    ///   sich niemals still ändern, Produktinvariante).
    /// - Git-Ansichten gehören zum Projekt → kein Wechsel.
    /// - Läge auch nur ein Datei-Tab außerhalb des Zielordners, würde der
    ///   Wechsel ihn schließen → kein Wechsel (nichts geht still verloren).
    /// Pure Funktion → unit-testbar.
    static func projectSwitchTarget(tabs: [EditorTab], projectURL: URL?,
                                    searchUIActive: Bool) -> URL? {
        guard let root = projectURL?.canonicalFileURL, !searchUIActive else { return nil }
        guard !tabs.contains(where: { $0.gitKind != nil }) else { return nil }
        let files = tabs.compactMap { $0.url?.canonicalFileURL }
        guard let first = files.first else { return nil }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard !files.contains(where: { $0.path.hasPrefix(rootPrefix) }) else { return nil }
        let target = first.deletingLastPathComponent()
        guard target.path != root.path else { return nil }
        let targetPrefix = target.path.hasSuffix("/") ? target.path : target.path + "/"
        guard files.allSatisfy({ $0.path.hasPrefix(targetPrefix) }) else { return nil }
        return target
    }

    /// Wendet `projectSwitchTarget` nach einem Tab-Schließen an — mit dem
    /// sichtbaren Hinweis, damit der Wechsel nie unbemerkt passiert.
    private func switchProjectAfterTabCloseIfNeeded() {
        guard let target = Self.projectSwitchTarget(
            tabs: tabs, projectURL: projectURL,
            searchUIActive: showSearchDialog || livePreview
        ) else { return }
        openProject(at: target)
        // Nach openProject setzen — der Projektwechsel räumt alte Hinweise ab.
        // codereview-ok: „…“ ist das korrekte deutsche Anführungszeichen-Paar
        showSidebarNotice(L10n.format("Seitenleiste zeigt jetzt „%@“",
                                      target.lastPathComponent))
    }

    /// Lädt einen Ordner als Projekt: Dateibaum-Seitenleiste zeigt ihn,
    /// der Ordner wandert in die Zuletzt-benutzt-Liste, der Willkommens-
    /// bildschirm verschwindet. URL wird kanonisiert — gleiche Begründung
    /// wie in `loadFile` (Dedup über URL-Formen hinweg).
    ///
    /// `keepingUnrelatedTabs`: Beim IMPLIZITEN Öffnen (Einzeldatei ohne
    /// Projekt → Elternordner erscheint in der Seitenleiste, Etappe 1
    /// Wunschpaket 2026-07) dürfen fremde offene Tabs NICHT geschlossen
    /// werden — der Nutzer hat keinen Projektwechsel verlangt. Nur der
    /// ausdrückliche Wechsel (Willkommensseite, ⌘⇧O) räumt wie bisher auf.
    func openProject(at url: URL, keepingUnrelatedTabs: Bool = false) {
        let url = url.canonicalFileURL
        NotificationCenter.default.post(name: .fastraProjectContextWillChange, object: self)
        stopFourDProjectMethodWatcher()
        cancelAllGitDiffLoads()
        let previousActive = activeTabID
        if !keepingUnrelatedTabs {
            tabs = Self.tabsAfterOpeningProject(tabs, root: url)
        }
        if let previousActive, tabs.contains(where: { $0.id == previousActive }) {
            activeTabID = previousActive
        } else {
            activeTabID = tabs.first?.id
        }
        // Markierter Seitenleisten-Ordner, Hinweis und Dateinamens-Filter
        // gehören zum ALTEN Projektbaum → beim Wechsel zurücksetzen.
        selectedFileTreeFolder = nil
        sidebarNotice = nil
        fileTreeFilterQuery = ""
        // Wurden ausschließlich saubere Dateien eines anderen Projekts
        // geschlossen, braucht das neue Projekt wieder einen Editor-Tab.
        if tabs.isEmpty {
            let tab = EditorTab(title: Workspace.untitledBaseName,
                                path: L10n.string("noch nicht gespeichert"))
            tabs = [tab]
            activeTabID = tab.id
        }
        projectGeneration &+= 1
        gitRepositoryObservation?.cancel()
        gitIdentityResolution?.cancel()
        gitOperationStateInspection?.cancel()
        gitIdentityInspection?.cancel()
        gitConflictInspectionLease?.cancel()
        gitConflictInspectionLease = nil
        gitAutoFetchObservation?.cancel()
        gitAutoFetchObservation = nil
        // Bis der erste Snapshot des neuen Roots eintrifft, darf keine Git-UI
        // oder Aktion versehentlich den Zustand des alten Projekts verwenden.
        gitStatus = nil
        gitRepositorySnapshot = nil
        gitBranches = []
        gitLog = []
        gitFeedback = nil
        gitOperationState = nil
        gitIdentity = nil
        gitConflictInspections = [:]
        gitConflictMarkerSizes = [:]
        gitConflictInspectionRequestIDs = [:]
        activeConflictIndex = 0
        showsConflictBase = false
        projectURL = url
        let generation = projectGeneration
        startFourDProjectMethodIndex(for: url, generation: generation)
        startFourDProjectMethodWatcher(for: url, generation: generation)
        gitRepositoryObservation = gitRepositoryStore.observe(repository: url) {
            [weak self] snapshot in
            guard let self, self.projectGeneration == generation,
                  self.projectURL.map(GitOperationRequest.canonicalRepositoryPath)
                    == snapshot.repositoryPath else { return }
            self.applyGitSnapshot(snapshot)
        }
        projectSearchConfiguration = ProjectSearchStore.load(
            for: url, defaults: defaultsStore
        )
        // Willkommen-Tab (falls aktiv) in ein normales leeres Dokument
        // umwandeln → Editor + Projekt-Seitenleiste statt Willkommensseite.
        dismissWelcomeTab()
        noteRecentProject(url)
        let beginGitObservation = { [weak self] in
            guard let self, self.projectGeneration == generation,
                  self.projectURL == url else { return }
            self.gitAutoFetchObservation = self.gitAutoFetchController?.observe(
                repository: url
            ) { completion in
                Self.promptForAutomaticFetch(completion: completion)
            }
            self.gitRepositoryStore.refresh(repository: url, scope: .full)
        }
        if let resolver = gitRepositoryIdentityResolver {
            gitIdentityResolution = resolver.resolve(url) { [weak self] identity in
                guard let self else { return }
                self.gitOperationsCoordinator.register(identity)
                DispatchQueue.main.async(execute: beginGitObservation)
            }
        } else {
            beginGitObservation()
        }
    }

    /// Liest ausschließlich die beiden 4D-Methodenordner außerhalb des
    /// Main-Threads. Die Generation verhindert, dass ein langsamer alter
    /// Scan den Highlight-Index eines inzwischen geöffneten Projekts ersetzt.
    private func startFourDProjectMethodIndex(for root: URL, generation: UInt64) {
        fourDProjectMethodIndexTask?.cancel()
        fourDProjectMethodNames = []
        fourDProjectMethodIndexTask = Task { @MainActor [weak self] in
            let names = await Task.detached(priority: .utility) {
                FourDProjectMethodIndex.methodNames(in: root)
            }.value
            guard !Task.isCancelled,
                  let self,
                  FourDProjectMethodIndex.shouldApply(
                    resultFor: root,
                    generation: generation,
                    currentRoot: self.projectURL,
                    currentGeneration: self.projectGeneration
                  ) else { return }

            // Der Scan oben darf nebenläufig arbeiten. Die veröffentlichte
            // Menge muss dagegen auf dem Main-Actor wechseln: Combine und
            // SwiftUI können sonst beim gleichzeitigen Editor-Update
            // gegenseitig auf ihre internen Locks warten.
            self.fourDProjectMethodNames = names
        }
    }

    /// Hält die Aktualisierung des 4D-Methodenindex am Projekt selbst. Der
    /// Dateibaum besitzt zwar einen eigenen Watcher für sein Rendering, kann
    /// aber unsichtbar sein; dieser zweite Besitzer bleibt deshalb für die
    /// gesamte Dauer eines geöffneten Projekts aktiv.
    private func startFourDProjectMethodWatcher(for root: URL, generation: UInt64) {
        let watcher = ProjectFileWatcher(rootURL: root)
        watcher.onRefresh = { [weak self, weak watcher] in
            guard let self,
                  self.fourDProjectMethodWatcher === watcher,
                  self.projectGeneration == generation else { return }
            self.projectFilesDidChange(for: root)
        }
        fourDProjectMethodWatcher = watcher
    }

    /// Stoppt den Stream ausdrücklich vor Wechsel oder Schließen. Das macht
    /// alte FSEvents wirkungslos und gibt den nativen Beobachter sofort frei.
    private func stopFourDProjectMethodWatcher() {
        fourDProjectMethodWatcher?.stop()
        fourDProjectMethodWatcher = nil
    }

    /// Der Workspace-eigene Projekt-Watcher meldet externe Änderungen hierher.
    /// Nur das aktuelle Projekt darf einen neuen Index auslösen; ein alter
    /// Callback kann dadurch keinen neuen Projektstand überschreiben.
    func projectFilesDidChange(for observedRoot: URL) {
        guard let currentRoot = projectURL,
              currentRoot.canonicalFileURL == observedRoot.canonicalFileURL else {
            return
        }
        let generation = projectGeneration
        fourDProjectMethodIndexRefreshTask?.cancel()
        fourDProjectMethodIndexRefreshTask = Task { @MainActor [weak self] in
            // Atomare Speicheroperationen liefern oft mehrere FSEvents.
            // Eine kleine Pause verhindert unnötige komplette Scans, ohne
            // die UI oder den Main-Actor zu blockieren.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  let self,
                  self.projectGeneration == generation,
                  self.projectURL?.canonicalFileURL == observedRoot.canonicalFileURL else {
                return
            }
            self.startFourDProjectMethodIndex(for: observedRoot, generation: generation)
        }
    }

    /// Beim Projektwechsel bleiben ungesicherte Inhalte immer erhalten.
    /// Saubere Dateien außerhalb des neuen Projektbaums und alte Git-Ansichten
    /// werden geschlossen; saubere unbenannte Notizzettel bleiben bestehen.
    static func tabsAfterOpeningProject(_ tabs: [EditorTab], root: URL) -> [EditorTab] {
        let root = root.canonicalFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return tabs.filter { tab in
            if tab.isDirty || tab.isWelcome { return true }
            if tab.gitKind != nil { return false }
            guard let file = tab.url?.canonicalFileURL else { return true }
            return file.path.hasPrefix(prefix)
        }
    }

    /// Blendet den Projekt-Dateibaum wieder aus (Seitenleiste zeigt dann
    /// wie bisher nur die geöffneten Tabs). Offene Tabs bleiben unberührt.
    func closeProject() {
        NotificationCenter.default.post(name: .fastraProjectContextWillChange, object: self)
        stopFourDProjectMethodWatcher()
        selectedFileTreeFolder = nil
        sidebarNotice = nil
        projectGeneration &+= 1
        fourDProjectMethodIndexTask?.cancel()
        fourDProjectMethodIndexTask = nil
        fourDProjectMethodIndexRefreshTask?.cancel()
        fourDProjectMethodIndexRefreshTask = nil
        fourDProjectMethodNames = []
        cancelAllGitDiffLoads()
        gitIdentityResolution?.cancel()
        gitIdentityResolution = nil
        gitOperationStateInspection?.cancel()
        gitOperationStateInspection = nil
        gitIdentityInspection?.cancel()
        gitIdentityInspection = nil
        gitConflictInspectionLease?.cancel()
        gitConflictInspectionLease = nil
        gitAutoFetchObservation?.cancel()
        gitAutoFetchObservation = nil
        gitRepositoryObservation?.cancel()
        gitRepositoryObservation = nil
        projectURL = nil
        gitStatus = nil
        gitRepositorySnapshot = nil
        gitLog = []
        gitBranches = []
        gitFeedback = nil
        gitOperationState = nil
        gitIdentity = nil
        gitConflictInspections = [:]
        gitConflictMarkerSizes = [:]
        gitConflictInspectionRequestIDs = [:]
        activeConflictIndex = 0
        showsConflictBase = false
    }

    /// Zieht offene Tabs nach einer Datei- oder Ordner-Umbenennung mit. Ohne
    /// diese Kopplung würde ein späteres ⌘S am alten Pfad eine zweite Datei
    /// erzeugen. Bei Ordnern werden alle darin geöffneten Dateien angepasst.
    func handleFileTreeMove(from source: URL, to destination: URL) {
        for index in tabs.indices {
            guard let oldURL = tabs[index].url,
                  let newURL = Self.movedURL(oldURL, from: source, to: destination)
            else { continue }
            tabs[index].url = newURL.canonicalFileURL
            tabs[index].title = newURL.lastPathComponent
            tabs[index].path = newURL.deletingLastPathComponent().path
            tabs[index].diskModificationDate = ExternalChange.diskModificationDate(of: newURL)
        }
    }

    /// Offene Inhalte bleiben nach dem Verschieben in den Papierkorb als
    /// unbenannte, geänderte Tabs erhalten. Das schützt auch noch nicht
    /// gespeicherte Änderungen und verhindert ein Wiederanlegen am alten Pfad.
    func handleFileTreeTrash(_ source: URL) {
        let sourcePath = source.standardizedFileURL.path
        let prefix = sourcePath + "/"
        for index in tabs.indices {
            guard let url = tabs[index].url else { continue }
            let path = url.standardizedFileURL.path
            guard path == sourcePath || path.hasPrefix(prefix) else { continue }
            tabs[index].url = nil
            tabs[index].path = "Aus Papierkorb gerettet"
            tabs[index].diskModificationDate = nil
            tabs[index].isDirty = true
        }
    }

    static func movedURL(_ candidate: URL, from source: URL,
                         to destination: URL) -> URL? {
        let candidatePath = candidate.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        if candidatePath == sourcePath { return destination }
        let prefix = sourcePath + "/"
        guard candidatePath.hasPrefix(prefix) else { return nil }
        let suffix = String(candidatePath.dropFirst(prefix.count))
        return destination.appendingPathComponent(suffix)
    }

    // MARK: - Git-Status (Projekt- & Git-Ausbau, Etappe 2)

    /// Aktualisiert nur den Status; Branches und Graph bleiben aus dem letzten
    /// vollständigen, gemeinsam revidierten Snapshot erhalten.
    func refreshGitStatus() {
        guard let root = projectURL, GitRunner.isAvailable else {
            gitStatus = nil
            gitRepositorySnapshot = nil
            gitBranches = []
            gitLog = []
            return
        }
        invalidateAndRefreshActiveConflictInspection()
        gitRepositoryStore.refresh(repository: root, scope: .status)
        // Auch wenn eine bereits als „M“ markierte Datei erneut gespeichert
        // wurde, hat sich ihr Patch geändert, obwohl die Status-Flags gleich
        // bleiben. Deshalb nicht allein auf Status-Equality vertrauen.
        refreshOpenGitDiffTabs()
    }

    /// Lädt die Commit-Historie für den Graph-Tab asynchron (`git log --all`).
    /// Kein Projekt/kein git → leere Liste. Wird beim Projekt-Öffnen und beim
    /// Anzeigen des Graph-Tabs sowie nach einem Commit angestoßen.
    func refreshGitLog() {
        refreshGitRepositoryFully()
    }

    /// Lädt die lokalen Branches asynchron. Remote-Branches bleiben bewusst
    /// außen vor: Ein Klick soll keinen impliziten Tracking-Branch erzeugen.
    func refreshGitBranches() {
        refreshGitRepositoryFully()
    }

    func refreshGitRepositoryFully() {
        guard let root = projectURL, GitRunner.isAvailable else { return }
        gitRepositoryStore.refresh(repository: root, scope: .full)
    }

    private func applyGitSnapshot(_ snapshot: GitRepositorySnapshot) {
        let graphChanged = gitRepositorySnapshot?.graph != snapshot.graph
        let statusChanged = gitStatus != snapshot.status
        gitRepositorySnapshot = snapshot
        gitStatus = snapshot.status
        gitBranches = snapshot.branches
        gitLog = snapshot.graph
        gitOperationState = snapshot.operation
        // Fetch ändert keine Arbeitsdateien, kann aber Remote-Tracking-Commits
        // im bereits offenen Verlauf sichtbar machen.
        if graphChanged {
            refreshOpenGitLogView()
        }
        if graphChanged { refreshOpenGitDiffTabs() }
        if statusChanged { invalidateAndRefreshActiveConflictInspection() }
    }

    var gitOperationsAreBusy: Bool {
        guard let root = projectURL else { return false }
        return gitRepositorySnapshot?.operations.isBusy == true
            || gitOperationsCoordinator.state(for: root).isBusy
    }

    var gitPullStrategyName: String {
        switch gitPreferencesStore.load().pullStrategy {
        case .rebase: return L10n.string("Rebase")
        case .merge: return L10n.string("Merge")
        case .ffOnly: return L10n.string("Nur Fast-Forward")
        case .unselected: return L10n.string("gewählter Strategie")
        }
    }

    /// Git-Zustand einer Datei anhand ihrer URL — für die Einfärbung in der
    /// Seitenleiste und der Tab-Liste. `nil` = kein Projekt, keine Änderung,
    /// oder Datei außerhalb des Projekts.
    func gitState(for url: URL?) -> GitFileState? {
        guard let url, let root = projectURL, let status = gitStatus else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return nil }
        let relative = String(url.path.dropFirst(rootPath.count))
        return status.entries[relative]
    }

    /// Ob ein Ordner (per URL) geänderte Dateien enthält — für den Rollup-Punkt
    /// an Ordner-Zeilen im Dateibaum (VS-Code-Verhalten). Prüft, ob irgendein
    /// geänderter Pfad unterhalb des Ordners liegt.
    func gitFolderHasChanges(_ url: URL) -> Bool {
        guard let root = projectURL, let status = gitStatus, !status.entries.isEmpty else {
            return false
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return false }
        let folderRelative = String(url.path.dropFirst(rootPath.count)) + "/"
        return status.entries.keys.contains { $0.hasPrefix(folderRelative) }
    }

    // MARK: - Git-Text-Tabs: History & Diff (Etappe 2, Schritt 2+3)

    /// Öffnet den Verlaufs-Graphen (`git log --graph`) als read-only-Tab.
    func openGitLog() {
        loadGitTab(kind: .log, title: L10n.string("Git-Verlauf"), args: GitLog.arguments,
                   emptyText: L10n.string("Noch keine Commits."))
    }

    /// Öffnet den Arbeitsverzeichnis-Diff (`git diff HEAD`) als read-only-Tab.
    func openGitDiff() {
        guard let context = currentGitActionContext else { return }
        let request = GitDiffRequest(
            repositoryPath: GitOperationRequest.canonicalRepositoryPath(context.root),
            source: .workingTree(path: nil)
        )
        loadGitDiffTab(request: request, title: L10n.string("Git-Diff"),
                       emptyText: L10n.string("Keine Änderungen gegenüber HEAD."))
    }

    /// Öffnet aus der Git-Änderungen-Ansicht genau den Diff der gewählten
    /// Datei. Index und Working-Tree bleiben getrennt; dadurch zeigt eine Datei,
    /// die in beiden Abschnitten vorkommt, jeweils den dort gemeinten Stand.
    func openGitChangeDiff(change: GitChange, staged: Bool) {
        guard let actionPath = change.actionPath else { return }
        let state = staged ? change.staged : change.unstaged
        let source: GitDiffRequest.Source
        if state == .untracked {
            source = .untracked(path: actionPath)
        } else if staged {
            source = .staged(path: actionPath)
        } else {
            source = .unstaged(path: actionPath)
        }
        guard let context = currentGitActionContext else { return }
        let request = GitDiffRequest(
            repositoryPath: GitOperationRequest.canonicalRepositoryPath(context.root),
            source: source
        )
        loadGitDiffTab(request: request, title: L10n.format("Git-Diff: %@", change.path),
                       emptyText: L10n.string("Kein Inhalt."))
    }

    /// Öffnet einen einzelnen Commit (`git show <hash>`) als read-only-Tab —
    /// aus dem Verlauf per Klick oder aus dem Graph per Doppelklick aufgerufen.
    func openGitCommit(hash: String) {
        loadGitTab(kind: .commit, title: L10n.format("Commit %@", hash),
                   args: GitDiff.showArguments(hash: hash),
                   emptyText: L10n.string("Kein Inhalt."))
    }

    /// Öffnet aus einem aufgeklappten Graph-Commit genau den Patch der
    /// angeklickten Datei im Hauptbereich. Der vollständige Repo-Pfad im
    /// Titel verhindert Kollisionen bei gleichnamigen Dateien in Unterordnern.
    func openGitCommitFile(hash: String, file: GitCommitFile) {
        guard let path = file.actionPath else { return }
        guard let context = currentGitActionContext else { return }
        let title = L10n.format("%@ in %@", file.path, String(hash.prefix(7)))
        guard let graphCommit = gitLog.first(where: { $0.hash == hash }) else {
            // Wenn der Graph zwischen Klick und Ausführung aktualisiert wurde,
            // ist die Elternsemantik nicht mehr sicher verfügbar. Der bewährte
            // Unified-`git show`-Fallback ist dann ehrlicher als ein erfundener
            // Root-Vergleich.
            loadGitTab(kind: .commit, title: title,
                       args: GitDiff.showFileArguments(hash: hash, path: path),
                       emptyText: L10n.string("Kein Inhalt."))
            return
        }
        let parents = graphCommit.parents
        let parent: GitDiffParent = parents.first.map {
            .commit(hash: $0, number: 1, total: parents.count)
        } ?? .emptyTree
        let request = GitDiffRequest(
            repositoryPath: GitOperationRequest.canonicalRepositoryPath(context.root),
            source: .commit(hash: hash, parent: parent, path: path)
        )
        loadGitDiffTab(request: request, title: title,
                       emptyText: L10n.string("Kein Inhalt."))
    }

    /// Lädt den strukturierten Diff mit harter Ausgabegrenze. Der Tab wird vor
    /// dem Prozess angelegt, damit ein erneuter Klick dieselbe stabile Request-
    /// Identität aktualisiert. Completion und Projektgeneration schützen gegen
    /// verspätete Antworten nach einem Projektwechsel.
    private func loadGitDiffTab(request: GitDiffRequest, title: String,
                                emptyText: String,
                                activate: Bool = true,
                                existingTabID: UUID? = nil) {
        guard let context = currentGitActionContext, GitRunner.isAvailable,
              request.repositoryPath
                == GitOperationRequest.canonicalRepositoryPath(context.root) else { return }
        guard let load = prepareGitDiffTab(request: request, title: title,
                                           activate: activate,
                                           existingTabID: existingTabID) else { return }
        let operation = GitOperationRequest(repository: context.root, kind: .diffRead,
                                            arguments: request.arguments,
                                            outputLimit: GitDiffRequest.outputLimit)
        let lease = gitOperationsCoordinator.perform(operation) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                guard let index = self.tabs.firstIndex(where: { $0.id == load.tabID }),
                      self.tabs[index].gitDiffRequest == request,
                      self.tabs[index].gitDiffLoadGeneration == load.generation else { return }
                defer { self.clearGitDiffLoad(tabID: load.tabID,
                                              generation: load.generation) }
                guard case .completed(let result) = outcome else {
                    let message = Self.gitExecutionFailureText(outcome)
                        ?? L10n.string("git-Aufruf fehlgeschlagen.")
                    self.updateGitDiffTab(index: index, title: title, content: message,
                                          document: GitDiffDocument(
                                            files: [], limitation: .malformed(message)))
                    return
                }
                guard request.acceptedExitCodes.contains(result.exitCode) else {
                    let error = result.stderrForDisplay
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = error.isEmpty ? L10n.string("git-Aufruf fehlgeschlagen.") : error
                    self.updateGitDiffTab(index: index, title: title, content: message,
                                          document: GitDiffDocument(
                                            files: [], limitation: .malformed(message)))
                    return
                }
                let document = GitDiffParser.parse(
                    result.stdoutData, wasTruncated: result.stdoutWasTruncated
                )
                let content = result.stdoutData.isEmpty ? emptyText : result.stdoutForDisplay
                self.updateGitDiffTab(index: index, title: title, content: content,
                                      document: document)
            }
        }
        gitDiffLoadLeases[load.tabID] = GitDiffLoadLease(generation: load.generation,
                                                         lease: lease)
    }

    /// Kern für alle Git-Text-Tabs: git asynchron ausführen und das Ergebnis in
    /// einen read-only-Tab schreiben. Dedup: pro `(kind, title)` genau ein Tab —
    /// erneuter Aufruf frischt den bestehenden Tab auf, statt zu duplizieren.
    /// `internal` (nicht private), damit die Git-Aktionen in `GitActions.swift`
    /// den Pickaxe-Verlauf öffnen können.
    func loadGitTab(kind: GitTabKind, title: String, args: [String], emptyText: String,
                    acceptedExitCodes: Set<Int32> = [0]) {
        guard let context = currentGitActionContext, GitRunner.isAvailable else { return }
        let request = GitOperationRequest(repository: context.root, kind: .refresh,
                                          arguments: args)
        gitOperationsCoordinator.perform(request) { [weak self] outcome in
            guard let self else { return }
            guard context.isCurrent(in: self) else { return }
            guard case .completed(let result) = outcome else {
                let text = Self.gitExecutionFailureText(outcome)
                    ?? L10n.string("git-Aufruf fehlgeschlagen.")
                self.setGitTab(kind: kind, title: title, content: text)
                return
            }
            guard acceptedExitCodes.contains(result.exitCode) else {
                // Fehler ehrlich zeigen (UX-Regel: echte git-Ausgabe), statt zu
                // schlucken. stderr in den Tab, damit der Nutzer den Grund sieht.
                let msg = result.stderrForDisplay
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.setGitTab(kind: kind, title: title,
                               content: msg.isEmpty
                                   ? L10n.string("git-Aufruf fehlgeschlagen.") : msg)
                return
            }
            let output = result.stdoutForDisplay
            let text = output.isEmpty ? emptyText : output
            self.setGitTab(kind: kind, title: title, content: text)
        }
    }

    /// Legt einen Git-Tab an oder aktualisiert den vorhandenen gleicher Art +
    /// gleichen Titels, und aktiviert ihn.
    private func setGitTab(kind: GitTabKind, title: String, content: String) {
        if let idx = tabs.firstIndex(where: { $0.gitKind == kind && $0.title == title }) {
            tabs[idx].content = content
            activeTabID = tabs[idx].id
        } else {
            let tab = EditorTab(title: title, path: "Git", content: content, gitKind: kind)
            tabs.append(tab)
            activeTabID = tab.id
        }
        // Der Git-Tab ist aktiv und nicht `isWelcome` → zeigt den Editor.
        // (Git-Aktionen setzen ohnehin ein geladenes Projekt voraus, dessen
        // Öffnen den Willkommen-Tab bereits umgewandelt hat.)
    }

    private func prepareGitDiffTab(request: GitDiffRequest, title: String,
                                   activate: Bool, existingTabID: UUID?)
        -> (tabID: UUID, generation: UInt64)? {
        let index: Int
        if let existingTabID {
            guard let found = tabs.firstIndex(where: {
                $0.id == existingTabID && $0.gitDiffRequest == request
            }) else { return nil }
            index = found
        } else if let found = tabs.firstIndex(where: { $0.gitDiffRequest == request }) {
            index = found
        } else {
            let tab = EditorTab(title: title, path: "Git", gitKind: .diff,
                                gitDiffRequest: request, gitDiffDocument: nil)
            tabs.append(tab)
            index = tabs.count - 1
        }
        tabs[index].gitDiffLoadGeneration &+= 1
        tabs[index].title = title
        if existingTabID == nil { tabs[index].gitDiffDocument = nil }
        let tabID = tabs[index].id
        let generation = tabs[index].gitDiffLoadGeneration
        cancelGitDiffLoad(tabID: tabID)
        if activate { activeTabID = tabID }
        return (tabID, generation)
    }

    private func updateGitDiffTab(index: Int, title: String, content: String,
                                  document: GitDiffDocument) {
        tabs[index].title = title
        tabs[index].content = content
        tabs[index].gitDiffDocument = document
    }

    private func clearGitDiffLoad(tabID: UUID, generation: UInt64) {
        guard gitDiffLoadLeases[tabID]?.generation == generation else { return }
        gitDiffLoadLeases.removeValue(forKey: tabID)
    }

    // MARK: - Datei-Vergleich (Etappe 1 Wunschpaket 2026-07c)

    /// Öffnet einen Datei-Vergleichs-Tab und startet die Berechnung im
    /// Hintergrund. Ein inhaltlich gleicher Vergleich (Seiten + Optionen)
    /// verwendet seinen bestehenden Tab wieder und rechnet frisch — der
    /// Plattenstand kann sich geändert haben, und Tabs sollen nicht stapeln.
    func openFileDiffTab(request: FileDiffRequest) {
        let title = L10n.format("Diff: %@ ↔ %@", request.left.name, request.right.name)
        let tabID: UUID
        if let idx = tabs.firstIndex(where: {
            $0.fileDiffRequest?.matches(request) == true
        }) {
            tabs[idx].fileDiffRequest = request
            tabs[idx].fileDiffDocument = nil
            tabs[idx].fileDiffLoadGeneration &+= 1
            tabID = tabs[idx].id
        } else {
            let tab = EditorTab(title: title, path: L10n.string("Vergleich"),
                                fileDiffRequest: request)
            tabs.append(tab)
            tabID = tab.id
        }
        activeTabID = tabID
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let generation = tabs[idx].fileDiffLoadGeneration

        // Laden + Diffen im Hintergrund — blockiert nie den Main-Thread.
        // [weak self]: Fenster darf während der Rechnung schließen.
        Task.detached(priority: .userInitiated) { [weak self] in
            let document = Workspace.computeFileDiffDocument(request: request)
            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tabs.firstIndex(where: { $0.id == tabID }),
                      self.tabs[idx].fileDiffLoadGeneration == generation,
                      self.tabs[idx].fileDiffRequest?.id == request.id else {
                    // Tab geschlossen oder inzwischen neu berechnet — dieses
                    // Ergebnis verwerfen (kein Fehler).
                    return
                }
                self.tabs[idx].fileDiffDocument = document
            }
        }
    }

    /// Lädt beide Seiten und berechnet den Diff. Läuft auf einem
    /// Hintergrund-Task; nutzt dieselben Grenzen wie das normale Datei-
    /// Öffnen (Binär-Erkennung, 32-MiB-Schwelle) und meldet sie verständlich
    /// statt still zu verfälschen.
    nonisolated static func computeFileDiffDocument(request: FileDiffRequest)
        -> FileDiffDocument {
        func loadSide(_ side: FileDiffSide, role: FileDiffSideRole)
            -> Swift.Result<String, FileDiffLimitation> {
            // Ungespeicherter Editor-Inhalt liegt schon vor — nichts laden.
            if let text = side.text { return .success(text) }
            guard let url = side.url else { return .failure(.unreadable(side: role)) }
            do {
                let loaded = try FileLoader.load(url: url)
                switch loaded.displayMode {
                case .hex:
                    return .failure(.binary(side: role))
                case .chunkedText:
                    // Über der Volllade-Schwelle liefert der Loader keinen
                    // Inhalt — ein Diff wäre eine stille Verfälschung.
                    return .failure(.tooLarge(side: role))
                case .text:
                    return .success(loaded.content)
                }
            } catch {
                return .failure(.unreadable(side: role))
            }
        }
        switch (loadSide(request.left, role: .left), loadSide(request.right, role: .right)) {
        case (.failure(let limitation), _):
            return .failure(limitation)
        case (_, .failure(let limitation)):
            return .failure(limitation)
        case (.success(let left), .success(let right)):
            switch FileDiff.compare(left: left, right: right,
                                    options: request.options) {
            case .result(let result): return .success(result)
            case .limitation(let limitation): return .failure(limitation)
            }
        }
    }

    /// „Mit gespeicherter Fassung vergleichen" (BBEdit „Compare Against Disk
    /// File") ist nur sinnvoll, wenn der aktive Tab eine Datei MIT
    /// ungespeicherten Änderungen zeigt.
    var canCompareActiveTabAgainstDisk: Bool {
        guard let tab = activeTab, tab.gitKind == nil, tab.fileDiffRequest == nil,
              !tab.isWelcome, tab.isDirty, tab.url != nil,
              tab.displayMode == .text else { return false }
        return true
    }

    /// Vergleicht den ungespeicherten Editor-Inhalt des aktiven Tabs mit dem
    /// Stand derselben Datei auf der Platte — ohne Dialog, direkt ins
    /// Differenzfenster. Links die gespeicherte Fassung (Vorher), rechts der
    /// Editor-Inhalt (Nachher) — gleiche Leserichtung wie die Ersetzungs-
    /// Vorschau und der Git-Diff.
    func compareActiveTabAgainstDisk() {
        guard canCompareActiveTabAgainstDisk,
              let tab = activeTab, let url = tab.url else {
            NSSound.beep()
            return
        }
        let request = FileDiffRequest(
            left: FileDiffSide(name: L10n.format("%@ (gespeichert)", tab.title),
                               path: url.path, url: url, text: nil),
            right: FileDiffSide(name: L10n.format("%@ (ungespeichert)", tab.title),
                                path: url.path, url: nil, text: tab.content),
            options: FileDiffOptions()
        )
        openFileDiffTab(request: request)
    }

    private func cancelGitDiffLoad(tabID: UUID) {
        gitDiffLoadLeases.removeValue(forKey: tabID)?.lease.cancel()
    }

    private func cancelAllGitDiffLoads() {
        let leases = gitDiffLoadLeases.values.map(\.lease)
        gitDiffLoadLeases.removeAll()
        leases.forEach { $0.cancel() }
    }

    /// Aktualisiert alle offenen Arbeitsbaum-/Index-Diffs dieses Projekts, ohne
    /// dem Nutzer dabei den aktiven Tab wegzunehmen. Historische Commit-Diffs
    /// sind unveränderlich und brauchen keinen Netzwerk-/Mutationsrefresh.
    func refreshOpenGitDiffTabs() {
        guard let root = projectURL else { return }
        let repositoryPath = GitOperationRequest.canonicalRepositoryPath(root)
        let open = tabs.compactMap { tab -> (UUID, GitDiffRequest, String)? in
            guard let request = tab.gitDiffRequest,
                  request.repositoryPath == repositoryPath else { return nil }
            if case .commit = request.source { return nil }
            return (tab.id, request, tab.title)
        }
        for (tabID, request, title) in open {
            loadGitDiffTab(request: request, title: title,
                           emptyText: L10n.string("Keine Änderungen."), activate: false,
                           existingTabID: tabID)
        }
    }

    /// „Ordner öffnen…" (⇧⌘O): Ordner wählen und als Projekt laden.
    /// Auch Ordner ohne `.git` sind erlaubt — die explizite Nutzerwahl
    /// zählt mehr als die Repo-Heuristik.
    func openFolderAsProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Ordner als Projekt öffnen")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
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

    /// Such-Scope. „Projekt" verwendet das pro Projekt gespeicherte aktive
    /// Datei-Set samt eigenem Dateitypfilter und Ausschlussmustern.
    enum SearchScope: String, CaseIterable, Identifiable {
        case file    = "Datei"
        case open    = "Geöffnet"
        case folder  = "Ordner"
        case project = "Projekt"
        var id: String { rawValue }
        var isFolderLike: Bool { self == .folder || self == .project }
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

    /// Projekt-spezifische Datei-Sets, Filter und Ausschlüsse. Beim
    /// Projektwechsel wird die passende persistente Konfiguration geladen.
    @Published var projectSearchConfiguration = ProjectSearchConfiguration.fresh()

    var projectSearchURLs: [URL] {
        guard let root = projectURL,
              let set = projectSearchConfiguration.activeSet else { return [] }
        let rootPath = root.standardizedFileURL.path
        return set.paths.compactMap { relative in
            let candidate = relative == "."
                ? root.standardizedFileURL
                : root.appendingPathComponent(relative).standardizedFileURL
            let path = candidate.path
            guard path == rootPath || path.hasPrefix(rootPath + "/"),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return candidate
        }
    }

    var activeMultiFileSearchURLs: [URL] {
        scope == .project ? projectSearchURLs : enabledSearchFolderURLs
    }

    var activeMultiFileFilter: FileTypeFilter {
        scope == .project ? projectSearchConfiguration.fileTypeFilter : fileTypeFilter
    }

    /// Öffnet einen NSOpenPanel zur Ordner-Auswahl und hängt das Ergebnis
    /// oben an die Recent-Folders-Liste (aktiviert). Persistenz läuft
    /// automatisch über den Combine-Sink in `init`.
    func addSearchFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L10n.string("Ordner zum Durchsuchen auswählen")
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
        if scope.isFolderLike {
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

    /// Nur für isolierte Tests/gezielte Laufzeitkonfiguration. `nil` nutzt den
    /// normalen Application-Support-Ordner; Tests schreiben nie dorthin.
    var folderApplyBackupRoot: URL? = nil

    /// Testbarer, aber produktiv sichtbarer Hinweis für Dirty-/Lade-Konflikte.
    /// Der Apply selbst bleibt immer blockiert; es gibt hier bewusst keinen
    /// stillen „Platte gewinnt“-Pfad.
    var folderApplyConflictHandler: ([String]) -> Void = Workspace.defaultFolderApplyConflict
    var folderPreviewConflictHandler: (String) -> Void = Workspace.defaultFolderPreviewConflict

    static func defaultFolderApplyConflict(_ titles: [String]) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { defaultFolderApplyConflict(titles) }
            return
        }
        let names = titles.sorted().joined(separator: "\n• ")
        NSAlert.runWarning(
            title: L10n.string("Ordner-Apply abgebrochen"),
            text: L10n.format("Diese betroffenen Tabs enthalten ungespeicherte Änderungen oder werden noch geladen:\n\n• %@\n\nSpeichere oder schließe sie und prüfe danach die Vorschau erneut.", names))
    }

    static func defaultFolderPreviewConflict(_ message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { defaultFolderPreviewConflict(message) }
            return
        }
        NSAlert.runWarning(title: L10n.string("Apply-Konflikt"), text: message)
    }

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
        guard scope.isFolderLike,
              searchError == nil,
              !folderResults.isEmpty,
              !folderApplying else { return false }
        let visibleResults = folderResults.filter { !$0.matches.isEmpty }
        guard !visibleResults.isEmpty else { return false }
        guard !folderResultsWereCapped,
              visibleResults.allSatisfy({ $0.totalMatches == $0.matches.count }) else {
            folderPreviewConflictHandler(L10n.string(
                "Die sichtbare Vorschau ist gekürzt. Verfeinere die Suche, bis alle Treffer sichtbar sind, bevor du Änderungen anwendest."))
            return false
        }
        let urls = visibleResults.map(\.url)
        let targetPaths = Set(urls.map { $0.canonicalFileURL.path })
        let blockedTabs = tabs.filter { tab in
            guard let url = tab.url else { return false }
            return targetPaths.contains(url.canonicalFileURL.path)
                && (tab.isDirty || tab.isLoading)
        }
        guard blockedTabs.isEmpty else {
            folderApplyConflictHandler(blockedTabs.map(\.title))
            return false
        }
        recordSearchHistory()

        // Nur billige, bereits mit der Vorschau gelieferte Metadaten werden
        // hier auf dem Main-Thread geprüft. Vollständiges Lesen, Planung,
        // Backup und Replace übernimmt danach ApplyTransaction im Worker.
        let options = currentSearchOptions
        guard visibleResults.allSatisfy({
            $0.searchOptions == options && $0.snapshot != nil
        }) else {
            folderPreviewConflictHandler(L10n.string(
                "Dateien oder Suchoptionen haben sich seit der sichtbaren Vorschau geändert. Starte die Suche erneut; es wurde nichts verändert."))
            return false
        }
        let inputs = visibleResults.map { result in
            ApplyTransaction.Input(
                url: result.url,
                snapshot: result.snapshot!,
                matches: result.matches.map {
                    PlannedMatch(range: $0.range, before: $0.matchText,
                                 after: $0.replacedText)
                })
        }

        // Die Warnung kommt VOR jedem Voll-Read. `byteCount` stammt aus dem
        // stabilen Vorschau-Snapshot und ist damit zugleich billig und exakt.
        let totalBytes = inputs.reduce(0) { $0 + $1.snapshot.byteCount }
        if totalBytes > Workspace.folderApplyWarnBytes {
            let alert = NSAlert()
            alert.messageText = L10n.string("Große Replace-Operation")
            alert.informativeText = L10n.format(
                "Insgesamt %@ in %ld Dateien. Trotzdem ausführen?",
                ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file),
                inputs.count
            )
            alert.addButton(withTitle: L10n.string("Ausführen"))
            alert.addButton(withTitle: L10n.string("Abbrechen"))
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        let transaction = ApplyTransaction(inputs: inputs, options: options)
        let backupRoot = folderApplyBackupRoot
        folderApplyGeneration &+= 1
        let generation = folderApplyGeneration
        let progressRelay = FolderApplyProgressRelay(workspace: self,
                                                     generation: generation)
        folderApplying = true
        folderApplyProgressText = L10n.string("Ordner-Apply wird vorbereitet…")
        folderApplyTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<ApplySession, Error>
            do {
                let session = try transaction.execute(
                    backupRoot: backupRoot,
                    shouldCancel: { Task.isCancelled },
                    progress: progressRelay.report)
                result = .success(session)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finishFolderApply(result, generation: generation)
            }
        }
        return true
    }

    /// Abbruch ist bis zum globalen Preflight garantiert write-frei. Hat die
    /// kurze Apply-Phase bereits begonnen, führt die Transaktion Journal und
    /// atomare Einzel-Replaces kontrolliert zu Ende.
    func cancelFolderApply() {
        guard folderApplying else { return }
        folderApplyTask?.cancel()
        folderApplyProgressText = L10n.string("Ordner-Apply wird abgebrochen…")
    }

    private func finishFolderApply(_ result: Result<ApplySession, Error>,
                                   generation: Int) {
        guard folderApplyGeneration == generation else { return }
        folderApplyTask = nil
        folderApplying = false
        folderApplyProgressText = nil
        switch result {
        case .success(let session):
            lastApplySession = session
            reloadOpenTabs(for: session.entries.map {
                URL(fileURLWithPath: $0.originalPath)
            })
        case .failure(ApplyError.cancelled):
            break
        case .failure(ApplyError.planNotApplyable(let message)),
             .failure(ApplyError.conflict(let message)):
            folderPreviewConflictHandler(message)
        case .failure(ApplyError.backupFailed(let message)):
            NSAlert.runWarning(
                title: L10n.string("Backup fehlgeschlagen"),
                text: L10n.format("Es wurde nichts verändert.\n\n%@", message))
        case .failure(ApplyError.writeFailed(let session, let message)):
            lastApplySession = session
            NSAlert.runWarning(
                title: L10n.string("Apply teilweise fehlgeschlagen"),
                text: L10n.format("%@\n\nBereits geschriebene Dateien können über die Rückgängig-Aktion zurückgespielt werden.", message))
            reloadOpenTabs(for: session.entries.map {
                URL(fileURLWithPath: $0.originalPath)
            })
        case .failure(let error):
            NSAlert(error: error).runModal()
        }
    }

    /// Macht die letzte Folder-Apply-Session bit-exakt rückgängig.
    @discardableResult
    func undoLastFolderApply() -> Bool {
        guard !folderApplying, let session = lastApplySession else { return false }
        do {
            try ApplyEngine.undo(session)
            reloadOpenTabs(for: session.entries.map { URL(fileURLWithPath: $0.originalPath) })
            lastApplySession = nil
            return true
        } catch ApplyError.undoConflict(let message) {
            NSAlert.runWarning(title: L10n.string("Rückgängig-Konflikt"), text: message)
            return false
        } catch ApplyError.legacySession(let message) {
            NSAlert.runWarning(title: L10n.string("Rückgängig abgelehnt"), text: message)
            return false
        } catch ApplyError.undoFailed(let partial, let message) {
            lastApplySession = partial
            NSAlert.runWarning(
                title: L10n.string("Rückgängig teilweise fehlgeschlagen"),
                text: L10n.format("%@\n\nDer bereits gespeicherte Fortschritt kann mit Rückgängig fortgesetzt werden.", message))
            reloadOpenTabs(for: partial.entries.filter { $0.state == .restored }
                .map { URL(fileURLWithPath: $0.originalPath) })
            return false
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
    var reloadFileLoader: @Sendable (URL) throws -> FileLoader.LoadedFile = {
        try FileLoader.load(url: $0)
    }
    var reopenFileLoader: @Sendable (URL, String.Encoding) throws -> FileLoader.LoadedFile = {
        try FileLoader.load(url: $0, forcedEncoding: $1)
    }

    func reloadOpenTabs(for changedURLs: [URL]) {
        let changed = Set(changedURLs.map { $0.canonicalFileURL.path })
        // Snapshot der zu reloadenden Tab-IDs + URLs aufnehmen — die
        // Schleife muss nicht auf dem aktuellen `tabs`-Array laufen.
        let toReload: [(id: UUID, url: URL, contentRevision: UInt64,
                       diskSnapshot: FileSnapshot?)] = tabs.compactMap { tab in
            guard let url = tab.url,
                  changed.contains(url.canonicalFileURL.path) else { return nil }
            // Ein Dirty-/Ladezustand darf weder hier noch in der Completion
            // automatisch verworfen werden.
            guard !tab.isDirty, !tab.isLoading else { return nil }
            return (id: tab.id, url: url, contentRevision: tab.contentRevision,
                    diskSnapshot: tab.diskSnapshot)
        }
        let loader = reloadFileLoader
        for (tabID, url, originalRevision, originalDiskSnapshot) in toReload {
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
                let loadResult = Result { try loader(url) }
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
                        guard !self.tabs[idx].isDirty,
                              self.tabs[idx].contentRevision == originalRevision,
                              self.tabs[idx].diskSnapshot == originalDiskSnapshot else {
                            self.tabs[idx].isLoading = false
                            return
                        }
                        self.tabs[idx].content    = loaded.content
                        self.tabs[idx].encoding   = loaded.encoding
                        self.tabs[idx].bom        = loaded.bom
                        self.tabs[idx].lineEnding = loaded.lineEnding
                        self.tabs[idx].displayMode = loaded.displayMode
                        self.tabs[idx].fileSize = loaded.fileSize
                        self.tabs[idx].diskSnapshot = loaded.diskSnapshot
                        self.tabs[idx].diskModificationDate = ExternalChange.diskModificationDate(of: url)
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
        guard !scope.isFolderLike, searchError == nil,
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
        NotificationCenter.default.postMatchJump(target, for: self)
    }

    /// Stößt die explizite Ordner-Suche an („Suchen"-Klick / Return in der
    /// Maske). Der Ordner-Scope wird bewusst NICHT live durchsucht
    /// (Konzept Abschnitt C) — dies ist der einzige Auslöser dafür.
    func runFolderSearchNow() {
        recordSearchHistory()
        searchRunner?.runFolderSearch()
    }

    /// Trefferliste als LF-getrennten String ins Clipboard kopieren —
    /// schneller Direktweg neben dem konfigurierbaren Extrahieren-Dialog.
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
        var options = HitExtraction.Options()
        options.useReplacement = !replacePattern.isEmpty
        options.destination = .newDocument
        return extractHits(options: options)
    }

    @discardableResult
    func extractHits(options: HitExtraction.Options) -> Bool {
        let matches: [BufferSearch.Match]
        if scope.isFolderLike || scope == .open {
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
        let content = HitExtraction.content(matches: matches, options: options)
        if options.destination == .clipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            return true
        }
        // Neues unbenanntes Dokument mit dem Extrakt — dirty, damit die
        // Schließen-Rückfrage greift (Inhalt existiert nur im Speicher).
        let tab = EditorTab(title: Workspace.untitledName(position: tabs.count + 1),
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

extension URL {
    /// Kanonische Form einer Datei-URL für Identitäts-Vergleiche (Tab-Dedup,
    /// Aktiv-Markierung im Projektbaum). WICHTIG: `resolvingSymlinksInPath`
    /// reicht NICHT — es lässt die `/private`-Aliasse (`/var`, `/tmp`, `/etc`)
    /// per dokumentierter Ausnahme stehen, Verzeichnis-Listings liefern aber
    /// die `/private/…`-Form (Befund 2026-07-12). `canonicalPathKey` löst
    /// vollständig auf (inkl. Groß-/Kleinschreibung des Dateisystems).
    /// Nicht existierende Pfade bleiben unverändert.
    var canonicalFileURL: URL {
        guard let path = try? resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else {
            return self
        }
        return URL(fileURLWithPath: path)
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
        a.addButton(withTitle: L10n.string("OK"))
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
enum FileTypeFilter: String, CaseIterable, Identifiable, Codable {
    case knownText = "Bekannte Textformate"
    case all       = "Alle Dateien"
    var id: String { rawValue }
}
