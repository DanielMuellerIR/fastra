# Lokale Snapshot-Steuerung

Ab Fastra 1.128.0. Protokollversion 1, unabhängig von der Produktversion.
Die Grundprobe zeigt begrenzte Textdateien in eigenen schreibgeschützten
Sitzungen. Sie verändert keine normalen Dokumente oder globalen Einstellungen.
Ab 1.129.0 ergänzt `explanation` gespeicherte Codefragen mit lokal gebundenen
UTF-8-Snapshots und einem eigenen Player. Git-Quellen und Parent→Commit-Reviews
bleiben eine getrennte geplante Etappe.

CLI und AppleEvent-Adapter verwenden `LocalControlController`. Das echte
Dictionary `Contents/Resources/Fastra.sdef` und die native Objektanbindung
sind gebündelt. Externe AppleScript- und PID-adressierte JXA-Läufe gegen die
notarisiert installierte App sind funktional geprüft. Die historische Ursache
eines früheren Timeouts bleibt diagnostisch offen; die aktuelle bestandene
Funktionsabnahme ist die Grundlage für den gespeicherten Player.
Quelltext, Dictionary-Extraktion und direkte Handler-Aufrufe ersetzen keine
externe Funktionsprüfung.

## CLI

```sh
/Applications/Fastra.app/Contents/Helpers/fastra-control --capabilities --json
/Applications/Fastra.app/Contents/Helpers/fastra-control --request /pfad/auftrag.json
/Applications/Fastra.app/Contents/Helpers/fastra-control --request - < /pfad/auftrag.json
/Applications/Fastra.app/Contents/Helpers/fastra-control --no-launch --request /pfad/auftrag.json
```

Capabilities funktionieren offline ohne App-Start. Sonst kann der Helfer die
zugehörige App ohne Aktivierung starten. `--no-launch` beschränkt ihn auf eine
bereits laufende Instanz. Ein Request-File muss eine reguläre Datei sein;
FIFO-Geräte werden abgewiesen. Standardinput wird bis EOF gelesen.

Exit 0 bedeutet eine erfolgreiche Protokollantwort, Exit 1 einen Aufruf-,
Transport- oder Controllerfehler als JSON in `error`. Ein `status` mit
`job.state = failed` bleibt eine erfolgreiche Statusabfrage: Clients müssen
den Jobzustand und `job.error` auswerten. Der Helfer wartet nicht auf Bereitschaft
oder das Schließen des Fensters.

## Requests und Antworten

Jeder Request enthält `version: 1`, eine UUID als `id`, `operation` und eine
absolute Unix-Frist `deadline` in Sekunden, typischerweise aktuelle Zeit + 10.
Unbekannte Felder und `null` sind ungültig. Das optionale `runtimeID` bindet
auch einen neuen Auftrag an die zuvor abgefragte App-Instanz; eine abweichende
Laufzeit wird vor jeder Operation mit `invalidID` abgewiesen.

| Operation | Zusätzliche Pflichtfelder | Ergebnis |
| --- | --- | --- |
| `capabilities` | keine | Fähigkeiten, Grenzen, laufende Produktversion |
| `objects` | keine | Fenster, Dokumente, Sitzungen und aktuelle Jobs |
| `snapshot` | `path`, `sha256`, `location`, `length` | angenommener Job für eine neue Sitzung |
| `navigate` | `sessionID`, `documentID`, `sha256`, `location`, `length` | angenommener Navigationsjob im bestehenden Snapshot |
| `status` | `jobID` | aktueller Jobzustand |
| `cancel` | `jobID` | laufenden Job abbrechen; terminale Jobs bleiben erhalten |
| `close` | `sessionID` | ausschließlich die eigene Snapshot-Sitzung schließen |

`path` ist absolut. `sha256` enthält 64 kleine Hexzeichen und bezieht sich
auf die unveränderten Dateibytes einschließlich einer vorhandenen BOM.
Dateiladen und Hashprüfung laufen im Hintergrund über `FileLoader`.
Quelle, Inhalt und Bytehash stammen aus demselben geöffneten Dateiobjekt.
Binär-, Abschnitts-, Geräte- und übergroße Quellen werden abgewiesen.

`location` und `length` zählen **UTF-16-Einheiten ab null** im dekodierten Text.
Der Anfang gehört zum Bereich, das Ende nicht; Länge null bezeichnet einen
Cursor, auch am EOF. Beide Grenzen müssen vollständige Swift-Characters sein.
Das schließt die Mitte von Surrogatpaaren, CRLF und zusammengesetzten Zeichen
aus. Zeilen-/Spaltenkoordinaten und Syntaxanalyse sind nicht Teil dieses Vertrags.

Antworten enthalten `protocolVersion` und im laufenden Prozess `runtimeID`.
Jobs liefern eigene `id`, `requestID`, `sessionID`, `windowID` und `documentID`.
Die möglichen Zustände sind `accepted`, `loading`, `presenting`, `ready`,
`failed` und `cancelled`. Die letzten drei sind terminal.

**Annahme ist keine Bereitschaft.** `ready` folgt erst, wenn die echte
Textansicht den geladenen Inhalt und exakt die verlangte Auswahl enthält und
deren Zielgeometrie den sichtbaren Ausschnitt schneidet. Das wird in weiteren
Layoutdurchläufen beobachtet, ohne die Auswahl erneut zu setzen. Große Bereiche
müssen nicht vollständig in ein Fenster passen. Der Job nennt `sha256`,
`textSHA256` (SHA-256 des dekodierten Texts als UTF-8) und tatsächliche
`selection`; Snapshot-Jobs ergänzen `byteCount`, `encoding` als Foundation-
`String.Encoding.rawValue` sowie `bomBytes`.

Der Snapshot bleibt eingefroren, wenn sich die Quelldatei danach ändert.
Navigation erfordert die unveränderte Inhaltsbindung. Eigene Auswahl,
Tastatur-/Mauseingaben, Live-Scrollen, neuere Navigation, Abbruch oder
Fensterende entwerten ausstehende Antworten. Ein später abgeschlossener
Ladevorgang darf dann keinen Inhalt oder Sprung mehr anwenden.

Eine neue Operation bekommt eine neue Request-ID. Nach verlorener Antwort
denselben JSON-Auftrag unverändert wiederholen: gleiche ID und anderer Inhalt
werden abgewiesen. Bekannte Präsentationsaufträge bleiben während
der Aufbewahrung auch nach ihrer Request-Frist idempotent abfragbar. Eine neue
abgelaufene Anfrage wird nicht angenommen. Eine bekannte Job-ID kann separat
mit einem frischen `status` abgefragt werden.

Fenster-IDs sind UUIDs, keine Titel oder Listenpositionen. Dokumentidentität
stammt bei normalen Tabs aus `documentID`, nicht aus einem wiederverwendeten
Tabplatz. Die normalen Fenster sind nur inventarisierbar; `navigate` und
`close` nehmen ausschließlich eigene Sitzungen an. IDs verfallen nach Neustart
beziehungsweise Schließen. Sitzungen werden nicht restauriert.

### Minimales Beispiel

Ein externer Client erzeugt den JSON-Auftrag aus Daten, ohne Quelltext in argv
oder Shell-Interpolation einzubauen. Beispiel für die ersten fünf UTF-16-
Einheiten einer Textdatei; bei kürzerem Text oder unpassender Zeichengrenze
scheitert der Job mit `invalidRange`:

```python
import hashlib, json, pathlib, subprocess, time, uuid

helper = "/Applications/Fastra.app/Contents/Helpers/fastra-control"
source = pathlib.Path("/pfad/quelle.txt")
with source.open("rb") as stream:
    raw = stream.read(262_145)
if len(raw) > 262_144:
    raise ValueError("source exceeds snapshot limit")
request = dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 10,
               operation="snapshot", path=str(source),
               sha256=hashlib.sha256(raw).hexdigest(),
               location=0, length=5)
result = subprocess.run([helper, "--request", "-"],
                        input=json.dumps(request).encode(), capture_output=True)
reply = json.loads(result.stdout)
# reply.job.id anschließend mit frischen status-Requests bis zum Endzustand abfragen.
```

## AppleScript und Objektmodell

Die vorbereiteten Befehle heißen `control capabilities`, `control inventory`
und `control request`. Die ersten beiden liefern JSON-Text; der letzte nimmt
denselben JSON-Request wie die CLI entgegen und liefert denselben semantischen
Job. Die Inventarabfrage heißt bewusst anders als die Objektkollektion.

```applescript
tell application "Fastra"
    control capabilities
    control inventory
    get id of every control window
    -- control request jsonText
end tell
```

`control window`, `control document`, `control session` und `control job`
besitzen ausschließlich lesbare `id`- und `details`-Eigenschaften. `details`
ist JSON. Ein expliziter Bezug lautet `control window id "UUID"`.
Objektbezüge lösen ihre ID neu auf und halten geschlossene Fenster nicht am Leben.
Schreibbare Dokumenteigenschaften oder Standard-Speicherbefehle werden nicht
exportiert. macOS kann für externe Sender eine Automation-Freigabe verlangen.

| Fehlercode | AppleScript-Nummer |
| --- | --- |
| `invalidRequest` | -1700 |
| `unsupported` | -1708 |
| `invalidID` | -1728 |
| `stale`, `invalidRange`, `sourceUnavailable`, `capacity`, `expired`, `interrupted`, `delivery` | -2700 |

Direkte Aufruffehler liefern diese nativen Nummern; Fehler eines angenommenen
Jobs stehen in dessen Status-JSON. Ein readonly-Property-Setter wird durch das
Cocoa-Scripting-Modell mit -10006 abgewiesen; JXA meldet bereits am
ScriptingBridge-Zugang -10003. Die Abnahme prüft zusätzlich, dass `id` und
`details` nach beiden abgewiesenen Settern unverändert sind.

## Grenzen und Abnahme

| Grenze | Wert |
| --- | --- |
| Quelldatei | 262.144 Bytes (256 KiB) |
| JSON-Request | 65.536 Bytes |
| Gleichzeitige Sitzungen | 16 |
| Aufbewahrte Jobs | 128 |
| Wiederholungsbelege neuer Arbeitsaufträge | 256 |
| Getrennte Wiederholungsbelege für Abbruch/Schließen | 256 (älteste werden verdrängt) |
| Request / Job | 10 / 30 Sekunden |
| Job- und Replay-Aufbewahrung | 300 Sekunden ab Annahme |

Die erste Abnahme umfasst echten CLI-Transport, Hash-/Auswahlbindung,
Unicode/CRLF/EOF, verzögerte und veraltete Antworten sowie unveränderte
ungespeicherte Arbeitsfenster. Der separate Heartbeat prüft zwei Textformen
nahe 256 KiB mit EOF-Ziel; seine Messungen sind keine Latenzgarantie für
beliebige Daten oder Rechnerlast. AppleEvent-Befehle, Unique-ID-Objektbezüge
und native Fehler müssen zusätzlich von einem externen Sender bewiesen werden.
Testbefehle stehen in [BUILD-AND-TEST.md](BUILD-AND-TEST.md).

Prüfstand 2026-10-04: Beide Phasen von `test.sh` bestanden (2.424 und 143
Tests), außerdem Lokalisierungs-Audit, Release-Build, Portabilitätsprüfung und
die gepackten Selbsttests `localization`, `search`, `filemodes`, `openscope`.
Die externe CLI-Probe bestätigte Quelle, Auswahl, EOF, Wiederholung, veraltete
Bindung und geschlossene IDs sowie zwei unveränderte ungespeicherte Fenster.
Verzögerte Antworten, Abbruch und eigenes Erkunden wurden zusätzlich im
Controller mit realen Textansichten geprüft. Sichtbelege liegen für Deutsch
und Englisch bei 400 und 900 pt vor. Die separate Heartbeat-Probe maß maximal
131,381 ms bei vielen kurzen Zeilen und 54,643 ms bei einer langen Zeile.

Die anschließende Prüfung gegen die vollständig notarisiert installierte
Version 1.128.0/286 bestand: Ein rohes, PID-adressiertes `FaCo/Caps` mit
drei Sekunden Frist antwortete nach 43 ms. Dictionary-Extraktion sowie getrennte
externe AppleScript- und JXA-Läufe bestätigten Capabilities, Inventar,
Unique-ID-Bezüge, Snapshot/Status/Navigation, dieselben CLI-Jobs und native
Fehler (-1700, -1708, -1728, -2700). Normale Fenster-IDs und geschlossene
Sitzungen wurden abgewiesen. Beide readonly-Properties blieben nach dem
Schreibversuch unverändert. Die beiden ungespeicherten normalen Fenster
blieben unverändert; externer Treiber und geschützter `controlhost` endeten
jeweils mit Exit 0. Deutsch und Englisch wurden bei 400 und 900 pt einschließlich
der Hash-Fehlerlage visuell geprüft. Die gezielten Controller-Tests bestanden
erneut, einschließlich unkooperativer verzögerter Completion, Abbruch,
eigener Auswahl und überholter Navigation.

Der frühere Timeout ist derzeit nicht reproduzierbar. Im damaligen
Empfängerlog steht eine TCC-Zugriffsanfrage ohne protokollierten Abschluss im
Prüffenster; die heutigen Anfragen erhalten nach etwa 10 ms ein positives
Ergebnis. Das ist eine Eingrenzung, kein vollständiger Ursachenbeweis. Weder
eine verweigerte Freigabe noch ein Dictionary-/Dispatchfehler wird daraus
abgeleitet. Diese historische Diagnosegrenze bleibt ausdrücklich offen;
die weitere Produktetappe nutzt die bestandene aktuelle Funktionsabnahme.

### Vergleichbare Release-Messung 2026-10-04

Baseline 1.127.4 und Grundprobe 1.128.0: `build.sh release`, arm64,
XcodeDefault/Apple Swift 6.4, macOS 26.7.1, gleicher Ad-hoc-Signierungsweg.
Gezählt werden logische Dateibytes aller regulären Dateien im Bundle, ohne
Symlink-Doppelzählung; keine APFS-Belegung oder komprimierte Downloadgröße.

| Messgröße | Baseline | Grundprobe | Differenz |
| --- | ---: | ---: | ---: |
| Bundle | 76.484.872 | 77.122.775 | +637.903 Bytes (+0,8340 %) |
| App-Binary | 62.395.024 | 62.636.288 | +241.264 Bytes |
| Neuer Control-Helfer | — | 387.744 | +387.744 Bytes |

Die Grundprobe liegt unter 5 MiB und unter 5 % Zuwachs. Neue Bestandteile sind
Helfer, Dictionary und lokaler Controller einschließlich Testhost; es gibt
keine neue externe Pflichtabhängigkeit, KI-Runtime oder gebündelte Medien.
Das anschließend Developer-ID-signierte/notarisierte Bundle wird nicht mit
wesentlich anders signierten historischen Größen verglichen.

Die erneute Messung nach der Abnahme verwendet dieselbe Release-Konfiguration
und Ad-hoc-Signierung. Der App-Binary und Helfer sind unverändert; die
ergänzte zweisprachige Hilfe erhöht die Bundlegröße um weitere 710 Bytes.

## Gespeicherte Codefrage ab 1.129.0

`explanation` nimmt ausschließlich einen absoluten `path` zum lokalen JSON-Manifest
an. Der Auftrag liefert denselben Jobvertrag wie `snapshot`; `ready` bestätigt
den geladenen ersten Schritt. Das Paket wird vollständig im Hintergrund geprüft,
bevor ein Player erscheint. CLI und AppleScript verwenden denselben Request:

```json
{
  "version": 1, "id": "<neue UUID>", "deadline": 0,
  "operation": "explanation", "path": "/pfad/zum/paket/explanation.json"
}
```

`deadline` durch die aktuelle Unix-Zeit plus höchstens 10 Sekunden ersetzen.
Normale Arbeitsfenster werden nicht als Quelle oder Ziel benutzt. Die eigene
Sitzung besitzt wechselnde Dokument-IDs für die eingefrorenen Quellen; ein
Auftrag an die zuvor angezeigte andere Quelle wird abgewiesen. Der Player
startet jede weitere Navigation über den bestehenden Controller und wartet
auf die tatsächlich bestätigte Auswahl.

Das Manifestschema 1 verlangt genau folgende Felder:

- `schemaVersion: 1`, `id`, `title`, `question`, `language` (`de` oder `en`),
  `createdAt` (ISO-8601), `projectID` und `projectName`;
- `sources`: eine bis fünf Quellen mit `id`, relativem `path`,
  `encoding: "utf8"` und kleingeschriebenem SHA-256 der Originalbytes in `sha256`;
- `steps`: zwei bis fünf Schritte mit `id`, `title`, `text`, `sourceID`,
  `location` und `length` als nullbasierte UTF-16-Range auf vollständigen Zeichen;
- `codeFontSize` und `explanationFontSize`: jeweils 8 bis 32 pt.

Manifest höchstens 64 KiB, jede Quelle höchstens 256 KiB, alle Quellen zusammen
höchstens 1 MiB. Titel höchstens 200 Zeichen, Frage 2.000, Erklärung je Schritt
4.096. Unbekannte Felder, ungültige IDs/Bereiche, fehlende Quellen, Binärdaten,
Symlinks im Paket sowie absolute oder ausbrechende Quellenpfade werden
abgewiesen. Die Quellen werden über komponentenweise geöffnete Deskriptoren
gelesen; Hash und Inhalt stammen aus denselben Bytes. Die Grenze gilt auch
für Dateien, die während des Lesens wachsen.

Das Menü **Datei → Code-Erklärung öffnen…** öffnet denselben Controllerauftrag.
Schrittliste, Zurück, Weiter, Pause, Beenden und bewusste Rückkehr sind sichtbar.
Eigene Auswahl oder Scrollen pausiert und entwertet ausstehende Navigation.
Code- und Erklärungsschrift bleiben getrennt und lokal. Wiederöffnung startet
bei Schritt eins mit neuen Laufzeit-IDs; sie benötigt das Paket, keine KI,
keinen Checkout und keine Änderung der Arbeitskopie. Die Sprache des gespeicherten
Inhalts bleibt die Sprache des Pakets; die Bedienoberfläche folgt der App-Sprache.

Die Erklärung ist vorbereiteter Text. Hashbindung und richtiges Highlight
belegen keine fachliche Wahrheit. Commit-Review, Git-OIDs, Audio und schreibende
Automation gehören nicht zu diesem ersten Player.

### Prüfstand 1.129.0 am 2026-10-04

Der Release-Build und dessen Portabilitätsprüfung sind bestanden. Die vollständige
Unit-Suite besteht mit 2.430 Tests in 113 Suites und die getrennte serielle
Integrationsphase mit 143 Tests in 16 Suites. Paketgrenzen, Hashabweichungen,
native Playeraktionen, Quellenwechsel, Abbruch verspäteter Ladevorgänge und
Kapazitätsfehler sind darin geprüft. Englische native Unit-Fensteraufnahmen bei
400/900 pt sind für Bereit-, Pause- und Kapazitätsfehlerzustand visuell geprüft.

Diese Entwicklungsbelege allein ersetzen nicht die unten dokumentierte Abnahme
der notarisiert installierten App: externe AppleScript-/CLI-Integration nach der letzten
Hoständerung, beide Sprachen einschließlich Fehlerlage, unveränderte dirty
Arbeitsfenster und Wiederöffnung nach einem echten App-Prozessneustart. Die
Notarisierung war am 2026-10-04 durch einen nicht verfügbaren lokalen
Schlüsselbund-Eintrag blockiert. Am 2026-10-05 ist das vorhandene Profil wieder
verfügbar: Der vollständige Installationslauf hat 1.129.0/287 notarisiert
installiert. Derselbe Stand ist auf einem separaten Testrechner installiert;
Notary-Ticket, Gatekeeper und vollständige Signaturprüfung bestehen dort vor
und nach der Installation. Die App-Binaries stimmen per SHA-256 überein.
Die installierte Abnahme vom 2026-10-05 ist unten festgehalten. Die frühere
Abnahme von 1.128.0 belegt für sich keine zusätzlichen Playerpfade.

Gleiche Release-Konfiguration wie beim obigen Ausgangsstand: Bundle
77.231.205 Bytes, App-Binary 62.737.776 Bytes, CLI-Helfer 390.848 Bytes.
Das Bundle wächst gegenüber dem Ausgangsstand um 746.333 Bytes (0,976 %),
gegenüber der abgenommenen Grundprobe um 108.430 Bytes. Diese Messung vergleicht
Ad-hoc-Bundles vor Developer-ID-Signierung und Notarisierung.

### Korrekturen in 1.129.1

Quellenwechsel entwerten auch extern gestartete Sitzungsnavigation vor der
Installation, unabhängig von der Kapazität des Folgeauftrags. Präsentation und
Bestätigung vergleichen zusätzlich Dokument-ID und Hash. Paketquellen erlauben
nur UTF-8 mit optionaler UTF-8-BOM und ohne Nullbytes. Abbruch und Schließen
bleiben bei voller Arbeitsjobliste möglich; ihre eigene Wiederholungshistorie
ist separat begrenzt. Datei → Schließen und ⌘W erkennen das Snapshot-Fenster.

Die Korrekturen bestehen 2.433 Tests in 113 Suites und 143 serielle
Integrationstests in 16 Suites. Der Capture-Treiber weist alte FAIL-Marker und
unvollständige Bildpaare ab und verlangt ein einmaliges Token in Auftrag,
PASS-Marker und beiden neuen Bildnamen. Nach der letzten Hoständerung bestehen die installierte deutsche AppleScript-
und englische JXA-Integration jeweils mit Exit 0. CLI und AppleEvents benutzen
dieselben Jobs. Die gespeicherte Erklärung öffnet nach einem echten
Prozessneustart ohne KI erneut; alte Runtime-Jobs werden abgewiesen. Beide
realen dirty Arbeitsfenster behalten Inhalt, Auswahl, Identitäten, Projekt und
Rahmen. Einstellungen bleiben unverändert. Die Prüfung vergleicht sämtliche
persistenten Test-/App-/Globaldomains und die wirksamen Einstellungen; fünf
belegte, erst beim Zeichnen registrierte Metal-/AppKit-Defaults werden nur bei
Übereinstimmung mit der Registrierungsdomain aus der wirksamen Sicht entfernt.
Eine Regression belegt, dass persistente Änderungen derselben Schlüssel sowie
der Editorschrift weiterhin erkannt werden.

Native Playerknöpfe, Quellenwechsel, Pause, Rückkehr, Fehlerpaket und lokale
getrennte Schriften bestehen. Bereit-, Pause- und Fehlerzustände sind in Deutsch
und Englisch bei 400/900 pt visuell geprüft. Auch die tatsächliche Maus-/Tastatur- und Menü-/⌘W-Abnahme besteht in beiden
Sprachen nach der letzten Änderung des externen GUI-Treibers. Mausaktionen
betätigen Zurück, Weiter, Pause, bewusste Rückkehr, Beenden sowie beide lokalen
Schriftgrößen. Ein echter Umschalt-Rechts-Tastendruck erweitert die Auswahl
während der Pause; sie bleibt anschließend stabil. Bewusste Rückkehr stellt
den gespeicherten Bereich wieder her. Das sichtbare Ablage-/File-Menü
schließt über Schließen/Close ausschließlich die Snapshot-Sitzung; ein
separater echter ⌘W-Tastendruck tut dasselbe. Beide dirty Arbeitsfenster und
die geschützten Einstellungen bleiben in beiden Läufen unverändert.
Die zusätzlichen Pause-Aufnahmen mit Code 14 pt und Erklärung 13 pt bestehen
die Sichtprüfung bei 400/900 pt.

1.129.1/288 ist vollständig notarisiert installiert und auf einem separaten
Testrechner vor und nach der Installation mit Ticket, Gatekeeper und
vollständiger Signatur geprüft. Gleiche Release-Konfiguration vor
Developer-ID-Signierung: Bundle 77.248.125 Bytes, App-Binary 62.754.352 Bytes,
Helfer 390.848 Bytes; gegenüber 1.129.0 wächst das Bundle um 16.920 Bytes.

## Herkunftsgebundene Übergabe

Ab 1.137.0 ergänzt `sourceSnapshot` den bestehenden `snapshot`-Auftrag.
Clients prüfen `sourceSnapshotSchemaVersion: 1` in den Fähigkeiten. Die
Transportversion bleibt 1. Bestehende Aufträge ändern sich nicht.

Zusätzlich zu `path`, `sha256`, `location` und `length` ist `provenance`
erforderlich. `path` bezeichnet die zu übernehmende Original- oder
materialisierte Blattdatei. Der Hash bindet deren exakte Bytes einschließlich
BOM; die Blattgrenze bleibt 262144 Bytes. Alle folgenden Objekte lehnen
unbekannte Felder und `null` ab:

| Feld in `provenance` | Vertrag |
| --- | --- |
| `schemaVersion` | Ganzzahl 1 |
| `runID` | UUID des Suchlaufs |
| `kind` | `original` oder `archiveMaterialization` |
| `hitIdentity` | `filesystemPath`, `archiveMembers`, `archiveMemberBytes` |
| `sourceGeneration` | `device`, `inode`, `size`, `modificationSeconds`, `modificationNanoseconds`, `changeSeconds`, `changeNanoseconds` |
| `archiveBinding` | Original: `notApplicable`; Archiv: `sha256` oder ausdrücklich `generation` |
| `outerSHA256` | Nur bei Archivbindung `sha256`: 64 kleine Hexzeichen |
| `positionBinding` | `exactUTF16` oder `unboundHit` |
| `searchEvidence` | Optionaler Suchbeleg des Senders, höchstens 4096 UTF-8-Bytes |

`filesystemPath` ist der absolute Pfad der Originaldatei beziehungsweise des
äußeren Archivs. Originaldateien verlangen denselben standardisierten Pfad
wie `path` und zwei leere Mitgliedslisten. Bei Archiven sind beide Listen
nicht leer und gleich lang: höchstens 32 Stufen, je Name beziehungsweise
Byteidentität höchstens 4096 Bytes. `archiveMemberBytes` enthält kanonisches
Base64 der verlustfreien Namenbytes. Gültige UTF-8-Namen müssen mit dem
Anzeigenamen übereinstimmen; bei ungültigen Bytes bleibt die Byteidentität
maßgeblich. `!/` ist keine Trennregel. Die Mitgliedskette wird als einzelne
Elemente übertragen, nicht aus einem Anzeigepfad rekonstruiert.

Die Generation beschreibt das äußere Dateiobjekt. `device`, `inode` und
`size` sind nichtnegative Ganzzahlen; Zeiten bestehen aus Unix-Sekunden und
Nanosekunden von 0 bis 999999999. Python-Sender können `st_mtime_ns` und
`st_ctime_ns` mit `divmod(value, 1000000000)` zerlegen. Zahlen müssen beim
JSON-Transport verlustfrei erhalten bleiben. Fastra prüft die Generation vor
und nach der Blattübernahme am geöffneten regulären Dateiobjekt und am erneut
aufgelösten Quellpfad. Ein Quellentausch liefert `stale`.

Bei `sha256` prüft Fastra zusätzlich den äußeren Archivhash vor und nach der
Übernahme. `maximumOuterArchiveBytes` beträgt 67108864 Bytes. Die Prüfung
liest in begrenzten Blöcken und ist abbrechbar; größere, verschwundene oder
unzugängliche starke Quellen liefern `sourceUnavailable`. Fastra wechselt
niemals still zu `generation`. Ein Sender darf für ein erreichbares größeres
Archiv ausdrücklich `generation` wählen; die Ansicht nennt dann die schwächere
Bindung. Generation allein beweist keine historische Byteidentität.

Auch ein geprüfter äußerer Hash beweist nicht, dass die Blattdatei aus dem
angegebenen Mitglied extrahiert wurde. Die Mitgliedszuordnung und Cachefrische
bleiben Verantwortung des Senders; Fastra entpackt das Archiv nicht erneut.
Der eigene Blattinhalt wird immer bytegenau gehasht. Suchzeilennummern eines
anderen Decoders sind keine UTF-16-Koordinaten: `exactUTF16` erfordert eine vom
Sender am identisch dekodierten Blatt bestätigte Position. Fastra prüft den
Bereich und vollständige Swift-Characters. Ohne diese Positionsbindung muss
`unboundHit` mit `location: 0, length: 0` verwendet werden. Die Ansicht erklärt,
dass sie am Anfang beginnt; ein Suchbeleg löst keinen geratenen Sprung aus.

Fastra kopiert die Rohbytes asynchron in ein eigenes privates, markiertes
Sitzungsverzeichnis, lädt und prüft diese Kopie und beobachtet anschließend
die echte Textansicht. Erst `state: ready` **und** `adopted: true` bestätigen
die unabhängige Übernahme. Danach darf der Sender seine Zwischendatei entfernen.
Jobstatus und Sitzungs-/Dokumentinventar liefern `provenance`; der sichtbare
Herkunftsbereich zeigt Schreibschutz, vollständige Mitgliedskette und Bindung.

Fehler und Abbruch entfernen unbestätigte Kopien; Sitzungsende und App-Ende
entfernen bestätigte Kopien. Verwaiste Wurzeln werden nach einem Prozessabbruch
nur anhand des eigenen Namensschemas, Markers und eines beendeten Besitzer-PIDs
bereinigt. Symlink-Wurzeln, unmarkierte Verzeichnisse und lebende Instanzen
bleiben erhalten. Übernommene Sitzungen werden nicht restauriert. Dauerhafte
Erklärungsartefakte müssen ihre benötigten Quellen ausdrücklich selbst speichern.
