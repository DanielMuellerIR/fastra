# F17 — Lokale Snapshot-Steuerung unter Linux

Der native Player und die lokale Steuerung verwenden denselben Controller. Der
JSON-Vertrag entspricht Protokollversion 1 aus [LOCAL-CONTROL](../LOCAL-CONTROL.md).
Unixsocket und `fastra-control` ersetzen Mach-Port und AppleEvents. Es gibt keine
Netzwerkverbindung und keine neuen Schreibbefehle für Arbeitsdateien. Normale
Editorfenster sind ausschließlich inventarisierbar.

## CLI und Transport

```sh
fastra-control --capabilities --json
fastra-control --request /absoluter/pfad/request.json
fastra-control --request - < request.json
fastra-control --no-launch --request request.json
```

Fähigkeiten funktionieren offline ohne GTK oder App-Start. Sonst startet der
Helfer ausschließlich die benachbarte `fastra-linux`-Anwendung mit dem internen
Argument `--local-control-service`; keine Shell und kein konfigurierbarer
Programmpfad. Dieser Start erzeugt kein zusätzliches normales Editorfenster.
Die laufende Steuerungsinstanz bleibt für Sitzungen, Status und Wiederholungen
verfügbar. Pro Desktop-D-Bus-Sitzung besitzt dieselbe native GApplication alle
normalen Fenster und Snapshot-Sitzungen. Ein späterer gewöhnlicher Start öffnet
auch nach einem reinen Dienststart ein sichtbares Editorfenster. Weitere Starts
und Dateiargumente werden durch GApplication an diese primäre Anwendung
weitergereicht; relative Pfade beziehen sich auf das Arbeitsverzeichnis des
Aufrufers. Linux-Dateinamen müssen dabei kein gültiges UTF-8 sein.
Ein Optionsseparator vor Bindestrich-Dateinamen wird einmal entfernt, auch
hinter anderen Pfaden; eine tatsächliche Datei namens `--` bleibt erhalten.
Scheitert der Socketstart, meldet ein Dienstaufruf einen Nichtnull-Exit und
hält keinen unsichtbaren funktionslosen Dienstprozess am Leben.

Dies ersetzt das frühere unabhängige Mehrprozessverhalten: Das Standardinventar
sah damals nur den ersten Socketbesitzer. Mehrere native Editorfenster bleiben
möglich, werden jetzt aber gemeinsam inventarisiert. Ein Dienstaufruf erzeugt
kein leeres Editorfenster und erwirbt höchstens eine Anwendungshalterung. Nach
einem Dienstaufruf bleibt der Prozess auch ohne sichtbare Fenster verfügbar;
gewöhnliche Starts können wieder Fenster öffnen. Ohne Dienstaufruf beendet das
Schließen des letzten Anwendungsfensters den Prozess. Ctrl+Q schließt weiterhin
das aktuelle Fenster mit dessen bestehender Prüfung ungesicherter Änderungen.
Ein ausdrückliches natives `GApplication.quit()` beendet auch den gehaltenen
Dienst und räumt Server, Snapshot-Sitzungen und Fensterregistrierung auf.

Ein Request-File muss regulär sein; FIFO und Geräte werden abgewiesen. Exit 0
bedeutet eine erfolgreiche Protokollantwort, Exit 1 einen Fehler als JSON in
`error`. `status` mit `job.state = failed` bleibt eine erfolgreiche Statusabfrage.
Die CLI wartet nicht auf `ready`. Verlorene Antworten werden ausschließlich mit
dem unveränderten ursprünglichen Request wiederholt.

Der Endpunkt heißt `org.fastra.Fastra.Development.control.v1.sock` im validierten
benutzereigenen `XDG_RUNTIME_DIR` (0700). Ohne diese Variable wird ausschließlich
`/tmp/fastra-control-<uid>` mit denselben Eigentums-/Rechteprüfungen verwendet.
Der Socket besitzt 0600; beide Seiten prüfen die Peer-UID über `SO_PEERCRED`.
Der erste erfolgreiche Listener besitzt den Standardendpunkt. Weitere Prozesse
übernehmen oder löschen ihn nicht. Eine gehaltene Sperrdatei und die geprüfte
Socketidentität schützen Start und Cleanup. Kein abstrakter oder TCP-Socket.

Je Verbindung wird genau ein Request verarbeitet: vier Byte Big-Endian-Länge,
danach exakt so viele UTF-8-JSON-Bytes. Dasselbe Framing gilt für die Antwort.
Vier feste Worker und eine Queue mit höchstens 16 Zustellungen begrenzen langsame
Clients. Annahme-/Controlleraktionen laufen auf GTK, Datei-I/O auf Hintergrund-
Threads. Die Gesamtfrist schließt Connect, fragmentierte Übertragung und Antwort ein.

Zwei dokumentierte Linux-Grenzen ergänzen den Mac-Vertrag:

- Vollständige Antworten dürfen höchstens 16 MiB beanspruchen. Bei Überschreitung
  folgt `capacity`; es gibt niemals ein abgeschnittenes oder teilweises Inventar.
  Die bestehenden `maximumMessageBytes = 65536` begrenzen Requests, nicht Antworten.
- Auch Standardinput bis EOF zählt zur gesamten zehnsekündigen CLI-Frist.
  Der Mac-Helfer wartet vor seiner Transportfrist unbegrenzt auf EOF.

GTK verweigert echtes U+0000 auch bei Raw-FFI mit expliziter Bytelänge. Dekodierte
Snapshots mit U+0000 scheitern deshalb unter Linux mit `sourceUnavailable` und
einem konkreten Fehlertext. Dies betrifft auch gültige UTF-16-/UTF-32-Dateien mit
BOM und explizite Decoderhinweise. Die App ersetzt keine Zeichen und bestätigt
keinen abweichenden Inhalt als `ready`. Der reproduzierbare Versuch liegt unter
[tools/linux-probes/local-control](../../tools/linux-probes/local-control/gtk-nul.c).
Das ist eine native Linux-Grenze, keine behauptete Mac-Parität für diesen Fall.

## Request-DTO und Operationen

Jeder Request enthält `version: 1`, `id: UUID`, `deadline: Double` (absolute
Unixsekunden), `operation: String` und optional `runtimeID: UUID`. Unbekannte
Felder und explizites `null` sind auch in verschachtelten Herkunftsobjekten
ungültig. UUIDs werden als UUID-Werte verglichen. Strings bei der
Wiederholungsprüfung besitzen Swifts kanonische Unicode-Gleichheit; tatsächliche
Quellpfade und Bytes werden dadurch nicht normalisiert.

Ganzzahlfelder akzeptieren auch mathematisch ganze Dezimal-/Exponentformen wie
`1.0`, `1e0` und `10e-1`. Die Werte werden aus dem validierten JSON-Zahltext exakt
berechnet, insbesondere auch oberhalb von 2^53 und für UInt64-Dateigenerationen.
Die nativen Foundation-Ablehnungen an den 64-Bit-Dezimalgrenzen sind durch
Mac-Referenzdaten belegt. Nicht ganze Werte werden unter Linux nicht durch
Rundung oder Unterlauf zu Ganzzahlen gemacht: etwa `1.00000000000000000000000000001`,
`9007199254740993.1` und `1e-100000` bleiben ungültig, obwohl Foundation diese
Werte toleriert. Fehlende optionale Felder bleiben von explizitem `null` getrennt;
doppelte und unbekannte Felder sind weiterhin ungültig.

| Operation | Exakte zusätzliche Pflichtfelder | Antwort |
| --- | --- | --- |
| capabilities | keine | capabilities |
| objects | keine | objects, jobs |
| snapshot | path, sha256, location, length | job |
| sourceSnapshot | path, sha256, location, length, provenance | job |
| explanation | path | job |
| navigate | sessionID, documentID, sha256, location, length | job |
| status / cancel | jobID | job |
| close | sessionID | keine Nutzfelder |

Nur `sourceSnapshot` erlaubt zusätzlich optional `textEncoding`:
`utf-8`, `utf-16-le`, `utf-16-be`, `windows-1252`, `iso-8859-1`, `mac-roman`.
Ein vorhandener BOM muss dazu passen. Ohne Hinweis gilt der bestehende strenge
Decoder: BOM, UTF-8, definiertes CP1252-Signal, sonst Latin-1. Kein verlustbehafteter
Fallback. `path` ist absolut und NUL-frei; `sha256` sind 64 kleine Hexzeichen über
alle unveränderten Rohbytes einschließlich BOM.

`location` und `length` sind nichtnegative 64-Bit-Ganzzahlen, zählen UTF-16-Einheiten
ab null und dürfen zusammen nicht überlaufen. Start inklusive, Ende exklusiv;
Länge null ist auch am EOF zulässig. Beide Grenzen liegen auf vollständigen
Graphemen, einschließlich CRLF, Combining-Sequenzen und Emoji-ZWJ. Die bereits
vorhandene ICU-Graphemprüfung des Codefragekerns wird wiederverwendet.

## Antwort-DTOs

Optionale Felder werden ausgelassen, niemals als `null` geschrieben.

```text
Selection { location: Int, length: Int }
Failure { code: String, message: String, appleScriptNumber: Int }
Object {
  id: UUID, kind: String, name: String,
  windowID?: UUID, documentID?: UUID, sessionID?: UUID,
  sha256?: String, selection?: Selection, provenance?: Provenance
}
Job {
  id: UUID, requestID: UUID, state: String,
  sessionID: UUID, windowID: UUID, documentID: UUID,
  sha256?: String, textSHA256?: String, byteCount?: Int,
  encoding?: UInt, bomBytes?: Int, selection?: Selection,
  error?: Failure, provenance?: Provenance, adopted?: Bool
}
Reply {
  protocolVersion: 1, runtimeID?: UUID, capabilities?: Capabilities,
  objects?: [Object], jobs?: [Job], job?: Job, error?: Failure
}
```

Objektarten: `window`, `document`, `session`. Zustände: `accepted`, `loading`,
`presenting`, `ready`, `failed`, `cancelled`; die letzten drei sind terminal.
`encoding` bleibt der numerische Foundation-`String.Encoding.rawValue`:
UTF-8 4, UTF-16LE 2483028224, UTF-16BE 2415919360, UTF-32LE 2617245952,
UTF-32BE 2550137088, CP1252 12, Latin-1 5, MacRoman 30. Es sind keine Rust-Enumwerte.
`textSHA256` bindet den dekodierten Text als UTF-8 ohne entfernte Datei-BOM.
Navigationsjobs liefern Hashbindungen; Byte-/Encodingdaten gehören zu Ladejobs.

Fehlercodes sind `invalidRequest` (−1700), `unsupported` (−1708), `invalidID`
(−1728), `stale`, `invalidRange`, `sourceUnavailable`, `capacity`, `expired`,
`interrupted`, `delivery` (je −2700). Das Feld `appleScriptNumber` bleibt aus
JSON-Kompatibilität erhalten; Linux bietet dadurch keine AppleEvents an.

Capabilities enthalten exakt die bestehenden Namen und Werte:

```text
protocolVersion: 1
operations: [capabilities, objects, snapshot, sourceSnapshot, explanation,
             status, cancel, navigate, close]
sourceKinds: [fileSnapshot, archiveMaterialization]
sourceSnapshotSchemaVersion: 1
sourceSnapshotTextEncodings: [die sechs Decoder oben]
maximumOuterArchiveBytes: 67108864
coordinates: "zero-based UTF-16; start inclusive, end exclusive; grapheme boundaries required"
readOnly: true
maximumSnapshotBytes: 262144
maximumMessageBytes: 65536
requestTimeoutSeconds: 10
jobTimeoutSeconds: 30
retentionSeconds: 300
maximumJobs: 128
explanationSchemaVersion: 1
maximumExplanationSteps: 5
maximumExplanationTotalSourceBytes: 1048576
explanationEncodings: [utf8]
maximumSessions: 16
runtimeID?: UUID
productVersion?: String
```

Die laufende App ergänzt Laufzeit und Produktversion; Offline-Capabilities lassen
beide weg. Inventar und Jobs sind nach UUID sortiert. Normale Fenster und ihre
Tabs besitzen schwache Laufzeitidentitäten; geschlossene Objekte werden nicht
festgehalten oder durch wiederverwendete Speicheradressen verwechselt.

## Herkunft und unabhängige Materialisierung

```text
Provenance {
  schemaVersion: 1, runID: UUID,
  kind: original | archiveMaterialization,
  hitIdentity: {
    filesystemPath: String,
    archiveMembers: [String], archiveMemberBytes: [canonical Base64]
  },
  sourceGeneration: {
    device: UInt64, inode: UInt64, size: UInt64,
    modificationSeconds: Int64, modificationNanoseconds: Int64,
    changeSeconds: Int64, changeNanoseconds: Int64
  },
  archiveBinding: notApplicable | sha256 | generation,
  outerSHA256?: String,
  positionBinding: exactUTF16 | unboundHit,
  searchEvidence?: String
}
```

Herkunftspfad: höchstens 16384 UTF-8-Bytes, absolut und NUL-frei. Höchstens
32 gleich lange Mitglieds-/Byteidentitätslisten, je Name und dekodierter
Byteidentität 1–4096 Bytes ohne NUL. Base64 ist kanonisch. Gültige UTF-8-Rohbytes
müssen dem Anzeigenamen bytegenau entsprechen; ungültige UTF-8-Rohbytes bleiben
maßgeblich. Suchbeleg: höchstens 4096 UTF-8-Bytes ohne NUL. Nanosekunden:
0–999999999. Es gibt keine Trennung über ein künstliches `!/` im Dateinamen.

`original` verlangt leere Mitgliedslisten, `notApplicable`, keinen äußeren Hash
und denselben lexikalisch standardisierten Pfad. Archivmaterialisierung verlangt
Mitglieder und entweder `sha256` samt äußerem Hash oder ausdrücklich schwächere
`generation` ohne Hash. `unboundHit` erlaubt ausschließlich Auswahl 0/0.

Quelle und Rohhash stammen aus demselben regulären geöffneten Dateiobjekt.
Links auf reguläre Textdateien und Hardlinks werden für diesen rein lesenden
Pfad nicht durch Schreibtransaktionsregeln ausgeschlossen. Änderungen während
des Reads werden verweigert. Die äußere Quelle wird vor und nach der Übernahme
auf ihre vollständige Generation geprüft. Bei Hashbindung werden höchstens
64 MiB mit Abbruchprüfung gestreamt; ein Fehler führt nie zum schwächeren Modus.
Die App extrahiert kein Archiv und prüft nicht eigenständig die vom Sender
angegebene Mitgliedszuordnung.

Die Materialisierung wird in eine eigene zufällige 0700-Wurzel mit Marker und
0400-Datei übernommen, unabhängig erneut gelesen und geprüft. Erst `ready` mit
`adopted: true` bestätigt die Übernahme. Unbestätigte Kopien verschwinden bei
Fehler/Abbruch, bestätigte beim Sitzungsende. Navigation und deren Abbruch
entfernen keine bereits bestätigte Kopie. Orphan-Cleanup betrifft nur eigene
markierte echte Verzeichnisse mit nachweislich beendetem Besitzer; lebende,
fremde, unmarkierte oder verlinkte Wurzeln bleiben erhalten.

## Budgets, Wiederholung und GTK-Bindung

Neue Requests brauchen eine noch gültige Frist bis höchstens jetzt + 11 Sekunden.
Jobs haben 30 Sekunden ab Erstellung; Jobs und Wiederholungseinträge bleiben
300 Sekunden. Höchstens 128 Jobs einschließlich terminaler Jobs und 16 Sitzungen
einschließlich Ladevorgängen. Es gibt 256 Annahme-Wiederholungseinträge ohne
Verdrängung und davon unabhängig 256 Aufräumeinträge für `cancel`/`close`, die
nur innerhalb ihres eigenen Speichers den ältesten Eintrag verdrängen dürfen.

Die Laufzeitbindung wird vor jeder Operation und Wiederholung kontrolliert.
Bekannte mutierende Requests werden vor der Fristprüfung auf Gleichheit geprüft;
unveränderte Wiederholung liefert den ursprünglichen aktuellen Job, auch nach
Ablauf der ursprünglichen Frist. Andere Inhalte mit derselben ID scheitern.
Nichtmutierende Abfragen werden nicht wiederholungsgespeichert.

`ready` verlangt echten unveränderten Ansichtsinhalt, exakte Auswahl und native
Geometrie, die den sichtbaren Ausschnitt schneidet. Die Auswahl wird einmal
gesetzt, danach dreimal im Abstand von 20 ms beobachtet. Ein großer Bereich
muss nicht vollständig ins Fenster passen. Eigene Auswahl, Tastatur, Maus,
Scrollen, neuere Navigation, Quellenwechsel, Cancel und Schließen entwerten
laufende Ergebnisse sofort über Generation und Abbruchsignal. Kein verspätetes
Laden oder Layout darf anschließend Inhalt oder Auswahl anwenden.

Der Player verwendet dieselben Sitzungen und Jobs. Seine sichtbaren Aktionen
wechseln eingefrorene Quellen mit stabiler Dokument-ID pro Quelle, pausieren
bei eigener Erkundung und kehren nur ausdrücklich zur erklärten Stelle zurück.
Externe Navigation pausiert den Player. Frühere Dokument-IDs werden bei einem
Quellenwechsel abgewiesen. Arbeitsdateien, normale Editorpuffer, globale Optionen
und Session-Restaurierung gehören nicht zu diesem Protokoll.

## Paketierung und Prüfung

`fastra-control` muss neben `fastra-linux` gebündelt werden. Der Helfer selbst benötigt kein
GTK; beide Programme verwenden dieselbe Protokoll-/IO-Bibliothek. Die festen
Paketlauncher setzen den privaten ICU-Pfad.
Bestehende ICU-Laufzeitbündelung gilt weiter. Neue Crates kommen ohne neue externe
Dependency-Pins aus. Cargo.lock wird durch den Integrator aktualisiert.

Die Regressionen prüfen Requestformen, Unicodebereiche, kanonische Wiederholung,
Fristen/Kapazität, sichere Materialisierung, Rohhash-/Gesamtbudgetfehler, echte
Socketfragmentierung und vollständige Antwortgrenzen. Native Tests laufen mit
echten CLI-Prozessen in einem isolierten Display, prüfen alle neun Operationen,
Nutzerabbruch, Playerquellenwechsel und unveränderte Arbeitsdokumente. Der
bestehende sichtbare Tools-/Dateiauswahl-Playerpfad bleibt zusätzlich geprüft.
