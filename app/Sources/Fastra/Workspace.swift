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

/// Referenzspeicher für den großen Hex-Verlauf eines Dokuments. SwiftUI hält
/// während eines Renderdurchlaufs mehrere `EditorTab`-Werte desselben
/// Dokuments; sie sollen dieselbe Session sehen, statt deren wachsendes
/// Dictionary bei jeder neuen Zeile per Copy-on-write zu vervielfältigen.
private final class HexEditSessionStorage: Equatable {
    var value: HexEditSession

    init(_ value: HexEditSession) {
        self.value = value
    }

    static func == (lhs: HexEditSessionStorage, rhs: HexEditSessionStorage) -> Bool {
        lhs.value == rhs.value
    }

}

struct EditorTab: Identifiable, Hashable {
    let id: UUID
    var title: String
    var path: String
    var url: URL?
    /// Ordner, den ein frisch angelegter ungespeicherter Tab beim ersten
    /// Sichern vorschlagen soll. `openNewTab()` übernimmt ihn vom zuvor
    /// aktiven Dokument; er ist reiner Fensterzustand und wird nicht
    /// sitzungsübergreifend gespeichert.
    var initialSaveDirectory: URL?
    var content: String {
        didSet {
            contentRevision &+= 1
            if content != oldValue {
                hexEditSession.invalidateHistory()
            }
        }
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
    /// Noch nicht gespeicherte Byteänderungen der Hex-Ansicht. Der Zustand
    /// liegt absichtlich am Dokument statt an `HexFileView`: SwiftUI baut die
    /// Ansicht bei Tab- und Ansichtswechseln ab, der Tab muss die Änderungen
    /// trotzdem weiter schützen und anzeigen können.
    private var hexEditSessionStorage: HexEditSessionStorage
    var hexEditSession: HexEditSession {
        get { hexEditSessionStorage.value }
        set { hexEditSessionStorage.value = newValue }
        _modify { yield &hexEditSessionStorage.value }
    }

    /// Fasst Session und sichtbaren Tabzustand in genau einer Mutation des
    /// `@Published tabs`-Arrays zusammen. So löst eine Byteaktion nur eine
    /// Workspace-Aktualisierung aus, obwohl SwiftUI mehrere Felder anzeigt.
    @discardableResult
    mutating func updateHexEditSession<Result>(
        pinHexViewWhenChanged: Bool = false,
        _ update: (inout HexEditSession) -> Result
    ) -> Result {
        let result = update(&hexEditSessionStorage.value)
        if pinHexViewWhenChanged && hexEditSessionStorage.value.hasChanges {
            isPreview = false
            viewMode = .hex
        }
        return result
    }
    /// `true`, während die Datei im Hintergrund geladen wird.
    /// Der Editor zeigt dann einen Lade-Spinner statt dem Inhalt
    /// (CESE-Falle: Inhalt kommt erst nach erfolgreicher Completion
    /// ins Tab → .id-Neuerzeugung läuft mit fertigem Inhalt).
    var isLoading: Bool
    /// Ein Vorschau-Tab stammt aus einem einfachen Klick in der
    /// Änderungen-Liste. Der nächste einfache Klick darf genau diesen
    /// ungesicherten Tab wiederverwenden; Doppelklick oder die erste Eingabe
    /// macht ihn dauerhaft.
    var isPreview: Bool
    /// Identität des momentan im Tabplatz dargestellten Dokuments. Sie ändert
    /// sich auch dann, wenn der flüchtige Vorschau-Tab seine Tab-ID behält.
    /// Cursor, Scrollposition und Editor-Neuaufbau folgen deshalb dem Inhalt
    /// statt versehentlich dem wiederverwendeten Platz in der Tab-Leiste.
    var documentID: UUID
    /// Erklärung für einen auswählbaren, aber nicht veränderbaren Text-Tab.
    /// `nil` bezeichnet einen normalen Editor. Die Erklärung erscheint bei
    /// einem Schreibversuch direkt an der Einfügemarke.
    var readOnlyReason: String?
    /// Identität einer aus Git geladenen Vorversion. Solche Tabs besitzen
    /// absichtlich keine Datei-URL: Die gelöschte Arbeitsdatei darf weder
    /// gespeichert noch in die Sitzungswiederherstellung aufgenommen werden.
    var gitSnapshotRequest: GitFileSnapshotRequest?
    /// Exakte Byte-/Identitätsbasis des letzten Ladens oder Speicherns. Der
    /// Save-Pfad vergleicht sie unmittelbar vor dem Write und verlässt sich
    /// damit nicht auf die begrenzte Auflösung eines Änderungsdatums.
    var diskSnapshot: FileSnapshot?
    /// Zuletzt für die automatische Extern-Änderungs-Erkennung bestätigter
    /// Plattenstand. Er ist absichtlich von `diskSnapshot` getrennt: Wählt der
    /// Nutzer bei einem dirty Tab „Behalten“, soll Fastra nicht bei jeder
    /// Aktivierung erneut fragen, der spätere Save muss den Fremdstand aber
    /// weiterhin als Überschreibkonflikt erkennen.
    var externalFileObservation: ExternalFileObservation?
    var externalContentSnapshot: FileSnapshot?
    /// Erhöht sich, wenn der Nutzer einen fremden Inhaltsstand ausdrücklich
    /// behält. Anders als ein Snapshot funktioniert die Generation auch für
    /// große und binäre Tabs, die absichtlich keinen Vollinhalt hashen.
    private(set) var externalContentGeneration: UInt64
    /// Generation, deren Bytes die Ansicht zuletzt wirklich geladen hat.
    private(set) var displayedExternalContentGeneration: UInt64
    /// `true`, wenn der zuletzt gebundene Pfad nicht mehr als reguläre Datei
    /// gelesen werden konnte. Ein vollständig geladener Text bleibt dann als
    /// dirty Tab geschützt, bis derselbe Platteninhalt sicher zurückkehrt oder
    /// der Nutzer ihn ausdrücklich speichert beziehungsweise neu lädt.
    var externalFileUnavailable: Bool
    /// Art eines Git-Text-Tabs (Etappe 2): `.log` / `.diff` / `.commit`.
    /// `nil` = normale, editierbare Datei. Git-Tabs sind read-only, haben
    /// `url == nil` und werden nicht gespeichert.
    var gitKind: GitTabKind?
    /// Strukturierter Side-by-side-Diff. `nil` bei normalen Dateien sowie beim
    /// kompatiblen Unified-Fallback für Verlauf/Commit-Metadaten.
    var gitDiffRequest: GitDiffRequest?
    var gitDiffDocument: GitDiffDocument?
    /// Auftrag eines Datei-Vergleichs-Tabs (Etappe 1 Wunschpaket 2026-07c).
    /// `nil` = normaler Tab. Vergleichs-Tabs sind wie Git-Tabs read-only,
    /// haben `url == nil` und werden nicht gespeichert.
    var fileDiffRequest: FileDiffRequest?
    /// Fertig berechneter Vergleich (Ergebnis ODER erklärte Grenze).
    /// `nil` = Berechnung läuft noch (Ansicht zeigt einen Spinner).
    var fileDiffDocument: FileDiffDocument?
    /// Jede Neuberechnung desselben Vergleichs-Tabs erhöht diesen Wert.
    /// Nur die Completion derselben Generation darf den Tab noch verändern
    var fileDiffLoadGeneration: UInt64
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
    /// Abbild des zuletzt geladenen bzw. gespeicherten Stands — bewusst ohne
    /// zweite Inhaltskopie: UTF-8-Länge (bei nativen Swift-Strings O(1)) als
    /// billiger Vorfilter, der Hash läuft nur bei gleicher Länge. Damit
    /// erkennt Fastra, wenn Änderungen den Inhalt exakt auf den gespeicherten
    /// Stand zurückführen (z. B. per Rückgängig): Der Punkt im Tab verschwindet
    /// dann wieder, wie in VS Code oder BBEdit. Das Zeilenende gehört zur
    /// Basis, weil „Zeilenenden umschalten" ohne Textänderung speicherpflichtig
    /// ist. `nil` = keine gültige Basis (z. B. aus dem Papierkorb gerettet);
    /// dann bleibt ein einmal gesetzter Punkt bestehen.
    private(set) var savedContentUTF8Length: Int?
    private(set) var savedContentHash: Int?
    private(set) var savedLineEnding: LineEnding?

    init(
        id: UUID = UUID(),
        title: String,
        path: String,
        url: URL? = nil,
        initialSaveDirectory: URL? = nil,
        content: String = "",
        encoding: String.Encoding = .utf8,
        bom: Data = Data(),
        lineEnding: LineEnding = .lf,
        displayMode: EditorDisplayMode = .text,
        fileSize: UInt64 = 0,
        hits: Int = 0,
        isDirty: Bool = false,
        hexEditSession: HexEditSession = HexEditSession(),
        isLoading: Bool = false,
        isPreview: Bool = false,
        documentID: UUID = UUID(),
        readOnlyReason: String? = nil,
        gitSnapshotRequest: GitFileSnapshotRequest? = nil,
        diskSnapshot: FileSnapshot? = nil,
        gitKind: GitTabKind? = nil,
        gitDiffRequest: GitDiffRequest? = nil,
        gitDiffDocument: GitDiffDocument? = nil,
        fileDiffRequest: FileDiffRequest? = nil,
        fileDiffDocument: FileDiffDocument? = nil,
        fileDiffLoadGeneration: UInt64 = 0,
        viewMode: EditorViewMode? = nil
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.url = url
        self.initialSaveDirectory = initialSaveDirectory
        self.content = content
        self.contentRevision = 0
        self.encoding = encoding
        self.bom = bom
        self.lineEnding = lineEnding
        self.displayMode = displayMode
        self.fileSize = fileSize
        self.hits = hits
        self.isDirty = isDirty
        self.hexEditSessionStorage = HexEditSessionStorage(hexEditSession)
        self.isLoading = isLoading
        self.isPreview = isPreview
        self.documentID = documentID
        self.readOnlyReason = readOnlyReason
        self.gitSnapshotRequest = gitSnapshotRequest
        self.diskSnapshot = diskSnapshot
        // Der asynchrone Ladepfad setzt den echten Platten-Fingerabdruck mit
        // dem fertigen Snapshot. Der Initializer selbst darf keine Datei-I/O
        // auf dem Main-Thread einschmuggeln (Lade-Platzhalter entstehen dort).
        self.externalFileObservation = nil
        self.externalContentSnapshot = diskSnapshot
        self.externalContentGeneration = 0
        self.displayedExternalContentGeneration = 0
        self.externalFileUnavailable = false
        self.gitKind = gitKind
        self.gitDiffRequest = gitDiffRequest
        self.gitDiffDocument = gitDiffDocument
        self.fileDiffRequest = fileDiffRequest
        self.fileDiffDocument = fileDiffDocument
        self.fileDiffLoadGeneration = fileDiffLoadGeneration
        self.viewMode = viewMode
        // Frische Tabs starten mit ihrem Anfangsinhalt als gespeicherter
        // Basis. Ein bereits geänderter Tab (isDirty) kennt seinen
        // Plattenstand hier nicht — er erhält erst beim nächsten Laden oder
        // Speichern wieder eine gültige Basis.
        if !isDirty {
            recordSavedContentBaseline()
        }
    }

    /// `EditorTab` bleibt ein Werttyp, seine Identität ist aber ausschließlich
    /// die stabile Tab-ID. Der geteilte, veränderliche Hex-Speicher darf den
    /// Hash einer bereits als Schlüssel gehaltenen Tabkopie niemals ändern.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Merkt den aktuellen Inhalt als „gespeicherten" Stand. Nach jedem
    /// erfolgreichen Laden, Neuladen und Speichern aufrufen.
    mutating func recordSavedContentBaseline() {
        savedContentUTF8Length = content.utf8.count
        savedContentHash = content.hashValue
        savedLineEnding = lineEnding
    }

    /// Verwirft die Basis ausdrücklich — z. B. wenn die Datei auf der Platte
    /// verschwunden ist und der Tab als ungesicherter Entwurf weiterlebt.
    mutating func invalidateSavedContentBaseline() {
        savedContentUTF8Length = nil
        savedContentHash = nil
        savedLineEnding = nil
    }

    /// Merkt den Plattenstand für den nächsten Aktivierungs-Check. Der
    /// schreibende Konfliktschutz (`diskSnapshot`) bleibt davon unabhängig.
    mutating func recordExternalFileObservation(
        snapshot: FileSnapshot?,
        observation: ExternalFileObservation?,
        contentChangeAccepted: Bool = false,
        contentLoaded: Bool = false
    ) {
        if contentChangeAccepted { externalContentGeneration &+= 1 }
        if contentLoaded {
            displayedExternalContentGeneration = externalContentGeneration
        }
        externalFileObservation = observation
        externalContentSnapshot = snapshot
        externalFileUnavailable = false
    }

    /// Bewahrt die letzte vollständig geladene Textfassung, wenn der Pfad
    /// gelöscht, unlesbar oder kein reguläres Dateiobjekt mehr ist. Hex- und
    /// Abschnittsansichten besitzen keinen speicherbaren Vollinhalt und dürfen
    /// deshalb nicht fälschlich als leerer, dirty Editor angeboten werden.
    mutating func protectContentAfterExternalFileBecameUnavailable() {
        externalFileObservation = nil
        externalFileUnavailable = true
        if diskSnapshot != nil, isOrdinaryTextDocument {
            isDirty = true
        }
    }

    /// `true`, wenn der aktuelle Stand exakt dem gespeicherten entspricht.
    /// Der Hash (SipHash über den ganzen Inhalt) läuft nur, wenn die billige
    /// Längenprüfung schon Gleichheit nahelegt.
    var matchesSavedContentBaseline: Bool {
        guard let savedContentUTF8Length, let savedContentHash,
              let savedLineEnding else { return false }
        return lineEnding == savedLineEnding
            && content.utf8.count == savedContentUTF8Length
            && content.hashValue == savedContentHash
    }

    /// Nur normale, vollständig geladene Textdokumente können als Paar für
    /// „Dateien vergleichen…“ markiert werden. Git-, Diff-, Hex- und
    /// Abschnitts-Tabs bleiben gewöhnliche einzelne Tabs.
    var isEligibleForFileComparison: Bool {
        isEditableTextDocument
    }

    /// Gemeinsame Verlustgrenze für Schließen, Beenden, Projektwechsel und
    /// automatische Reloads. `isDirty` bleibt der Textpuffer-Zustand; die
    /// Hex-Änderungen besitzen eine eigene Vorschau- und Speichersemantik.
    var hasUnsavedChanges: Bool {
        isDirty || hexEditSession.hasChanges
    }

    /// Ein normaler, vollständig geladener Textpuffer. Diese Grundgrenze bleibt
    /// auch bei offenen Hex-Änderungen wahr: Verschwindet dann die Datei, muss
    /// Fastra die letzte Volltextkopie unabhängig vom Hex-Zustand schützen.
    private var isOrdinaryTextDocument: Bool {
        !isLoading && displayMode == .text && readOnlyReason == nil
            && gitSnapshotRequest == nil && gitKind == nil
            && gitDiffRequest == nil && fileDiffRequest == nil
    }

    /// Gemeinsame Schreibbarkeitsgrenze für Editorbefehle und Ersetzen.
    /// Eine sichtbare Textdarstellung allein genügt nicht: Git-Vorversionen,
    /// Diffs, noch ladende Tabs und Dokumente mit einer offenen Byteänderung
    /// dürfen niemals über einen zweiten Modellpfad verändert werden.
    var isEditableTextDocument: Bool {
        isOrdinaryTextDocument && !hexEditSession.hasChanges
    }

    /// „Unberührter Notizzettel": unbenannt, leer, ungeändert, fertig geladen,
    /// normale Textansicht, keine Sonderrolle (Git/Vergleich). Genau diese
    /// Tabs zeigen den Willkommens-Platzhalter über dem Editor (Firefox-artig,
    /// Daniel-Entscheidung 2026-07-30 — ersetzt den eigenen Willkommen-Tab vom
    /// 2026-07-12) und dürfen beim Öffnen echter Dateien abgeräumt werden.
    /// Ab dem ersten getippten Zeichen ist der Tab nicht mehr unberührt;
    /// löscht man alles wieder, gilt er erneut als unberührt — der Zustand
    /// ist bewusst rein aus dem Tab abgeleitet, ohne verstecktes Flag.
    var isPristineScratch: Bool {
        url == nil && content.isEmpty && !isDirty && !isLoading
            && gitKind == nil && fileDiffRequest == nil && gitSnapshotRequest == nil
            && displayMode == .text
    }
}

/// Unveränderliche Identität der Hex-Basis, die eine konkrete SwiftUI-Ansicht
/// anzeigt. Der Kontext kopiert nur Skalare und den URL-Wert: Eine alte View
/// darf nach Reload, Verwerfen oder Save keine neue Session mehr verändern.
struct HexEditActionContext: Equatable, Sendable {
    let tabID: UUID
    let documentID: UUID
    let editingLineageID: UUID
    let fileURL: URL?

    init(
        tabID: UUID,
        documentID: UUID,
        editingLineageID: UUID,
        fileURL: URL?
    ) {
        self.tabID = tabID
        self.documentID = documentID
        self.editingLineageID = editingLineageID
        self.fileURL = fileURL
    }

    init(tab: EditorTab) {
        self.init(
            tabID: tab.id,
            documentID: tab.documentID,
            editingLineageID: tab.hexEditSession.editingLineageID,
            fileURL: tab.url
        )
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

/// Kleines threadsicheres Signal zwischen Main-Actor und synchronem
/// Hintergrund-Read. `FileLoader` fragt es zwischen seinen Abschnitten ab.
private final class PreviewLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Startwerte und UserDefaults-Schlüssel der ziehbaren Fensterbreiten. Die
/// Werte sind PRO FENSTER veränderlich (siehe `Workspace.sidebarWidth`); der
/// gespeicherte Wert dient nur als Startbreite neuer Fenster. Die Schlüssel
/// bleiben identisch zur früheren `@AppStorage`-Fassung, damit bereits
/// gespeicherte Nutzerbreiten weiter gelten.
enum SidebarLayout {
    static let defaultSidebarWidth: Double = 200
    static let defaultPreviewWidth: Double = 420
    static let minimumSidebarWidth: Double = 180
    /// Lange Projektpfade dürfen auf breiten Fenstern vollständig lesbar
    /// werden. Der Editor behält durch sein eigenes Mindestlayout Vorrang,
    /// wenn das Fenster selbst schmaler ist.
    static let maximumSidebarWidth: Double = 760
    static let sidebarWidthKey = "editor.sidebarWidth"
    static let previewWidthKey = "markdown.previewWidth"
}

/// Bindet einen asynchronen Datei-Ladevorgang an den Zustand seines Aufrufers.
/// Der Werttyp hält die Gültigkeitsprüfung getrennt von der abschließenden
/// Completion-Closure; dadurch bleiben bestehende `loadFile { ... }`-Aufrufe
/// für Swift eindeutig. Ausgeführt wird die Prüfung ausschließlich auf dem
/// Main-Thread: unmittelbar vor dem Start und vor dem Publizieren des Tabs.
struct FileLoadAcceptance: @unchecked Sendable {
    private let isAccepted: () -> Bool

    init(_ isAccepted: @escaping () -> Bool) {
        self.isAccepted = isAccepted
    }

    func acceptsResult() -> Bool {
        isAccepted()
    }
}

/// Typisiertes Ergebnis eines snapshot-gebundenen Ladeauftrags. Die
/// Treffer-Navigation muss unterscheiden, WARUM ein Auftrag nicht ausgeführt
/// wurde: Nur ein echter Plattenstand-Konflikt entwertet die
/// Ordner-Trefferbasis. Vorher galt jedes `false` als „veraltet" — ein
/// zweiter Sprung während des ersten Ladens löschte damit korrekte
/// Ordnerergebnisse, und ein ungesicherter Tab erzwang eine neue Suche, die
/// den Pufferkonflikt gar nicht lösen kann (Review 2026-08-31).
enum FileLoadOutcome: Equatable {
    /// Datei geladen bzw. der passende Tab aktiviert.
    case opened
    /// Der Plattenstand entspricht nicht mehr dem erwarteten Snapshot.
    case staleSnapshot
    /// Der Ziel-Tab lädt gerade noch (ein früherer Auftrag läuft).
    case busyLoading
    /// Der Ziel-Tab enthält ungesicherte Änderungen.
    case unsavedChanges
    /// Der Auftrag wurde durch einen neueren entwertet oder abgebrochen
    /// (Acceptance, Generation, geschlossener Tab, Kontextwechsel).
    case cancelled
    /// Datei nicht lesbar oder Ladefehler.
    case failed

    var isOpened: Bool { self == .opened }
}

/// Prozessweite Pfadsperre für Dateioperationen, die einen Plattenstand
/// außerhalb eines einzelnen Dokumentfensters verändern. Neue Fenster fragen
/// denselben Zustand ab und können deshalb nicht zwischen Start und Abschluss
/// einer Ordner-Operation noch eine Hex-Bearbeitung am Ziel beginnen.
private enum WorkspacePathOperationRegistry {
    private static let lock = NSLock()
    private static var pathsByOperation: [UUID: [String]] = [:]

    static func begin(paths: [URL]) -> UUID? {
        let standardized = Array(Set(paths.map { $0.standardizedFileURL.path }))
        guard !standardized.isEmpty else { return nil }
        return lock.withLock {
            let occupied = pathsByOperation.values.joined()
            guard !standardized.contains(where: { candidate in
                occupied.contains(where: { pathsOverlap(candidate, $0) })
            }) else { return nil }
            let id = UUID()
            pathsByOperation[id] = standardized
            return id
        }
    }

    static func finish(_ id: UUID) {
        _ = lock.withLock { pathsByOperation.removeValue(forKey: id) }
    }

    static func contains(_ url: URL?) -> Bool {
        guard let path = url?.standardizedFileURL.path else { return false }
        return lock.withLock {
            pathsByOperation.values.joined().contains {
                path == $0 || path.hasPrefix($0 + "/")
            }
        }
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}

final class Workspace: ObservableObject {
    struct FileTreeTrashOperation {
        fileprivate let id: UUID
        fileprivate let workspaces: [Workspace]
    }

    struct FileTreeMoveOperation {
        fileprivate let id: UUID
        fileprivate let workspaces: [Workspace]
    }

    private struct FolderApplyMutationOperation {
        let id: UUID
        let workspaces: [Workspace]
    }

    private struct HexSaveMutationOperation {
        let id: UUID
        let tabID: UUID
        let documentID: UUID
        let path: String
        let workspaces: [Workspace]
    }

    /// Dauerhafte Fensteridentität für langlebige Singleton-Dienste. Anders
    /// als eine schwache Referenz bleibt sie auch nach dem Schließen des
    /// auslösenden Fensters eindeutig und kann keinem anderen Fenster zufallen.
    let instanceID = UUID()
    typealias ProjectContextScheduler = (@escaping @Sendable () -> Void) -> Void
    typealias ProjectContextResolver = @Sendable (URL, URL?) -> URL?

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
    /// Ein Speicherbefehl oder Schließen-Dialog kann die dokumentgebundene
    /// Hex-Vorschau anfordern. Die Anfrage bleibt an eine Tab-ID gebunden,
    /// damit kein anderes Fenster oder inzwischen gewählter Tab reagiert.
    @Published private(set) var hexSavePreviewRequestTabID: UUID?
    /// Während Fastra einen Datei- oder Ordnerpfad in den Papierkorb bewegt,
    /// darf dort keine neue Byteänderung beginnen: Nach dem Verschieben gäbe
    /// es für die Hex-Vorschau kein schreibbares Original mehr.
    @Published private(set) var fileMutationRevision: UInt64 = 0
    /// Standardmäßig die echten registrierten Dokumentfenster. Tests können
    /// mehrere headless Workspaces koppeln, ohne dafür NSWindow zu öffnen.
    var fileTreeMutationWorkspaceProvider: () -> [Workspace] = {
        WorkspaceWindowRegistry.registeredWorkspaces()
    }
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
            // Merkliste „zuletzt benutzt" pflegen: der aktive Tab wandert an
            // die Spitze. Doppelte Einträge gibt es nicht, jeder Tab steht
            // höchstens einmal in der Liste.
            if let id = activeTabID {
                recentlyActiveTabIDs.removeAll { $0 == id }
                recentlyActiveTabIDs.insert(id, at: 0)
            }
            // Makro-Katalog folgt der aktiven `.4dm`-Datei (Makros-Menü).
            // Billig: gescannt wird nur bei gewechseltem Dokumentordner.
            refreshFourDMacroCatalogIfNeeded()
        }
    }
    /// Zuletzt aktive Tabs, der jüngste zuerst. Bestimmt nach dem Schließen
    /// des aktiven Tabs den Nachfolger: ⌘W soll zum zuletzt benutzten Tab
    /// zurückkehren und nicht stumpf zum ersten Tab der Leiste springen
    /// (Daniel-Befund 2026-07-29: echtes Dokument + mehrere frische ⌘T-Tabs,
    /// zweimal ⌘W schloss das echte Dokument statt der leeren Tabs).
    /// Einträge geschlossener Tabs werden beim Schließen entfernt; die Liste
    /// bleibt dadurch so klein wie die Tab-Leiste selbst.
    private var recentlyActiveTabIDs: [UUID] = []
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
    /// Fertiges Scan-Ergebnis zum Filter. Liegt am Workspace und nicht als
    /// `@State` in der Seitenleiste, weil SwiftUI die Dateien-Ansicht beim
    /// Wechsel auf einen anderen Seitenleisten-Tab vollständig abbaut: Der
    /// Suchtext blieb danach stehen, das Ergebnis war weg und der Baum zeigte
    /// sich ungefiltert (Daniel-Befund 2026-08-24).
    @Published var fileTreeFilterResult: FileTreeFilterResult?
    /// Aktiver Tab der Seitenleiste. Ebenfalls am Workspace, weil Befehle ihn
    /// setzen müssen — „Git-Historie anzeigen" im Kontextmenü des Dateibaums
    /// springt damit auf den Graph-Tab.
    @Published var sidebarMode: SidebarMode = .files
    /// Scrollpositionen der Seitenleisten-Listen über einen Tab-Wechsel
    /// hinweg. Bewusst NICHT `@Published`: Der Wert wird beim Scrollen
    /// laufend fortgeschrieben und darf kein SwiftUI-Update auslösen.
    let sidebarScrollMemory = SidebarScrollMemory()
    /// Atomarer 4D-Projektindex für dieses Fenster. Projekt- und Komponenten-
    /// methoden wechseln gemeinsam; bis zum ersten Scan bleibt er leer.
    @Published private(set) var fourDMethodIndexSnapshot = FourDMethodIndexSnapshot.empty
    /// Kompatible Lesesichten für bestehende Verbraucher. Sie besitzen keinen
    /// eigenen Zustand, sondern stammen immer aus demselben Snapshot.
    var fourDProjectMethodNames: Set<String> {
        fourDMethodIndexSnapshot.projectMethodNames
    }
    var fourDProjectMethodDisplayNames: [String] {
        fourDMethodIndexSnapshot.projectMethodDisplayNames
    }
    var fourDComponentMethods: [String: FourDComponentMethod] {
        fourDMethodIndexSnapshot.componentMethods
    }
    /// Geparste 4D-Methodeneditor-Makros für die aktive `.4dm`-Datei
    /// (Makros-Menü + Shortcuts). Leer, solange keine `.4dm`-Datei aktiv ist
    /// oder an den bekannten Fundorten keine Makro-XML liegt.
    @Published var fourDMacros: [FourDMacro] = []
    /// Schlüssel des letzten Makro-Scans (Dokumentordner), damit ein bloßer
    /// Tabwechsel innerhalb desselben Ordners keinen neuen Scan auslöst.
    /// (Intern statt privat: Die Pflege lebt in `FourDMacroAssist.swift`.)
    var fourDMacroScanKey: String?
    /// Entwertet veraltete, noch laufende Makro-Scans nach Tab-/Projektwechsel.
    var fourDMacroScanGeneration = UUID()
    /// Diff-Vorschau eines Makrolaufs (Sheet). Anwenden ist erst nach dieser
    /// sichtbaren Vorschau möglich — Produktinvariante „keine Schreibänderung
    /// ohne Vorschau".
    @Published var fourDMacroPreview: FourDMacroPreviewState?
    /// `true`, während ein tool4d-Makrolauf dieses Fensters läuft. Sperrt
    /// Menüeinträge und Shortcuts gegen parallele Läufe desselben Puffers.
    @Published var fourDMacroEngineBusy = false
    /// Laufende Nachbearbeitung des Engine-Ergebnisses: Rücktokenisierung UND
    /// Diff-Berechnung samt Tab ihrer Lease. Eine Inhaltsänderung, Tab- oder
    /// Fensterschließung entwertet die Lease endgültig und gibt die Makro-Sperre
    /// sofort frei. Die ID verhindert, dass ein spät endender abgebrochener Task
    /// den Handle seines Nachfolgers löscht. (Pflege in `FourDMacroAssist.swift`.)
    var fourDMacroPostprocessTask: Task<Void, Never>?
    var fourDMacroPostprocessTabID: UUID?
    var fourDMacroPostprocessID: UUID?
    /// Identität des laufenden Engine-Laufs (Preflight + tool4d-Prozess),
    /// VOR der Nachbearbeitung. Nur die Completions genau dieses Laufs dürfen
    /// die gemeinsame Sperre `fourDMacroEngineBusy` freigeben: Gibt Home oder
    /// Fensterschluss die Sperre vorzeitig frei und startet danach ein neuer
    /// Lauf, darf die verspätete Completion des alten Laufs die Sperre des
    /// Nachfolgers nicht löschen (Review 2026-08-29). (Pflege in
    /// `FourDMacroAssist.swift`.)
    var fourDMacroEngineRunID: UUID?
    /// Zuletzt angeforderter, noch von keinem Editor verarbeiteter
    /// Treffer-Sprung. Die Sprung-Notification kann in eine Editor-
    /// Neuerzeugung fallen und verpuffen; der frisch eingehängte Editor
    /// desselben Dokuments holt den Sprung von hier nach und verbraucht ihn
    /// (siehe `PendingEditorJump`). Bewusst kein `@Published` — der Editor
    /// liest ihn imperativ beim Erscheinen und im Notification-Pfad.
    var pendingEditorJump: PendingEditorJump?
    /// Laufende Nummer des zuletzt angemeldeten Treffer-Sprungs. Jede neue
    /// Navigation (Klick, ⌘G, Pfeil, Nachrück-Sprung) zieht sich hier eine
    /// Nummer und entwertet damit alle älteren Aufträge.
    ///
    /// Warum zusätzlich zu `MatchJumpTarget`? Der Dokument-/URL-Guard erkennt
    /// nur einen Wechsel des Ziels. Wählt der Nutzer zwei Treffer DERSELBEN
    /// noch ladenden Datei, ist der Guard für beide wahr: Die späte Completion
    /// des ersten Auftrags überschreibt dann den bereits geposteten zweiten
    /// Sprung, und der Editor springt zum älteren Treffer, während die
    /// Trefferliste den neueren anzeigt. Die Nummer trennt diesen Fall.
    /// Bewusst kein `@Published`: reiner Ablaufschutz, keine Anzeige.
    private(set) var matchJumpGeneration: Int = 0

    /// Meldet einen neuen Sprungauftrag an und liefert dessen Nummer. Alle
    /// zuvor vergebenen Nummern sind danach veraltet.
    func beginMatchJump() -> Int {
        matchJumpGeneration &+= 1
        return matchJumpGeneration
    }

    /// `true`, solange `generation` der zuletzt angemeldete Auftrag ist.
    func isCurrentMatchJump(_ generation: Int) -> Bool {
        generation == matchJumpGeneration
    }

    /// Zielindex des zuletzt angemeldeten, noch nicht abgeschlossenen
    /// Navigationsauftrags. `activeMatchIndex` wird bei Ordner-Treffern erst
    /// in der asynchronen Snapshot-/Lade-Completion fortgeschrieben; ohne
    /// diese Vormerkung berechneten mehrere schnelle ⌘G-/Pfeil-Eingaben alle
    /// denselben Nachfolger aus dem alten Index und bewegten die Auswahl nur
    /// um EINEN Treffer (Review 2026-08-31). Gültig nur, solange seine
    /// Generation die aktuelle ist; jede neue Navigation oder Entwertung
    /// macht ihn damit automatisch bedeutungslos.
    private var pendingMatchNavigation: (generation: Int, index: Int)?

    /// Basisindex für die NÄCHSTE Navigationseingabe: das noch ausstehende
    /// Ziel der laufenden Navigation, sonst der bestätigte aktive Index.
    var matchNavigationBaseIndex: Int {
        if let pending = pendingMatchNavigation,
           isCurrentMatchJump(pending.generation) {
            return pending.index
        }
        return activeMatchIndex
    }

    /// Merkt das Ziel eines gerade angemeldeten asynchronen Sprungauftrags
    /// synchron vor — im selben Main-Thread-Durchlauf wie `beginMatchJump`.
    func noteMatchNavigationTarget(index: Int, generation: Int) {
        guard isCurrentMatchJump(generation) else { return }
        pendingMatchNavigation = (generation, index)
    }

    /// Räumt die Vormerkung ab, sobald der Auftrag abgeschlossen ist —
    /// gleich ob erfolgreich, verworfen oder gescheitert. Eine fremde
    /// (neuere) Vormerkung bleibt unberührt.
    func resolveMatchNavigationTarget(generation: Int) {
        guard pendingMatchNavigation?.generation == generation else { return }
        pendingMatchNavigation = nil
    }

    /// Entwertet alle offenen Sprungaufträge, ohne einen neuen anzumelden.
    ///
    /// Aufzurufen, sobald die navigierbare Trefferbasis ungültig wird: neues
    /// Suchmuster, geänderte Optionen oder Scope, verworfene Ordner-Vorschau,
    /// neuer Ordnerlauf, geschlossene Maske. Ein Trefferklick in einer noch
    /// ladenden Funddatei zieht seine Nummer beim Klick; ohne diese
    /// Entwertung passierte seine Lade-Completion nach einer Sucheingabe
    /// weiterhin `isCurrentMatchJump` und den URL-Guard, postete den Sprung
    /// aus der ALTEN Ergebnisliste und übernahm den alten Index in die neue
    /// Trefferbasis (Review 2026-08-22). Ein bereits hinterlegter, noch nicht
    /// verbrauchter `pendingEditorJump` gehört ebenfalls zur alten Basis und
    /// wird mit verworfen.
    func invalidateMatchJumps() {
        matchJumpGeneration &+= 1
        pendingEditorJump = nil
    }
    var fourDComponentMethodDisplayNames: [String] {
        fourDMethodIndexSnapshot.componentMethodDisplayNames
    }
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
    /// Alle lokal konfigurierten Remotes samt effektiver Push-Adresse in der
    /// Reihenfolge aus `.git/config`. Die Änderungen-Ansicht bietet jedes Ziel
    /// getrennt an und zeigt die Adresse direkt in seiner klickbaren Fläche.
    @Published var gitPushTargets: [GitPushTarget] = []
    /// Sichtbarer Hinweis, wenn einzelne konfigurierte Remotes nicht gelesen
    /// werden konnten, während andere Ziele weiterhin benutzbar bleiben.
    @Published var gitPushTargetWarning: String?
    /// Atomarer, gemeinsam revidierter Zustand aller Git-Oberflächen.
    @Published var gitRepositorySnapshot: GitRepositorySnapshot?
    /// Commit-Historie des aktuellen Projekts für den Graph-Tab (Phase 3).
    /// Leer = kein Repo/keine Commits oder noch nicht geladen. Asynchron über
    /// `refreshGitLog()` gefüllt.
    @Published var gitLog: [GitCommit] = []
    /// Auf eine Datei eingeschränkter Verlauf: `nil` = ganze Historie.
    /// Der volle `gitLog` bleibt daneben stehen, deshalb kommt der Rücksprung
    /// auf die ganze Historie ohne neuen git-Aufruf aus.
    @Published var gitHistoryFile: GitHistoryFile?
    /// Commits, die die unter `gitHistoryFile` genannte Datei geändert haben.
    @Published var gitFileHistory: [GitCommit] = []
    /// Ladezustand dazu — die Ansicht unterscheidet damit „lädt noch" von
    /// „diese Datei hat keine Commits".
    @Published var gitFileHistoryState: GitFileHistoryState = .idle
    /// Aufgeklappte Commits des Graph-Tabs. Am Workspace, damit ein
    /// Tab-Wechsel in der Seitenleiste die Ansicht nicht zusammenklappt.
    @Published var gitGraphExpandedCommits: Set<String> = []
    /// Lokale Branches für die Auswahl in der Projekt-Seitenleiste.
    @Published var gitBranches: [GitBranch] = []
    /// Kurzlebige, nicht-modale Rückmeldung erfolgreicher Git-Aktionen.
    @Published var gitFeedback: GitActionFeedback?
    /// Sichtbare Push-Phase je Remote für die Karten der Änderungen-Ansicht:
    /// `running` zeigt den drehenden Kreis, `succeeded` für zwei Sekunden das
    /// Häkchen. Kein Eintrag = Karte im Normalzustand.
    @Published var gitPushFeedback: [String: GitPushFeedbackPhase] = [:]
    /// Generation je Remote: Ein älterer, noch auslaufender Push-Ablauf darf
    /// die Anzeige eines neueren nicht mehr verändern (gleiches Muster wie
    /// die ID in `GitActionFeedback`).
    var gitPushFeedbackGenerations: [String: UUID] = [:]
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
    @Published var showSearchDialog: Bool = false {
        didSet {
            // Während Suche/Ersetzung bleibt ihr Projektkontext eingefroren.
            // Nach dem Schließen holen wir einen inzwischen erfolgten stabilen
            // Tabwechsel nach; sonst bliebe die Seitenleiste dauerhaft beim
            // vorherigen Repository stehen.
            if oldValue, !showSearchDialog {
                synchronizeProjectWithActiveTabIfNeeded()
            }
        }
    }
    /// Öffnet den Dialog „Dateien vergleichen…" (Etappe 1 Wunschpaket
    /// 2026-07c) als Sheet auf dem Hauptfenster.
    @Published var showCompareFilesDialog: Bool = false
    /// Geordnete Vorbelegung für den nächsten Vergleichsdialog. Die Reihenfolge
    /// folgt der sichtbaren Tab-Leiste, nicht der Klickreihenfolge.
    @Published private(set) var compareDialogPrefillTabIDs: [UUID] = []
    @Published var findPattern: String = "([a-zA-Z0-9._%+-]+)@([a-zA-Z0-9.-]+)\\.([a-zA-Z]{2,})" {
        didSet { disableWildcardLiteralOptionIfUnavailable() }
    }
    @Published var replacePattern: String = "[$1](mailto:$1@$2.$3)"
    @Published var livePreview: Bool = false {
        didSet {
            if oldValue, !livePreview {
                synchronizeProjectWithActiveTabIfNeeded()
            }
        }
    }
    @Published var scope: SearchScope = .folder

    // MARK: - Such-Optionen (Suchmasken-Konzept B.5)
    //
    // Default-Haltung: RegEx aus. Fastra ist „ein Editor mit RegEx-
    // Superkraft", nicht „ein RegEx-Tool, das auch suchen kann". Wer RegEx
    // kennt, schaltet es bewusst ein; wer es nicht kennt, bekommt mit
    // Klartext- und Stern-Suche das erwartbare Verhalten (Testerin-Befund
    // 2026-08-28: Klartext-Suche fand mit aktivem RegEx nichts). Der alte
    // Prototyp-Startwert `true` stammte aus der Demo-Phase und sollte laut
    // damaligem Kommentar mit der echten Suchlogik auf `false` wechseln —
    // das holt dieser Default nach. RegEx-Vorlagen und der Element-Picker
    // schalten den Modus weiterhin selbst ein.
    @Published var useRegex: Bool = false {
        didSet { disableWildcardLiteralOptionIfUnavailable() }
    }
    @Published var caseSensitive: Bool = false
    @Published var wholeWord: Bool = false
    @Published var wrapAround: Bool = true

    /// Mini-Schalter „`*` wörtlich nehmen" (Feature J). Bleibt in der Maske
    /// sichtbar, ist aber nur aktiv, wenn RegEx aus ist und das Muster ein `*`
    /// enthält. Aus = `*` wirkt als Platzhalter; an = `*` wird buchstäblich
    /// gesucht. Ungültige Zustände setzen den Wert sofort auf `false` zurück.
    @Published var treatWildcardLiterally: Bool = false

    /// Gemeinsame Aktivierungsbedingung für Modell, View und Selbsttests.
    /// Der Schalter darf nur Plain-Text-Sterne in normale Zeichen umdeuten;
    /// im RegEx-Modus oder ohne Stern hätte sein Zustand keine sichtbare
    /// Bedeutung und wäre beim nächsten passenden Muster überraschend.
    var wildcardLiteralOptionIsEnabled: Bool {
        !useRegex && WildcardPattern.containsWildcard(findPattern)
    }

    private func disableWildcardLiteralOptionIfUnavailable() {
        if !wildcardLiteralOptionIsEnabled && treatWildcardLiterally {
            treatWildcardLiterally = false
        }
    }

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
    /// Bündelt die mehreren SwiftUI-Signale eines Editoraufbaus. Ohne diese
    /// kurze Verzögerung zählten `onAppear`, Inhalts- und Cursoränderung
    /// dieselben vier Megabyte gleichzeitig auf mehreren Threads.
    private var statsTask: Task<Void, Never>?

    // MARK: - Asynchrones Datei-Laden (v0.9)
    //
    // Jede `loadFile`-Anfrage bekommt eine Generation-Nummer (pro Tab-ID).
    // Wenn ein Tab geschlossen wird, bevor der Hintergrund-Task fertig ist,
    // erkennt der Guard das an der fehlenden ID und bricht ab — kein
    // Geister-Tab, kein falsches activeTabID.
    /// Aktuellste Lade-Generation pro Tab-UUID. Pattern analog zu
    /// `statsGeneration` in `recomputeDocumentStats`.
    private var loadGeneration: [UUID: Int] = [:]
    /// Testnaht für das erste, nicht-flüchtige Laden einer Datei. Der
    /// Produktionspfad bleibt `FileLoader.load`; Tests können den Read
    /// kontrolliert anhalten und so zwei echte Folgeaufträge reproduzieren,
    /// ohne auf Dateigröße oder Scheduler-Timing zu vertrauen.
    var initialFileLoader: @Sendable (URL) throws -> FileLoader.LoadedFile = {
        try FileLoader.load(url: $0)
    }
    /// Neuester logischer Ordner-Sprung, der auf den physischen Read dieser
    /// Datei wartet. Zwei schnelle Treffer derselben anfangs ungeöffneten
    /// Datei teilen sich dadurch EINEN Read; nur das jüngste Ziel wird nach
    /// dessen Abschluss ausgeführt (Review 2026-09-01).
    private struct PendingFolderMatchFileLoad {
        let generation: Int
        let expectedDiskSnapshot: FileSnapshot
        let outcome: (FileLoadOutcome) -> Void
    }
    private var pendingFolderMatchFileLoads: [String: PendingFolderMatchFileLoad] = [:]
    /// Der physische Read, der den wartenden Sprung dieses Pfades gerade
    /// bedient. Der Schlüssel allein reicht dafür nicht: Benennt die
    /// Seitenleiste die Datei während des Lesens um, liest DERSELBE Read ab
    /// dann einen ANDEREN Pfad zu Ende. Ohne diese Kennung rechnete seine
    /// Completion trotzdem den Wartenden des alten Pfads ab und meldete ihm
    /// das Ergebnis der umbenannten Datei (Review 2026-09-04).
    private var folderMatchReadTokens: [String: UUID] = [:]
    /// Kooperative Abbruchsignale ausschließlich für flüchtige Dateivorschauen.
    /// Ein neuer Klick beendet den alten Read an der nächsten Abschnittsgrenze,
    /// statt mehrere große Dateien parallel bis zum Ende einzulesen.
    private var previewLoadCancellations: [UUID: PreviewLoadCancellation] = [:]
    /// Fensterlokaler Besitzer der laufenden Plattenprüfungen. Der Inspector
    /// kennt keinen Workspace; Tab- und Reload-Entscheidungen bleiben hier.
    private let externalChangeInspector: ExternalChangeInspector
    /// Tabs, deren Prüf-Anlass während einer bereits laufenden Inspektion
    /// eintraf. Ohne dieses Gedächtnis ginge ein ausdrücklicher Check (etwa
    /// nach einem Hex-Schreibvorgang) einfach verloren: Die laufende
    /// Inspektion hat den alten Stand womöglich schon erfasst und meldet
    /// dann „nichts Neues“. Nach jeder Completion wird für gemerkte Tabs
    /// mit frischem Modellzustand erneut geprüft.
    private var pendingExternalCheckTabIDs: Set<UUID> = []
    /// Quellen, für die die Markdown-Hinweisleiste weggeklickt wurde. Nur für
    /// diese Sitzung — der Hinweis ist keine Einstellung, und der Menübefehl
    /// bleibt ohnehin erreichbar.
    @Published private var dismissedMarkdownImports: Set<URL> = []

    /// Stößt eine (asynchrone) Neuberechnung der Footer-Statistik an.
    /// - Parameters:
    ///   - fullText: Gesamter Editor-Inhalt.
    ///   - selectionNSRange: Selektion als `NSRange` (UTF-16-Offsets, wie
    ///     vom Editor geliefert) oder `nil`, wenn nur ein Cursor ohne
    ///     Auswahl steht → dann zählt die ganze Datei.
    func recomputeDocumentStats(fullText: String, selectionNSRange: NSRange?) {
        statsTask?.cancel()
        statsGeneration += 1
        let generation = statsGeneration
        let textSnapshot = fullText

        statsTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Ein Editoraufbau veröffentlicht mehrere eng benachbarte
            // Zustände. Erst den letzten zählen; `String` bleibt bis dahin
            // als unveränderlicher Copy-on-write-Snapshot geteilt.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }

            // NSRange (UTF-16) erst hier übersetzen. Vorher erzeugte schon
            // dieser Schritt auf dem UI-Thread eine vollständige Textkopie.
            let selectedRange: Range<String.Index>? = {
                guard let ns = selectionNSRange, ns.length > 0 else { return nil }
                return Range(ns, in: textSnapshot)
            }()
            let counts = if let selectedRange {
                DocumentStats.counts(of: textSnapshot[selectedRange])
            } else {
                DocumentStats.counts(of: textSnapshot)
            }
            guard !Task.isCancelled else { return }
            let formatted = DocumentStats.format(counts)
            let isSelection = selectedRange != nil

            await MainActor.run { [weak self] in
                guard let self, generation == self.statsGeneration else { return }
                self.documentStatsText = formatted
                self.statsIsSelection = isSelection
                self.statsTask = nil
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
    /// Nach Einzel-Ersetzen im Geöffnet-Scope liefert erst der asynchrone
    /// Suchlauf die neue flache Trefferliste. Bis dahin merken wir uns den
    /// gewünschten Nachrück-Index samt Suchoptionen; nur ein Lauf mit genau
    /// denselben Optionen darf anschließend dorthin springen.
    private var pendingOpenReplaceNavigation: (options: SearchOptions, index: Int)?

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
    /// Eigene Dateischreibvorgänge verlangen einen neuen, ausdrücklich gestarteten Lauf.
    @Published var folderResultsAreStale = false

    var waitingForShortFolderSearch: Bool {
        scope.isFolderLike && folderNeedsSearch && !folderSearching
            && !findPattern.isEmpty && !activeMultiFileSearchURLs.isEmpty
            && searchError == nil && !folderResultsAreStale
            && !SearchRunner.shouldRunFolderLive(for: findPattern)
    }
    /// `true`, wenn der letzte Ordner-Such-Lauf durch den Gesamt-Cap
    /// (`FolderSearch.find maxTotalMatches`) vorzeitig abgebrochen wurde.
    /// Die Maske zeigt dann einen dezenten Hinweis-Streifen, damit der
    /// Nutzer NICHT still-trunkierte Ergebnisse für vollständig hält.
    @Published var folderResultsWereCapped: Bool = false
    /// Verständlicher Hinweis nach einem abgewiesenen Treffer-Sprung. Das ist
    /// kein Syntaxfehler und sperrt deshalb den erneuten Suchlauf nicht.
    @Published var folderNavigationNotice: String? = nil
    /// Planung/Backup/Apply einer bestätigten Ordner-Vorschau laufen im
    /// Hintergrund. Der Suchdialog zeigt Status und eine Abbruchaktion.
    @Published var folderApplying: Bool = false
    @Published var folderApplyProgressText: String? = nil
    private var folderApplyTask: Task<Void, Never>?
    private var folderApplyGeneration = 0
    private var folderApplyMutationOperation: FolderApplyMutationOperation?
    private var hexSaveMutationOperations: [UUID: HexSaveMutationOperation] = [:]

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

    /// Die Suchoptionen, zu denen die aktuell SICHTBAREN Treffer der Datei-
    /// und Geöffnet-Suche gehören. `nil` heißt: Es gibt gerade keine gültige
    /// Vorschau — eine Eingabe hat sich geändert und der neue Lauf ist noch
    /// nicht fertig.
    ///
    /// Warum ein eigenes Feld: „Alle ersetzen" rechnet die Ersetzung frisch
    /// aus `currentSearchOptions`, benutzt als Freigabe aber nur die
    /// Trefferzahl der Vorschau. Zwischen einem Tastendruck und dem 120 ms
    /// später laufenden Neu-Suchen gehörten beide zu VERSCHIEDENEN Mustern:
    /// Die alte sichtbare Trefferzahl gab eine Ersetzung frei, die mit dem
    /// neuen Muster gerechnet wurde — eine Änderung ohne je gezeigte
    /// Vorschau (Review 2026-08-02). Der Ordner-Scope prüft dasselbe schon
    /// länger über `result.searchOptions == options` in `applyAllInFolder`.
    ///
    /// Bewusst NICHT `@Published`: Das Feld steuert nur die Freigabe, keine
    /// Anzeige — jede Änderung würde sonst die gesamte Maske neu zeichnen.
    var visibleBufferResultsOptions: SearchOptions?

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
    /// Dieselbe Suite zum Lesen für Wege außerhalb des Workspace — die
    /// Druckeinstellungen etwa müssen im Selbsttest aus der isolierten Suite
    /// kommen und nicht aus `.standard` (siehe `DocumentPrinting`).
    var preferencesStore: UserDefaults { defaultsStore }
    /// Was eine seitenweise Ansicht gerade zeigt (Hex-Abzug, Abschnitt einer
    /// großen Textdatei). Nur diese Ansicht kennt ihren geladenen Abschnitt,
    /// und genau er ist die Druckvorlage.
    ///
    /// Bewusst KEIN `@Published`: Der Wert dient allein dem Drucken und darf
    /// keinen Neuaufbau der Oberfläche auslösen.
    var visiblePrintPage: VisiblePrintPage?
    /// Das geladene Objekt der Bild-/PDF-Vorschau — die Druckvorlage dieser
    /// Ansichten. Gedruckt wird genau dieses Objekt, nie ein Neuladen von der
    /// Platte (siehe `VisiblePreviewSnapshot`). Bewusst KEIN `@Published`,
    /// gleiche Begründung wie `visiblePrintPage`.
    var visiblePreviewSnapshot: VisiblePreviewSnapshot?
    /// Gemeinsame Quelle für formatspezifischen Soft Wrap. Der Store ist
    /// injizierbar und bleibt dadurch mit isolierten Defaults unit-testbar.
    let softWrapProfiles: SoftWrapProfileStore
    /// Gemerkte manuelle Formatwahl je Datei (Sprach-Chip in der Fußzeile).
    let languageChoices: LanguageChoiceStore
    let gitPreferencesStore: GitPreferencesStore
    let gitOperationsCoordinator: GitOperationsCoordinator
    let gitRepositoryStore: GitRepositoryStore
    private var gitRepositoryObservation: GitRepositoryObservation?
    private let gitRepositoryIdentityResolver: GitRepositoryIdentityResolving?
    private let gitAutoFetchController: GitAutoFetchController?
    private let terminalOpener: TerminalOpening
    private let terminalDirectoryResolver: TerminalDirectoryResolving
    private let gitPreviewLoads = GitPreviewLoads()
    /// Laufender Verlaufs-Lauf EINER Datei plus seine Generation. Eine
    /// überholte Antwort darf die inzwischen gewählte Datei nicht überschreiben.
    private var gitFileHistoryLease: GitOperationLease?
    private var gitFileHistoryGeneration: UInt64 = 0
    private var gitIdentityResolution: GitCancelling?
    /// Reiner Anzeige-Refresh der Remote-Flächen. Er darf eine bereits vom
    /// Nutzer gestartete Push-Prüfung nicht abbrechen.
    var gitPushTargetInspection: GitCancelling?
    /// Nur die jüngste Anzeige-Auflösung darf publizieren. `cancel()` reicht
    /// nicht, wenn eine ältere Completion bereits auf der Main-Queue liegt.
    var gitPushTargetInspectionRequestID: UUID?
    /// Zielauflösung innerhalb einer aktiven Push-Prüfung, getrennt vom
    /// nebenläufig möglichen Anzeige-Refresh.
    var gitPushActionTargetInspection: GitCancelling?
    /// Eigene Config-Auflösung für einen manuellen Fetch. Remote-Tracking-Refs
    /// sind vor dem ersten Fetch absichtlich noch leer und daher keine Quelle
    /// für die tatsächlich konfigurierten Remote-Namen.
    var gitFetchRemoteInspection: GitCancelling?
    var gitFetchRemoteInspectionRequestID: UUID?
    var gitOperationStateInspection: GitCancelling?
    var gitIdentityInspection: GitCancelling?
    var gitConflictInspectionLease: GitCancelling?
    var gitConflictInspectionRequestIDs: [Data: UUID] = [:]
    private var gitAutoFetchObservation: GitRepositoryObservation?
    /// Fensterlokaler Besitzer von Watcher, Scan und Debounce des 4D-Indexes.
    /// Projekt-URL und Generation bleiben dagegen Quellen des Workspace.
    private let fourDProjectIndexController = FourDProjectIndexController()
    /// Erhöht sich bei jedem Projektwechsel. Asynchrone Aktionsketten binden
    /// sich an diesen Wert und können nie in ein später geöffnetes Repo laufen.
    private(set) var projectGeneration: UInt64 = 0
    /// Bindet einen asynchronen Sitzungs-Restore an den Zustand, in dem er
    /// gestartet wurde. Ein späterer Nutzer-Projektwechsel entwertet seine
    /// Abschlussaktion, bevor sie Tabs oder Projektkontext zurücksetzen kann.
    var sessionRestoreGeneration: UInt64 = 0
    /// Zählt hoch, sobald ein gezielter Sprung in DIESEM Fenster scrollt.
    /// Die laufende Ausschnitt-Wiederherstellung dieses Fensters erkennt
    /// daran, dass sie überholt wurde (`EditorView.restoreScrollOffset`).
    /// Bewusst je Workspace statt prozessweit (Review 2026-08-02).
    var scrollRestoreGeneration = 0

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
    /// Swift-Testing erzeugt Workspaces parallel, und jede Erzeugung setzt
    /// diesen Wert. Eine schwache Referenz darf nicht gleichzeitig aus zwei
    /// Threads überschrieben werden, sonst geben beide dieselbe alte Referenz
    /// frei (beobachtet am 2026-07-26 als SIGSEGV). Der Zugriff läuft deshalb
    /// über ein kurz gehaltenes Lock — wie bei `liveWorkspaces`.
    private static weak var sharedStorage: Workspace?
    private static let sharedLock = NSLock()

    static var shared: Workspace? {
        get { sharedLock.withLock { sharedStorage } }
        set {
            sharedLock.withLock { sharedStorage = newValue }
            // Die Kontextaktivierung liest den Wert ERNEUT aus dem Storage
            // und läuft immer auf dem Main-Thread. Vorher konnte eine späte
            // Aktivierung mit ihrem alten, festgehaltenen Wert eine neuere
            // überholen — Storage und Kontext zeigten dann dauerhaft auf
            // verschiedene Workspaces (Review 2026-08-02). Durch das erneute
            // Lesen konvergiert der Kontext stets auf den letzten Write.
            // (Direkt über den Lock statt über den Getter: Der Fenster-Audit
            // erlaubt `Workspace.shared`-Lesezugriffe nur in CommandTargeting;
            // HIER ist der Zugriff Teil des Setters selbst.)
            if Thread.isMainThread {
                ActiveDocumentContext.shared.activate(sharedLock.withLock { sharedStorage })
            } else {
                DispatchQueue.main.async {
                    ActiveDocumentContext.shared.activate(sharedLock.withLock { sharedStorage })
                }
            }
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
         externalChangeInspector: ExternalChangeInspector = ExternalChangeInspector(),
         documentLanguageDetector: DocumentLanguageDetector? = nil,
         resolveProjectContext: @escaping ProjectContextResolver = {
             Workspace.existingProjectContextTarget(for: $0, currentProject: $1)
         },
         scheduleProjectContextWork: @escaping ProjectContextScheduler = {
             DispatchQueue.global(qos: .userInitiated).async(execute: $0)
         },
         deliverProjectContextResult: @escaping ProjectContextScheduler = {
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
        self.languageChoices = LanguageChoiceStore(defaults: defaults)
        self.gitPreferencesStore = GitPreferencesStore(defaults: defaults)
        self.gitOperationsCoordinator = gitOperationsCoordinator
        self.terminalOpener = terminalOpener
        self.terminalDirectoryResolver = terminalDirectoryResolver
        self.externalChangeInspector = externalChangeInspector
        self.documentLanguageDetector = documentLanguageDetector
            ?? DocumentLanguageDetector()
        self.resolveProjectContext = resolveProjectContext
        self.scheduleProjectContextWork = scheduleProjectContextWork
        self.deliverProjectContextResult = deliverProjectContextResult
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
        // mit einem leeren unbenannten Tab, über dem der erklärende
        // Willkommens-Platzhalter liegt. Ein automatisch geöffnetes
        // Musterdokument wirkt wie eine fremde Datei und untergräbt bei einem
        // lokalen Editor das Vertrauen in die Herkunft der angezeigten Daten.
        let scratch = Workspace.makeScratchTab()
        self.tabs = [scratch]
        self.hexSavePreviewRequestTabID = nil
        self.activeTabID = scratch.id
        self.findPattern = ""
        self.replacePattern = ""
        // Combine legt das Verlags-Objekt hinter jedem @Published-Feld erst
        // beim ersten Zugriff an und tauscht dabei UNGESCHÜTZT den internen
        // Feldspeicher aus. Ab der nächsten Zeile entkommt `self` anderen
        // Threads: Der SearchRunner schickt sein initiales `rerun()` auf die
        // Main-Queue (die dort viele @Published-Felder liest UND schreibt),
        // und `Workspace.shared` stößt die Kontextaktivierung an, deren
        // objectWillChange-Getter ALLE Felder einzeln verdrahtet. Die
        // parallele Testsuite erzeugt Workspaces auf eigenen Threads —
        // Main- und Erzeuger-Thread konvertierten dann denselben Speicher
        // gleichzeitig, beobachtet am 2026-08-09 als SIGSEGV/Heap-Korruption
        // (os_unfair_lock auf NULL in PublishedSubject, Müll-Adressen in
        // deinit und Subject-Sends). Der eine Getter-Aufruf hier erledigt
        // die komplette Anlage, solange NUR dieser Thread das Objekt kennt;
        // danach sind alle @Published-Zugriffe durch Combines interne
        // Verriegelung gedeckt. MUSS vor der SearchRunner-Erzeugung stehen.
        // (Regressionstest: WorkspaceParallelStressTests.)
        _ = objectWillChange
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

    deinit {
        // Zusätzliche Dokumentfenster geben ihren Workspace beim Schließen
        // frei. Ein noch rechnender Makro-Task darf diese Lebenszeit nicht
        // überdauern; `Task.cancel()` ist threadsicher und fasst kein UI an.
        fourDMacroPostprocessTask?.cancel()
    }

    var activeTab: EditorTab? {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs.first
    }

    var activeDocumentID: UUID? { activeTab?.documentID }

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

    /// Kanonischer Typ für Formatieren/Minifizieren. Eine bewusste manuelle
    /// Formatwahl gewinnt vor der Endung; „Reiner Text“ auf einer `.json`
    /// schaltet die JSON-Befehle daher ebenso bewusst aus wie „JSON“ auf einer
    /// `.txt` sie einschaltet.
    var activeDocumentFormattingID: DocumentFormatID? {
        guard let tab = activeTab, textEditingIsAllowed(for: tab) else { return nil }
        let formatID = activeDocumentFormat.id
        return DocumentFormatter.supports(formatID: formatID) ? formatID : nil
    }

    /// Effektiver Prüfmodus, aber nur bei einem wirklich editierbaren,
    /// vollständig geladenen Textdokument. Damit versprechen Menü und
    /// Kontextmenü keine Aktion in Git-Vorversionen ohne Editorinstanz.
    var activeDocumentLintMode: DocumentLintMode? {
        guard let tab = activeTab, textEditingIsAllowed(for: tab) else { return nil }
        return DocumentLintMode.resolve(tab: tab)
    }

    /// Zeigt der aktive Tab ein Markdown-Dokument? Gemeinsame Antwort für
    /// Vorschau, Toolbar, Bild-Drop, Tab-Leiste und Markdown-Menü — alle
    /// folgen damit derselben Formatwahl wie der Sprach-Chip in der Fußzeile.
    var activeTabIsMarkdown: Bool {
        // Git-Verlauf und Dateivergleiche sind read-only Sonderansichten und
        // bekommen keine Markdown-Werkzeuge, auch wenn ihr Inhalt Markdown ist.
        guard let tab = activeTab, tab.gitKind == nil,
              tab.fileDiffRequest == nil else { return false }
        return MarkdownFormat.isMarkdown(format: activeDocumentFormat)
    }

    /// Gespeicherte Formatwahl für das aktive effektive Dokumentformat.
    var configuredSoftWrapEnabled: Bool {
        softWrapProfiles.isEnabled(for: activeDocumentFormat.id)
    }

    var softWrapEnabled: Bool {
        configuredSoftWrapEnabled
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

    // MARK: - Einrückungsprofil (Etappe 4, Beschluss 2026-07-19)

    /// Das wirksame Einrückungsprofil des aktiven Formats. Return/Tab
    /// (CESE-`indentOption`), Shift-Links/Rechts, Entab/Detab und
    /// „Einfügen und Einrückung angleichen" verwenden alle dieses Profil.
    var activeIndentationProfile: IndentationProfile {
        softWrapProfiles.indentationProfile(for: activeDocumentFormat.id)
    }

    func setIndentUsesTabs(_ usesTabs: Bool) {
        softWrapProfiles.setIndentUsesTabs(usesTabs, for: activeDocumentFormat.id)
    }

    func setIndentWidth(_ width: Int) {
        // Eine Breitenwahl ist zugleich die Entscheidung für Leerzeichen.
        softWrapProfiles.setIndentUsesTabs(false, for: activeDocumentFormat.id)
        softWrapProfiles.setIndentWidth(width, for: activeDocumentFormat.id)
    }

    func setEditorTabWidth(_ width: Int) {
        softWrapProfiles.setTabWidth(width, for: activeDocumentFormat.id)
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

    /// Erzeugt den frischen unbenannten Start-Tab. Eine gemeinsame Fabrik
    /// verhindert, dass Start, Home und Restore-Fallback unterschiedliche
    /// Varianten anlegen. Der Tab ist ein ganz normales leeres Dokument —
    /// solange er unberührt ist (`isPristineScratch`), liegt der
    /// Willkommens-Platzhalter über seiner Editorfläche.
    static func makeScratchTab() -> EditorTab {
        EditorTab(
            title: Workspace.untitledBaseName,
            path: L10n.string("noch nicht gespeichert")
        )
    }

    /// `true`, wenn dieses Fenster gerade den Willkommens-Platzhalter zeigt —
    /// nämlich genau dann, wenn der AKTIVE Tab ein unberührter leerer Tab ist
    /// (oder ausnahmsweise gar kein Tab existiert). Fenstertitel
    /// (Version+Datum statt Dateiname), Home-Symbol, Fußzeile und das
    /// Editor-Overlay greifen auf dieselbe Wahrheit zu.
    var isWelcomeScreen: Bool {
        WelcomeLogic.shouldShow(activeTab: activeTab)
    }

    /// Setzt dieses Fenster ohne Zwischenzustand auf genau einen frischen
    /// unbenannten Tab zurück (der den Willkommens-Platzhalter zeigt). Der
    /// Aufrufer muss ungesicherte Inhalte vorher geklärt haben. Restore darf
    /// denselben sicheren Fallback verwenden, wenn sämtliche gespeicherten
    /// Dateien während des asynchronen Ladens verschwinden.
    func enterWelcomeState() {
        cancelFourDMacroPostprocessing()
        showSearchDialog = false
        livePreview = false
        showCompareFilesDialog = false
        compareDialogPrefillTabIDs = []
        comparisonTabID = nil

        // Ein Home-Wechsel darf weder alte Projektbeobachter noch später
        // eintreffende Datei-Ladevorgänge in den neuen Zustand hineintragen.
        closeProject()
        loadGeneration.removeAll()
        documentLanguageDetector.cancelAll()

        let scratch = Self.makeScratchTab()
        hexSavePreviewRequestTabID = nil
        tabs = [scratch]
        activeTabID = scratch.id
        cursorLine = nil
        cursorColumn = nil
        selectionRange = nil
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
                guard self.textEditingIsAllowed(for: self.tabs[idx]) else { return }
                if self.tabs[idx].content != newValue {
                    let tabID = self.tabs[idx].id
                    let needsLanguageLengths = Self.isEligibleForContentDetection(
                        self.tabs[idx]
                    )
                    // Gespeicherte Dateien wie die betroffene `.txt` nehmen
                    // nicht an der Inhaltserkennung teil. Für sie vermeiden
                    // wir deshalb auch das lineare `String.count` bei jedem
                    // Tastendruck auf einer mehrere MiB großen Datei.
                    let oldLanguageLength = needsLanguageLengths
                        ? self.tabs[idx].content.count : 0
                    // Die erste echte Eingabe macht aus dem flüchtigen
                    // Quick-Look-Tab ein dauerhaftes Dokument. Sonst könnte
                    // der nächste einfache Klick ungesicherte Arbeit ersetzen.
                    self.tabs[idx].isPreview = false
                    self.tabs[idx].content = newValue
                    // Eine Inhaltsänderung entwertet die Lease der gesamten
                    // Makro-Nachbearbeitung (Rücktokenisierung und Diff).
                    self.cancelFourDMacroPostprocessing(ifTab: tabID)
                    // Punkt im Tab folgt dem Vergleich mit dem gespeicherten
                    // Stand: Er erscheint bei der ersten echten Abweichung und
                    // verschwindet wieder, wenn z. B. Rückgängig den Inhalt
                    // exakt zurückführt (VS-Code-/BBEdit-Verhalten).
                    let matchesSaved = self.tabs[idx].matchesSavedContentBaseline
                    if self.tabs[idx].isDirty {
                        if matchesSaved {
                            self.tabs[idx].isDirty = false
                        }
                    } else if !matchesSaved {
                        self.tabs[idx].isDirty = true
                    }
                    // Inhaltsbasierte Spracherkennung (Etappe 3): reagiert
                    // nur bei geeigneten Tabs; Block-Einfügungen sofort,
                    // Tippen debounced. Kostet hier nur den Längenvergleich.
                    if needsLanguageLengths {
                        self.scheduleLanguageDetection(
                            tabID: tabID,
                            oldLength: oldLanguageLength,
                            newLength: newValue.count
                        )
                    }
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
        // Anders als ein globaler `activeTabID.didSet` läuft dieser Hook erst
        // nach einer endgültigen Nutzerauswahl. Ein Save-Dialog darf Tabs für
        // seine Rückfrage vorübergehend aktivieren, ohne im modalen Runloop
        // Projekt- und Git-Watcher umzuschalten.
        synchronizeProjectWithActiveTabIfNeeded()
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
        // Der neue Tab verliert absichtlich die Datei-URL, aber nicht den
        // räumlichen Kontext: Sein erster Save-Dialog beginnt im Ordner des
        // Dokuments, das unmittelbar vor ⌘T aktiv war. Bei einer Kette neuer
        // Tabs wird derselbe Hinweis weitergereicht.
        let initialSaveDirectory = activeTab?.url?.deletingLastPathComponent()
            ?? activeTab?.initialSaveDirectory
        let new = EditorTab(
            title: Workspace.untitledName(position: tabs.count + 1),
            path: "—",
            initialSaveDirectory: initialSaveDirectory,
            content: ""
        )
        tabs.append(new)
        activeTabID = new.id
        // Der neue Tab ist selbst ein unberührter leerer Tab → wie in Firefox
        // zeigt auch ER den Willkommens-Platzhalter, bis das erste Zeichen
        // getippt ist (Daniel-Entscheidung 2026-07-30). Nachbartabs bleiben
        // unangetastet.
    }

    /// BBEdit-Stil-Rückfrage beim Schließen eines Tabs mit ungespeicherten
    /// Änderungen: Sichern / Nicht sichern / Abbrechen. Standardmäßig ein echter
    /// `NSAlert`; in Tests injizierbar (kein Modal), damit der Schließen-Pfad
    /// prüfbar bleibt. Bekommt den Tab-Titel, liefert die Nutzer-Entscheidung.
    var confirmCloseHandler: (String) -> CloseConfirmation = Workspace.defaultCloseConfirmation
    /// Hex-Änderungen brauchen vor jedem Schreiben ihre eigene sichtbare
    /// Vorschau. „Änderungen prüfen" führt deshalb zurück in diesen Ablauf,
    /// statt den großen Dateischreibvorgang im modalen Schließen-Hook auf dem
    /// Main-Thread auszuführen.
    var confirmHexCloseHandler: (String) -> CloseConfirmation =
        Workspace.defaultHexCloseConfirmation

    /// Schließt das Dokumentfenster, nachdem der letzte Tab erfolgreich
    /// aufgelöst wurde. Die echte App setzt den Handler über
    /// `MainWindowTitleBridge`; Tests injizieren eine Zähl-Closure. Optional,
    /// damit reine Workspace-Tests auch ohne NSWindow funktionieren.
    var closeWindowHandler: (() -> Void)?

    /// Erste, folgenlose Sicherheitsstufe des Home-Buttons. Nur wenn wirklich
    /// ungesicherte Inhalte vorhanden sind, bestätigt der Nutzer zunächst den
    /// gesamten Wechsel, bevor einzelne Save-Dialoge erscheinen.
    var confirmReturnToWelcomeHandler: () -> Bool = Workspace.defaultReturnToWelcomeConfirmation

    /// Zweite Stufe des Home-Buttons: Jeder geänderte Tab muss gesichert oder
    /// der gesamte Wechsel abgebrochen werden. Anders als beim expliziten
    /// Tab-Schließen gibt es hier bewusst kein „Nicht sichern".
    var confirmSaveForWelcomeHandler: (String) -> Bool = Workspace.defaultSaveForWelcomeConfirmation

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

    static func defaultHexCloseConfirmation(_ title: String) -> CloseConfirmation {
        let alert = NSAlert()
        alert.messageText = L10n.format("Hex-Änderungen an „%@“ prüfen?", title)
        alert.informativeText = L10n.string("Fastra schreibt Byteänderungen erst nach der sichtbaren Vorschau und einer weiteren Bestätigung. „Änderungen prüfen“ lässt das Dokument offen und öffnet diese Vorschau.")
        alert.addButton(withTitle: L10n.string("Änderungen prüfen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        alert.addButton(withTitle: L10n.string("Nicht sichern"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default:                      return .cancel
        }
    }

    static func defaultReturnToWelcomeConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string("Zum Willkommensbildschirm zurückkehren?")
        alert.informativeText = L10n.string("Dabei werden das aktuelle Projekt oder der geöffnete Ordner und alle Tabs geschlossen. Ungesicherte Dateien müssen anschließend einzeln gesichert werden.")
        alert.addButton(withTitle: L10n.string("Projekt schließen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func defaultSaveForWelcomeConfirmation(_ title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.format("Möchten Sie die Änderungen an „%@“ sichern?", title)
        alert.informativeText = L10n.string("Zum Willkommensbildschirm kann erst gewechselt werden, nachdem die Datei gesichert wurde.")
        alert.addButton(withTitle: L10n.string("Sichern"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Entspricht der Verlustprüfung des normalen Schließen-Pfads. Ein leerer,
    /// unbenannter Tab enthält auch dann nichts zu sichern, wenn er nach
    /// Tippen und Löschen technisch noch als geändert markiert ist.
    private static func requiresSaveBeforeClosing(_ tab: EditorTab) -> Bool {
        let isEmptyUntitled = tab.url == nil && tab.content.isEmpty
        return tab.hexEditSession.hasChanges || (tab.isDirty && !isEmptyUntitled)
    }

    /// Braucht dieser Workspace beim Schließen mindestens eine Rückfrage?
    /// Der Beenden-Pfad nutzt exakt dieselbe Verlustprüfung wie `mayCloseTab`,
    /// damit er nur dann das zugehörige Fenster nach vorn holt.
    var hasTabsRequiringSaveBeforeClosing: Bool {
        tabs.contains(where: Self.requiresSaveBeforeClosing)
    }

    /// Vorschau und laufender Schreibauftrag sind die Fortsetzung der Aktion
    /// am betroffenen Dokument. Aufrufer dürfen dann nicht zum zuvor aktiven
    /// Hintergrund-Tab zurückspringen.
    private func keepsHexTabVisibleAfterBlockedClose(_ id: UUID) -> Bool {
        hexSavePreviewRequestTabID == id
            || tabs.first(where: { $0.id == id })?.hexEditSession.isSaving == true
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
        guard Self.requiresSaveBeforeClosing(tab) else {
            return true
        }
        // Den Tab, um den es geht, VOR der Rückfrage nach vorn holen. Sonst
        // nennt der Dialog einen Dateinamen, während im Fenster ein ganz
        // anderer Tab steht: Der Nutzer kann nicht nachsehen, worüber er
        // gerade entscheidet, und „Nicht sichern" wird zum Blindflug
        // (Fehlerbericht 2026-08-07). Der `.save`-Zweig brauchte diese
        // Aktivierung ohnehin — jetzt gilt sie für alle drei Antworten.
        // Die Aufrufer stellen den ursprünglich aktiven Tab am Ende wieder her.
        activeTabID = id
        // Ein bereits bestätigter Schreibvorgang läuft weiter. Währenddessen
        // darf weder „Nicht sichern“ den Tab entfernen noch ein zweiter
        // Speicher- oder Reload-Pfad denselben Zustand übernehmen.
        guard !tab.hexEditSession.isSaving else { return false }
        let decision = tab.hexEditSession.hasChanges
            ? confirmHexCloseHandler(tab.title)
            : confirmCloseHandler(tab.title)
        switch decision {
        case .dontSave:
            return true
        case .cancel:
            return false
        case .save:
            if tab.hexEditSession.hasChanges {
                requestHexSavePreview(for: id)
                return false
            }
            saveActiveTab()
            // Erfolg = der Tab ist jetzt nicht mehr dirty (Panel/Schreiben ok).
            if let i = tabs.firstIndex(where: { $0.id == id }) {
                return !tabs[i].hasUnsavedChanges
            }
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
            // Ist die Fensterbrücke ausnahmsweise noch nicht gebunden, darf
            // der Workspace nicht als sichtbarer Null-Tab-Rahmen zurückbleiben.
            // Nach derselben Save-Entscheidung fällt er sicher auf Willkommen
            // zurück; mit echter Fensterbrücke bleibt das bisherige Schließen.
            guard let closeWindow = closeWindowHandler else {
                guard mayCloseTab(id: id) else { return }
                enterWelcomeState()
                return
            }
            guard prepareToCloseWindow() else { return }
            closeWindow()
            return
        }

        let previousActive = activeTabID
        guard mayCloseTab(id: id) else {
            // „Änderungen prüfen“ ist kein Abbruch: Der angeforderte Hex-Tab
            // muss sichtbar bleiben, damit seine Vorschau erscheinen kann.
            // Nur ein echter Abbruch stellt den zuvor aktiven Tab wieder her.
            if !keepsHexTabVisibleAfterBlockedClose(id),
               let previousActive,
               tabs.contains(where: { $0.id == previousActive }) {
                activeTabID = previousActive
            }
            return                                          // Abbrechen → Tab bleibt
        }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        previewLoadCancellations.removeValue(forKey: id)?.cancel()
        loadGeneration.removeValue(forKey: id)
        documentLanguageDetector.cancel(tabID: id, documentID: tabs[idx].documentID)
        gitPreviewLoads.cancel(tabID: id)
        // Ein geschlossener Tab kann die Lease einer laufenden
        // Makro-Nachbearbeitung nie wieder erfüllen.
        cancelFourDMacroPostprocessing(ifTab: id)
        if hexSavePreviewRequestTabID == id { hexSavePreviewRequestTabID = nil }
        tabs.remove(at: idx)
        recentlyActiveTabIDs.removeAll { $0 == id }
        if comparisonTabID == id {
            comparisonTabID = nil
        }
        // Aktiven Tab konsistent halten: war ein ANDERER Tab aktiv und existiert
        // noch, bleibt er aktiv (mayCloseTab kann activeTabID fürs Sichern kurz
        // umgesetzt haben); sonst übernimmt der zuletzt benutzte Tab.
        if let prev = previousActive, prev != id, tabs.contains(where: { $0.id == prev }) {
            activeTabID = prev
        } else {
            activeTabID = nextActiveTabAfterClosing(removedIndex: idx)
        }
        synchronizeProjectWithActiveTabIfNeeded()
    }

    func closeActiveTab() {
        guard let id = activeTabID else { return }
        closeTab(id: id)
    }

    /// Nachfolger des soeben geschlossenen AKTIVEN Tabs: zuerst der zuletzt
    /// benutzte noch offene Tab (wie BBEdit und Safari), erst wenn die
    /// Merkliste nichts mehr hergibt der Nachbar an der bisherigen Position
    /// (der Tab rechts davon, am Leistenende der links davon).
    private func nextActiveTabAfterClosing(removedIndex idx: Int) -> UUID? {
        if let recent = recentlyActiveTabIDs.first(where: { candidate in
            tabs.contains(where: { $0.id == candidate })
        }) {
            return recent
        }
        if tabs.indices.contains(idx) { return tabs[idx].id }
        return tabs.last?.id
    }

    /// Löst alle Tabs eines zu schließenden Dokumentfensters nach denselben
    /// Regeln wie ⌘W auf und entfernt sie erst, wenn keine Entscheidung mehr
    /// offen ist. Wird auch vom roten Schließen-Knopf zusätzlicher Fenster
    /// verwendet. `false` bedeutet: Nutzer hat abgebrochen, Fenster bleibt.
    func prepareToCloseWindow() -> Bool {
        guard !folderApplying else { return false }
        let previousActive = activeTabID
        for id in tabs.map(\.id) {
            guard mayCloseTab(id: id) else {
                // Die Hex-Vorschau ist die Fortsetzung der gewählten
                // Speicheraktion, kein Abbruch. Sie muss den betroffenen Tab
                // sichtbar lassen; nur „Abbrechen“ stellt den alten Tab her.
                if !keepsHexTabVisibleAfterBlockedClose(id),
                   let previousActive,
                   tabs.contains(where: { $0.id == previousActive }) {
                    activeTabID = previousActive
                }
                return false
            }
        }
        gitPreviewLoads.cancelAll()
        cancelAllPreviewLoads()
        cancelFourDMacroPostprocessing()
        hexSavePreviewRequestTabID = nil
        tabs.removeAll()
        recentlyActiveTabIDs.removeAll()
        activeTabID = nil
        // Das Fenster schließt gleich — der Workspace kann es aber überleben:
        // SwiftUI hält die Szene des Hauptfensters samt Workspace am Leben,
        // und macOS kann dieselbe Szene später wieder anzeigen (Dock-Klick).
        // Bliebe es beim leeren Tab-Array, stünde dann ein Fenster ganz ohne
        // Tabs da, dessen Editorfläche sich tippen lässt, aber nirgendwohin
        // schreibt (vermutete Ursache von Daniels leerem Startfenster,
        // 2026-07-29). Deshalb sofort in den definierten Willkommens-Zustand
        // zurückkehren; im wirklich schließenden Fenster ist das unsichtbar.
        enterWelcomeState()
        return true
    }

    /// Schließt alle Tabs außer dem mit `id` (BBEdit „Close Others", K8).
    /// Der behaltene Tab wird aktiv. Bei nur einem Tab no-op. Vor dem Schließen
    /// wird pro Tab mit ungespeicherten Änderungen gefragt; „Abbrechen" bricht die
    /// GESAMTE Aktion ab (es wird dann kein Tab geschlossen).
    func closeOtherTabs(keeping id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let previousActive = activeTabID
        for otherID in tabs.map(\.id) where otherID != id {
            guard mayCloseTab(id: otherID) else {
                if !keepsHexTabVisibleAfterBlockedClose(otherID),
                   let previousActive,
                   tabs.contains(where: { $0.id == previousActive }) {
                    activeTabID = previousActive
                }
                return                                      // Abbrechen → alles bleibt
            }
        }
        for removedID in tabs.map(\.id) where removedID != id {
            previewLoadCancellations.removeValue(forKey: removedID)?.cancel()
            loadGeneration.removeValue(forKey: removedID)
            if let removedTab = tabs.first(where: { $0.id == removedID }) {
                documentLanguageDetector.cancel(
                    tabID: removedID, documentID: removedTab.documentID
                )
            }
            gitPreviewLoads.cancel(tabID: removedID)
            cancelFourDMacroPostprocessing(ifTab: removedID)
        }
        if let requested = hexSavePreviewRequestTabID, requested != id {
            hexSavePreviewRequestTabID = nil
        }
        tabs.removeAll { $0.id != id }
        recentlyActiveTabIDs.removeAll { $0 != id }
        comparisonTabID = nil
        activeTabID = id
        synchronizeProjectWithActiveTabIfNeeded()
    }

    /// Vor dem App-Beenden (⌘Q): über JEDEN Tab mit ungespeicherten Änderungen die
    /// BBEdit-Rückfrage führen (Sichern / Nicht sichern / Abbrechen). Liefert
    /// `true`, wenn alle aufgelöst sind (gesichert oder bewusst verworfen) → die App
    /// darf enden; `false`, sobald der Nutzer einmal „Abbrechen" wählt oder ein
    /// „Sichern unter…" abbricht → Beenden abbrechen. Schließt KEINE Tabs (die App
    /// endet ohnehin) — entscheidend ist nur, dass nichts ungefragt verloren geht.
    /// Vom AppDelegate aus `applicationShouldTerminate` aufgerufen.
    func confirmCloseAllDirtyForQuit() -> Bool {
        guard !folderApplying else { return false }
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
                if !keepsHexTabVisibleAfterBlockedClose(id),
                   let prev = previousActive,
                   tabs.contains(where: { $0.id == prev }) {
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

    /// Home ist ein atomarer Workspace-Wechsel, kein Tab-Klick. Der erste
    /// Dialog bestätigt nur die Absicht und ändert noch gar nichts. Erst danach
    /// wird jeder betroffene Tab einzeln gesichert. Ein Abbruch lässt Projekt
    /// und Tabs offen; bereits ausdrücklich gespeicherte Dateien bleiben wie
    /// beim abgebrochenen App-Beenden gespeichert.
    @discardableResult
    func returnToWelcome() -> Bool {
        guard !folderApplying else { return false }
        if projectURL == nil, tabs.count == 1, tabs[0].isPristineScratch {
            return true
        }

        let dirtyIDs = tabs.filter(Self.requiresSaveBeforeClosing).map(\.id)
        guard dirtyIDs.isEmpty || confirmReturnToWelcomeHandler() else {
            return false
        }

        let previousActive = activeTabID
        for id in dirtyIDs {
            guard let index = tabs.firstIndex(where: { $0.id == id }),
                  Self.requiresSaveBeforeClosing(tabs[index]) else { continue }
            guard confirmSaveForWelcomeHandler(tabs[index].title) else {
                restoreActiveTab(afterCancelledWelcomeTransition: previousActive)
                return false
            }
            activeTabID = id
            if tabs[index].hexEditSession.hasChanges {
                requestHexSavePreview(for: id)
                return false
            }
            saveActiveTab()
            guard let savedIndex = tabs.firstIndex(where: { $0.id == id }),
                  !tabs[savedIndex].hasUnsavedChanges else {
                restoreActiveTab(afterCancelledWelcomeTransition: previousActive)
                return false
            }
        }

        enterWelcomeState()
        return true
    }

    private func restoreActiveTab(afterCancelledWelcomeTransition previous: UUID?) {
        if let previous, tabs.contains(where: { $0.id == previous }) {
            activeTabID = previous
        } else if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
        }
    }

    // MARK: - Zeilenenden umschalten (K7)

    /// Setzt die Zeilenende-Konvention des aktiven Tabs. Der Inhalt wird NICHT
    /// sofort umgeschrieben (das überlebte die CESE-Binding-Reconcile-Falle
    /// nicht) — stattdessen konvertiert `write` beim Speichern. Der Tab wird
    /// als geändert markiert, damit klar ist, dass Speichern nötig ist.
    func setActiveLineEnding(_ ending: LineEnding) {
        guard let idx = activeTabIndex,
              textEditingIsAllowed(for: tabs[idx]) else { return }
        guard tabs[idx].lineEnding != ending else { return }
        tabs[idx].lineEnding = ending
        tabs[idx].hexEditSession.invalidateHistory()
        // Zurückschalten auf das gespeicherte Zeilenende (bei unverändertem
        // Text) macht den Tab wieder sauber — wie eine rückgängig gemachte
        // Textänderung.
        tabs[idx].isDirty = !tabs[idx].matchesSavedContentBaseline
    }

    var canChangeActiveLineEnding: Bool {
        guard let tab = activeTab else { return false }
        return textEditingIsAllowed(for: tab)
    }

    func textEditingIsAllowed(for tab: EditorTab) -> Bool {
        tab.isEditableTextDocument && !fileMutationIsInFlight(for: tab.url)
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
        guard !tabs[idx].hexEditSession.isSaving,
              !fileMutationIsInFlight(for: url) else {
            NSSound.beep()
            return
        }
        if tabs[idx].hasUnsavedChanges {
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
                    // URL-Vergleich wie in `reloadTabFromDisk`: kein Inhalt
                    // des alten Pfads in einen umgebundenen Tab.
                    guard self.tabs[i].url == url,
                          self.tabs[i].contentRevision == originalRevision,
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
                    self.tabs[i].hexEditSession.discard()
                    self.tabs[i].isLoading  = false
                    self.tabs[i].diskSnapshot = loaded.diskSnapshot
                    self.tabs[i].recordExternalFileObservation(
                        snapshot: loaded.diskSnapshot,
                        observation: loaded.externalObservation,
                        contentLoaded: true
                    )
                    // Neuer Plattenstand = neue Basis für den Punkt im Tab.
                    self.tabs[i].recordSavedContentBaseline()
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
    /// „Automatically refresh documents"-Default). Der leichte `stat`-
    /// Fingerabdruck erkennt auch atomare Ersetzungen mit beibehaltenem oder
    /// älterem Änderungsdatum. Nur bei einer Abweichung werden die Bytes im
    /// Hintergrund gelesen, damit weder große Dateien noch falsche Alarme
    /// durch reine Metadatenänderungen den Main-Thread belasten.
    /// `only` beschränkt die Prüfung auf einen Tab — das nutzen die
    /// Nachprüfungen aus der Completion, damit sie nicht für alle Tabs
    /// neue Inspektionen anstoßen.
    func checkExternalChanges(only limitedTabID: UUID? = nil) {
        for tab in tabs {
            if let limitedTabID, tab.id != limitedTabID { continue }
            guard let url = tab.url, !tab.isLoading else { continue }
            guard !externalChangeInspector.isInspecting(tabID: tab.id) else {
                // Läuft schon eine Prüfung, darf dieser Anlass nicht
                // stillschweigend entfallen: Die laufende Inspektion kann
                // den soeben veränderten Stand bereits verpasst haben.
                pendingExternalCheckTabIDs.insert(tab.id)
                continue
            }
            // Auf dem Main-Thread nur Modellzustand einsammeln. Schon der
            // Platten-Fingerabdruck (`open`+`fstat`) kann auf getrennten oder
            // nicht reagierenden Datenträgern blockieren und entsteht deshalb
            // erst in der Hintergrundprüfung des Inspectors.
            let observedContent = tab.externalContentSnapshot ?? tab.diskSnapshot
            let request = ExternalChangeInspector.Request(
                tabID: tab.id,
                documentID: tab.documentID,
                url: url,
                knownObservation: tab.externalFileObservation,
                observedByteCount: observedContent?.byteCount,
                isDirty: tab.hasUnsavedChanges
            )
            externalChangeInspector.inspect(request) { [weak self] inspection in
                guard let self else { return }
                // Während der Prüfung eingegangene Anlässe jetzt nachholen —
                // unabhängig davon, ob dieses Ergebnis unten noch verwertbar
                // ist. Die Nachprüfung startet mit frischem Modellzustand.
                let rerunPending = self.pendingExternalCheckTabIDs
                    .remove(inspection.tabID) != nil
                defer {
                    if rerunPending {
                        self.checkExternalChanges(only: inspection.tabID)
                    }
                }
                guard let idx = self.tabs.firstIndex(where: {
                          $0.id == inspection.tabID
                              && $0.documentID == inspection.documentID
                      }),
                      !self.tabs[idx].isLoading,
                      // „Sichern unter" und Verschieben im Dateibaum wechseln
                      // die URL bei unveränderter Dokument-Identität. Ein
                      // Befund zum alten Pfad darf dann weder Dialog noch
                      // Reload am neu gebundenen Tab auslösen.
                      self.tabs[idx].url == inspection.url else {
                    return
                }

                // Ein verschwundener, unlesbarer oder nicht mehr regulärer
                // Pfad ist gerade bei einem zuvor sauberen Tab gefährlich:
                // Ohne Schutz könnte der Nutzer die letzte geladene Kopie
                // ohne Rückfrage schließen. Nur vollständige Textinhalte
                // werden dabei dirty; Hex-/Abschnittsansichten besitzen keine
                // speicherbare Vollfassung.
                guard let after = inspection.observation else {
                    self.tabs[idx].protectContentAfterExternalFileBecameUnavailable()
                    return
                }
                guard after != self.tabs[idx].externalFileObservation else { return }

                // Hat sich der Dirty-Zustand seit dem Start der Prüfung
                // geändert, passt die damalige Lese-Entscheidung nicht mehr
                // zum Tab: Eine sauber gestartete Prüfung hat z. B. keinen
                // Snapshot gelesen, den die Rückfrage eines inzwischen
                // dirty gewordenen Tabs aber bräuchte. Ergebnis verwerfen
                // und sofort mit dem aktuellen Zustand neu prüfen.
                guard inspection.wasDirty == self.tabs[idx].hasUnsavedChanges else {
                    // Läuft ohnehin gleich eine gemerkte Nachprüfung (defer
                    // oben), genügt die; sonst hier selbst neu anstoßen.
                    if !rerunPending {
                        self.checkExternalChanges(only: inspection.tabID)
                    }
                    return
                }

                let observedContent = self.tabs[idx].externalContentSnapshot
                    ?? self.tabs[idx].diskSnapshot
                if let observedContent, let stableSnapshot = inspection.stableSnapshot,
                   observedContent.hasSameContent(as: stableSnapshot) {
                    // Nur Metadaten oder Dateiidentität haben sich
                    // geändert. Das ist kein sichtbarer Fremdinhalt.
                    let wasUnavailable = self.tabs[idx].externalFileUnavailable
                    self.tabs[idx].recordExternalFileObservation(
                        snapshot: stableSnapshot,
                        observation: after
                    )
                    // Ein Schutzpunkt wegen vorübergehend verschwundener Datei
                    // darf nur dann wieder weg, wenn der Editorinhalt seitdem
                    // unverändert auf seiner gespeicherten Basis steht.
                    if wasUnavailable && self.tabs[idx].matchesSavedContentBaseline {
                        self.tabs[idx].isDirty = false
                    }
                    return
                }

                if self.tabs[idx].hasUnsavedChanges {
                    if self.externalReloadConfirmHandler(self.tabs[idx].title) {
                        self.reloadTabFromDisk(id: inspection.tabID)
                    } else {
                        // Die automatische Rückfrage gilt als beantwortet;
                        // `diskSnapshot` bleibt absichtlich alt, damit ein
                        // späteres Speichern weiterhin gesondert warnt.
                        self.tabs[idx].recordExternalFileObservation(
                            snapshot: inspection.stableSnapshot,
                            observation: after,
                            contentChangeAccepted: true
                        )
                    }
                } else {
                    self.reloadTabFromDisk(id: inspection.tabID)
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
        guard !tabs[idx].hexEditSession.isSaving,
              !fileMutationIsInFlight(for: url) else { NSSound.beep(); return }
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
                    // Der URL-Vergleich schützt gegen „Sichern unter" und
                    // Verschieben während des Ladens: Der Inhalt des alten
                    // Pfads darf nicht in den inzwischen umgebundenen Tab
                    // übernommen werden.
                    guard self.tabs[i].url == url,
                          self.tabs[i].contentRevision == originalRevision,
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
                    self.tabs[i].hexEditSession.discard()
                    self.tabs[i].isLoading  = false
                    self.tabs[i].diskSnapshot = loaded.diskSnapshot
                    self.tabs[i].recordExternalFileObservation(
                        snapshot: loaded.diskSnapshot,
                        observation: loaded.externalObservation,
                        contentLoaded: true
                    )
                    // Neuer Plattenstand = neue Basis für den Punkt im Tab.
                    self.tabs[i].recordSavedContentBaseline()
                case .failure:
                    // Datei nicht (mehr) lesbar → Tab-Inhalt behalten, kein
                    // Datenverlust; Spinner aus. Kein Alert im Auto-Pfad —
                    // ein App-Wechsel darf keine Modal-Kaskade auslösen.
                    self.tabs[i].isLoading = false
                    if self.tabs[i].url == url {
                        self.tabs[i].protectContentAfterExternalFileBecameUnavailable()
                    }
                }
            }
        }
    }

    /// Menü-Einstieg „Ablage → Von Festplatte neu laden" (BBEdit „Reload
    /// from Disk"): lädt den AKTIVEN Tab neu; dirty → gleiche Rückfrage
    /// wie die automatische Erkennung.
    func reloadActiveTabFromDisk() {
        guard let idx = activeTabIndex, let url = tabs[idx].url else {
            NSSound.beep()
            return
        }
        guard !tabs[idx].hexEditSession.isSaving,
              !fileMutationIsInFlight(for: url) else {
            NSSound.beep()
            return
        }
        if tabs[idx].hasUnsavedChanges,
           !externalReloadConfirmHandler(tabs[idx].title) { return }
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
        guard isDir.boolValue else {
            loadFile(at: url)
            return
        }
        // Ein Ordner OHNE Endung ist immer ein Projekt — der Normalfall bleibt
        // dadurch völlig unverzögert. Nur ein Ordner MIT Endung kann ein
        // Dokumentpaket wie `.rtfd` sein; erst dafür wird der Formatkatalog
        // befragt (aus dem Zwischenspeicher meist sofort).
        guard !url.pathExtension.isEmpty else {
            openProject(at: url)
            return
        }
        MarkdownImportService.shared.withCatalog { [weak self] catalog in
            guard let self else { return }
            // Bewusst auch NICHT verfügbare Formate erkennen: Fehlt nur das
            // Zusatzwerkzeug (meist pandoc), soll die Rückfrage das erklären,
            // statt das Dokumentpaket stillschweigend als Ordner zu öffnen
            // (Daniel-Befund 2026-07-29).
            guard let format = catalog?.format(forExtension: url.pathExtension),
                  format.isPackage else {
                self.openProject(at: url)
                return
            }
            switch Workspace.askMarkdownImportPackageChoice(for: url, format: format) {
            case .convert:      self.convertToMarkdown(url)
            case .openAsFolder: self.openProject(at: url)
            case .cancel:       break
            }
        }
    }

    /// Wie ein Dokumentpaket geöffnet werden soll.
    enum MarkdownImportPackageChoice {
        case convert
        case openAsFolder
        case cancel
    }

    /// Testhaken: ersetzt die Rückfrage. `nil` = echter Dialog. Nötig, weil ein
    /// modaler `NSAlert` einen fensterlosen Selbsttest anhalten würde.
    static var markdownImportPackageChoiceProvider:
        ((URL, MarkdownImportFormat) -> MarkdownImportPackageChoice)?

    /// Ein Dokumentpaket sieht im Finder aus wie ein Ordner. Fastra kann es
    /// nicht gleichzeitig als Ordner zeigen und umwandeln, deshalb ist hier —
    /// anders als bei einer Datei — eine echte Rückfrage nötig.
    ///
    /// Die Frage selbst kennt keinen Aufrufer-Kontext: Was „als Ordner öffnen"
    /// bedeutet, entscheidet die aufrufende Stelle (Projekt laden bzw. im
    /// Dateibaum aufklappen).
    static func askMarkdownImportPackageChoice(
        for url: URL,
        format: MarkdownImportFormat
    ) -> MarkdownImportPackageChoice {
        if let provider = markdownImportPackageChoiceProvider {
            return provider(url, format)
        }
        let alert = NSAlert()
        alert.messageText = L10n.format("„%@“ ist ein Dokument, kein Projektordner.",
                                        url.lastPathComponent)
        // Fehlt das Zusatzwerkzeug (meist pandoc), gibt es keinen
        // Umwandeln-Knopf, der ohnehin scheitern würde — stattdessen erklärt
        // der Dialog, was fehlt und wie man es bekommt (Daniel-Befund
        // 2026-07-29: vorher öffnete das Paket wortlos als Ordner).
        guard format.isAvailable else {
            alert.informativeText = [
                L10n.format(
                    "Fastra könnte das %@-Dokument in Markdown umwandeln, doch dafür fehlt gerade etwas.",
                    format.identifier.uppercased()
                ),
                markdownImportUnavailableExplanation(for: format),
            ].compactMap { $0 }.joined(separator: "\n\n")
            alert.addButton(withTitle: L10n.string("Als Ordner öffnen"))
            alert.addButton(withTitle: L10n.string("Abbrechen"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .openAsFolder
            default:                      return .cancel
            }
        }
        // Bewusst EIN Literal: Ein per `+` zusammengesetzter Text wäre kein
        // statisch erkennbarer Lokalisierungsschlüssel mehr.
        alert.informativeText = L10n.format(
            "Fastra kann das %@-Dokument in Markdown umwandeln und danach öffnen. Das Original bleibt unverändert.",
            format.identifier.uppercased()
        )
        alert.addButton(withTitle: L10n.string("In Markdown umwandeln"))
        alert.addButton(withTitle: L10n.string("Als Ordner öffnen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .convert
        case .alertSecondButtonReturn: return .openAsFolder
        default:                       return .cancel
        }
    }

    /// Erklärung in Nutzersprache, warum ein erkanntes Format gerade nicht
    /// umgewandelt werden kann — samt Installationshilfe, wenn das fehlende
    /// Werkzeug bekannt ist. Wird von Dialog UND Hinweisleiste benutzt.
    static func markdownImportUnavailableExplanation(
        for format: MarkdownImportFormat
    ) -> String? {
        let missing = format.missingTools
        guard !missing.isEmpty else {
            // Unbekannte Maschinenform → den Grund wörtlich zeigen, statt zu
            // raten. Ohne Grund gibt es auch nichts zu erklären.
            return format.unavailableReason
        }
        var lines = [L10n.format("Es fehlt das Zusatzprogramm %@.",
                                 missing.joined(separator: ", "))]
        if missing.contains("pandoc") {
            lines.append(L10n.string(
                "pandoc lässt sich im Terminal mit „brew install pandoc“ installieren. Danach Fastra neu starten."
            ))
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Markdown-Umwandlung

    /// Angebot für den aktiven Tab — oder `nil`, wenn es keins gibt.
    ///
    /// Bewusst nur aus dem ZWISCHENGESPEICHERTEN Katalog: Diese Eigenschaft
    /// wird bei jedem Neuzeichnen gelesen und darf nie einen Prozess starten.
    ///
    /// Auch ein erkanntes, aber gerade NICHT umwandelbares Format liefert ein
    /// Angebot: Die Leiste zeigt dann statt des Umwandeln-Knopfs, welches
    /// Zusatzprogramm fehlt (Daniel-Befund 2026-07-29 — vorher blieb die
    /// Leiste bei fehlendem pandoc einfach unsichtbar).
    func markdownImportOffer(for url: URL?) -> MarkdownImportOffer? {
        guard let url, !dismissedMarkdownImports.contains(url),
              let catalog = MarkdownImportService.shared.cachedCatalog,
              let format = catalog.format(forExtension: url.pathExtension) else {
            return nil
        }
        return MarkdownImportOffer(sourceURL: url, format: format)
    }

    /// Kann diese Datei gerade umgewandelt werden? Anders als
    /// `markdownImportOffer` ignoriert das ein weggeklicktes Angebot — ein
    /// ausgeblendeter Hinweis darf den Befehl nicht mit verschwinden lassen.
    func canConvertToMarkdown(_ url: URL) -> Bool {
        MarkdownImportService.shared.cachedCatalog?
            .availableFormat(forExtension: url.pathExtension) != nil
    }

    /// Format, WENN dieser Ordner in Wahrheit ein Dokumentpaket ist (`.rtfd`).
    /// `nil` für jeden echten Ordner — und auch dann, wenn der Formatkatalog
    /// noch nicht vorliegt; dann bleibt es beim gewohnten Ordnerverhalten.
    /// Ein bekanntes, aber gerade nicht umwandelbares Paket zählt mit, damit
    /// die Rückfrage erklären kann, was fehlt (statt wortlos aufzuklappen).
    func markdownImportPackageFormat(at url: URL) -> MarkdownImportFormat? {
        guard let format = MarkdownImportService.shared.cachedCatalog?
            .format(forExtension: url.pathExtension),
              format.isPackage else { return nil }
        return format
    }

    /// Blendet das Angebot für genau diese Quelle aus — nur für diese Sitzung.
    /// Der Menübefehl bleibt erreichbar, das Angebot war ja nur ein Hinweis.
    func dismissMarkdownImport(_ url: URL) {
        dismissedMarkdownImports.insert(url)
    }

    /// Wandelt um und öffnet das Ergebnis. Die Quelle bleibt unverändert und
    /// ihr Tab offen; das Markdown kommt als neuer, aktiver Tab dazu.
    func convertToMarkdown(_ url: URL) {
        MarkdownImportService.shared.convert(url, owner: self) { [weak self] markdownFile in
            guard let self, let markdownFile else { return }
            self.dismissedMarkdownImports.insert(url)
            // Den Projektbaum aktualisiert der FSEvents-Watcher von selbst; nur
            // der Git-Status wird nicht ereignisgetrieben nachgezogen.
            self.refreshGitStatus()
            self.loadFile(at: markdownFile)
        }
    }

    /// Menübefehl „In Markdown umwandeln…". Er greift auch dann, wenn die
    /// Hinweisleiste bereits weggeklickt wurde.
    func convertActiveTabToMarkdown() {
        guard let url = activeMarkdownImportSource else { NSSound.beep(); return }
        convertToMarkdown(url)
    }

    /// Quelle, die der Menübefehl gerade umwandeln würde — steuert auch, ob der
    /// Menüpunkt aktiv ist.
    var activeMarkdownImportSource: URL? {
        guard let url = activeTab?.url,
              let catalog = MarkdownImportService.shared.cachedCatalog,
              catalog.availableFormat(forExtension: url.pathExtension) != nil else {
            return nil
        }
        return url
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
            // Dieselbe Definition wie der Willkommens-Platzhalter: nur ein
            // wirklich unberührter leerer Tab ist wertlos und darf weg.
            return !tab.isPristineScratch
        }
    }

    /// Lädt eine Ordner-Funddatei und bindet den physischen Read an den
    /// NEUESTEN Sprung derselben URL. Der erste Sprung darf seinen laufenden
    /// Platzhalter nicht mehr verwerfen, wenn unmittelbar danach ein zweiter
    /// Treffer derselben Datei gewählt wird: Dessen Generation und Completion
    /// ersetzen den alten Wartenden, während der Read weiterläuft.
    func loadFolderMatchFile(atCanonicalURL url: URL,
                             expectedDiskSnapshot: FileSnapshot,
                             jumpGeneration: Int,
                             outcome: @escaping (FileLoadOutcome) -> Void) {
        guard isCurrentMatchJump(jumpGeneration) else {
            outcome(.cancelled)
            return
        }
        // Ein Hinweis erklärt immer nur den LETZTEN Versuch. Ohne dieses
        // zentrale Löschen blieb eine Dirty-Ablehnung auch nach einem
        // erfolgreichen Sprung zu einer anderen Datei sichtbar. Das Löschen
        // steht bewusst HINTER dem Generations-Guard: Ein veralteter Auftrag
        // — etwa der Folgeauftrag, den die Read-Completion unten für einen
        // inzwischen geänderten Snapshot startet — darf den Hinweis eines
        // neueren Sprungs nicht mehr anfassen (Review 2026-09-02).
        folderNavigationNotice = nil

        let key = url.path
        let request = PendingFolderMatchFileLoad(
            generation: jumpGeneration,
            expectedDiskSnapshot: expectedDiskSnapshot,
            outcome: outcome
        )
        if let previous = pendingFolderMatchFileLoads.updateValue(request,
                                                                   forKey: key) {
            // Der ältere UI-Auftrag ist abgeschlossen, der physische Read
            // bleibt bestehen. Seine Completion prüft beim Eintreffen den
            // inzwischen aktualisierten Eintrag und bedient nur den neuesten.
            previous.outcome(.cancelled)
            return
        }

        // Kennung genau dieses physischen Reads. Nur solange sie unter dem
        // Pfad eingetragen ist, gehört der Read zu diesem Schlüssel.
        let readToken = UUID()
        folderMatchReadTokens[key] = readToken

        loadFile(
            atCanonicalURL: url,
            expectedDiskSnapshot: expectedDiskSnapshot,
            acceptance: FileLoadAcceptance { [weak self] in
                guard let self,
                      self.folderMatchReadTokens[key] == readToken,
                      let latest = self.pendingFolderMatchFileLoads[key]
                else { return false }
                return self.isCurrentMatchJump(latest.generation)
                    && latest.expectedDiskSnapshot == expectedDiskSnapshot
            },
            folderMatchReadToken: readToken
        ) { [weak self] physicalOutcome in
            guard let self else {
                outcome(.cancelled)
                return
            }
            // Wurde der Read inzwischen auf einen anderen Pfad umgehängt, hat
            // `releaseFolderMatchRead` den Wartenden bereits an einen eigenen
            // Read übergeben. Hier darf dann nichts mehr gemeldet werden —
            // sonst bekäme derselbe logische Auftrag zwei Ergebnisse.
            guard self.folderMatchReadTokens[key] == readToken else { return }
            self.folderMatchReadTokens.removeValue(forKey: key)
            guard let latest = self.pendingFolderMatchFileLoads.removeValue(forKey: key)
            else {
                outcome(.cancelled)
                return
            }

            // Stammt der neueste Auftrag bereits aus einer neuen Suche mit
            // anderem Snapshot, konnte der alte Read ihn nicht erfüllen. Nach
            // dem verworfenen Platzhalter startet derselbe logische Auftrag
            // deshalb einmal frisch auf seiner eigenen Basis.
            guard latest.expectedDiskSnapshot == expectedDiskSnapshot else {
                self.loadFolderMatchFile(
                    atCanonicalURL: url,
                    expectedDiskSnapshot: latest.expectedDiskSnapshot,
                    jumpGeneration: latest.generation,
                    outcome: latest.outcome
                )
                return
            }
            guard self.isCurrentMatchJump(latest.generation) else {
                latest.outcome(.cancelled)
                return
            }
            latest.outcome(physicalOutcome)
        }
    }

    /// Gibt den Pfad `url` durch den Read mit der Kennung `token` frei, weil
    /// dieser Read ab jetzt eine umbenannte Datei unter einem ANDEREN Pfad
    /// liest. Ein Ordner-Sprung, der noch auf `url` wartet, darf sein Ergebnis
    /// nicht mehr von ihm bekommen: Er bekäme den Inhalt einer anderen Datei
    /// als geöffnet gemeldet, und der URL-Guard der Treffer-Navigation könnte
    /// den Sprung danach nicht mehr ausführen. Der Wartende bekommt deshalb
    /// einen eigenen Read auf seinem eigenen Pfad (Review 2026-09-04).
    private func releaseFolderMatchRead(token: UUID, forPathOf url: URL) {
        let key = url.path
        guard folderMatchReadTokens[key] == token else { return }
        folderMatchReadTokens.removeValue(forKey: key)
        guard let waiting = pendingFolderMatchFileLoads.removeValue(forKey: key)
        else { return }
        loadFolderMatchFile(
            atCanonicalURL: url,
            expectedDiskSnapshot: waiting.expectedDiskSnapshot,
            jumpGeneration: waiting.generation,
            outcome: waiting.outcome
        )
    }

    /// Lädt eine Datei asynchron in einen neuen Tab und kehrt sofort zurück.
    ///
    /// - Parameter url: Datei-URL; muss eine reguläre Datei sein.
    /// - Parameter acceptance: Optionale Bindung an einen Aufruferzustand.
    ///   Wird sie ungültig, verwirft Fastra den noch laufenden Ladevorgang.
    /// - Parameter expectedDiskSnapshot: Bindet einen Ordner-Treffer an genau
    ///   den beim Suchlauf gelesenen Plattenstand. Ein geänderter oder bereits
    ///   dirty geöffneter Tab wird weder aktiviert noch veröffentlicht.
    /// - Parameter completion: Optionaler Callback, der auf dem Main-Thread
    ///   aufgerufen wird. `true` = Inhalt steht im Tab (Datei war schon offen
    ///   oder Laden erfolgreich). `false` = Laden fehlgeschlagen, Platzhalter
    ///   wurde entfernt. Zugesichert wird GENAU EIN Aufruf — auch dann, wenn
    ///   der Workspace während des Ladens verschwindet (Fenster geschlossen).
    ///
    /// Ablauf:
    /// 1. Dedup: Datei schon offen → im Ordnerfall den Platten-Snapshot im
    ///    Hintergrund prüfen, danach erst aktiv schalten und zurückmelden.
    /// 2. Platzhalter-Tab anlegen (`isLoading = true`), activeTabID setzen.
    /// 3. Hintergrund-Task (Task.detached) → `FileLoader.load(url:)`.
    /// 4. Zurück auf Main: Generation + Tab-Existenz prüfen, Inhalt setzen,
    ///    `isLoading = false`, completion(true).
    ///    Bei Fehler: Beep, Platzhalter entfernen, vorherige activeTabID
    ///    wiederherstellen, completion(false).
    func loadFile(at url: URL, preview: Bool = false,
                  expectedGitContext: GitActionContext? = nil,
                  expectedDiskSnapshot: FileSnapshot? = nil,
                  acceptance: FileLoadAcceptance? = nil,
                  completion: ((Bool) -> Void)? = nil) {
        // URL-Form vereinheitlichen: dieselbe Datei kommt je nach Quelle in
        // verschiedenen Formen an — programmatisch gebaut `/var/…`, aus
        // Verzeichnis-Listings (Projektbaum!) und NSOpenPanel dagegen
        // `/private/var/…`. Ohne Normalisierung scheitern Tab-Dedup und
        // Aktiv-Markierung im Projektbaum an `/var` ≠ `/private/var`
        // (Befund Screenshot 2026-07-12).
        loadFile(atCanonicalURL: url.canonicalFileURL,
                 preview: preview,
                 expectedGitContext: expectedGitContext,
                 expectedDiskSnapshot: expectedDiskSnapshot,
                 acceptance: acceptance,
                 outcome: completion.map { completion in
                     { completion($0.isOpened) }
                 })
    }

    /// Variante für Pfade, die ein Hintergrundlauf bereits über
    /// `canonicalPathKey` aufgelöst hat. Ordner-Treffer verwenden sie, damit
    /// ihr Klick auf dem Main-Thread keine zweite Metadatenabfrage ausführt.
    /// Meldet ein TYPISIERTES Ergebnis: Die Treffer-Navigation behandelt nur
    /// den echten Snapshot-Konflikt als veraltete Trefferbasis, nicht jeden
    /// abgelehnten Auftrag (Review 2026-08-31).
    /// - Parameter folderMatchReadToken: Nur von `loadFolderMatchFile` gesetzt.
    ///   Kennzeichnet den Read als Bediener des wartenden Ordner-Sprungs unter
    ///   diesem Pfad, damit er die Zuständigkeit abgeben kann, sobald ihn eine
    ///   Umbenennung auf einen anderen Pfad umhängt.
    func loadFile(atCanonicalURL url: URL, preview: Bool = false,
                  expectedGitContext: GitActionContext? = nil,
                  expectedDiskSnapshot: FileSnapshot? = nil,
                  acceptance: FileLoadAcceptance? = nil,
                  folderMatchReadToken: UUID? = nil,
                  outcome: ((FileLoadOutcome) -> Void)? = nil) {
        // Ein Restore-Ladevorgang kann bereits entwertet sein, bevor er hier
        // startet. Dann weder einen vorhandenen Tab aktivieren noch einen
        // Platzhalter veröffentlichen.
        guard acceptance?.acceptsResult() != false else {
            outcome?(.cancelled)
            return
        }
        // ── (1) Dedup ──────────────────────────────────────────────────────
        // Wenn die Datei schon als Tab offen ist, nur aktivieren — kein zweiter Tab.
        if let existingIdx = tabs.firstIndex(where: { $0.url == url }) {
            if let expectedDiskSnapshot {
                let existing = tabs[existingIdx]
                // Die Gründe getrennt melden: Ein noch ladender oder
                // ungesichert geänderter Tab ist KEIN Beleg für eine
                // veraltete Trefferbasis.
                if existing.hasUnsavedChanges {
                    outcome?(.unsavedChanges)
                    return
                }
                if existing.isLoading {
                    outcome?(.busyLoading)
                    return
                }
                guard existing.diskSnapshot == expectedDiskSnapshot else {
                    outcome?(.staleSnapshot)
                    return
                }
                let existingID = existing.id
                // `diskSnapshot` beschreibt den zuletzt geladenen Stand des
                // Tabs. Ein Fremdprogramm kann den Pfad danach ersetzt haben,
                // bevor der Dateiwächter reagiert. Deshalb den aktuellen
                // Plattenstand im Hintergrund erneut hashen und erst danach
                // den bereits offenen Tab aktivieren.
                Task.detached(priority: .userInitiated) { [weak self] in
                    let currentDiskSnapshot = try? FileSnapshot.readSnapshotOnly(
                        from: url, byteLimit: FileLoader.largeFileThreshold)
                    await MainActor.run { [weak self] in
                        guard let self, acceptance?.acceptsResult() != false else {
                            outcome?(.cancelled)
                            return
                        }
                        guard currentDiskSnapshot == expectedDiskSnapshot else {
                            outcome?(.staleSnapshot)
                            return
                        }
                        guard let currentIndex = self.tabs.firstIndex(where: {
                            $0.id == existingID && $0.url == url
                        }) else {
                            // Der Tab wurde während des Hintergrund-Hashs
                            // geschlossen — der Auftrag ist gegenstandslos.
                            outcome?(.cancelled)
                            return
                        }
                        if self.tabs[currentIndex].hasUnsavedChanges {
                            outcome?(.unsavedChanges)
                            return
                        }
                        if self.tabs[currentIndex].isLoading {
                            outcome?(.busyLoading)
                            return
                        }
                        guard self.tabs[currentIndex].diskSnapshot
                                == expectedDiskSnapshot else {
                            outcome?(.staleSnapshot)
                            return
                        }
                        if !preview { self.tabs[currentIndex].isPreview = false }
                        self.activeTabID = existingID
                        self.noteRecentFile(url)
                        self.synchronizeProjectWithActiveTabIfNeeded()
                        outcome?(.opened)
                    }
                }
                return
            }
            // Ein Doppelklick folgt in der Änderungen-Liste auf den bereits
            // ausgeführten Einzelklick. Er findet denselben Tab und steckt ihn
            // fest, statt einen zweiten zu öffnen.
            if !preview { tabs[existingIdx].isPreview = false }
            activeTabID = tabs[existingIdx].id
            noteRecentFile(url)
            synchronizeProjectWithActiveTabIfNeeded()
            outcome?(.opened)
            return
        }

        // ── (2) Platzhalter-Tab anlegen ───────────────────────────────────
        // Der Tab ist sofort in der Tab-Leiste sichtbar (isLoading = true →
        // Spinner statt Editor). Dadurch fühlt sich die App sofort reaktiv an,
        // auch bei großen Dateien.
        let replaceablePreviewIndex = preview
            ? tabs.firstIndex(where: { $0.isPreview && !$0.hasUnsavedChanges })
            : nil
        let reusedID = replaceablePreviewIndex.map { tabs[$0].id }
        let previousActiveTabID: UUID?
        if let reusedID, activeTabID == reusedID {
            previousActiveTabID = tabs.first(where: { $0.id != reusedID })?.id
        } else {
            previousActiveTabID = activeTabID
        }
        let placeholder = EditorTab(
            id: reusedID ?? UUID(),
            title: url.lastPathComponent,
            path: url.deletingLastPathComponent().path,
            url: url,
            content: "",
            isDirty: false,
            isLoading: true,
            isPreview: preview
        )
        // Ein etwaiger unberührter Start-Tab bleibt während des Ladens einfach
        // stehen: Sein Willkommens-Platzhalter ist nur sichtbar, wenn ER aktiv
        // ist — aktiv ist ab jetzt der Lade-Platzhalter. Nach erfolgreichem
        // Laden räumt `tabsRemovingEmptyScratch` ihn ab; scheitert das Laden,
        // ist er unverändert wieder da (keine Sonder-Maschinerie mehr nötig).
        if let replaceablePreviewIndex {
            // Derselbe Tab-Platz bleibt erhalten; dadurch springt die Leiste
            // beim raschen Durchsehen vieler Dateien nicht nach links/rechts.
            documentLanguageDetector.cancel(tabID: placeholder.id)
            gitPreviewLoads.cancel(tabID: placeholder.id)
            previewLoadCancellations.removeValue(forKey: placeholder.id)?.cancel()
            comparisonTabID = nil
            tabs[replaceablePreviewIndex] = placeholder
        } else {
            tabs.append(placeholder)
        }
        // Ein Ordner-Treffer wird erst nach dem Snapshot-Abgleich aktiviert.
        // Bis der Hintergrund-Read fertig ist, bleibt das bisherige Dokument
        // sichtbar und kann nicht durch eine veraltete Treffbasis verdrängt
        // werden.
        if expectedDiskSnapshot == nil {
            activeTabID = placeholder.id
        }

        // ── (3) Generation hochzählen ─────────────────────────────────────
        // Ermöglicht es, einen abgebrochenen Load zu erkennen (Tab schon
        // gelöscht, oder inzwischen ein neuerer Load für dieselbe ID gestartet).
        let tabID = placeholder.id
        // Die Dokument-ID ist die eigentliche Ladeidentität: Ein recycelter
        // Vorschauplatz behält seine Tab-ID, bekommt aber mit jedem neuen
        // Inhalt eine frische Dokument-ID. Die Generation allein reicht nicht
        // — sie wird nach jedem abgeschlossenen Laden aus dem Wörterbuch
        // entfernt und beginnt für denselben Platz wieder bei 1, sodass ein
        // sehr später alter Read dieselbe Nummer tragen kann wie der gerade
        // laufende (Review 2026-09-02).
        let placeholderDocumentID = placeholder.documentID
        let generation = (loadGeneration[tabID] ?? 0) + 1
        loadGeneration[tabID] = generation
        let previewCancellation = preview ? PreviewLoadCancellation() : nil
        if let previewCancellation {
            previewLoadCancellations[tabID] = previewCancellation
        }

        // ── (4) Hintergrund-Task starten ──────────────────────────────────
        startInitialFileRead(
            url: url, tabID: tabID, placeholderDocumentID: placeholderDocumentID,
            generation: generation, previewCancellation: previewCancellation,
            expectedDiskSnapshot: expectedDiskSnapshot, acceptance: acceptance,
            expectedGitContext: expectedGitContext,
            previousActiveTabID: previousActiveTabID,
            folderMatchReadToken: folderMatchReadToken, outcome: outcome
        )
    }

    /// Schritt (4) von `loadFile`: liest `url` im Hintergrund und schreibt das
    /// Ergebnis in den Platzhalter `tabID`. Eigene Methode, weil der Read sich
    /// selbst neu starten muss, wenn die Seitenleiste den Platzhalter während
    /// des Lesens umbenennt (`handleFileTreeMoveLocally`, Review 2026-09-03).
    private func startInitialFileRead(
        url: URL, tabID: UUID, placeholderDocumentID: UUID, generation: Int,
        previewCancellation: PreviewLoadCancellation?,
        expectedDiskSnapshot: FileSnapshot?, acceptance: FileLoadAcceptance?,
        expectedGitContext: GitActionContext?, previousActiveTabID: UUID?,
        folderMatchReadToken: UUID?,
        outcome: ((FileLoadOutcome) -> Void)?
    ) {
        // [weak self]: Workspace darf verschwinden (z.B. Preview), ohne Leak.
        let initialFileLoader = initialFileLoader
        Task.detached(priority: .userInitiated) { [weak self] in
            // I/O im Hintergrund — blockiert NICHT den Main-Thread.
            let loadResult = Result {
                if let previewCancellation {
                    return try FileLoader.load(
                        url: url,
                        isCancelled: { previewCancellation.isCancelled }
                    )
                }
                return try initialFileLoader(url)
            }

            // Zurück auf den Main-Thread für alle UI-/Model-Mutationen.
            await MainActor.run { [weak self] in
                // ── Completion garantieren ────────────────────────────────
                // Die Completion hängt NICHT am Workspace: Schließt der Nutzer
                // das Fenster während des Ladens, ist `self` hier nil — der
                // Wartende (z. B. `SessionRestorationCoordinator`, der seine
                // offenen Fenster ausschließlich über diese Rückmeldungen
                // herunterzählt) bekäme sonst nie eine Antwort und lieferte
                // gepufferte Finder-/CLI-Öffnungen nicht mehr aus.
                // `report` ist einmalig; das `defer` fängt jeden Rückweg ab,
                // auf dem sonst gar nichts gemeldet würde.
                var didReport = false
                func report(_ result: FileLoadOutcome) {
                    guard !didReport else { return }
                    didReport = true
                    outcome?(result)
                }
                defer { report(.failed) }

                guard let self else { return }

                func discardPlaceholder() {
                    // Nur wenn der Platzhalter beim Verwerfen selbst noch aktiv
                    // ist, darf sein Verschwinden die Auswahl verschieben. Hat
                    // der Nutzer während des Ladens bewusst einen anderen Tab
                    // gewählt (z. B. beim Restore mehrerer Dateien), bliebe
                    // ein bedingungsloser Rücksprung auf den gemerkten
                    // Vorgängertab wie eine Geisterhand-Umschaltung zurück.
                    let placeholderWasActive = self.activeTabID == tabID
                    self.tabs.removeAll { $0.id == tabID }
                    if self.tabs.isEmpty {
                        let scratch = Self.makeScratchTab()
                        self.tabs = [scratch]
                        self.activeTabID = scratch.id
                    } else if placeholderWasActive {
                        if let previousActiveTabID,
                           self.tabs.contains(where: { $0.id == previousActiveTabID }) {
                            self.activeTabID = previousActiveTabID
                        } else {
                            self.activeTabID = self.tabs.first?.id
                        }
                    } else if !self.tabs.contains(where: { $0.id == self.activeTabID }) {
                        // Sicherheitsnetz: Zeigt die Auswahl aus anderem Grund
                        // ins Leere, fällt sie auf den ersten Tab zurück.
                        self.activeTabID = self.tabs.first?.id
                    }
                }

                // ── Generation-Guard ──────────────────────────────────────
                // Wenn der Tab inzwischen geschlossen wurde (`loadGeneration`
                // hat keine Eintrags-ID mehr) ODER eine neue Generation für
                // diese ID gestartet wurde ODER unter dieser Tab-ID inzwischen
                // ein anderes Dokument liegt (recycelter Vorschauplatz mit
                // neuer Dokument-ID) → dieses Ergebnis verwerfen.
                guard self.loadGeneration[tabID] == generation,
                      let placeholderIndex = self.tabs.firstIndex(where: {
                          $0.id == tabID && $0.documentID == placeholderDocumentID
                      }) else {
                    // Platzhalter kann weg sein (Nutzer hat Tab während des
                    // Ladens geschlossen) — kein Fehler, einfach still beenden.
                    // Aufräumen: Ist der Tab weg, kommt seine UUID nie wieder
                    // → Generation-Eintrag entfernen, sonst bliebe er für
                    // immer im Dictionary. (Bei bloß veralteter Generation
                    // bleibt der Eintrag — er gehört dem neueren Ladevorgang.)
                    if !self.tabs.contains(where: { $0.id == tabID }) {
                        self.loadGeneration.removeValue(forKey: tabID)
                    }
                    report(.cancelled)
                    return
                }

                // ── Während des Ladens umbenannt ──────────────────────────
                // Derselbe Platzhalter (Tab- und Dokument-ID unverändert,
                // Generation noch unsere) trägt eine andere URL: Die
                // Seitenleiste hat die Datei während des Reads umbenannt
                // (`handleFileTreeMoveLocally`). Das Ergebnis stammt vom
                // alten Pfad und wird nicht übernommen. Den Platzhalter
                // einfach zu verwerfen oder still liegen zu lassen wäre aber
                // falsch: Er bliebe unter dem neuen Pfad für immer im
                // Ladezustand, und ein erneutes Öffnen fände nur den
                // ladenden Tab (Review 2026-09-03). Deshalb denselben Auftrag
                // mit neuer Generation für den neuen Pfad noch einmal
                // starten; die Rückmeldung an den Aufrufer übernimmt der
                // neue Read — deswegen hier ausdrücklich nichts melden.
                if let movedURL = self.tabs[placeholderIndex].url, movedURL != url {
                    // Ab hier liest dieser Read einen anderen Pfad. Einen
                    // Ordner-Sprung, der noch auf den alten wartet, dürfte er
                    // dann nicht mehr bedienen — der bekommt seinen eigenen
                    // Read (Review 2026-09-04). Mit der Zuständigkeit fällt
                    // auch die Gültigkeitsprüfung des Sprungs weg: Sie hängt
                    // am freigegebenen Wartenden und würde den umbenannten
                    // Platzhalter sonst als entwertet verwerfen. Ein Read mit
                    // Sprung-Kennung hat keine andere Bindung.
                    var movedAcceptance = acceptance
                    if let folderMatchReadToken {
                        self.releaseFolderMatchRead(token: folderMatchReadToken,
                                                    forPathOf: url)
                        movedAcceptance = nil
                    }
                    let nextGeneration = generation + 1
                    self.loadGeneration[tabID] = nextGeneration
                    self.startInitialFileRead(
                        url: movedURL, tabID: tabID,
                        placeholderDocumentID: placeholderDocumentID,
                        generation: nextGeneration,
                        previewCancellation: previewCancellation,
                        expectedDiskSnapshot: expectedDiskSnapshot,
                        acceptance: movedAcceptance,
                        expectedGitContext: expectedGitContext,
                        previousActiveTabID: previousActiveTabID,
                        folderMatchReadToken: nil,
                        outcome: outcome
                    )
                    didReport = true
                    return
                }

                // Sitzungs-Restore und andere gebundene Aufrufer prüfen ihre
                // Gültigkeit VOR dem Publizieren des fertigen Tabs. Besonders
                // nach `closeProject()` darf ein verspäteter Restore-Load nicht
                // mehr über die automatische Projektsynchronisierung den eben
                // geschlossenen Ordner wieder öffnen.
                guard acceptance?.acceptsResult() != false else {
                    self.loadGeneration.removeValue(forKey: tabID)
                    discardPlaceholder()
                    report(.cancelled)
                    return
                }

                // Eintrags-ID verbraucht → aus dem Dictionary entfernen.
                self.loadGeneration.removeValue(forKey: tabID)
                if let previewCancellation,
                   self.previewLoadCancellations[tabID] === previewCancellation {
                    self.previewLoadCancellations.removeValue(forKey: tabID)
                }

                // Dateiöffnungen aus der Änderungen-Liste gehören zum beim
                // Klick eingefrorenen Repository. Nach Projektwechsel oder
                // Schließen darf ein später Read den alten Kontext keinesfalls
                // über den aktiven Dateitab erneut öffnen.
                if let expectedGitContext,
                   !expectedGitContext.isCurrent(in: self) {
                    self.tabs.removeAll { $0.id == tabID }
                    if self.tabs.isEmpty {
                        let scratch = Self.makeScratchTab()
                        self.tabs = [scratch]
                        self.activeTabID = scratch.id
                    } else if !self.tabs.contains(where: { $0.id == self.activeTabID }) {
                        self.activeTabID = self.tabs.first?.id
                    }
                    report(.cancelled)
                    return
                }

                switch loadResult {
                case .success(let loaded):
                    // ── Erfolg ────────────────────────────────────────────
                    // Inhalt in den Platzhalter-Tab schreiben und isLoading
                    // auf false setzen. Der EditorView reagiert darauf:
                    // isLoading-Kippen → `.id(activeTab.id)` erzeugt den
                    // SourceEditor NEU → makeNSViewController läuft mit
                    // fertigem Inhalt (CESE-Falle umgangen).
                    guard let idx = self.tabs.firstIndex(where: {
                        $0.id == tabID && $0.documentID == placeholderDocumentID
                    }) else {
                        report(.cancelled)
                        return
                    }
                    guard expectedDiskSnapshot == nil
                            || loaded.diskSnapshot == expectedDiskSnapshot else {
                        discardPlaceholder()
                        report(.staleSnapshot)
                        return
                    }
                    // Den fertigen Tab lokal aufbauen und erst einmalig
                    // publizieren. Feldweise Zuweisungen an `tabs[idx]`
                    // lösten vorher für ein einziges Laden mehr als zehn
                    // vollständige SwiftUI-/Such-/Statistik-Runden aus.
                    var loadedTab = self.tabs[idx]
                    loadedTab.content    = loaded.content
                    loadedTab.encoding   = loaded.encoding
                    loadedTab.bom        = loaded.bom
                    loadedTab.lineEnding = loaded.lineEnding
                    loadedTab.displayMode = loaded.displayMode
                    loadedTab.fileSize = loaded.fileSize
                    loadedTab.diskSnapshot = loaded.diskSnapshot
                    loadedTab.recordExternalFileObservation(
                        snapshot: loaded.diskSnapshot,
                        observation: loaded.externalObservation,
                        contentLoaded: true
                    )
                    loadedTab.isDirty = false
                    // Früher manuell gewähltes Format dieser Datei zurückholen,
                    // BEVOR der Editor mit `isLoading = false` entsteht.
                    self.applyRememberedLanguageChoice(to: &loadedTab)
                    loadedTab.isLoading = false
                    // Frisch geladener Plattenstand ist die Vergleichsbasis,
                    // gegen die der Punkt im Tab künftig verschwinden kann.
                    loadedTab.recordSavedContentBaseline()
                    // BBEdit-Verhalten: das leere unbenannte Start-/Scratch-
                    // Dokument abräumen, sobald eine echte Datei geladen ist
                    // (der gerade geladene Tab bleibt erhalten).
                    var loadedTabs = self.tabs
                    loadedTabs[idx] = loadedTab
                    self.tabs = Workspace.tabsRemovingEmptyScratch(
                        loadedTabs,
                        keeping: tabID
                    )
                    if expectedDiskSnapshot != nil {
                        self.activeTabID = tabID
                    }
                    self.noteRecentFile(url)
                    self.synchronizeProjectWithActiveTabIfNeeded()
                    report(.opened)

                case .failure(let error):
                    // ── Fehler ────────────────────────────────────────────
                    // Platzhalter entfernen und früheren Tab reaktivieren.
                    // Ein etwaiger Start-Tab wurde nie angerührt und steht
                    // damit von selbst wieder da.
                    if case FileLoader.LoadError.cancelled = error {
                        // Der nächste Vorschauklick ist bereits sichtbar; der
                        // alte Hintergrundlauf endet absichtlich geräuschlos.
                        discardPlaceholder()
                        report(.cancelled)
                        return
                    }
                    NSSound.beep()
                    discardPlaceholder()
                    report(.failed)
                }
            }
        }
    }

    func saveActiveTab() {
        guard let id = activeTabID else { return }
        saveTab(id: id)
    }

    /// Speichert genau den adressierten Tab. Das Tab-Kontextmenü darf damit
    /// auch ein Hintergrunddokument sichern, ohne dafür still den sichtbaren
    /// Editor umzuschalten.
    func saveTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Git-Text-Tabs (Verlauf/Diff) und Datei-Vergleichs-Tabs sind
        // read-only — ⌘S tut nichts.
        if tabs[idx].gitKind != nil || tabs[idx].fileDiffRequest != nil
            || tabs[idx].readOnlyReason != nil { return }
        guard !tabs[idx].hexEditSession.isSaving else { NSSound.beep(); return }
        guard !fileMutationIsInFlight(for: tabs[idx].url) else {
            NSSound.beep()
            return
        }
        if tabs[idx].hexEditSession.hasChanges {
            requestHexSavePreview(for: id)
            return
        }
        // Abschnitts- und Hex-Views halten absichtlich keinen vollständigen
        // editierbaren Buffer; Speichern wäre daher eine Trunkierungsgefahr.
        guard tabs[idx].displayMode == .text else { NSSound.beep(); return }
        guard !tabs[idx].isLoading else { NSSound.beep(); return }
        if let url = tabs[idx].url {
            _ = write(tab: tabs[idx], to: url)
        } else {
            saveTabAs(id: id)
        }
    }

    func saveActiveTabAs() {
        guard let tabID = activeTabID else { return }
        saveTabAs(id: tabID)
    }

    private func saveTabAs(id tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        // Read-only Git- und Vergleichs-Tabs lassen sich nicht „speichern unter".
        if tabs[idx].gitKind != nil || tabs[idx].fileDiffRequest != nil
            || tabs[idx].readOnlyReason != nil { return }
        guard !fileMutationIsInFlight(for: tabs[idx].url) else {
            NSSound.beep()
            return
        }
        let visibleMode = ViewModeRouting.effectiveMode(
            chosen: tabs[idx].viewMode,
            fileExtension: tabs[idx].url?.pathExtension,
            loadedDisplayMode: tabs[idx].displayMode,
            hasURL: tabs[idx].url != nil
        )
        if visibleMode == .hex {
            saveSafetyWarningHandler(
                L10n.string("Speichern unter nicht verfügbar"),
                L10n.string("Die Hex-Ansicht kann noch nicht als neue Datei gespeichert werden. Wechsle bei Textdateien zur Textansicht oder bearbeite die geöffnete Datei über die Hex-Vorschau."))
            return
        }
        guard tabs[idx].displayMode == .text else { NSSound.beep(); return }
        guard !tabs[idx].isLoading else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let stateCapture = SavePanelStateCapture()
        panel.delegate = stateCapture
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = true
        let format = DocumentFormatResolver.resolve(tab: tabs[idx])
        let formatChoice = SavePanelFormatSupport.choice(for: format.id)
        panel.nameFieldStringValue = SavePanelFormatSupport.initialFileName(
            tabs[idx].title, choice: formatChoice
        )
        let formatAccessory = SavePanelFormatAccessory(
            panel: panel, selectedFormatID: format.id
        )
        panel.accessoryView = formatAccessory.view
        panel.message = L10n.string("Datei speichern unter…")
        // Vorschlagsordner: eine bewusste Seitenleisten-Markierung gewinnt.
        // Danach folgt der Ordner dieses Dokuments bzw. bei einem neuen Tab
        // der Ordner der unmittelbar zuvor aktiven Datei; der Projektordner
        // bleibt der letzte Fallback.
        let documentDirectory = tabs[idx].url?.deletingLastPathComponent()
            ?? tabs[idx].initialSaveDirectory
        if let directory = Self.suggestedSaveDirectory(
            selectedFolder: usableDirectory(selectedFileTreeFolder),
            documentDirectory: usableDirectory(documentDirectory),
            projectURL: usableDirectory(projectURL)
        ) {
            panel.directoryURL = directory
        }
        // Das Popup hält sein Target nicht selbst stark. Die ausdrückliche
        // Lebensdauer umfasst deshalb den gesamten modalen Panel-Lauf.
        let response = withExtendedLifetime(formatAccessory) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        guard let expectedState = stateCapture.expectedState,
              let currentIndex = tabs.firstIndex(where: { $0.id == tabID }),
              write(tab: tabs[currentIndex], to: url,
                    expectedTargetState: expectedState),
              let savedIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        adoptSavedTarget(url, forTabAt: savedIndex)
        synchronizeProjectWithActiveTabIfNeeded()
    }

    /// Übernimmt das Ziel eines erfolgreichen „Speichern unter" in den Tab.
    ///
    /// Bewusst eine eigene Methode: Der Zustandswechsel nach dem Schreiben
    /// ist damit ohne den modalen Speichern-Dialog prüfbar.
    func adoptSavedTarget(_ url: URL, forTabAt idx: Int) {
        tabs[idx].url = url
        tabs[idx].title = url.lastPathComponent
        tabs[idx].path = url.deletingLastPathComponent().path
        // Die manuelle Formatwahl gehört zur DATEI und muss deshalb am NEUEN
        // Pfad landen. Bei einem noch nie gespeicherten Tab war sie mangels
        // URL überhaupt nicht abgelegt (siehe `rememberLanguageChoice`), bei
        // einer bestehenden Datei hing sie am alten Pfad. Ohne diese Zeile
        // öffnete die eben geschriebene Datei wieder mit der Automatik —
        // gerade bei einer Datei ohne Endung fällt das sofort auf
        // (Review 2026-08-06). „Automatisch" schreibt bewusst `nil` und
        // löscht damit eine ältere Wahl am Zielpfad.
        rememberLanguageChoice(currentLanguageChoiceID(forTabAt: idx),
                               forTabAt: idx)
    }

    /// Rückfrage bei einem Save-Ziel, das nicht mehr dem geladenen Snapshot
    /// entspricht. `true` erlaubt genau den gerade beobachteten Fremdstand zu
    /// überschreiben; eine weitere Änderung danach bricht trotzdem ab.
    var saveConflictConfirmHandler: (String) -> Bool = Workspace.defaultSaveConflictConfirmation
    /// Deterministischer Testpunkt nach Temp-Write, aber vor Koordination.
    var saveBeforeCoordinateHandler: ((URL) -> Void)? = nil
    /// Testpunkt nach der letzten Zielprüfung, unmittelbar vor dem Austausch.
    /// Der produktive Pfad setzt ihn nie; Regressionstests treffen damit die
    /// sonst nur wenige Instruktionen breite Fremdänderungs-Lücke.
    var saveBeforeAtomicReplaceHandler: ((URL) -> Void)? = nil
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
        guard !fileMutationIsInFlight(for: tab.url),
              !fileMutationIsInFlight(for: url) else { return false }
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
            var preserveTemporaryForRecovery = false
            defer {
                if !preserveTemporaryForRecovery { try? fm.removeItem(at: tmpURL) }
            }
            try out.write(to: tmpURL, options: .atomic)
            saveBeforeCoordinateHandler?(url)
            guard tabStillMatches() else { throw CoordinatedSaveError.tabChanged }

            var coordinationError: NSError?
            var writeError: Error?
            var writtenSnapshot: FileSnapshot?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            let finalExpectedState = expectedTargetState ?? observedState
            // Laut Foundation ist `.forReplacing` ausdrücklich nur für ein
            // fachlich anderes Ziel (Save As), nicht für einen Safe-Save des
            // bestehenden Dokuments über Temp-Datei plus Rename.
            let coordinationOptions: NSFileCoordinator.WritingOptions = sameDocument
                ? [] : .forReplacing
            coordinator.coordinate(writingItemAt: url, options: coordinationOptions,
                                   error: &coordinationError) { coordinatedURL in
                do {
                    guard coordinatedURL.standardizedFileURL.path
                            == url.standardizedFileURL.path else {
                        throw CoordinatedSaveError.targetChanged
                    }
                    switch finalExpectedState {
                    case .present(let expectedBeforeWrite):
                        do {
                            writtenSnapshot = try AtomicFileCommit.replaceExisting(
                                at: coordinatedURL,
                                withPreparedFile: tmpURL,
                                expecting: expectedBeforeWrite,
                                replacementContent: FileSnapshot(
                                    data: out, identity: nil),
                                beforeSwap: { target in
                                    self.saveBeforeAtomicReplaceHandler?(target)
                                })
                        } catch let failure as AtomicFileCommit.Failure {
                            preserveTemporaryForRecovery = failure.mustPreservePreparedPath
                            switch failure {
                            case .conflictUnchanged, .conflictRolledBack:
                                throw CoordinatedSaveError.targetChanged
                            case .unsupportedAtomicSwap, .recoveryRequired:
                                throw failure
                            }
                        }
                    case .absent:
                        guard !fm.fileExists(atPath: coordinatedURL.path) else {
                            throw CoordinatedSaveError.targetChanged
                        }
                        // moveItem ist ein exklusives Create: entsteht nach
                        // dem Check doch noch ein Ziel, schlägt es fehl, statt
                        // den fremden Stand zu überschreiben.
                        try fm.moveItem(at: tmpURL, to: coordinatedURL)
                        writtenSnapshot = FileSnapshot(data: out, at: coordinatedURL)
                    }
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
                    tabs[currentIndex].fileSize = UInt64(writtenSnapshot.byteCount)
                    tabs[currentIndex].recordExternalFileObservation(
                        snapshot: writtenSnapshot, observation: nil
                    )
                    tabs[currentIndex].isDirty = true
                }
                throw CoordinatedSaveError.tabChangedAfterWrite
            }
            guard let finalIndex = tabs.firstIndex(where: { $0.id == tab.id }) else {
                throw CoordinatedSaveError.tabChangedAfterWrite
            }
            tabs[finalIndex].isDirty = false
            tabs[finalIndex].hexEditSession.invalidateHistory()
            // Unser eigener Write ist keine „externe" Änderung — Basis-Datum
            // nachziehen, sonst schlüge die Erkennung beim nächsten
            // App-Wechsel auf die selbst geschriebene Datei an.
            tabs[finalIndex].diskSnapshot = writtenSnapshot
            tabs[finalIndex].fileSize = UInt64(writtenSnapshot.byteCount)
            tabs[finalIndex].recordExternalFileObservation(
                snapshot: writtenSnapshot, observation: nil,
                contentLoaded: true
            )
            // Gespeicherter Stand = neue Basis: Rückgängig bis genau hierher
            // lässt den Punkt im Tab wieder verschwinden.
            tabs[finalIndex].recordSavedContentBaseline()
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
        // Jedes Dokumentfenster besitzt einen eigenen Workspace. Vor der
        // Änderung deshalb den neuesten gemeinsamen Store lesen: Sonst würde
        // ein später schreibendes, schon länger offenes Fenster die inzwischen
        // in einem anderen Fenster gemerkten Dateien mit seiner alten lokalen
        // Kopie wieder löschen.
        let persisted = RecentFilesStore.load(from: defaultsStore)
        recentFiles = RecentFilesStore.prepending(url.path, to: persisted)
        if let root = ProjectStore.repositoryRoot(for: url) {
            noteRecentProject(root)
        }
    }

    // MARK: - Projekte (Projekt- & Git-Ausbau, Etappe 1)

    /// Merkt sich einen Projekt-Ordner oben in `recentProjects` — nur die
    /// Liste, lädt NICHT das Projekt (Persistenz via Combine-Sink in `init`).
    func noteRecentProject(_ url: URL) {
        // Wie bei `recentFiles` hält jedes Fenster nur eine lokale Ansicht.
        // Vor dem Schreiben deshalb den gemeinsamen Stand zusammenführen.
        let persisted = ProjectStore.load(from: defaultsStore)
        recentProjects = ProjectStore.prepending(url.path, to: persisted)
    }

    // MARK: - Etappe-1-UX (Wunschpaket 2026-07)

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

    /// Bestimmt den Projektkontext eines aktiven Datei-Tabs. Ein Git-Root
    /// gewinnt immer, auch bei tief verschachtelten oder ungetrackten Dateien.
    /// Ohne Git bleibt der bestehende Projektkontext unverändert; nur wenn
    /// noch gar kein Projekt offen ist, dient der Elternordner als Ziel.
    static func projectContextTarget(
        for url: URL,
        currentProject: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let repository = ProjectStore.repositoryRoot(for: url,
                                                        fileManager: fileManager) {
            return repository.canonicalFileURL
        }
        if let current = currentProject?.canonicalFileURL { return current }
        return url.canonicalFileURL.deletingLastPathComponent()
    }

    /// Teurer Dateisystemteil des Projektwechsels. Dieser Helfer läuft im
    /// Produkt ausschließlich auf der Hintergrund-Queue.
    static func existingProjectContextTarget(
        for url: URL,
        currentProject: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let target = projectContextTarget(
            for: url, currentProject: currentProject, fileManager: fileManager
        ) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path,
                                     isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return target.canonicalFileURL
    }

    /// Lässt Projekt- und Git-Seitenleiste dem tatsächlich aktiven Datei-Tab
    /// folgen. Fremde Tabs bleiben offen; ein Wechsel der sichtbaren Datei ist
    /// kein Auftrag, ihren Inhalt oder andere Tabs zu schließen.
    private func synchronizeProjectWithActiveTabIfNeeded() {
        guard !showSearchDialog, !livePreview,
              let tab = activeTab, !tab.isLoading,
              let url = tab.url else {
            return
        }
        projectContextRequestGeneration &+= 1
        let requestGeneration = projectContextRequestGeneration
        let tabID = tab.id
        // Nur lexikalisch normalisieren: `canonicalFileURL` fragt das
        // Dateisystem ab und gehört deshalb ebenfalls in den Hintergrundteil.
        let expectedURL = url.standardizedFileURL
        let expectedProjectGeneration = projectGeneration
        let currentProject = projectURL
        let resolve = resolveProjectContext
        let deliver = deliverProjectContextResult
        scheduleProjectContextWork { [weak self] in
            let target = resolve(expectedURL, currentProject)
            deliver { [weak self] in
                guard let self,
                      self.projectContextRequestGeneration == requestGeneration,
                      self.projectGeneration == expectedProjectGeneration,
                      !self.showSearchDialog, !self.livePreview,
                      self.activeTabID == tabID,
                      self.activeTab?.url?.standardizedFileURL == expectedURL,
                      let target,
                      target.standardizedFileURL
                        != self.projectURL?.standardizedFileURL else { return }
                // Dieser Projektwechsel gehört zum Abschluss genau des
                // Datei-Ladevorgangs. Eine Sitzungswiederherstellung darf
                // sich dadurch nicht selbst entwerten; ausdrückliche Nutzer-
                // Projektwechsel verwenden weiterhin den Standardwert.
                self.openProject(at: target, keepingUnrelatedTabs: true,
                                 invalidatingSessionRestore: false)
                self.showSidebarNotice(L10n.format(
                    "Seitenleiste zeigt jetzt „%@“", target.lastPathComponent
                ))
            }
        }
    }

    // MARK: - Inhaltsbasierte Spracherkennung (Etappe 3 Wunschpaket 2026-07)

    /// Fensterlokale Mechanik für Debounce, Hintergrundarbeit und veraltete
    /// Ergebnisse. Eignung und jede Mutation des Tab-Zustands bleiben hier.
    private let documentLanguageDetector: DocumentLanguageDetector
    private let resolveProjectContext: ProjectContextResolver
    private let scheduleProjectContextWork: ProjectContextScheduler
    private let deliverProjectContextResult: ProjectContextScheduler
    private var projectContextRequestGeneration: UInt64 = 0

    /// Nur ungespeicherte Tabs ohne Dateiendung, ohne manuelle Sprachwahl
    /// und ohne Sonderrolle (Git/Vergleich) nehmen an der Automatik teil.
    /// Nach dem Speichern gewinnt die Endung; manuelle Wahl gewinnt immer.
    static func isEligibleForContentDetection(_ tab: EditorTab) -> Bool {
        tab.url == nil && tab.gitKind == nil
            && tab.fileDiffRequest == nil
            && tab.gitSnapshotRequest == nil
            && tab.languageOverride == nil
            && tab.customLanguageOverrideID == nil
            && (tab.title as NSString).pathExtension.isEmpty
    }

    /// Übergibt nur die mechanischen Eingaben an den Detector. Der Workspace
    /// entscheidet weiterhin vor dem Start über die Eignung und unmittelbar
    /// vor dem Anwenden über Dokumentidentität und manuelle Vorrangregeln.
    func scheduleLanguageDetection(
        tabID: UUID, oldLength: Int, newLength: Int,
        forceAnalysis: Bool = false
    ) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              Self.isEligibleForContentDetection(tabs[idx]) else { return }
        let tab = tabs[idx]
        let request = DocumentLanguageDetector.Request(
            tabID: tab.id,
            documentID: tab.documentID,
            contentRevision: tab.contentRevision,
            oldLength: oldLength,
            newLength: newLength,
            content: tab.content,
            forceAnalysis: forceAnalysis
        )
        documentLanguageDetector.schedule(request) { [weak self] result in
            guard let self,
                  let i = self.tabs.firstIndex(where: {
                      $0.id == result.tabID && $0.documentID == result.documentID
                  }),
                  self.tabs[i].contentRevision == result.contentRevision,
                  Self.isEligibleForContentDetection(self.tabs[i]) else { return false }

            let format = result.analysis.format
            let detectedLanguage = format.map(Self.grammarForDetectedFormat)
                ?? result.analysis.fallbackLanguage
            // Hysterese über den Grammatik-Vergleich: `nil` (nichts
            // erkannt) lässt eine bestehende Erkennung stehen.
            let current = self.tabs[i].contentDetectedLanguage
            let currentFormat = self.tabs[i].contentDetectedFormat
            if let detectedLanguage,
               detectedLanguage != current || format != currentFormat {
                self.tabs[i].contentDetectedLanguage = detectedLanguage
                self.tabs[i].contentDetectedFormat = format
            }
            return true
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
        // Die Wahl gehört zur DATEI, nicht nur zum offenen Tab: Beim nächsten
        // Öffnen soll dieselbe Datei wieder mit diesem Format erscheinen.
        rememberLanguageChoice(
            language.map { LanguageMenuSupport.Entry.grammar($0).id },
            forTabAt: idx
        )
        if language != nil {
            // Manuelle Wahl beendet die Automatik: wartende Analyse abräumen.
            documentLanguageDetector.cancel(
                tabID: tabs[idx].id, documentID: tabs[idx].documentID
            )
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
        rememberLanguageChoice(LanguageMenuSupport.Entry.custom(language).id,
                               forTabAt: idx)
        documentLanguageDetector.cancel(
            tabID: tabs[idx].id, documentID: tabs[idx].documentID
        )
        editorReloadNonce += 1
    }

    /// Schreibt die manuelle Formatwahl in den dateibezogenen Speicher.
    /// `nil` = „Automatisch" und löscht einen vorhandenen Eintrag. Ein Tab
    /// ohne Datei (noch nicht gespeichert) hat nichts zu merken.
    private func rememberLanguageChoice(_ entryID: String?, forTabAt idx: Int) {
        guard let url = tabs[idx].url else { return }
        languageChoices.setChoiceID(entryID, for: url)
    }

    /// Der Menü-Bezeichner der aktuell wirksamen MANUELLEN Wahl eines Tabs —
    /// `nil`, wenn die Automatik gilt. Eine Eigen-Sprache trägt ihre Kennung
    /// selbst als Bezeichner (`LanguageMenuSupport.Entry.custom`), eine
    /// Grammatik bekommt den `grammar.`-Bezeichner.
    private func currentLanguageChoiceID(forTabAt idx: Int) -> String? {
        if let customID = tabs[idx].customLanguageOverrideID { return customID }
        if let language = tabs[idx].languageOverride {
            return LanguageMenuSupport.Entry.grammar(language).id
        }
        return nil
    }

    /// Holt eine gemerkte Formatwahl auf einen frisch geladenen Tab zurück.
    /// Läuft VOR dem ersten Editor-Aufbau, damit Grammatik und Chip von
    /// Anfang an stimmen und kein sichtbarer Sprachwechsel nachflackert.
    private func applyRememberedLanguageChoice(toTabAt idx: Int) {
        var tab = tabs[idx]
        applyRememberedLanguageChoice(to: &tab)
        tabs[idx] = tab
    }

    /// Inout-Fassung für den Ladepfad: Die Formatwahl wird in den noch nicht
    /// veröffentlichten fertigen Tab geschrieben und verursacht dadurch
    /// keinen eigenen vollständigen View-Neuaufbau.
    private func applyRememberedLanguageChoice(to tab: inout EditorTab) {
        guard let url = tab.url,
              let entryID = languageChoices.choiceID(for: url),
              let entry = LanguageMenuSupport.entry(withID: entryID) else { return }
        switch entry {
        case .grammar(let language):
            tab.languageOverride = language
            tab.customLanguageOverrideID = nil
        case .custom(let language):
            tab.customLanguageOverrideID = language.id
            tab.languageOverride = nil
        }
        // Eine manuelle Wahl beendet die Automatik — wie beim Setzen im Menü.
        documentLanguageDetector.cancel(
            tabID: tab.id, documentID: tab.documentID
        )
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
        guard let tab = activeTab, tab.gitKind == nil,
              tab.fileDiffRequest == nil, tab.readOnlyReason == nil else {
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
    /// Git-Ansichten und Datei-Vergleiche haben keinen Umschalter.
    var availableViewModes: [EditorViewMode] {
        guard let tab = activeTab, tab.gitKind == nil,
              tab.fileDiffRequest == nil, tab.readOnlyReason == nil else { return [] }
        if tab.hexEditSession.hasChanges { return [.hex] }
        return ViewModeRouting.availableModes(
            fileExtension: tab.url?.pathExtension,
            loadedDisplayMode: tab.displayMode,
            hasURL: tab.url != nil
        )
    }

    /// Effektive Ansicht des aktiven Tabs (manuelle Wahl vor Standard).
    var activeViewMode: EditorViewMode {
        guard let tab = activeTab else { return .text }
        // Solange Byteänderungen offen sind, bleibt dieses Dokument in der
        // einzigen Ansicht, die deren vollständige Vorschau zeigen kann.
        if tab.hexEditSession.hasChanges { return .hex }
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
        guard !tabs[idx].hexEditSession.hasChanges || mode == .hex else {
            NSSound.beep()
            return
        }
        tabs[idx].viewMode = mode
    }

    /// Bindet `HexFileView` an den Tab statt an ihre eigene Lebensdauer. Die
    /// erste echte Byteänderung macht einen flüchtigen Vorschau-Tab dauerhaft.
    func hexEditSessionBinding(for tabID: UUID) -> Binding<HexEditSession> {
        Binding(
            get: {
                self.tabs.first(where: { $0.id == tabID })?.hexEditSession
                    ?? HexEditSession()
            },
            set: { session in
                guard let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else {
                    return
                }
                let current = self.tabs[idx].hexEditSession
                // SwiftUI schreibt ein mutiertes Binding als ganzen Wert
                // zurück. Die Prüfung hier ist die letzte Sicherheitsgrenze,
                // falls ein bereits aufgebauter Undo-/Redo-Knopf genau dann
                // feuert, wenn Text- oder Ordnerarbeit den Tab gesperrt hat.
                guard session.hasSameEditingLineage(as: current),
                      session == current || self.hexEditingIsAllowed(for: tabID) else {
                    return
                }
                let discardedLastChange = current.hasChanges
                    && !current.isSaving && !session.hasChanges
                self.tabs[idx].updateHexEditSession(
                    pinHexViewWhenChanged: true
                ) { $0 = session }
                if discardedLastChange {
                    self.reloadAcceptedExternalStateAfterDiscardingHexChanges(
                        tabID: tabID
                    )
                }
            }
        )
    }

    /// Startet den dokumentgebundenen Hex-Save nur auf einer weiterhin
    /// schreibbaren Grundlage. Abschluss und Fehler laufen über die
    /// Operation-ID unten und bleiben deshalb auch dann zulässig, wenn ein
    /// Extern-Check den Tab während des Hintergrund-Saves sperrt.
    func beginHexSave(_ context: HexEditActionContext) -> HexSaveOperation? {
        guard let idx = hexActionTabIndex(for: context, requiresEditing: true),
              let url = tabs[idx].url else {
            return nil
        }
        let workspaces = fileTreeMutationWorkspaces()
        guard let mutationID = WorkspacePathOperationRegistry.begin(paths: [url]) else {
            NSSound.beep()
            return nil
        }
        guard let operation = tabs[idx].updateHexEditSession({
            $0.beginSave()
        }) else {
            WorkspacePathOperationRegistry.finish(mutationID)
            return nil
        }
        hexSaveMutationOperations[operation.id] = HexSaveMutationOperation(
            id: mutationID, tabID: context.tabID,
            documentID: context.documentID,
            path: url.standardizedFileURL.path, workspaces: workspaces
        )
        noteFileMutationChange(in: workspaces)
        return operation
    }

    @discardableResult
    func finishHexSave(_ operation: HexSaveOperation, for tabID: UUID) -> Bool {
        guard let mutation = hexSaveMutationOperations[operation.id],
              mutation.tabID == tabID else {
            return false
        }
        hexSaveMutationOperations.removeValue(forKey: operation.id)
        defer { finishHexSaveMutation(mutation) }
        guard let idx = tabs.firstIndex(where: {
            $0.id == tabID && $0.documentID == mutation.documentID
                && $0.url?.standardizedFileURL.path == mutation.path
        }) else {
            return false
        }
        let saved = tabs[idx].updateHexEditSession { session in
            let saved = session.markSaved(operation)
            if !saved {
                session.markSaveFailed(
                    operation, message: L10n.string(
                        "Der Hex-Speicherzustand hat sich unerwartet geändert. Die Byteänderungen bleiben erhalten."
                    )
                )
            }
            return saved
        }
        return saved
    }

    func failHexSave(
        _ operation: HexSaveOperation,
        for tabID: UUID,
        message: String
    ) {
        guard let mutation = hexSaveMutationOperations[operation.id],
              mutation.tabID == tabID else { return }
        hexSaveMutationOperations.removeValue(forKey: operation.id)
        defer { finishHexSaveMutation(mutation) }
        guard let idx = tabs.firstIndex(where: {
            $0.id == tabID && $0.documentID == mutation.documentID
                && $0.url?.standardizedFileURL.path == mutation.path
        }) else { return }
        tabs[idx].updateHexEditSession {
            $0.markSaveFailed(operation, message: message)
        }
    }

    private func finishHexSaveMutation(_ mutation: HexSaveMutationOperation) {
        WorkspacePathOperationRegistry.finish(mutation.id)
        noteFileMutationChange(in: fileTreeMutationWorkspaces(
            including: mutation.workspaces
        ))
    }

    func clearHexSaveError(_ context: HexEditActionContext) {
        guard let idx = hexActionTabIndex(for: context) else { return }
        tabs[idx].updateHexEditSession { $0.clearSaveError() }
    }

    /// Verwerfen ist eine Aufräumaktion, keine neue Byteeingabe. Es muss auch
    /// bei einem inzwischen dirty gewordenen Rettungspuffer funktionieren;
    /// nur ein noch laufender Save darf seinen eigenen Zustand behalten.
    func discardHexChanges(_ context: HexEditActionContext) {
        guard let idx = hexActionTabIndex(for: context),
              tabs[idx].hexEditSession.hasChanges,
              !tabs[idx].hexEditSession.isSaving else { return }
        tabs[idx].updateHexEditSession { $0.discard() }
        reloadAcceptedExternalStateAfterDiscardingHexChanges(tabID: context.tabID)
    }

    /// Mutiert die große Session direkt im Dokument-Tab. Der frühere Weg über
    /// ein schreibendes SwiftUI-Binding hielt während jeder Eingabe noch eine
    /// alte Wertkopie und kopierte dadurch Dictionary und Undo-Array mit
    /// wachsendem Verlauf immer wieder vollständig.
    func editHexRow(
        _ context: HexEditActionContext,
        text: String,
        data: Data,
        baseOffset: UInt64,
        row: Int
    ) {
        guard let idx = hexActionTabIndex(for: context, requiresEditing: true) else {
            return
        }
        let hadChanges = tabs[idx].hexEditSession.hasChanges
        tabs[idx].updateHexEditSession(pinHexViewWhenChanged: true) {
            $0.editRow(text, data: data, baseOffset: baseOffset, row: row)
        }
        if hadChanges && !tabs[idx].hexEditSession.hasChanges {
            reloadAcceptedExternalStateAfterDiscardingHexChanges(
                tabID: context.tabID
            )
        }
    }

    func undoHexChange(_ context: HexEditActionContext) {
        guard let idx = hexActionTabIndex(for: context, requiresEditing: true) else {
            return
        }
        let hadChanges = tabs[idx].hexEditSession.hasChanges
        tabs[idx].updateHexEditSession { $0.undo() }
        if hadChanges && !tabs[idx].hexEditSession.hasChanges {
            reloadAcceptedExternalStateAfterDiscardingHexChanges(tabID: context.tabID)
        }
    }

    func redoHexChange(_ context: HexEditActionContext) {
        guard let idx = hexActionTabIndex(for: context, requiresEditing: true) else {
            return
        }
        tabs[idx].updateHexEditSession(pinHexViewWhenChanged: true) {
            $0.redo()
        }
    }

    /// Prüft alle Identitäten, die eine alte View überleben können. Die URL
    /// gehört dazu, weil „Sichern unter" denselben Tab und dasselbe Dokument
    /// an einen anderen Plattenstand bindet.
    private func hexActionTabIndex(
        for context: HexEditActionContext,
        requiresEditing: Bool = false
    ) -> Int? {
        guard let idx = tabs.firstIndex(where: { $0.id == context.tabID }),
              tabs[idx].documentID == context.documentID,
              tabs[idx].hexEditSession.editingLineageID
                == context.editingLineageID,
              tabs[idx].url?.canonicalFileURL.path
                == context.fileURL?.canonicalFileURL.path,
              !requiresEditing || hexEditingIsAllowed(for: context.tabID) else {
            return nil
        }
        return idx
    }

    /// „Externen Stand behalten“ bestätigt die neue Datei, ohne eine laufende
    /// Hex-Bearbeitung zu verwerfen. Sobald Verwerfen oder Undo deren letzte
    /// Änderung entfernt, muss die Ansicht auf diesen bestätigten Stand
    /// wechseln; sonst wäre ein sauberer Tab weiterhin an alte Bytes gebunden.
    private func reloadAcceptedExternalStateAfterDiscardingHexChanges(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let acceptedGenerationDiffers = tab.externalContentGeneration
            != tab.displayedExternalContentGeneration
        let acceptedSnapshotDiffers = switch (
            tab.diskSnapshot, tab.externalContentSnapshot
        ) {
        case let (old?, accepted?):
            !old.hasSameContent(as: accepted)
        case (nil, .some):
            true
        default:
            false
        }
        // Bei einem vollständigen Textpuffer hat die Fehlprüfung den Inhalt
        // bereits als dirty Rettungskopie geschützt. Ein erneuter, sicher
        // scheiternder Read würde nur kurz den Zugriff darauf blockieren.
        if tab.isDirty { return }
        guard tab.externalFileUnavailable || acceptedGenerationDiffers
                || acceptedSnapshotDiffers else { return }
        reloadTabFromDisk(id: tabID)
    }

    func hexEditingIsAllowed(for tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        return !tab.isDirty && !tab.isLoading
            && !fileMutationIsInFlight(for: tab.url)
    }

    func requestHexSavePreview(for tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[idx].hexEditSession.hasChanges,
              !tabs[idx].hexEditSession.isSaving else { return }
        activeTabID = tabID
        tabs[idx].viewMode = .hex
        hexSavePreviewRequestTabID = tabID
    }

    func consumeHexSavePreviewRequest(for tabID: UUID) {
        guard hexSavePreviewRequestTabID == tabID else { return }
        hexSavePreviewRequestTabID = nil
    }

    /// Vorschlagsordner für den Save-Dialog: der in der Seitenleiste
    /// markierte Ordner gewinnt vor dem Dokumentkontext und dieser vor dem
    /// Projektordner; ohne alles `nil` (= Systemverhalten).
    /// Pure Funktion → unit-testbar.
    static func suggestedSaveDirectory(selectedFolder: URL?,
                                       documentDirectory: URL?,
                                       projectURL: URL?) -> URL? {
        selectedFolder ?? documentDirectory ?? projectURL
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

    /// Lädt einen Ordner als Projekt: Dateibaum-Seitenleiste zeigt ihn,
    /// der Ordner wandert in die Zuletzt-benutzt-Liste. URL wird kanonisiert —
    /// gleiche Begründung wie in `loadFile` (Dedup über URL-Formen hinweg).
    ///
    /// `keepingUnrelatedTabs`: Beim IMPLIZITEN Öffnen (Einzeldatei ohne
    /// Projekt → Elternordner erscheint in der Seitenleiste, Etappe 1
    /// Wunschpaket 2026-07) dürfen fremde offene Tabs NICHT geschlossen
    /// werden — der Nutzer hat keinen Projektwechsel verlangt. Nur der
    /// ausdrückliche Wechsel (Willkommensseite, ⌘⇧O) räumt wie bisher auf.
    /// Ein unberührter leerer Start-Tab bleibt in beiden Fällen einfach
    /// stehen — sein Willkommens-Platzhalter zeigt sich nur, solange er
    /// selbst aktiv ist.
    func openProject(at url: URL, keepingUnrelatedTabs: Bool = false,
                     invalidatingSessionRestore: Bool = true) {
        if invalidatingSessionRestore { sessionRestoreGeneration &+= 1 }
        let url = url.canonicalFileURL
        NotificationCenter.default.post(name: .fastraProjectContextWillChange, object: self)
        fourDProjectIndexController.stop()
        cancelGitPreviewsForProjectChange()
        cancelAllPreviewLoads()
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
        // Auch das ERGEBNIS des Filters, nicht nur der Suchtext: Steht beim
        // Wechsel der Graph-Tab vorn, existiert `FileTreeSidebar` gar nicht und
        // kann es über seinen `onChange`-Pfad nicht wegräumen. Tippt der Nutzer
        // im neuen Projekt denselben Filtertext, galten sonst die Pfade des
        // alten Projekts als Treffer, bis der neue Scan fertig war
        // (Review-Fund 2026-08-25).
        fileTreeFilterResult = nil
        // Die Scroll-Schlüssel der Seitenleiste sind projektübergreifend
        // dieselben. Ohne Leerung öffnete das neue Projekt an der Position des
        // alten (Review-Fund 2026-08-25).
        sidebarScrollMemory.removeAll()
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
        gitPushTargetInspection?.cancel()
        gitPushTargetInspection = nil
        gitPushTargetInspectionRequestID = nil
        gitPushActionTargetInspection?.cancel()
        gitPushActionTargetInspection = nil
        gitFetchRemoteInspection?.cancel()
        gitFetchRemoteInspection = nil
        gitFetchRemoteInspectionRequestID = nil
        gitOperationStateInspection?.cancel()
        gitIdentityInspection?.cancel()
        gitConflictInspectionLease?.cancel()
        gitConflictInspectionLease = nil
        gitAutoFetchObservation?.cancel()
        gitAutoFetchObservation = nil
        // Bis der erste Snapshot des neuen Roots eintrifft, darf keine Git-UI
        // oder Aktion versehentlich den Zustand des alten Projekts verwenden.
        gitStatus = nil
        gitPushTargets = []
        gitPushTargetWarning = nil
        gitRepositorySnapshot = nil
        gitBranches = []
        gitLog = []
        clearGitHistoryFile()
        gitFeedback = nil
        gitPushFeedback = [:]
        gitPushFeedbackGenerations = [:]
        gitOperationState = nil
        gitIdentity = nil
        gitConflictInspections = [:]
        gitConflictMarkerSizes = [:]
        gitConflictInspectionRequestIDs = [:]
        activeConflictIndex = 0
        showsConflictBase = false
        projectURL = url
        let generation = projectGeneration
        fourDMethodIndexSnapshot = .empty
        fourDProjectIndexController.start(
            projectURL: url,
            projectGeneration: generation
        ) { [weak self] indexedRoot, indexedGeneration, snapshot in
            guard let self,
                  self.projectGeneration == indexedGeneration,
                  self.projectURL?.canonicalFileURL == indexedRoot else { return }
            self.fourDMethodIndexSnapshot = snapshot
        }
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

    /// Beim Projektwechsel bleiben ungesicherte Inhalte immer erhalten.
    /// Saubere Dateien außerhalb des neuen Projektbaums und alte Git-Ansichten
    /// werden geschlossen; saubere unbenannte Notizzettel bleiben bestehen.
    static func tabsAfterOpeningProject(_ tabs: [EditorTab], root: URL) -> [EditorTab] {
        let root = root.canonicalFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return tabs.filter { tab in
            // Ungesicherte echte Tabs bleiben immer erhalten; unbenannte
            // Notizzettel (auch der unberührte Start-Tab) ebenfalls.
            if tab.hasUnsavedChanges { return true }
            if tab.gitKind != nil || tab.gitSnapshotRequest != nil { return false }
            guard let file = tab.url?.canonicalFileURL else { return true }
            return file.path.hasPrefix(prefix)
        }
    }

    /// Blendet den Projekt-Dateibaum wieder aus (Seitenleiste zeigt dann
    /// wie bisher nur die geöffneten Tabs). Offene Tabs bleiben unberührt.
    func closeProject() {
        sessionRestoreGeneration &+= 1
        NotificationCenter.default.post(name: .fastraProjectContextWillChange, object: self)
        fourDProjectIndexController.stop()
        selectedFileTreeFolder = nil
        sidebarNotice = nil
        projectGeneration &+= 1
        fourDMethodIndexSnapshot = .empty
        cancelGitPreviewsForProjectChange()
        cancelAllPreviewLoads()
        gitIdentityResolution?.cancel()
        gitIdentityResolution = nil
        gitPushTargetInspection?.cancel()
        gitPushTargetInspection = nil
        gitPushTargetInspectionRequestID = nil
        gitPushActionTargetInspection?.cancel()
        gitPushActionTargetInspection = nil
        gitFetchRemoteInspection?.cancel()
        gitFetchRemoteInspection = nil
        gitFetchRemoteInspectionRequestID = nil
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
        gitPushTargets = []
        gitPushTargetWarning = nil
        gitRepositorySnapshot = nil
        gitLog = []
        clearGitHistoryFile()
        gitBranches = []
        gitFeedback = nil
        gitPushFeedback = [:]
        gitPushFeedbackGenerations = [:]
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
    func handleFileTreeMove(
        from source: URL,
        to destination: URL,
        operation: FileTreeMoveOperation? = nil
    ) {
        // Die gemerkten Formatwahlen hängen am Dateipfad und müssen deshalb
        // mitwandern. Das gilt auch für Dateien in einem verschobenen Ordner,
        // die gar nicht offen sind — für sie gibt es keinen Tab, über den man
        // später nachbessern könnte (Review 2026-08-06).
        languageChoices.moveChoices(from: source, to: destination)
        for workspace in fileTreeMutationWorkspaces(
            including: operation?.workspaces ?? []
        ) {
            workspace.handleFileTreeMoveLocally(from: source, to: destination)
        }
    }

    private func handleFileTreeMoveLocally(from source: URL, to destination: URL) {
        for index in tabs.indices {
            guard let oldURL = tabs[index].url,
                  let newURL = Self.movedURL(oldURL, from: source, to: destination)
            else { continue }
            tabs[index].url = newURL.canonicalFileURL
            tabs[index].title = newURL.lastPathComponent
            tabs[index].path = newURL.deletingLastPathComponent().path
            tabs[index].recordExternalFileObservation(
                snapshot: tabs[index].diskSnapshot, observation: nil
            )
        }
    }

    /// Reserviert Quell- und Zielpfad, bevor die Seitenleiste eine Datei oder
    /// einen Ordner umbenennt. Ein noch schreibender Hex-Tab darf nicht
    /// gleichzeitig seinen alten Pfad ersetzen und dort eine zweite Datei
    /// hinterlassen.
    @MainActor
    func beginFileTreeMove(
        from source: URL,
        to destination: URL
    ) -> FileTreeMoveOperation? {
        let workspaces = fileTreeMutationWorkspaces()
        let savingHexTabs = workspaces.flatMap { workspace in
            workspace.tabs.compactMap { tab -> (Workspace, EditorTab)? in
                guard tab.hexEditSession.isSaving,
                      tab.url.map({ Self.path($0, isInside: source) }) == true else {
                    return nil
                }
                return (workspace, tab)
            }
        }
        guard savingHexTabs.isEmpty else {
            if let (workspace, tab) = savingHexTabs.first {
                workspace.requestHexSavePreview(for: tab.id)
                CommandTargeting.registeredWindow(for: workspace)?.makeKeyAndOrderFront(nil)
            }
            fileTreeMoveConflictHandler(savingHexTabs.map { $0.1.title })
            return nil
        }
        guard let token = WorkspacePathOperationRegistry.begin(
            paths: [source, destination]
        ) else {
            NSSound.beep()
            return nil
        }
        noteFileMutationChange(in: workspaces)
        return FileTreeMoveOperation(id: token, workspaces: workspaces)
    }

    func finishFileTreeMove(_ operation: FileTreeMoveOperation) {
        WorkspacePathOperationRegistry.finish(operation.id)
        noteFileMutationChange(in: fileTreeMutationWorkspaces(
            including: operation.workspaces
        ))
    }

    var fileTreeMoveConflictHandler: ([String]) -> Void = { titles in
        NSAlert.runWarning(
            title: L10n.string("Umbenennen nicht möglich"),
            text: L10n.format(
                "Fastra speichert gerade Byteänderungen in %@. Warte auf den Abschluss und benenne den Eintrag danach um.",
                titles.joined(separator: ", ")
            )
        )
    }

    /// Startet die Papierkorb-Operation nur, wenn kein betroffenes Dokument
    /// offene Byteänderungen besitzt. Der Token hält neue Hex-Eingaben bis zur
    /// asynchronen Rückmeldung von NSWorkspace gesperrt.
    @MainActor
    func beginFileTreeTrash(_ source: URL) -> FileTreeTrashOperation? {
        let workspaces = fileTreeMutationWorkspaces()
        let blocked = workspaces.flatMap { workspace in
            workspace.tabs.compactMap { tab -> (Workspace, EditorTab)? in
                guard tab.hexEditSession.hasChanges,
                      tab.url.map({ Self.path($0, isInside: source) }) == true else {
                    return nil
                }
                return (workspace, tab)
            }
        }
        guard blocked.isEmpty else {
            if let (workspace, tab) = blocked.first {
                workspace.requestHexSavePreview(for: tab.id)
                CommandTargeting.registeredWindow(for: workspace)?.makeKeyAndOrderFront(nil)
            }
            fileTreeTrashConflictHandler(blocked.map { $0.1.title })
            return nil
        }
        guard let token = WorkspacePathOperationRegistry.begin(paths: [source]) else {
            NSSound.beep()
            return nil
        }
        noteFileMutationChange(in: workspaces)
        return FileTreeTrashOperation(id: token, workspaces: workspaces)
    }

    func finishFileTreeTrash(_ operation: FileTreeTrashOperation) {
        WorkspacePathOperationRegistry.finish(operation.id)
        noteFileMutationChange(in: fileTreeMutationWorkspaces(
            including: operation.workspaces
        ))
    }

    func fileTreeTrashIsInFlight(for url: URL?) -> Bool {
        fileMutationIsInFlight(for: url)
    }

    func fileMutationIsInFlight(for url: URL?) -> Bool {
        WorkspacePathOperationRegistry.contains(url)
    }

    var fileTreeTrashConflictHandler: ([String]) -> Void = { titles in
        NSAlert.runWarning(
            title: L10n.string("Offene Hex-Änderungen"),
            text: L10n.format(
                "Speichere oder verwirf zuerst die Byteänderungen in %@. Erst danach kann der Eintrag in den Papierkorb gelegt werden.",
                titles.joined(separator: ", ")
            )
        )
    }

    private static func path(_ candidate: URL, isInside source: URL) -> Bool {
        path(candidate.standardizedFileURL.path,
             isInsidePath: source.standardizedFileURL.path)
    }

    private static func path(_ candidatePath: String, isInsidePath sourcePath: String) -> Bool {
        candidatePath == sourcePath || candidatePath.hasPrefix(sourcePath + "/")
    }

    private func fileTreeMutationWorkspaces() -> [Workspace] {
        fileTreeMutationWorkspaces(including: [])
    }

    private func fileTreeMutationWorkspaces(
        including captured: [Workspace]
    ) -> [Workspace] {
        var seen = Set<ObjectIdentifier>()
        return ([self] + captured + fileTreeMutationWorkspaceProvider()).filter { workspace in
            seen.insert(ObjectIdentifier(workspace)).inserted
        }
    }

    private func noteFileMutationChange(in workspaces: [Workspace]) {
        for workspace in workspaces {
            workspace.fileMutationRevision &+= 1
        }
    }

    /// Offene Inhalte bleiben nach dem Verschieben in den Papierkorb als
    /// unbenannte, geänderte Tabs erhalten. Das schützt auch noch nicht
    /// gespeicherte Änderungen und verhindert ein Wiederanlegen am alten Pfad.
    func handleFileTreeTrash(
        _ source: URL,
        operation: FileTreeTrashOperation? = nil
    ) {
        let workspaces = fileTreeMutationWorkspaces(
            including: operation?.workspaces ?? []
        )
        for workspace in workspaces {
            workspace.handleFileTreeTrashLocally(source)
        }
    }

    private func handleFileTreeTrashLocally(_ source: URL) {
        let sourcePath = source.standardizedFileURL.path
        let prefix = sourcePath + "/"
        var nonTextTabIDs: [UUID] = []
        for index in tabs.indices {
            guard let url = tabs[index].url else { continue }
            let path = url.standardizedFileURL.path
            guard path == sourcePath || path.hasPrefix(prefix) else { continue }
            // Ein Lade-Platzhalter besitzt noch keinen vollständigen Inhalt,
            // den Fastra retten könnte. Er muss wie eine Abschnittsansicht
            // verschwinden; seine Generation wird unten gleichzeitig
            // entwertet, sodass die späte Lade-Completion nichts mehr schreibt.
            if tabs[index].isLoading {
                nonTextTabIDs.append(tabs[index].id)
                continue
            }
            // Hex- und Abschnitts-Tabs halten absichtlich keinen vollständigen
            // Puffer. Ein leerer, als dirty markierter „geretteter" Tab wäre
            // deshalb keine Rettung. Saubere Exemplare schließen; eine
            // unerwartet doch dirty Hex-Sitzung bleibt sichtbar erhalten.
            guard tabs[index].displayMode == .text else {
                if tabs[index].hasUnsavedChanges {
                    requestHexSavePreview(for: tabs[index].id)
                } else {
                    nonTextTabIDs.append(tabs[index].id)
                }
                continue
            }
            tabs[index].url = nil
            tabs[index].path = "Aus Papierkorb gerettet"
            tabs[index].externalFileObservation = nil
            tabs[index].externalContentSnapshot = nil
            tabs[index].isDirty = true
            // Ohne Datei gibt es keinen gespeicherten Stand mehr — der Punkt
            // darf durch Rückgängig nicht mehr verschwinden.
            tabs[index].invalidateSavedContentBaseline()
        }
        let previousActive = activeTabID
        for id in nonTextTabIDs {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            previewLoadCancellations.removeValue(forKey: id)?.cancel()
            loadGeneration.removeValue(forKey: id)
            documentLanguageDetector.cancel(
                tabID: id, documentID: tabs[index].documentID
            )
            gitPreviewLoads.cancel(tabID: id)
            recentlyActiveTabIDs.removeAll { $0 == id }
            if comparisonTabID == id { comparisonTabID = nil }
            tabs.remove(at: index)
        }
        if tabs.isEmpty {
            let scratch = Self.makeScratchTab()
            tabs = [scratch]
            activeTabID = scratch.id
        } else if let previousActive,
                  tabs.contains(where: { $0.id == previousActive }) {
            activeTabID = previousActive
        } else if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
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
            clearGitHistoryFile()
            return
        }
        invalidateAndRefreshActiveConflictInspection()
        gitRepositoryStore.refresh(repository: root, scope: .status)
        // Auch wenn eine bereits als „M“ markierte Datei erneut gespeichert
        // wurde, hat sich ihr Patch geändert, obwohl die Status-Flags gleich
        // bleiben. Deshalb nicht allein auf Status-Equality vertrauen.
        refreshOpenGitDiffTabs()
        // Index und HEAD sind ebenfalls symbolische Quellen. Ein externer
        // Stage-/Commit-Vorgang kann ihren Inhalt ändern, ohne dass Fastra
        // selbst durch `refreshOpenGitViews` gelaufen ist.
        refreshOpenGitSnapshotTabs()
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
        guard let root = projectURL, GitRunner.isAvailable else { return }
        // Eine ausdrückliche Branch-Aktualisierung muss NACH einem schon
        // laufenden Full-Batch nochmals lesen. Sonst kann ein externer
        // Checkout genau während dieses Batches dauerhaft unsichtbar bleiben.
        gitRepositoryStore.refresh(
            repository: root, scope: .full,
            ensureFreshAfterCurrentBatch: true
        )
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
            // Eine eingeschränkte Dateihistorie ist ein eigener git-Aufruf und
            // steckt nicht im Snapshot. Sie muss deshalb ausdrücklich nachziehen.
            refreshGitFileHistoryIfNeeded()
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

    // MARK: - Verlauf einer einzelnen Datei (Seitenleiste, Graph-Tab)

    /// Lässt sich für diese Datei überhaupt ein Verlauf zeigen? Ohne Repo,
    /// ohne git oder außerhalb des Projekts bleibt der Menüpunkt weg, statt
    /// später wirkungslos zu sein.
    func canShowGitHistory(for url: URL) -> Bool {
        guard let root = projectURL, gitStatus != nil, GitRunner.isAvailable else {
            return false
        }
        return GitFileHistory.relativePath(of: url, in: root) != nil
    }

    /// Schränkt den Graph-Tab auf den Verlauf EINER Datei ein und zeigt ihn.
    /// Aufrufer ist „Git-Historie anzeigen" im Kontextmenü des Dateibaums.
    func showGitHistory(for url: URL) {
        guard let root = projectURL, gitStatus != nil, GitRunner.isAvailable,
              let relativePath = GitFileHistory.relativePath(of: url, in: root)
        else { return }
        let file = GitHistoryFile(relativePath: relativePath)
        // Der Tabwechsel geschieht auch dann, wenn dieselbe Datei erneut
        // gewählt wird: Der Nutzer hat sichtbar etwas angefordert.
        sidebarMode = .graph
        if gitHistoryFile != file {
            gitHistoryFile = file
            gitFileHistory = []
            gitGraphExpandedCommits = []
        }
        loadGitFileHistory(file)
    }

    /// Zurück zur ganzen Historie. Der volle `gitLog` liegt bereits im
    /// Speicher, deshalb genügt das Verwerfen der Einschränkung.
    func clearGitHistoryFile() {
        guard gitHistoryFile != nil else { return }
        gitFileHistoryLease?.cancel()
        gitFileHistoryLease = nil
        gitHistoryFile = nil
        gitFileHistory = []
        gitFileHistoryState = .idle
        gitGraphExpandedCommits = []
    }

    /// Lädt die Commits der eingeschränkten Datei asynchron.
    ///
    /// Die Generation verwirft die Antwort eines überholten Laufs: Klickt der
    /// Nutzer schnell hintereinander zwei Dateien an, darf die spätere Antwort
    /// der ERSTEN Datei die inzwischen sichtbare zweite nicht überschreiben.
    private func loadGitFileHistory(_ file: GitHistoryFile) {
        guard let context = currentGitActionContext, GitRunner.isAvailable else { return }
        gitFileHistoryLease?.cancel()
        gitFileHistoryGeneration &+= 1
        let generation = gitFileHistoryGeneration
        gitFileHistoryState = .loading
        let request = GitOperationRequest(
            repository: context.root, kind: .refresh,
            arguments: GitFileHistory.arguments(relativePath: file.relativePath)
        )
        gitFileHistoryLease = gitOperationsCoordinator.perform(request) { [weak self] outcome in
            guard let self, self.gitFileHistoryGeneration == generation,
                  context.isCurrent(in: self), self.gitHistoryFile == file else { return }
            self.gitFileHistoryLease = nil
            guard case .completed(let result) = outcome else {
                self.gitFileHistoryState = .failed(
                    Self.gitExecutionFailureText(outcome)
                        ?? L10n.string("git-Aufruf fehlgeschlagen.")
                )
                return
            }
            guard result.ok else {
                // Echte git-Ausgabe zeigen statt sie zu schlucken (UX-Regel).
                let message = result.stderrForDisplay
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.gitFileHistoryState = .failed(
                    message.isEmpty ? L10n.string("git-Aufruf fehlgeschlagen.") : message
                )
                return
            }
            self.gitFileHistory = GitGraph.parse(result.stdoutData)
            self.gitFileHistoryState = .idle
        }
    }

    /// Zieht eine sichtbare Dateihistorie nach, wenn sich das Repository
    /// geändert hat (eigener Commit, Pull, externe Änderung). Ohne das zeigte
    /// die eingeschränkte Ansicht nach einem Commit weiter den alten Stand,
    /// während die ganze Historie daneben schon aktuell war.
    private func refreshGitFileHistoryIfNeeded() {
        guard let file = gitHistoryFile else { return }
        loadGitFileHistory(file)
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
    /// Mit `preview` (Einzelklick in der Liste) landet der Diff im flüchtigen
    /// Vorschau-Tab, den der nächste Einzelklick wiederverwendet; ohne
    /// `preview` (Kontextmenü) bleibt der Tab dauerhaft.
    func openGitChangeDiff(change: GitChange, staged: Bool, preview: Bool = false) {
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
                       emptyText: L10n.string("Kein Inhalt."), preview: preview)
    }

    /// Öffnet eine Zeile der Änderungen-Liste als Datei-Tab: mit `preview`
    /// als flüchtigen Vorschau-Tab, sonst (Doppelklick oder „Datei öffnen“
    /// im Kontextmenü) dauerhaft. Gelöschte Dateien werden nicht vom
    /// (fehlenden) Arbeitsverzeichnis gelesen, sondern aus der zum Abschnitt
    /// passenden Git-Version rekonstruiert.
    func openGitChangeFile(change: GitChange, staged: Bool, preview: Bool) {
        guard let context = currentGitActionContext,
              let path = change.actionPath,
              !path.hasSuffix("/") else { return }
        // Der Doppelklick folgt auf seinen eigenen ersten Klick, und der hat
        // den Diff dieser Datei bereits als Vorschau geöffnet. Die dauerhafte
        // Datei übernimmt dann den Tabplatz dieser Diff-Vorschau, statt
        // daneben aufzugehen und die Vorschau verwaist stehen zu lassen.
        // Eine Vorschau zu einer ANDEREN Datei bleibt unberührt.
        let supersededDiffTabID = preview ? nil : tabs.first(where: {
            $0.isPreview && !$0.hasUnsavedChanges
                && $0.gitDiffRequest?.source.changeListPath == path
        })?.id
        let takesPreviewSlot = preview || supersededDiffTabID != nil
        defer {
            // Der Tabplatz wurde wiederverwendet (gleiche ID, jetzt die
            // Datei) oder die Datei war schon offen und wurde nur aktiviert —
            // dann steht die Diff-Vorschau noch daneben und muss weg. Die
            // Datei ist in beiden Fällen ein zweiter Tab, das Fenster bleibt.
            if let supersededDiffTabID, tabs.count > 1,
               tabs.contains(where: {
                   $0.id == supersededDiffTabID && $0.gitDiffRequest != nil
               }) {
                closeTab(id: supersededDiffTabID)
            }
        }
        let state = staged ? change.staged : change.unstaged
        let snapshotSource: GitFileSnapshotSource?
        if staged, state == .deleted {
            snapshotSource = .head
        } else if !staged, state == .deleted {
            snapshotSource = .index
        } else if staged, change.unstaged == .deleted {
            // Gemischtes MD/AD/RD: Die staged Fassung liegt im Index, während
            // der Working Tree die Datei bereits entfernt hat.
            snapshotSource = .index
        } else {
            snapshotSource = nil
        }
        guard let source = snapshotSource else {
            let url = context.root.appendingPathComponent(path)
            loadFile(at: url, preview: takesPreviewSlot, expectedGitContext: context)
            if !preview, let index = tabs.firstIndex(where: {
                $0.url == url.canonicalFileURL
            }) {
                tabs[index].isPreview = false
            }
            return
        }
        let request = GitFileSnapshotRequest(
            repositoryPath: GitOperationRequest.canonicalRepositoryPath(context.root),
            path: path,
            source: source
        )
        loadGitFileSnapshot(request: request, title: change.name,
                            directory: change.directory, preview: takesPreviewSlot,
                            context: context)
        if !preview, let index = tabs.firstIndex(where: {
            $0.gitSnapshotRequest == request
        }) {
            tabs[index].isPreview = false
        }
    }

    /// Lädt einen einzelnen Git-Blob mit fester Speichergrenze in einen
    /// normalen, auswählbaren read-only Text-Tab. Fehler erscheinen im Tab;
    /// ein System-Beep wäre bei aktivierter Bedienungshilfe ein weißes
    /// Bildschirmblitzen und erklärt zudem die Ursache nicht.
    private func loadGitFileSnapshot(request: GitFileSnapshotRequest,
                                     title: String, directory: String,
                                     preview: Bool, context: GitActionContext) {
        guard GitRunner.isAvailable,
              request.repositoryPath
                == GitOperationRequest.canonicalRepositoryPath(context.root) else { return }
        if let index = tabs.firstIndex(where: { $0.gitSnapshotRequest == request }) {
            if !preview {
                // Der Doppelklick folgt unmittelbar auf den Einzelklick und
                // steckt dessen bereits geladenen Tab nur fest. Git-Mutationen
                // stoßen den separaten Snapshot-Refresh selbst an.
                tabs[index].isPreview = false
                activeTabID = tabs[index].id
                return
            }
            activeTabID = tabs[index].id
            // Symbolische Git-Quellen können sich nach Stage/Unstage ändern.
            // Erneutes Öffnen lädt deshalb denselben Tab frisch, statt einen
            // womöglich veralteten Blob aus dem Speicher zu zeigen.
            startGitFileSnapshotLoad(tabID: tabs[index].id, request: request,
                                     context: context)
            return
        }

        let slot = preview ? claimReplaceablePreviewSlot() : nil
        let reason = L10n.string(
            "Diese Datei wurde gelöscht. Fastra zeigt die letzte Git-Version schreibgeschützt."
        )
        let tab = EditorTab(
            id: slot?.id ?? UUID(),
            title: title,
            path: directory.isEmpty ? L10n.string("Git-Vorversion") : directory,
            content: "",
            isLoading: true,
            isPreview: preview,
            readOnlyReason: reason,
            gitSnapshotRequest: request
        )
        if let slot {
            tabs[slot.index] = tab
        } else {
            tabs.append(tab)
        }
        activeTabID = tab.id
        tabs = Workspace.tabsRemovingEmptyScratch(tabs, keeping: tab.id)

        startGitFileSnapshotLoad(tabID: tab.id, request: request,
                                 context: context)
    }

    private func startGitFileSnapshotLoad(tabID: UUID,
                                          request: GitFileSnapshotRequest,
                                          context: GitActionContext) {
        guard let initialIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let ticket = gitPreviewLoads.begin(tab: tabs[initialIndex],
                                           request: .snapshot(request), context: context)
        tabs[initialIndex].isLoading = true
        let operation = GitOperationRequest(
            repository: context.root,
            kind: .diffRead,
            arguments: request.arguments,
            outputLimit: GitOutputLimit(stdoutBytes: Int(FileLoader.largeFileThreshold),
                                        stderrBytes: 256 * 1024)
        )
        let lease = gitOperationsCoordinator.perform(operation) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.gitPreviewLoads.finish(ticket) }
                guard let index = self.gitPreviewLoads.currentIndex(for: ticket, in: self) else { return }
                defer { self.tabs[index].isLoading = false }
                guard case .completed(let result) = outcome, result.exitCode == 0 else {
                    self.tabs[index].content = Self.gitExecutionFailureText(outcome)
                        ?? L10n.string("Die letzte Git-Version konnte nicht geladen werden.")
                    self.tabs[index].recordSavedContentBaseline()
                    return
                }
                guard !result.stdoutWasTruncated else {
                    self.tabs[index].content = L10n.string(
                        "Die letzte Git-Version ist zu groß für die vollständige Textvorschau."
                    )
                    self.tabs[index].recordSavedContentBaseline()
                    return
                }
                let (bom, bomEncoding) = ApplyEngine.detectBOM(in: result.stdoutData)
                let payload = Data(result.stdoutData.dropFirst(bom.count))
                // Nullbytes ohne erklärende Unicode-BOM sind ein belastbares
                // Binärsignal. Die großzügigen Text-Fallbacks des normalen
                // Decoders dürfen daraus keinen scheinbar editierbaren Text machen.
                guard (bomEncoding != nil || !payload.contains(0)),
                      let decoded = ApplyEngine.decode(payload: payload,
                                                       bomEncoding: bomEncoding) else {
                    self.tabs[index].content = L10n.string(
                        "Die letzte Git-Version ist binär oder verwendet eine nicht unterstützte Zeichenkodierung."
                    )
                    self.tabs[index].recordSavedContentBaseline()
                    return
                }
                self.tabs[index].content = decoded.0
                self.tabs[index].encoding = decoded.1
                self.tabs[index].bom = bom
                self.tabs[index].lineEnding = LineEnding.detect(in: decoded.0)
                self.tabs[index].fileSize = UInt64(result.stdoutData.count)
                self.tabs[index].recordSavedContentBaseline()
            }
        }
        gitPreviewLoads.attach(lease, to: ticket)
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
                                existingTabID: UUID? = nil,
                                preview: Bool = false) {
        guard let context = currentGitActionContext, GitRunner.isAvailable,
              request.repositoryPath
                == GitOperationRequest.canonicalRepositoryPath(context.root) else { return }
        guard let tab = prepareGitDiffTab(request: request, title: title,
                                           activate: activate,
                                           existingTabID: existingTabID,
                                           preview: preview) else { return }
        let ticket = gitPreviewLoads.begin(tab: tab, request: .diff(request), context: context)
        let operation = GitOperationRequest(repository: context.root, kind: .diffRead,
                                            arguments: request.arguments,
                                            outputLimit: GitDiffRequest.outputLimit)
        let lease = gitOperationsCoordinator.perform(operation) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.gitPreviewLoads.finish(ticket) }
                guard let index = self.gitPreviewLoads.currentIndex(for: ticket, in: self) else { return }
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
        gitPreviewLoads.attach(lease, to: ticket)
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
        // Der Git-Tab ist aktiv und kein unberührter leerer Tab (er trägt
        // `gitKind`) → er zeigt den Editor, nie den Willkommens-Platzhalter.
    }

    /// `preview` gilt nur beim Anlegen oder Wiederfinden über den Request:
    /// Ein Vorschau-Diff (Einzelklick) übernimmt den flüchtigen Vorschau-Tab,
    /// ein erneuter Aufruf ohne Vorschau-Absicht (Kontextmenü) steckt den
    /// gefundenen Tab dauerhaft fest. Der Refresh über `existingTabID` lässt
    /// den Vorschau-Zustand unverändert.
    private func prepareGitDiffTab(request: GitDiffRequest, title: String,
                                   activate: Bool, existingTabID: UUID?,
                                   preview: Bool = false)
        -> EditorTab? {
        let index: Int
        if let existingTabID {
            guard let found = tabs.firstIndex(where: {
                $0.id == existingTabID && $0.gitDiffRequest == request
            }) else { return nil }
            index = found
        } else if let found = tabs.firstIndex(where: { $0.gitDiffRequest == request }) {
            index = found
            if !preview { tabs[index].isPreview = false }
        } else {
            let slot = preview ? claimReplaceablePreviewSlot() : nil
            let tab = EditorTab(id: slot?.id ?? UUID(), title: title, path: "Git",
                                isPreview: preview, gitKind: .diff,
                                gitDiffRequest: request, gitDiffDocument: nil)
            if let slot {
                tabs[slot.index] = tab
                index = slot.index
            } else {
                tabs.append(tab)
                index = tabs.count - 1
            }
        }
        tabs[index].title = title
        if existingTabID == nil { tabs[index].gitDiffDocument = nil }
        let tabID = tabs[index].id
        if activate { activeTabID = tabID }
        return tabs[index]
    }

    /// Sucht den flüchtigen Vorschau-Tab, den der nächste Einzelklick der
    /// Änderungen-Liste wiederverwenden darf, und bricht dessen laufende
    /// Ladevorgänge ab. Der Aufrufer legt seinen neuen Tab unter derselben ID
    /// an derselben Stelle ab; so springt die Tab-Leiste beim raschen
    /// Durchsehen vieler Zeilen nicht. Ein Vorschau-Tab mit ungesicherter
    /// Arbeit ist tabu.
    private func claimReplaceablePreviewSlot() -> (index: Int, id: UUID)? {
        guard let index = tabs.firstIndex(where: {
            $0.isPreview && !$0.hasUnsavedChanges
        }) else { return nil }
        let id = tabs[index].id
        // Einen noch laufenden Datei-Read dieses Platzes entwerten, ohne den
        // Zähler auf einen wiederverwendbaren Anfangswert zurückzusetzen:
        // Nach `removeValue` bekäme der nächste `loadFile` desselben Platzes
        // wieder Generation 1 — genau die Nummer, mit der ein alter, noch
        // nicht zugestellter Read unterwegs sein kann. Der landete dann mit
        // dem Inhalt der zuvor angeklickten Datei im Tab der neuen (Review
        // 2026-09-02). Hochzählen entwertet ihn und hält die Folge lückenlos.
        loadGeneration[id] = (loadGeneration[id] ?? 0) + 1
        previewLoadCancellations.removeValue(forKey: id)?.cancel()
        documentLanguageDetector.cancel(tabID: id)
        gitPreviewLoads.cancel(tabID: id)
        comparisonTabID = nil
        return (index, id)
    }

    private func updateGitDiffTab(index: Int, title: String, content: String,
                                  document: GitDiffDocument) {
        tabs[index].title = title
        tabs[index].content = content
        tabs[index].gitDiffDocument = document
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
              tab.isDirty, tab.url != nil,
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

    /// Projekt-Schließen lässt Tabs stehen. Die Ladeanzeige muss deshalb
    /// sofort enden, unabhängig davon, ob der abgebrochene Prozess noch antwortet.
    private func cancelGitPreviewsForProjectChange() {
        let tickets = gitPreviewLoads.cancelAll()
        let message = L10n.string("Die Git-Vorschau wurde wegen eines Projektwechsels beendet.")
        for ticket in tickets {
            guard let index = tabs.firstIndex(where: ticket.matches) else { continue }
            tabs[index].isLoading = false
            switch ticket.request {
            case .diff:
                updateGitDiffTab(index: index, title: tabs[index].title, content: message,
                                 document: GitDiffDocument(files: [], limitation: .malformed(message)))
            case .snapshot:
                tabs[index].content = message
                tabs[index].recordSavedContentBaseline()
            }
        }
    }

    private func cancelAllPreviewLoads() {
        let cancellations = previewLoadCancellations.values
        previewLoadCancellations.removeAll()
        cancellations.forEach { $0.cancel() }
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

    /// Index- und HEAD-Adressen sind symbolisch: Nach Stage, Unstage oder
    /// Amend können sie auf einen anderen Blob zeigen. Offene Vorversions-
    /// Tabs werden deshalb zusammen mit den Diffs frisch gelesen.
    func refreshOpenGitSnapshotTabs() {
        guard let context = currentGitActionContext else { return }
        let repositoryPath = GitOperationRequest.canonicalRepositoryPath(context.root)
        let open = tabs.compactMap { tab -> (UUID, GitFileSnapshotRequest)? in
            guard let request = tab.gitSnapshotRequest,
                  request.repositoryPath == repositoryPath else { return nil }
            return (tab.id, request)
        }
        for (tabID, request) in open {
            startGitFileSnapshotLoad(tabID: tabID, request: request,
                                     context: context)
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
        // Ein zweites Fenster kann seit unserem Init weitere Einträge
        // gespeichert haben. Die lokale Kopie darf sie nicht überschreiben.
        let persisted = SearchHistoryStore.load(from: defaultsStore)
        searchHistory = SearchHistoryStore.prepending(entry, to: persisted)
    }

    /// Bewusster Löschbefehl aus dem Verlauf-Menü. Anders als beim Hinzufügen
    /// wird hier nicht zusammengeführt: Der Nutzer will den gemeinsamen
    /// persistenten Verlauf vollständig leeren.
    func clearSearchHistory() {
        searchHistory = []
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

    /// Entscheidet, ob ein Suchkürzel den Scope wechseln darf. Ist eine
    /// befüllte Suchmaske bereits offen, bedeutet ⌘F bzw. ⇧⌘F nur noch
    /// „Maske nach vorn“: Ein unbemerkter Wechsel von Ordner zu Datei würde
    /// sonst die Ergebnisliste neu aufbauen und den aktiven Treffer verlieren.
    static func searchScopeWhenPresenting(requested: SearchScope,
                                          current: SearchScope,
                                          dialogOpen: Bool,
                                          findPattern: String) -> SearchScope {
        dialogOpen && !findPattern.isEmpty ? current : requested
    }

    /// Gemeinsamer Modellpfad für Menü und globale Tastenkürzel. Die
    /// Auswahl wird nur beim echten NEUÖFFNEN der Datei-Suche eingefroren;
    /// ein bloßes Nach-vorn-Holen verändert weder Scope noch „Nur Auswahl“.
    ///
    /// `forceScope` gilt für den ausdrücklich beschrifteten Menüpunkt „In
    /// Ordnern suchen…“: Er verspricht einen bestimmten Bereich und muss ihn
    /// deshalb auch bei offener, befüllter Maske herstellen. Die Kurzbefehle
    /// bleiben bereichserhaltend (Review 2026-08-06).
    func presentSearch(requestedScope: SearchScope, captureSelection: Bool = false,
                       forceScope: Bool = false) {
        let preserveExistingSearch = showSearchDialog && !findPattern.isEmpty
        scope = forceScope ? requestedScope : Self.searchScopeWhenPresenting(
            requested: requestedScope,
            current: scope,
            dialogOpen: showSearchDialog,
            findPattern: findPattern
        )
        if captureSelection && !preserveExistingSearch && scope == .file {
            captureSelectionForSearch()
        }
        showSearchDialog = true
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
        addSearchFolderPaths(panel.urls.map(\.path))
    }

    /// Fügt Ordner auf Grundlage des jüngsten gemeinsamen Defaults-Stands
    /// hinzu. Der getrennte Helfer hält den Panel-Pfad testbar und verhindert,
    /// dass ein älteres Fenster Einträge eines anderen Fensters verliert.
    func addSearchFolderPaths(_ paths: [String]) {
        let persisted = RecentSearchFoldersStore.load(from: defaultsStore)
        recentSearchFolders = Workspace.prependingFolders(paths, to: persisted)
    }

    /// Ändert genau den über seinen Pfad identifizierten gemeinsamen Eintrag.
    /// UUIDs eignen sich hier nicht: Sie werden beim Laden aus UserDefaults
    /// absichtlich neu erzeugt und unterscheiden sich deshalb je Fenster.
    func setSearchFolderEnabled(path: String, enabled: Bool) {
        let normalized = (path as NSString).expandingTildeInPath
        var persisted = RecentSearchFoldersStore.load(from: defaultsStore)
        guard let index = persisted.firstIndex(where: {
            ($0.path as NSString).expandingTildeInPath == normalized
        }) else {
            recentSearchFolders = persisted
            return
        }
        persisted[index].enabled = enabled
        recentSearchFolders = persisted
    }

    /// Entfernt genau einen Ordner aus dem neuesten gemeinsamen Stand.
    func removeSearchFolder(path: String) {
        let normalized = (path as NSString).expandingTildeInPath
        var persisted = RecentSearchFoldersStore.load(from: defaultsStore)
        persisted.removeAll {
            ($0.path as NSString).expandingTildeInPath == normalized
        }
        recentSearchFolders = persisted
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
        /// Exakte Dateibasis eines Ordner-Treffers. Zusammen mit der bereits
        /// im Such-Worker kanonisierten URL bindet sie einen verzögerten
        /// Sprung an genau den sichtbaren Plattenstand, ohne Main-Thread-I/O.
        let fileSnapshot: FileSnapshot?
        /// Ziel-Tab im Geöffnet-Scope: Die Navigation aktiviert diesen Tab
        /// statt eine Datei zu laden (auch ungespeicherte Tabs erreichbar).
        let tabID: UUID?
        let match: BufferSearch.Match

        init(id: UUID, url: URL?, fileSnapshot: FileSnapshot? = nil,
             tabID: UUID? = nil, match: BufferSearch.Match) {
            self.id = id
            self.url = url
            self.fileSnapshot = fileSnapshot
            self.tabID = tabID
            self.match = match
        }
    }

    var navMatches: [NavMatch] {
        if scope.isFolderLike {
            // Während ein neuer Lauf aussteht oder arbeitet, existiert keine
            // gültige Navigations-/Apply-Basis — selbst dann nicht, wenn ein
            // zukünftiger Refactor das physische Leeren einmal verzögert.
            guard !folderSearching, !folderNeedsSearch else { return [] }
            return folderResults.flatMap { pf in
                pf.matches.map {
                    NavMatch(id: $0.id, url: pf.url,
                             fileSnapshot: pf.snapshot, match: $0)
                }
            }
        }
        // Datei- und Geöffnet-Treffer bleiben während des 120-ms-Debounce
        // sichtbar, damit die Liste beim Tippen nicht flackert. Sobald der
        // SearchRunner ihre Optionsbindung entzieht, dürfen Klick, Return,
        // Chevron und ⌘G diese alte Trefferbasis aber nicht mehr verwenden.
        // Erst der abgeschlossene Neulauf bindet die Liste wieder an genau
        // die aktuellen Optionen.
        guard visibleBufferResultsOptions == currentSearchOptions else {
            return []
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

    private func blockedTabsForFileMutation(
        urls: [URL], workspaces: [Workspace]
    ) -> [(workspace: Workspace, tab: EditorTab)] {
        // Ordnersuche und Dateilader veröffentlichen bereits kanonische URLs.
        // Hier bleibt nur eine lexikalische Normalisierung; anders als
        // `canonicalFileURL` fragt sie keine Dateisystem-Metadaten ab.
        let targetPaths = Set(urls.map { $0.standardizedFileURL.path })
        return workspaces.flatMap { workspace in
            workspace.tabs.compactMap { tab in
                guard let url = tab.url,
                      targetPaths.contains(url.standardizedFileURL.path),
                      tab.hasUnsavedChanges || tab.isLoading else { return nil }
                return (workspace, tab)
            }
        }
    }

    private func reportFolderFileMutationConflict(
        _ blocked: [(workspace: Workspace, tab: EditorTab)]
    ) {
        if let first = blocked.first, first.tab.hexEditSession.hasChanges {
            first.workspace.requestHexSavePreview(for: first.tab.id)
        }
        folderApplyConflictHandler(blocked.map(\.tab.title))
    }

    private func reloadOpenTabsAcrossWorkspaces(
        for urls: [URL], capturedWorkspaces: [Workspace]
    ) {
        for workspace in fileTreeMutationWorkspaces(including: capturedWorkspaces) {
            workspace.reloadOpenTabs(for: urls)
        }
    }

    /// Ein Hex-Save schreibt direkt aus der Abschnittsansicht. Alle Fenster,
    /// die dieselbe Datei sauber geöffnet haben, müssen den neuen Plattenstand
    /// trotzdem sofort übernehmen; ein App-Aktivierungswechsel findet bei
    /// zwei gleichzeitig sichtbaren Fastra-Fenstern nicht statt.
    func handleHexWrite(at url: URL) {
        let path = url.standardizedFileURL.path
        for workspace in fileTreeMutationWorkspaces() {
            if workspace.folderResults.contains(where: {
                $0.url.standardizedFileURL.path == path
            }) {
                // Der Hex-Save ist eine eigene Plattenmutation. Tabänderungen
                // starten im Ordner-Scope absichtlich keine neue Suche; die
                // sichtbare Vorschau muss deshalb hier ausdrücklich verfallen.
                workspace.searchRunner?.folderResultsBecameStale()
            }
            let dirtyIDs = workspace.tabs.compactMap { tab -> UUID? in
                guard tab.url?.standardizedFileURL.path == path,
                      tab.hasUnsavedChanges else { return nil }
                return tab.id
            }
            workspace.reloadOpenTabs(for: [url])
            for id in dirtyIDs {
                workspace.checkExternalChanges(only: id)
            }
        }
    }

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
              !folderSearching,
              !folderNeedsSearch,
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

        // Ein Alert pumpt die Runloop; auch ein zweites Fenster kann bis hier
        // noch Text oder Bytes geändert haben. Erst unmittelbar vor dem
        // Hintergrundstart wird deshalb app-weit erneut geprüft und gesperrt.
        let mutationWorkspaces = fileTreeMutationWorkspaces()
        let blockedTabs = blockedTabsForFileMutation(
            urls: urls, workspaces: mutationWorkspaces
        )
        guard blockedTabs.isEmpty else {
            reportFolderFileMutationConflict(blockedTabs)
            return false
        }
        guard let mutationID = WorkspacePathOperationRegistry.begin(paths: urls) else {
            folderPreviewConflictHandler(L10n.string(
                "Eine andere Dateioperation verändert bereits mindestens eine Zieldatei. Warte auf ihren Abschluss und prüfe danach die Vorschau erneut."))
            return false
        }
        folderApplyMutationOperation = FolderApplyMutationOperation(
            id: mutationID, workspaces: mutationWorkspaces
        )
        noteFileMutationChange(in: mutationWorkspaces)

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
                guard let self else {
                    WorkspacePathOperationRegistry.finish(mutationID)
                    return
                }
                self.finishFolderApply(
                    result, generation: generation, mutationID: mutationID
                )
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

    private func finishFolderApply(
        _ result: Result<ApplySession, Error>, generation: Int, mutationID: UUID
    ) {
        guard folderApplyGeneration == generation else {
            WorkspacePathOperationRegistry.finish(mutationID)
            return
        }
        let mutation = folderApplyMutationOperation
        folderApplyMutationOperation = nil
        defer {
            WorkspacePathOperationRegistry.finish(mutationID)
            noteFileMutationChange(in: fileTreeMutationWorkspaces(
                including: mutation?.workspaces ?? []
            ))
        }
        folderApplyTask = nil
        folderApplying = false
        folderApplyProgressText = nil
        switch result {
        case .success(let session):
            lastApplySession = session
            // Die Dateien auf der Platte sind jetzt andere als die, aus denen
            // die sichtbare Trefferliste entstand.
            searchRunner?.folderResultsBecameStale()
            reloadOpenTabsAcrossWorkspaces(for: session.entries.map {
                URL(fileURLWithPath: $0.originalPath)
            }, capturedWorkspaces: mutation?.workspaces ?? [])
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
            // Auch der Teil-Erfolg hat Dateien verändert.
            searchRunner?.folderResultsBecameStale()
            reloadOpenTabsAcrossWorkspaces(for: session.entries.map {
                URL(fileURLWithPath: $0.originalPath)
            }, capturedWorkspaces: mutation?.workspaces ?? [])
        case .failure(let error):
            NSAlert(error: error).runModal()
        }
    }

    /// Macht die letzte Folder-Apply-Session bit-exakt rückgängig.
    @discardableResult
    func undoLastFolderApply() -> Bool {
        guard !folderApplying, let session = lastApplySession else { return false }
        let urls = session.entries.map { URL(fileURLWithPath: $0.originalPath) }
        let mutationWorkspaces = fileTreeMutationWorkspaces()
        let blockedTabs = blockedTabsForFileMutation(
            urls: urls, workspaces: mutationWorkspaces
        )
        guard blockedTabs.isEmpty else {
            reportFolderFileMutationConflict(blockedTabs)
            return false
        }
        guard let mutationID = WorkspacePathOperationRegistry.begin(paths: urls) else {
            folderPreviewConflictHandler(L10n.string(
                "Eine andere Dateioperation verändert bereits mindestens eine Zieldatei. Warte auf ihren Abschluss und versuche Rückgängig danach erneut."))
            return false
        }
        noteFileMutationChange(in: mutationWorkspaces)
        defer {
            WorkspacePathOperationRegistry.finish(mutationID)
            noteFileMutationChange(in: fileTreeMutationWorkspaces(
                including: mutationWorkspaces
            ))
        }
        do {
            try ApplyEngine.undo(session)
            // Rückgängig schreibt die Dateien erneut — dieselbe Lage wie nach
            // dem Apply: Die sichtbaren Treffer gehören zu einem alten Stand.
            searchRunner?.folderResultsBecameStale()
            reloadOpenTabsAcrossWorkspaces(
                for: urls, capturedWorkspaces: mutationWorkspaces
            )
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
            searchRunner?.folderResultsBecameStale()
            reloadOpenTabsAcrossWorkspaces(
                for: partial.entries.filter { $0.state == .restored }
                    .map { URL(fileURLWithPath: $0.originalPath) },
                capturedWorkspaces: mutationWorkspaces
            )
            return false
        } catch ApplyError.backupFailed(let message) {
            // Beschädigte oder manipulierte Sicherung: Der sichere Abbruch ist
            // beabsichtigt. Die bereits lokalisierte Hash-/Backup-Ursache muss
            // als Nutzermeldung erscheinen, nicht als rohe Enum-Beschreibung.
            NSAlert.runWarning(title: L10n.string("Rückgängig abgelehnt"),
                               text: message)
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
        let changed = Set(changedURLs.map { $0.standardizedFileURL.path })
        // Snapshot der zu reloadenden Tab-IDs + URLs aufnehmen — die
        // Schleife muss nicht auf dem aktuellen `tabs`-Array laufen.
        let toReload: [(id: UUID, url: URL, contentRevision: UInt64,
                       diskSnapshot: FileSnapshot?)] = tabs.compactMap { tab in
            guard let url = tab.url,
                  changed.contains(url.standardizedFileURL.path) else { return nil }
            // Ein Dirty-/Ladezustand darf weder hier noch in der Completion
            // automatisch verworfen werden.
            guard !tab.hasUnsavedChanges, !tab.isLoading else { return nil }
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
                        // URL-Vergleich wie in `reloadTabFromDisk`: kein
                        // Inhalt des alten Pfads in einen während des Ladens
                        // umgebundenen Tab.
                        guard self.tabs[idx].url == url,
                              !self.tabs[idx].hasUnsavedChanges,
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
                        self.tabs[idx].hexEditSession.discard()
                        self.tabs[idx].diskSnapshot = loaded.diskSnapshot
                        self.tabs[idx].recordExternalFileObservation(
                            snapshot: loaded.diskSnapshot,
                            observation: loaded.externalObservation,
                            contentLoaded: true
                        )
                        self.tabs[idx].isDirty    = false
                        self.tabs[idx].isLoading  = false
                        // Der frisch geladene Inhalt IST jetzt der gespeicherte
                        // Stand — wie auf jedem anderen Lade- und Speicherpfad.
                        // Ohne diese Zeile blieb die alte Basis stehen: Ein Undo
                        // auf den Vor-Apply-Inhalt hätte den Tab wieder „sauber"
                        // aussehen lassen, und ⌘W hätte ihn ohne Nachfrage
                        // geschlossen (Review 2026-08-02).
                        self.tabs[idx].recordSavedContentBaseline()
                    } else {
                        // Reload fehlgeschlagen: isLoading zurücksetzen,
                        // aber alten Inhalt NICHT löschen (besser veralteter
                        // Inhalt als leere Anzeige).
                        self.tabs[idx].isLoading = false
                        if self.tabs[idx].url == url {
                            self.tabs[idx].protectContentAfterExternalFileBecameUnavailable()
                        }
                    }
                }
            }
        }
    }

    /// Gemeinsame Freigabe für „Alle ersetzen" im aktiven Buffer.
    ///
    /// `bufferTotalMatches` statt `bufferMatches.count`: bei gekappter Liste
    /// gibt es mehr Treffer als materialisiert sind.
    ///
    /// Die letzte Bedingung hält die Vorschau-Grenze: Die sichtbare
    /// Trefferzahl darf nur eine Ersetzung freigeben, die zu GENAU DIESEN
    /// Optionen gehört. Sonst gäbe der alte Trefferstand kurz nach einem
    /// Tastendruck eine Ersetzung mit dem neuen Muster frei
    /// (Review 2026-08-02).
    ///
    /// Jede Oberfläche mit einem „Alle ersetzen"-Knopf muss dieselbe Freigabe
    /// abfragen. Die Vorschau tat das nicht und ließ ihren Knopf allein an
    /// der Zeilenzahl aktiv: Ein Klick im Debounce-Fenster sah wirksam aus
    /// und tat nichts (Review 2026-08-06).
    var canApplyAllInActiveBuffer: Bool {
        activeTab.map { textEditingIsAllowed(for: $0) } == true
            && bufferTotalMatches > 0 && searchError == nil
            && !bufferResultsWereCapped
            && bufferMatches.count == bufferTotalMatches
            && visibleBufferResultsOptions == currentSearchOptions
    }

    /// `true`, sobald die sichtbare Geöffnet-Trefferbasis mindestens einen
    /// schreibgeschützten Tab enthält. Die Maske erklärt damit sichtbar,
    /// warum „Alle ersetzen“ gesperrt bleibt.
    var openResultsContainReadOnlyTabs: Bool {
        let matchingTabIDs = Set(openResults.map(\.id))
        return tabs.contains {
            matchingTabIDs.contains($0.id) && !textEditingIsAllowed(for: $0)
        }
    }

    /// Freigabe für „Alle ersetzen“ im Geöffnet-Bereich. Die sichtbare
    /// Trefferbasis muss vollständig schreibbar sein: Ein Treffer in einer
    /// read-only Git-Ansicht darf nicht bloß übersprungen werden, denn dann
    /// würde Apply auf weniger Treffer wirken als die Vorschau zeigt.
    var canApplyAllInOpenTabs: Bool {
        guard openTotalMatches > 0, searchError == nil,
              !openResultsWereCapped,
              openResults.reduce(0, { $0 + $1.matches.count }) == openTotalMatches,
              visibleBufferResultsOptions == currentSearchOptions else {
            return false
        }
        let matchingTabIDs = Set(openResults.map(\.id))
        return !matchingTabIDs.isEmpty && matchingTabIDs.allSatisfy { id in
            guard let tab = tabs.first(where: { $0.id == id }) else { return false }
            return textEditingIsAllowed(for: tab)
        }
    }

    var canReplaceActiveSearchMatch: Bool {
        guard !scope.isFolderLike, searchError == nil,
              visibleBufferResultsOptions == currentSearchOptions else {
            return false
        }
        if scope == .open {
            let matches = navMatches
            guard matches.indices.contains(activeMatchIndex),
                  let tabID = matches[activeMatchIndex].tabID else { return false }
            guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
            return textEditingIsAllowed(for: tab)
        }
        return activeTab.map { textEditingIsAllowed(for: $0) } == true
            && bufferMatches.indices.contains(activeMatchIndex)
    }

    /// Ersetzt alle aktuell gefundenen Treffer im aktiven Buffer durch
    /// ihre Replacement-Texte. NUR im Speicher — keine Disk-Writes, kein
    /// Apply-Backup (das ist die Schiene für die Ordner-Suche). Speichern
    /// erfolgt wie gewohnt über CMD+S; das markiert den Tab als dirty.
    /// Liefert `true`, wenn wirklich ersetzt wurde. Der Rückgabewert ist keine
    /// Kosmetik: Die Vorschau darf sich nur nach einer bestätigten Anwendung
    /// schließen, sonst verschwindet sie im Debounce-Fenster wirkungslos
    /// (Review 2026-08-06).
    @discardableResult
    func applyAllInActiveBuffer() -> Bool {
        guard canApplyAllInActiveBuffer else { return false }
        recordSearchHistory()
        let text = activeTabContent.wrappedValue
        // Voll-Replace über den ganzen Text (bzw. die eingefrorene Auswahl bei
        // „Nur in Auswahl"). Der Guard oben verlangt eine vollständige
        // Trefferliste; damit entspricht die angewendete Menge exakt der
        // sichtbaren Vorschau und enthält keine Treffer jenseits des Caps.
        guard let replaced = BufferSearch.replaceAll(in: text, options: currentSearchOptions,
                                                     searchRange: activeSearchRange),
              replaced != text else { return false }
        activeTabContent.wrappedValue = replaced
        // Editor zur Neuerzeugung zwingen, sonst zeigt CodeEditSourceEditor
        // weiter den Vor-Replace-Text (Binding-Änderungen fließen NICHT zurück
        // in die TextView). Ohne das wirkt „Alle ersetzen" folgenlos, obwohl
        // das Modell korrekt ersetzt wurde (siehe `editorReloadNonce`).
        editorReloadNonce += 1
        // Wie im Geöffnet-Pfad: Eine programmgesteuerte Ganzersetzung kann
        // das Format bei fast gleicher Länge komplett wechseln. Die vom
        // Binding-Setter angestoßene Erkennung würde so einen Fall über die
        // Tipp-Drossel verschlucken — deshalb ausdrücklich erzwingen
        // (Review 2026-08-31).
        forceLanguageDetectionAfterProgrammaticReplace(
            oldText: text, newText: replaced)
        // „Nur in Auswahl": eingefrorene Range um die Gesamt-Längenänderung
        // aller ersetzten Treffer mitführen, damit der (async) Re-Find des
        // SearchRunners den richtigen Bereich nimmt.
        adjustSearchSelectionRange(lengthDelta: (replaced as NSString).length - (text as NSString).length)
        // SearchRunner reagiert auf die tabs-Änderung und sucht neu.
        // Nach Apply gibt es typischerweise 0 Treffer (Pattern matched
        // den eingefügten Replace-Text nicht mehr); activeMatchIndex
        // wird vom Runner auf 0 geclampt.
        return true
    }

    /// „Alle ersetzen" im Geöffnet-Scope: ersetzt ALLE Treffer in ALLEN
    /// offenen Tabs — rein in-memory (kein Disk-Write, kein Apply-Backup;
    /// Speichern wie gewohnt via ⌘S pro Tab). Geänderte Tabs werden dirty
    /// markiert, der sichtbare Editor per Reload-Nonce neu erzeugt (CESE
    /// übernimmt Binding-Änderungen nicht — gleiche Falle wie im
    /// Buffer-Pfad). Liefert die Anzahl geänderter Tabs (Testbarkeit).
    @discardableResult
    func applyAllInOpenTabs() -> Int {
        // Gleiche Vorschau-Grenze wie im Datei-Scope: nur eine Trefferzahl,
        // die zu den aktuellen Suchoptionen gehört, gibt das Ersetzen frei.
        guard canApplyAllInOpenTabs else { return 0 }
        recordSearchHistory()
        let inputs = tabs.filter { textEditingIsAllowed(for: $0) }.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title, content: $0.content)
        }
        let changed = OpenTabsSearch.replaceAll(tabs: inputs, options: currentSearchOptions)
        guard !changed.isEmpty else { return 0 }
        for idx in tabs.indices {
            guard let newContent = changed[tabs[idx].id] else { continue }
            // Eignung VOR den Längen bestimmen: `String.count` läuft linear
            // über alle Graphemcluster und blockierte hier den Main-Thread
            // auch für gespeicherte große Dateien, die an der
            // Inhaltserkennung gar nicht teilnehmen (Review 2026-08-31).
            // Die Eignung hängt nicht vom Inhalt ab und ändert sich durch die
            // Ersetzung nicht.
            let needsLanguageLengths = Self.isEligibleForContentDetection(tabs[idx])
            let oldLength = needsLanguageLengths ? tabs[idx].content.count : 0
            tabs[idx].content = newContent
            tabs[idx].isDirty = true
            // Direkte Modellmutation läuft am `activeTabContent`-Binding (und
            // damit an dessen Makro-Abbruch) vorbei. Eine Inhaltsänderung
            // entwertet die Lease der Makro-Nachbearbeitung aber genauso wie
            // normales Tippen — sonst blieben Diff-Task und Makro-Sperre bis
            // zum Rechenende aktiv (Review 2026-08-29).
            cancelFourDMacroPostprocessing(ifTab: tabs[idx].id)
            if needsLanguageLengths {
                scheduleLanguageDetection(
                    tabID: tabs[idx].id,
                    oldLength: oldLength,
                    newLength: newContent.count,
                    forceAnalysis: true)
            }
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
        // Auch hier gilt die Vorschau-Grenze, und zwar noch direkter als beim
        // Alle-Ersetzen: Der Treffer wird als BEREICH in den aktuellen Text
        // gespleißt. Gehört er zu einem älteren Muster oder Textstand, träfe
        // der Bereich die falsche Stelle (Review 2026-08-02).
        guard canReplaceActiveSearchMatch else { return }
        recordSearchHistory()
        if scope == .open {
            replaceActiveOpenMatch()
            return
        }
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
        // Auch das Einzel-Ersetzen ist eine programmgesteuerte Ersetzung und
        // muss die Tipp-Drossel der Inhaltserkennung umgehen (siehe
        // applyAllInActiveBuffer, Review 2026-08-31).
        forceLanguageDetectionAfterProgrammaticReplace(
            oldText: text, newText: replaced)

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
        // Die frische Vorschau gehört zu genau diesen Optionen — sonst bliebe
        // „Alle ersetzen" nach einem Einzel-Ersetzen bis zum Async-Lauf gesperrt.
        visibleBufferResultsOptions = currentSearchOptions
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
        NotificationCenter.default.postMatchJump(
            target, for: self, generation: beginMatchJump())
    }

    /// Geöffnet-Scope-Gegenstück zum Datei-Pfad oben. Der sichtbare Treffer
    /// trägt seine Ziel-Tab-ID; `bufferMatches` ist in diesem Scope absichtlich
    /// leer. Die erneute Suche über alle Tabs bleibt im `SearchRunner`, damit
    /// auch viele oder große offene Dokumente den Main-Thread nicht blockieren.
    private func replaceActiveOpenMatch() {
        let matches = navMatches
        guard matches.indices.contains(activeMatchIndex) else { return }
        let target = matches[activeMatchIndex]
        guard let tabID = target.tabID,
              let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              textEditingIsAllowed(for: tabs[tabIndex]) else { return }

        let text = tabs[tabIndex].content
        let replaced = BufferSearch.applyReplacements(in: text, matches: [target.match])
        guard replaced != text else { return }

        // Vor der @Published-Array-Mutation setzen: Sie stößt synchron die
        // Invalidierung und verzögert danach den asynchronen Neulauf an.
        pendingOpenReplaceNavigation = (currentSearchOptions, activeMatchIndex)
        // Eignung VOR den Längen bestimmen — `String.count` ist linear und
        // für ungeeignete (z. B. gespeicherte große) Tabs reine Main-Thread-
        // Verschwendung (Review 2026-08-31, wie in applyAllInOpenTabs).
        let needsLanguageLengths = Self.isEligibleForContentDetection(tabs[tabIndex])
        tabs[tabIndex].content = replaced
        tabs[tabIndex].isDirty = true
        // Wie in `applyAllInOpenTabs`: Die direkte Modellmutation muss die
        // Makro-Nachbearbeitung dieses Tabs selbst abbrechen — sie umgeht
        // das `activeTabContent`-Binding (Review 2026-08-29).
        cancelFourDMacroPostprocessing(ifTab: tabID)
        if needsLanguageLengths {
            scheduleLanguageDetection(
                tabID: tabID, oldLength: text.count, newLength: replaced.count,
                forceAnalysis: true)
        }
        if activeTabID != tabID { selectTab(id: tabID) }
        editorReloadNonce += 1
    }

    /// Erzwingt die Inhaltsspracherkennung nach einer programmgesteuerten
    /// Ersetzung im aktiven Tab. Der Setter von `activeTabContent` plant nur
    /// die gedrosselte Tipp-Erkennung; ersetzt eine Aktion den gesamten
    /// Inhalt durch ein anderes Format ähnlicher Länge, lieferte die Drossel
    /// `.none` und Sprache samt Syntaxhervorhebung blieben beim alten Format
    /// (Review 2026-08-31). Längen werden nur für geeignete Tabs gezählt.
    private func forceLanguageDetectionAfterProgrammaticReplace(
        oldText: String, newText: String
    ) {
        guard let idx = activeTabIndex,
              Self.isEligibleForContentDetection(tabs[idx]) else { return }
        scheduleLanguageDetection(
            tabID: tabs[idx].id,
            oldLength: oldText.count,
            newLength: newText.count,
            forceAnalysis: true)
    }

    /// Wird ausschließlich von der erfolgreichen Geöffnet-Suche aufgerufen.
    /// Der frühere Nachfolger steht nach dem Entfernen des aktiven Treffers am
    /// selben flachen Index; am Listenende springt der Clamp zum letzten noch
    /// vorhandenen Treffer. Ein inzwischen geändertes Pattern verwirft den
    /// vorgemerkten Sprung, statt auf eine andere Trefferbasis zu zeigen.
    func finishPendingOpenReplaceNavigation(for options: SearchOptions) {
        guard let pending = pendingOpenReplaceNavigation else { return }
        pendingOpenReplaceNavigation = nil
        guard scope == .open, pending.options == options else { return }
        let matches = navMatches
        guard !matches.isEmpty else { return }

        let previousIndex = activeMatchIndex
        let nextIndex = min(pending.index, matches.count - 1)
        let target = matches[nextIndex]
        if let tabID = target.tabID, activeTabID != tabID {
            selectTab(id: tabID)
        }
        guard let tabID = target.tabID,
              let documentID = tabs.first(where: { $0.id == tabID })?.documentID
        else { return }
        let expected = MatchJumpTarget.document(documentID)
        // Auch der Nachrück-Sprung ist eine Navigation: Klickt der Nutzer
        // währenddessen einen anderen Treffer an, darf diese Completion den
        // neueren Sprung nicht mehr überschreiben.
        let jumpGeneration = beginMatchJump()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scope == .open else { return }
            let posted = NotificationCenter.default.postMatchJump(
                target.match, for: self, requiring: expected,
                generation: jumpGeneration
            )
            guard let index = MatchJumpCommit.index(
                previous: previousIndex, current: self.activeMatchIndex,
                next: nextIndex, posted: posted
            ) else { return }
            self.activeMatchIndex = index
        }
    }

    /// Verhindert, dass ein abgebrochener Geöffnet-Neulauf seinen alten
    /// Weitersuchen-Auftrag nach Schließen der Maske oder Scope-Wechsel später
    /// wieder aufgreift.
    func discardPendingOpenReplaceNavigation() {
        pendingOpenReplaceNavigation = nil
    }

    /// Stößt die explizite Ordner-Suche an („Suchen"-Klick / Return in der
    /// Maske). Der Ordner-Scope wird bewusst NICHT live durchsucht
    /// (Konzept Abschnitt C) — dies ist der einzige Auslöser dafür.
    func runFolderSearchNow() {
        recordSearchHistory()
        searchRunner?.runFolderSearch()
    }

    /// Verwirft eine Ordner-Trefferbasis, deren Datei sich seit dem Suchlauf
    /// geändert hat, und erklärt den nötigen neuen Suchlauf.
    func folderMatchNavigationBecameStale() {
        searchRunner?.folderResultsBecameStale()
        folderNavigationNotice = L10n.string(
            "Die Datei hat sich seit der Suche geändert. Bitte erneut suchen.")
    }

    /// Erklärt, warum der Sprung zu einem Ordner-Treffer gerade nicht
    /// ausgeführt wird, OHNE die weiterhin gültige Trefferbasis zu verwerfen:
    /// Der offene Tab der Funddatei enthält ungesicherte Änderungen, und eine
    /// neue Suche würde diesen Konflikt nicht lösen (Review 2026-08-31).
    func folderMatchNavigationBlockedByUnsavedChanges() {
        folderNavigationNotice = L10n.string(
            "Die Funddatei ist mit ungesicherten Änderungen geöffnet. Ohne Speichern schließen und erneut springen – oder speichern und danach erneut suchen.")
    }

    /// Gemeinsame Reaktion der Treffer-Navigation (ContentView und
    /// Suchmaske) auf einen abgelehnten Ladeauftrag: Nur der echte
    /// Plattenstand-Konflikt (und eine nicht mehr lesbare Datei) entwertet
    /// die Trefferbasis. Ein noch laufender Ladevorgang oder ein entwerteter
    /// Auftrag lässt die gültigen Ordnerergebnisse unangetastet
    /// (Review 2026-08-31).
    func handleFolderMatchLoadDenial(_ outcome: FileLoadOutcome,
                                     jumpGeneration: Int) {
        guard isCurrentMatchJump(jumpGeneration) else { return }
        switch outcome {
        case .staleSnapshot, .failed:
            folderMatchNavigationBecameStale()
        case .unsavedChanges:
            folderMatchNavigationBlockedByUnsavedChanges()
        case .busyLoading, .cancelled, .opened:
            break
        }
    }

    /// Trefferliste als LF-getrennten String ins Clipboard kopieren —
    /// schneller Direktweg neben dem konfigurierbaren Extrahieren-Dialog.
    /// Im Folder-Scope werden Treffer aus allen Dateien zusammengezogen.
    func copyHitsToClipboard(_ pasteboard: NSPasteboard = .general) {
        let texts = navMatches.map(\.match.matchText)
        // Während ein neuer Suchlauf noch aussteht, bleibt die alte Liste
        // zur Orientierung sichtbar, `navMatches` ist aber absichtlich leer.
        // Ein Klick darf in diesem Zustand das Clipboard nicht leeren.
        guard !texts.isEmpty else { return }
        let joined = texts.joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(joined, forType: .string)
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

    /// Index Pfad → Häkchen für die Ordnerliste des Suchdialogs: ein
    /// Durchlauf statt einer Suche pro Zeile. Bei doppelten Pfaden gewinnt
    /// der erste Eintrag — dieselbe Reihenfolge, die auch die Liste zeigt.
    static func enabledByPath(_ entries: [SearchFolderEntry]) -> [String: Bool] {
        var index: [String: Bool] = [:]
        index.reserveCapacity(entries.count)
        for entry in entries where index[entry.path] == nil {
            index[entry.path] = entry.enabled
        }
        return index
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
