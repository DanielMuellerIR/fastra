# Fastra Erklärungen am Code und Skriptbarkeit

Stand: 2026-10-05. Planungsbasis: Fastra 1.127.4.
Ab 1.128.0 ist die begrenzte lokale Snapshot-Grundprobe implementiert.
Ihr tatsächlicher Vertrag, die bestandenen externen AppleEvent-Funktionsproben
und die gesondert offene historische Timeout-Diagnose stehen in
[LOCAL-CONTROL.md](LOCAL-CONTROL.md). Ab 1.129.0 ist der kleine gespeicherte
Codefrage-Player mit UTF-8-Snapshots implementiert. Seine installierte
zweisprachige Controller-, Neustart-, Bedien- und Sichtabnahme besteht ab
1.129.1; Git-Quellen und Parent→Commit-Reviews bleiben geplant. Das unterstützte Paketformat steht ebenfalls dort.

## Ziel

Fastra soll kurze, vorab erstellte Erklärungen direkt am sichtbaren Code
wiedergeben können. Fragen zu Programmablauf, Funktionen und Fehlerpfaden sind
mindestens gleichrangig mit Commit-Reviews. Ein externes Werkzeug erstellt die
Erklärung; Fastra zeigt ihren gespeicherten Inhalt, öffnet die gebundenen Quellen
und führt durch wenige nachvollziehbare Schritte.

Die Erklärung bleibt ohne erneute KI-Erzeugung wiederverwendbar. Der übliche
Ablauf ist: Frage stellen, Erklärung erstellen und direkt öffnen, selbst
erkunden, anschließend im ursprünglichen Gespräch nachfragen. Ein laufendes
KI-Gespräch in Fastra ist dafür nicht erforderlich. Folgefragen können im
Gespräch oder durch eine weitere kleine Erklärung beantwortet werden.

Vorhanden sind der lokale externe Dateivergleich, Git- und Datei-Diff-Ansichten,
schreibgeschützte Git-Snapshots sowie gezielte Editornavigation. Hinzugekommen
sind eine begrenzte lokale Snapshot-Steuerung und ein kleiner nativer
Erklärungsplayer. Eine allgemeine Skriptschnittstelle fehlt noch. Ein visueller
Entwurf belegt weder die technische Funktion noch einen Lernvorteil.

## Umfang und Grenzen

Fastra bleibt eine kleine native Mac-App. Der Ausbau verwendet vorhandene
AppKit-/SwiftUI-, Editor-, Diff- und Markdown-Komponenten. Er führt keine
LLM-Runtime, Cloud-SDKs, Konten, gebündelten Stimmen, neue Web-Anwendung oder
unnötigen Pflichtabhängigkeiten ein.

Nicht zum ersten Umfang gehören:

- freie Texteinblendungen über dem Desktop;
- Live-Chat, Spracherkennung und selbstständige Codeanalyse in der App;
- eine allgemeine Symbol- oder Aufrufgraph-Engine;
- vollständige BBEdit-Kompatibilität;
- schreibende Skriptbefehle und automatische Codekorrekturen;
- das Ausführen von Erklärungsinhalten als Shell-, AppleScript- oder
  JavaScript-Code.

Die vorhandene Markdown-/Mermaid-Darstellung kann eine Architekturübersicht
ergänzen, von der wenige Schritte in den tatsächlichen Code führen. Sie ist
keine Voraussetzung für die erste Erklärung. Optionales Audio folgt separat
über vorhandene Systemstimmen oder extern gespeicherte Audiodateien; Audiodaten
gehören nicht ins App-Bundle.

## Bedienung

Standard ist ein Erklärbereich neben oder unter dem Code im selben Fenster.
Die erste Umsetzung öffnet einen eigenen, klar bezeichneten
Erklärungs-Workspace. Bestehende Arbeitsfenster samt Tabs, Projektkontext,
ungespeicherten Änderungen und Auswahl bleiben erhalten.

Der Bereich enthält Titel und Frage, kurze Erklärung zum aktuellen Schritt,
sichtbaren Quellenstand, eine kleine Schrittliste sowie Zurück, Weiter, Pause
und Beenden. Nach eigenem Erkunden führt „Zur erklärten Stelle zurück“ bewusst
zum aktuellen Schritt zurück.

Der erste Player wird manuell weitergeschaltet. Jeder Schritt wartet, bis seine
Quelle und Markierung tatsächlich angewendet sind. Feste Wartezeiten erzwingen
keine Sprünge. Scrollen, Auswählen, Tabwechsel oder anderes eigenes Erkunden
pausiert ausstehende Navigation. Eine später eintreffende Antwort darf danach
nicht zurückspringen. „Weiter“ setzt bewusst beim nächsten Schritt fort.

Ein separates Erklärfenster ist eine weitere, spätere Anordnung desselben
Players. Es bleibt fest an seine Quellensitzung gebunden und bestimmt sein Ziel
nicht aus dem zufälligen Vordergrundfenster. Freie Desktop-Einblendungen bleiben
ausgeklammert.

Code- und Erklärungsschrift sind unabhängig vergrößerbar. Tour-eigene Zoom- und
Layoutänderungen sind vorübergehend und lokal; sie verändern keine global
gespeicherten Einstellungen. Spätere Fensteranordnungen verwenden logische
Koordinaten und die verfügbare Bildschirmfläche. Gespeicherte absolute
Pixelpositionen garantieren keine passende Anordnung auf einem anderen Monitor.

Ein späteres Anhängen an ein vorhandenes Arbeitsfenster erfordert ein explizites
Ziel und eine konfliktfreie Rücknahme eigener Änderungen. Die erste Etappe
vermeidet diesen zusätzlichen Zustand.

## Gemeinsamer Controller

Ein semantischer Controller nimmt Operationen von CLI, AppleScript und Player
entgegen. Die drei Eingänge entwickeln keine eigene Navigation, Git- oder
Dateiladelogik.

```text
CLI ───────────┐
AppleEvents ───┼── Steuerungscontroller ── Quellenauflösung und Jobs
Tour-Player ───┘              │
                             └── MainActor: Workspace, Editor, Diff, Erklärung
```

| Verantwortung | Aufgabe |
| --- | --- |
| Steuerungsvertrag | Befehle, IDs, Capabilities, Versionen und Fehler |
| Steuerungscontroller | Zielauflösung, Annahme, Abbruch und Status |
| Quellenauflösung | Commit- und Snapshot-Bindung; begrenztes asynchrones Laden |
| Präsentationssitzung | Zugeordnete Fenster/Tabs, lokale Einstellungen und Lebensdauer |
| Erklärungsformat | Validierte Daten mit Quellen, Schritten und optionalen Assets |
| Player | Schrittabfolge, Pause, Erkunden und Wiedergabe |

Das sind Verantwortlichkeiten, kein Auftrag zu sechs neuen Frameworks.
Gemeinsame Typen können in einem kleinen lokalen Target liegen, wenn CLI und
App sie tatsächlich benötigen. Ein späterer MCP-Adapter verwendet denselben
Vertrag; er ist keine Voraussetzung für den Player.

### Vorhandene Anknüpfungspunkte

| Code unter `app/Sources/` | Geplanter Anschluss |
| --- | --- |
| `Fastra/ExternalDiff.swift` | Lokale Annahme, getrennte Vergleichsfenster, abbrechbares Laden |
| `FastraDiffProtocol/DiffProtocol.swift` | Geeignete Frist-, Request-ID- und Transportmechanik |
| `Fastra/AppDelegate.swift` | Bereitschaft nach Sitzungswiederherstellung und AppleEvents |
| `Fastra/CommandTargeting.swift` | Zusammengehörige Fenster-, Workspace- und Editorziele |
| `Fastra/MainWindowTitle.swift` | `WorkspaceWindowRegistry`, ergänzt um öffentliche Objekt-IDs |
| `Fastra/DocumentWindowController.swift` | Eigener Erklärungs-Workspace |
| `Fastra/ContentView.swift` | Erklärbereich in der bestehenden Fensterhierarchie |
| `Fastra/Workspace.swift` | Datei-, Snapshot- und Git-Diff-Operationen |
| `Fastra/EditorView.swift`, `Fastra/BufferSearch.swift` | Dokumentidentität und bestätigte Navigation |
| `Fastra/GitDiff.swift` | Explizite Vergleichsquellen und Elternwahl |
| `Fastra/Theme.swift` | Lokale Overrides über den bisherigen globalen Zoomwerten |
| `Fastra/FileLoader.swift` | Encoding-, Großdatei- und Binärgrenzen |

`Workspace.openProject` kann standardmäßig saubere fremde Tabs schließen. Eine
Führung darf diesen Weg nicht auf einem beliebigen vorhandenen Workspace
aufrufen. `keepingUnrelatedTabs` allein isoliert noch nicht alle Projektzustände.

`GoToTarget.swift` bietet Spezialnavigation insbesondere für 4D und Markdown.
Daraus folgt keine allgemeine Symbolanalyse für beliebige Sprachen. Erklärende
Werkzeuge bestimmen weitere Stellen zunächst außerhalb der App.

## Steuerungsvertrag

Produktversion, Transportprotokoll und Erklärungsformat werden unabhängig
versioniert. Eine Capability-Abfrage nennt tatsächlich verfügbare Operationen,
Protokoll- und Schema-Versionen, Quellenarten, Koordinatenkonventionen sowie
relevante Größen- und Laufzeitgrenzen. Sie unterscheidet Änderungen an der
Darstellung von möglichen späteren Schreiboperationen. CLI-Capabilities bleiben
ohne App-Start abfragbar; die laufende App kann zusätzliche Verfügbarkeit melden,
etwa fehlendes Git.

Fenster, Tabs, Sitzungen und Jobs erhalten eigene IDs. Fenster-IDs sind weder
Listenpositionen noch Titel. Tab-ID und Dokumentgeneration werden getrennt
berücksichtigt: Ein wiederverwendeter Vorschau-Tab kann bereits ein anderes
Dokument enthalten. Nach App-Neustart sind alte Laufzeit-IDs ungültig; ein
gespeichertes Artefakt erhält beim Öffnen eine neue Laufzeitsitzung.

Eine kleine öffentliche CLI kann als zusätzlicher Bundle-Helfer entstehen.
Der bestehende [fastra-diff-Vertrag](EXTERNAL-DIFF.md) bleibt kompatibel. Dessen
Exit 0 bestätigt Annahme und Fenstererzeugung, keine fertig gezeichnete oder
eingefrorene Vergleichsquelle.

Ein neuer Befehl liefert nach kurzer Validierung eine Job-ID. Datei-, Git- und
Layoutarbeit läuft asynchron. Statusabfragen unterscheiden Annahme, laufende
Arbeit und Bereitschaft. Optionales CLI-Warten geschieht im Helfer; die App
blockiert dafür nicht den Main-Thread.

Eine Bereitschaftsantwort nennt Sitzungs-, Fenster-, Tab- und Dokument-ID,
Quellenkennung, Inhaltsbindung sowie tatsächlich angewendete Position. `ready`
heißt: Die gebundene Quelle ist geladen und die angeforderte Ansicht oder Auswahl
angewendet. Es garantiert nicht, dass macOS das Fenster vor allen anderen Apps
sichtbar hält.

Wiederholungen derselben Request-ID mit identischem Inhalt sind innerhalb einer
dokumentierten Aufbewahrungsfrist idempotent. Gleiche ID mit anderem Inhalt ist
ein Fehler. Ein Zustellungs-Timeout beweist keine Nichtannahme; der Client fragt
den bekannten Auftrag ab, statt blind einen neuen anzulegen.

## AppleScript

Fastra erhält ein echtes macOS-Scripting-Dictionary und AppleEvent-Handler.
Accessibility-Klickautomation ersetzt diese Schnittstelle nicht. Das im Bundle
liegende `.sdef` beschreibt Klassen, Eigenschaften und Befehle;
`NSAppleScriptEnabled` kennzeichnet die Skriptfähigkeit. Dictionary,
Bundle-Einbindung und tatsächliche Handler werden gemeinsam geprüft.
[Apple Scripting Terminology](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AboutScriptingTerminology.html),
[Apple NSAppleScriptEnabled](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapplescriptenabled)

Das erste Wörterbuch bleibt überschaubar: Anwendung und Fähigkeiten, Fenster und
Tabs mit IDs, Präsentationssitzungen und Jobs, Datei/Projekt öffnen oder gezielt
anzeigen, Navigation und Auswahl sowie Status und Abbruch. Git-Quelle, Diff,
Erklärtext und lokales Zoom/Layout folgen nach Nutzwert. Ein Befehl wird erst
zugesagt, wenn sein echter AppleEvent-Pfad funktioniert; die erste vertikale
Etappe exportiert noch nicht jede Player-Funktion.

Dünne `NSObject`-Adapter können die Cocoa-Scripting-Objekte über dem Controller
abbilden. Standardklassen dürfen keine unbeabsichtigten schreibenden
Eigenschaften öffnen. Native Fehler tragen Nummer, verständliche Beschreibung
und betroffenes Objekt. [Apple NSScriptCommand](https://developer.apple.com/documentation/foundation/nsscriptcommand)

Lang laufende Operationen liefern vorzugsweise einen Job. Für später benötigte
offene Befehle bietet `NSScriptCommand` Suspend/Resume; der Handler muss nach dem
Suspend zunächst zurückkehren. Blockierendes AppleEvent-Warten auf dem
Main-Thread ist ausgeschlossen.
[Apple resumeExecution](https://developer.apple.com/documentation/foundation/nsscriptcommand/resumeexecution(withresult:))

Empfangen von Skriptbefehlen und Senden von AppleEvents an andere Apps sind
unterschiedliche Anforderungen. Berechtigungen für ausgehende Automation werden
nur für tatsächlich geplante Sender benötigt; Ablehnung und ausstehende
Systemfreigabe bleiben sichtbare Zustände.
[Apple AppleEvents Usage Description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription),
[Apple Apple Events Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)

BBEdit dient als Referenz für nützliche inkrementelle Skriptbarkeit. Konkrete
Syntax- und Verhaltensübernahmen werden am aktuellen Dictionary oder Handbuch
geprüft; vollständige Kompatibilität ist kein Ziel.
[Bare Bones Scripting](https://barebones.com/products/bbedit/benefitswork.html),
[Bare Bones Handbuch](https://www.barebones.com/support/bbedit/manual.html)

## Quellenbindung

Ein Artefakt speichert einen konkreten Quellenstand. Branch-Namen und `HEAD`
sind nur Anzeigehinweise. Git-Quellen enthalten Projekt-/Repository-Identität,
Git-Objektformat, vollständige Commit- und Blob-OIDs, relativen Dateipfad sowie
bei Umbenennungen den alten Pfad. Vergleiche speichern beide Quellen und Rollen;
Merge-Commits ihren ausdrücklich gewählten Eltern-Commit, Root-Commits den leeren
Baum als Ausgangsbasis.

Git besitzt keine universelle unveränderliche Repository-ID. Eine lokale
Zuordnung verbindet deshalb eine undurchsichtige Projektkennung mit einem
Checkout. Ein gleicher Ordnername reicht nicht als Identitätsbeweis;
vertrauliche Remote-URLs gehören nicht in das Artefakt.

Die erste Etappe verwendet feste Commit-Inhalte und explizite
Parent→Commit-Vergleiche. Die Elternwahl hängt nicht vom zufällig geladenen
Ausschnitt des Git-Graphen ab. `openGitCommitFile` ist ein Anschluss, ersetzt
aber keinen vollständigen Quellenvertrag.

Später werden zusätzliche Stände getrennt unterstützt:

| Stand | Gebundene Quellen |
| --- | --- |
| Staged | HEAD oder leerer Ausgangsbaum → konkrete Index-Fassung |
| Unstaged | konkrete Index-Fassung → eingefrorener Platteninhalt |
| Untracked | ausdrücklich neue Datei mit eigenem Snapshot |
| Unsaved | eingefrorener Editorinhalt mit Dokument-ID und Generation |

HEAD→Disk allein bildet gemischte staged/unstaged Änderungen nicht korrekt ab.
Konfliktstufen und nicht unterstützte Git-Zustände werden abgelehnt oder später
als eigene Quellenart spezifiziert.

### Snapshots und Projekte ohne Git

Das Format unterstützt begrenzte Snapshots der tatsächlich erklärten Dateien.
Ohne Git wird der fehlende Commit-Bezug sichtbar benannt. Ein Snapshot einzelner
Dateien ist kein Snapshot des gesamten Projekts.

Bei Plattendateien wird über unveränderte Originalbytes gehasht; Encoding,
Byte-Reihenfolge-Markierung und Zeilenenden bleiben Teil der Beschreibung.
Ungespeicherter Editortext bekommt eine eigene definierte Serialisierung,
beispielsweise UTF-8 ohne Unicode-Normalisierung. Dessen Texthash wird nicht als
Hash einer gespeicherten Datei ausgegeben.

Schritte sind an eingefrorene Inhalte gebunden. Wiederöffnung führt keinen
Checkout aus und verändert keine Arbeitskopie. Historische Git-Inhalte werden
lesend geladen, Snapshots schreibgeschützt präsentiert. Fehlende Objekte oder
Snapshots ergeben „Quelle nicht verfügbar“, keinen stillen Ersatz durch die
heutige Datei. Für langfristige Wiederverwendung können die wenigen benötigten
Snapshots mitgespeichert werden. Der Ablageort ist konfigurierbar und liegt
außerhalb öffentlicher Projektdateien.

Ein Fortschreiten von HEAD macht einen historischen Commit nicht ungültig.
`stale` bezeichnet die Verletzung der erwarteten Quellenbindung, nicht bloß
einen älteren Commit.

## Erklärungsformat und Textkoordinaten

Eine Führung ist ein versioniertes Datenpaket, etwa ein Manifest mit relativen
Markdown-, Snapshot- und optionalen Audiodateien. Es enthält keine ausführbaren
Skripte.

| Bereich | Mindestinhalt |
| --- | --- |
| Identität | Schema-Version, eindeutige ID, Titel, Erstellungszeit, Sprache |
| Anforderungen | benötigte Capabilities und Formatgrenzen |
| Projekt | Projekt-/Repository-ID und lesbare Bezeichnung |
| Quellen | Quellenart, OIDs oder Snapshot-Hashes, Encoding, relativer Pfad |
| Schritte | Schritt-ID, Erklärung, Quellenreferenz, Darstellung, Zielbereich |
| Einstellungen | lokale Schriftgrößen und gegebenenfalls Fensteranordnung |
| Wiedergabe | später optionale Dauer, Pause, Audio-Referenz und Zeitmarken |
| Assets | relative Dateien mit Typ, Größe und Hash |

Lokale Projektpfade werden getrennt von portablen Artefaktdaten zugeordnet.
Paketpfade dürfen nicht aus der Ablage ausbrechen; Symlinks, Dateitypen und
Größen werden vor dem Lesen geprüft. Unbekannte Operationen oder fehlende
erforderliche Capabilities erzeugen sichtbare Fehler. Optionale Erweiterungen
dürfen nur nach dokumentierten Regeln übersprungen werden.

Für Textziele gilt der geplante Vertrag:

- Zeilen und Spalten sind 1-basiert; Spalten zählen UTF-16-Codeeinheiten.
- Anfang ist inklusive, Ende exklusiv. Tabs zählen als eine Codeeinheit,
  nicht nach ihrer sichtbaren Breite.
- Zeilen folgen Fastras bestehender `NSString`-Semantik: LF, CR, CRLF, NEL,
  U+2028 und U+2029; CRLF ist ein Umbruch.
- Abschließender Umbruch und EOF-Ziele werden gegen die Editorregeln
  spezifiziert und mit Fixtures geprüft.
- Absolute UTF-16-Ranges gelten nur auf dem exakt gebundenen Text.
- Ungültige Bereiche, gespaltene Surrogatpaare und widersprüchliche
  Koordinaten werden abgelehnt; sichtbare Markierungen beachten Graphemgrenzen.

Ein kurzer Textanker oder dessen Hash bestätigt den erwarteten Ausschnitt.
Unscharfes Wiederfinden in einer geänderten Datei gehört nicht zur ersten
Version. Die technische Prüfung belegt Quellen und Positionen; sie bestätigt
nicht automatisch die fachliche Wahrheit der Erklärung.

Binär- und Großdateien umgehen keine vorhandene Ladegrenze. Der erste Player
unterstützt begrenzte Textquellen. Ein späterer Abschnitts- oder Hex-Schritt
braucht eigene Bytekoordinaten und darf keine Textposition vortäuschen.

## Zustände und Abbruch

Auftrags- und Playerzustand bleiben getrennt.

| Auftrag | Bedeutung |
| --- | --- |
| `accepted` | Vertrag geprüft, Job vergeben |
| `resolving` / `loading` | Quellen werden geprüft und geladen |
| `presenting` | Ansicht und Auswahl werden angewendet |
| `ready` | Gebundener Inhalt und Ziel bestätigt |
| `failed` | Fehler mit Code und Erklärung |
| `cancelled` | Auftrag beendet; spätere Antworten werden verworfen |

| Player | Bedeutung |
| --- | --- |
| `ready` | Schritt kann gestartet werden |
| `loadingStep` | Schritt wird vorbereitet |
| `paused` | Manuelle Pause oder eigenes Erkunden |
| `stale` | Erwarteter Inhalt oder Bezug stimmt nicht |
| `completed` | Letzter Schritt abgeschlossen |
| `cancelled` | Sitzung beendet |

Jeder Schritt besitzt eine Generation. Pause, neuer Schritt, geschlossenes
Fenster und Abbruch entwerten ältere Antworten. Quellenprüfung, Diff,
Navigation und Markierung prüfen sie vor der Anwendung. Fehlerhafte Quellen
werden nicht still übersprungen; ein anderer verfügbarer Schritt kann bewusst
gewählt werden.

## Etappen und Abnahme

### Etappe 0 Steuerungsvertrag und AppleEvent Grundprobe

Implementierter Teil: gemeinsamer Controller, CLI, gebündeltes Dictionary,
Laufzeit-IDs und eigener schreibgeschützter Dateisnapshot mit bestätigter
UTF-16-Auswahl und abfragbaren Jobs. Externes AppleScript/JXA und native
Objektbezüge sind gegen die notarisiert installierte App funktional geprüft.
Die Ursache eines früheren Zustellungs-Timeouts ist nur eingegrenzt;
Diese historische Diagnosegrenze bleibt gesondert offen. Die aktuelle
Funktionsabnahme trägt den gespeicherten Codefrage-Player.
Die Grundprobe aus 1.128.0 umfasst 256 KiB Text und keine Git-Quelle. Der Player
aus 1.129.0 ergänzt darauf gespeicherte Codefragen; die installierte Abnahme
besteht ab 1.129.1 einschließlich echter Maus-, Umschalt-Pfeil- und Menüaktionen.
Die konkreten Belege und weiterhin gesonderten Grenzen stehen in LOCAL-CONTROL.md.


Vor Implementierung Quellen, Version und [Build-Regeln](BUILD-AND-TEST.md)
erneut prüfen. Befehle, Quellenmodell, IDs, Fehler und Koordinaten als kleine
ausführbare Fixtures festlegen. Ein minimales `.sdef` mit Capability- und
Fensterabfrage früh im realen AppleEvent-Weg prüfen.

Abnahme: CLI und echtes AppleEvent erreichen denselben Controller. Ungültige
IDs und nicht unterstützte Operationen liefern native beziehungsweise
maschinenlesbare Fehler. Der Umfang wird nicht zu einer neuen allgemeinen
Automatisierungsplattform erweitert.

### Etappe 1 Kurze Codefrage und Commit Review

Zunächst ein lokales Git-Repository, feste Commit-Inhalte, ein bis zwei normale
Textdateien und je zwei bis vier Schritte.

Zwei vollständige Anwendungsfälle verwenden denselben Controller und Player:

1. Eine Ablauf-Frage zeigt Einstieg, entscheidende Verarbeitung und Fehlerpfad.
2. Ein Commit-Review zeigt Änderungen als expliziten Parent→Commit-Diff mit
   erklärenden Schritten.

Enthalten sind eigener Erklärungs-Workspace, Erklärbereich im selben Fenster,
lokale Code-/Erklärungsschrift, Zurück/Weiter/Pause/Beenden, ID-gebundene
Navigation, lokaler Start und bestätigte Bereitschaft. Das gespeicherte Paket
lässt sich erneut öffnen. Audio, Working Tree, allgemeine Symbolanalyse und
Favenio folgen später.

Technische Abnahme:

- Beide Führungen laufen ohne manuelle Reparatur; Ziele sind am gebundenen
  Inhalt geprüft.
- Zwei vorhandene Arbeitsfenster einschließlich ungespeichertem Dokument und
  ihre globalen Einstellungen bleiben unverändert.
- Pause während eines verzögerten Ladens verhindert den späteren Sprung.
- Wiederöffnung nach App-Neustart braucht keine neue Erzeugung.
- Echte AppleEvents nutzen Fähigkeiten, Fenster und mindestens eine gezielte
  Präsentationsoperation.

Nutzwert-Abnahme: Inhaltlich gleiche Erklärungen werden mit Dateilinks und als
Tour verwendet. Entscheidend sind verständliche eigene Beschreibung des Ablaufs
oder der Änderung und selbstständiges Wiederfinden einer benachbarten relevanten
Stelle. Bei wiederholtem Reparaturbedarf oder fehlendem Vorteil wird zuerst
vereinfacht, statt den Funktionsumfang auszubauen.

### Etappe 2 Weitere Quellen und Anordnungen

Working Tree, Index, untracked und ungespeicherte Inhalte getrennt ergänzen.
Projekte ohne Git folgen mit ehrlichem Snapshot-Bezug. Quellenvalidierung,
Wiederaufruf und Meldungen bei fehlenden Quellen vervollständigen.

Danach separates Erklärfenster und benötigte Fensteranordnungen ergänzen.
AppleScript wird jeweils zusammen mit dem semantischen Befehl erweitert.

### Etappe 3 Alltagstaugliche Skriptbarkeit

Häufige Operationen über CLI und AppleScript dokumentieren und absichern:
Öffnen, Projekt-/Fenster-/Tabaufzählung, Navigation, Auswahl, Git-Quellen, Diff,
Erklärung sowie lokale Darstellungseinstellungen.

Schreiboperationen bleiben eine gesonderte spätere Etappe. Sie nutzen denselben
vollständigen Preview→Apply-Vertrag wie die Oberfläche: sichtbare Trefferbasis,
gebundene Vorschau, abschließende Snapshot-Prüfung und ausdrücklicher
Apply-Schritt. Ein Skript oder eine Tour erteilt keine automatische
Schreibfreigabe.

### Etappe 4 Sprache und zeitgesteuerte Wiedergabe

Nach belegtem Nutzen des stillen Players vorhandene Systemstimmen oder externe
Audiodateien ergänzen. Text bleibt die vollständige Alternative. Keine Stimmen
oder Medien automatisch herunterladen oder mit dem App-Bundle ausliefern.

Gespeicherte Zeitmarken und Einstellungen ermöglichen Wiederholung ohne LLM.
Der Wiedergabe-Zeitlauf eines Schritts beginnt erst nach bestätigter
Quellenbereitschaft; Audio kann vorbereitet werden. Pause, Schrittwechsel,
Abbruch und eigenes Erkunden stoppen auch Audio und geplante Folgeschritte.
Fertige Audiodateien binden ihre tatsächliche Dauer, statt bei jeder Wiedergabe
eine identische Synthesedauer anzunehmen.

## Größenbudget und Prüfung

Vor und nach jeder Etappe unter gleicher Release-Konfiguration, Toolchain,
Architektur und Signierungsart messen: Bundlegröße in Bytes, neue Bestandteile,
absolute Differenz und Differenz relativ zur Baseline vor diesem Ausbau.
Historische Größenangaben ersetzen diese Messung nicht.

Vorgeschlagenes Gesamtbudget für Steuerungs- und Textplayer-Kern einschließlich
AppleScript: höchstens 5 MiB und höchstens 5 % Zuwachs gegenüber dieser Baseline.
Das ist ein Planungsbudget, kein gemessener Zuwachs. Eine Überschreitung verlangt
Erklärung und Vereinfachung vor weiterem Ausbau. Tourdateien, Snapshots und Audio
werden außerhalb des Bundles separat bilanziert und begrenzt.

Risikogerechte Prüfungen:

- Schema, Pfade, Größen, Hashbindung, Koordinaten, IDs und Zustandsübergänge;
- temporäre Git-Fixtures für Root-/Merge-Commits, Umbenennung, Löschung und
  später gemischte Index-/Disk-Zustände;
- Unicode, CRLF, EOF, Encoding, Binär- und Großdateigrenzen;
- reale Fenster: sichtbare Auswahl, eigene Navigation, falsches Ziel,
  veraltete Antworten und unveränderte Nutzerdokumente;
- echte AppleEvents von einem externen Sender, sichtbares Dictionary und
  gültige Objektbezüge;
- Kalt-/Warmstart, Wiederholung, fehlende App, Timeout, Abbruch und Fensterende;
- Deutsch/Englisch und visuelle Prüfung bei Mindestbreite und breitem Fenster.

Zuerst `app/build.sh`, danach passende Tests über `app/test.sh` und relevante
Selbsttests. Ressourcen-/Paketierungsänderungen verlangen Lokalisierungs-Audit,
Portabilitätsprüfung und `localization` aus dem gepackten Bundle. Reales
Installations-, LaunchServices- und Berechtigungsverhalten wird gegen die
notarisiert installierte App geprüft. Umgebungs-Skips sind kein grüner Lauf.

Nutzersichtbare Etappen folgen der bestehenden Versionskonvention. Deutsche
und englische Hilfe werden geprüft und bei Bedarf ergänzt; der Hilfe-Marker
wird nach dem bestehenden Verfahren fortgeschrieben. Dieser Plan allein
verändert weder Produktversion noch Hilfe-Marker.
