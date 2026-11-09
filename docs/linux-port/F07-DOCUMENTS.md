# F07/F14: Verlustfreie Codecs und begrenzte Dokumentansichten

`fastra-core::encoding` stellt die plattformunabhängigen Dateicodecs bereit.
`fastra-document` baut darauf und auf `fastra-io::Snapshot` die Linux-
Dokumentbasis auf. Die APIs sind synchron; Hosts rufen Dateioperationen auf
Hintergrund-Threads auf und übersetzen die typisierten Fehler in Nutzersprache.

## Codecs

```rust
encoding::decode(bytes: &[u8], explicit: Option<Encoding>)
    -> Result<Decoded, EncodingError>
Decoded::text() -> &str
Decoded::encoding() -> Encoding
Decoded::bom() -> &[u8]
Decoded::encode(new_text: &str) -> Result<Vec<u8>, EncodingError>
```

Unterstützt sind UTF-8, UTF-16 LE/BE, UTF-32 LE/BE, Windows-1252, ISO-8859-1
(Latin-1) und MacRoman. `Decoded` besitzt private validierte Felder. Die
Original-BOM wird genau einmal abgetrennt und beim Encodieren bytegenau
wieder vorangestellt. Ein zweites U+FEFF bleibt Inhalt. UTF-32-BOMs werden vor
UTF-16 geprüft. Ohne BOM wird keine erzeugt. Zeilenenden werden unverändert
gespeichert; `LineEnding::detect/convert` bildet die ausdrücklich gewählte
Mac-Konvention ab: CRLF hat bei der Erkennung Vorrang vor CR, sonst LF.

Automatische Wahl folgt dem bestehenden Mac-Verhalten: strenges UTF-8 zuerst,
danach Windows-1252 nur bei mindestens einem definierten druckbaren C1-Byte und
gültiger vollständiger CP1252-Konvertierung, sonst Latin-1. MacRoman wird nur
ausdrücklich gewählt. NUL ohne UTF-16-/UTF-32-BOM liefert bei automatischer Wahl
`Binary`; auch eine UTF-8-BOM erklärt keine NUL-Bytes. Eine ausdrückliche Wahl
überspringt diese Binärklassifikation.

Eine vorhandene Datei-BOM wird wie im expliziten Mac-Öffnungspfad abgetrennt,
auch wenn das ausdrücklich gewählte Body-Encoding davon abweicht. Die BOM bleibt
für das unveränderte spätere Speichern erhalten. Die API bietet bewusst konkrete
LE-/BE-Varianten statt einer mehrdeutigen generischen UTF-16-/UTF-32-Variante.

Ungültiges UTF-8, unvollständige Codeeinheiten, ungepaarte UTF-16-Surrogate und
ungültige UTF-32-Skalare sind Fehler. Nach ausdrücklicher Wahl oder BOM wird
niemals auf einen anderen Codec zurückgefallen. Nicht darstellbare Ersetzungen
liefern `Unrepresentable(char)` vor jeder Dateischreiboperation. Insbesondere
wird Latin-1 nicht als Windows-1252 behandelt.

`decode_payload(bytes, encoding)` dekodiert streng ohne BOM-Abtrennung; der
Seitenreader verwendet es für bereits ausgerichtete Nutzdaten.
`detect_bom(bytes)` liefert die tatsächlich vorhandene Präfixscheibe und den
zugehörigen Codec. Diese Hilfsfunktionen verändern keine Daten.

## Dokumente und Quellenidentität

`Document::open(path, explicit, cancellation)` liefert:

- `Text(TextDocument)`: vollständig geladener Text mit höchstens 32 MiB
  Quelldaten und 32 MiB dekodiertem UTF-8-Text, mit `Decoded`, unveränderlichem Save-`Snapshot` und
  `SourceIdentity`. Texte mit einer über 64 KiB langen UTF-8-Zeile wechseln in
  die begrenzte Abschnittsansicht.
- `ReadOnlyText(ReadOnlyTextDocument)`: dieselben vollständigen Textgrenzen,
  aber ausschließlich lesbar, wenn keine sichere Schreibmetadatenbasis erfasst
  werden kann. Die Schreibschnittstelle ist an diesem Typ nicht verfügbar.
- `Sections(SectionDocument)`: große oder langzeilige Texte, ausschließlich
  lesbar und ohne schreibbaren Snapshot.
- `Hex(SectionDocument)`: binäre Daten, ebenfalls ausschließlich lesbar.

Die ersten 8 KiB einer kleinen Datei erkennen offensichtliche NUL-Binärdaten,
bevor ein vollständiger Save-Snapshot angefordert wird. Bei großen Dateien
prüft die Klassifikation höchstens 1 MiB plus drei UTF-8-Lookahead-Bytes.
UTF-16-/UTF-32-BOMs legen den Codec direkt fest. Spätere Abschnitte werden
jeweils streng geprüft; eine gültige Anfangsprobe verspricht keine Gültigkeit
der gesamten großen Datei. Spätere NUL-Binärdaten oder fehlerhafte Codeeinheiten
ergeben einen Seitenfehler statt einer verlustbehafteten Ersatzdarstellung.

Der Loader löst Symlinks auf und öffnet das Ziel mit `O_NONBLOCK`, `O_CLOEXEC`
und `O_NOFOLLOW`. Typ und Größe stammen vom geöffneten Deskriptor. FIFOs,
Sockets, Geräte und Verzeichnisse werden vor dem Lesen abgewiesen. Die
Symlink-Länge kann deshalb weder Größenlimits umgehen noch große Ziele als
kleine editierbare Dateien klassifizieren.

Die Quelle hält denselben nur lesbaren Deskriptor für ihre Lebensdauer. Ihre
Identität enthält Gerät, Inode, Größe, mtime/ctime mit Nanosekunden,
Dateimodus und Eigentümer. Jeder Abschnitt prüft davor und danach diese
Metadaten und die aktuelle Bindung des ursprünglich angefragten Pfads; ein
Dateiaustausch, eine In-place-Änderung oder ein umgebogener Symlink liefert
`Stale`. Das ist bei großen Dateien ein Metadaten-Fingerabdruck, kein
vollständiger Hash einer mehrgigabytegroßen Datei.

Bei editierbaren Dateien muss die vom Save-Snapshot selbst erfasste
`file_identity()` zusätzlich Gerät und Inode des gehaltenen Quelldeskriptors
treffen. Gleiche Bytes aus einem anderen Inode genügen nicht. Der IO-Snapshot
bleibt die verbindliche Basis für eine spätere Save-Transaktion.

## Seiten- und Host-API

`TextDocument` stellt `decoded`, `text`, `snapshot`, `identity`, `path`,
`line_ending`, `encode` und `verify_current` bereit. `snapshot().clone()` bleibt
die günstige unveränderliche Save-Basis; der Host muss den neuen Text zuerst
mit `encode` verlustfrei encodieren und anschließend den vorhandenen
IO-Transaktionsweg verwenden. Er darf keine neue Snapshot-Basis aus einem
später erneut gelesenen Pfad erzeugen.

`SectionDocument` stellt Identität, aufgelösten Pfad, Encoding, BOM und
`verify_current` sowie diese zwei Operationen bereit:

```rust
read_text(byte_offset, cancellation) -> TextSection
// byte_range: tatsächlich gelieferte Quellbytes, text, next_offset
read_hex(byte_offset, byte_count, cancellation) -> HexSection
// byte_range und exakte bytes; byte_count höchstens 256 KiB
```

Textseiten lesen höchstens 64 KiB plus 16 Bytes Kontext. Der Start wird bei
einem beliebigen Byteoffset höchstens drei Bytes zum Skalaranfang zurückgesetzt;
UTF-16-Surrogatpaare und UTF-32-Einheiten werden nicht zerrissen. Die erste
Datei-BOM erscheint nicht als Inhalt. Auch die nach UTF-8 umgesetzte sichtbare
Seite bleibt auf 64 KiB begrenzt; Single-Byte-Konvertierung darf das Editorlimit
nicht durch Expansion umgehen. `next_offset` setzt lückenlos fort, unabhängig
von den unterschiedlichen Längen von Quellbytes und UTF-8-Text.

Hex-Seiten werden nicht als Text interpretiert. Ungültige Offsets, zu große
Anforderungen und Abbruch sind eigene Fehler. Abbruch wird vor dem Öffnen,
zwischen begrenzten Leseblöcken und vor/nach einer Seite geprüft. Es gibt
keinen Schreibpfad für `Sections` oder `Hex`.

## Prüfung, 2026-11-04

Sechs Codec- und zwölf Dokumenttests bestanden, ebenso Clippy mit
`--all-targets -- -D warnings`. Die vorhandenen 22 Such- und elf
Textoperationstests liefen im selben Prüflauf ebenfalls erfolgreich.

Die Codec-Prüfung vergleicht alle 256 Bytewerte jedes Single-Byte-Codecs mit
einem auf macOS mit Foundation erzeugten Referenzsatz und prüft dessen
verlustfreie Rückrichtung. `tests/fixtures/encoding-reference.swift` erzeugt
die kleine JSON-Referenz erneut. Alle 768 Vergleiche stimmten einschließlich
der von Foundation abgewiesenen CP1252-Werte überein. Weitere Fälle prüfen
Unicode mit/ohne BOM, doppelte BOM, gemischte Zeilenenden, falsche Codeeinheiten,
explizite Codecs und nicht darstellbare Ersetzungen.

Die Dokumenttests verwenden ausschließlich synthetische temporäre Dateien:
ein 8-GiB-Sparsefile mit begrenztem Hex-Read, UTF-8-Grenzen an einer Probe und
an Seitenwechseln, UTF-16-Surrogate, UTF-32, Single-Byte-Expansion,
Save-Basiserhalt, Dateiaustausch, Symlink-Zielmetadaten und Retargeting,
Abbruch, FIFO/Verzeichnis sowie späte Binärdaten und unvollständige Endcodeunits.
Sparsefiles werden mit dem Testverzeichnis entfernt; keine Benutzerdaten
werden benötigt.

Die Fachlogik und begrenzten Ansichten sind damit vorhanden. Die Linux-GUI
muss Encoding-Wahl, Seitenwechsel, Hex-Darstellung und ihre Fehlerzustände noch
anbinden und im echten Lauf prüfen. Große und binäre Dateien bleiben in dieser
Ausbaustufe bewusst schreibgeschützt.

## Reine Lesegrundlage ab 1.218.0

`fastra_io::ReadSnapshot` ist von der schreibfähigen `Snapshot`-Basis getrennt.
Er liest ausschließlich reguläre Dateien, absolut und ohne Symlink-Traversierung,
mit einem vom Aufrufer enger wählbaren Limit bis 32 MiB und Abbruchprüfung je
64-KiB-Block. Bekannte Dateien brauchen am Elternordner nur Suchrechte; die
Verzeichnisbindung verwendet `O_PATH`. Gehaltener Elternordner, Dateiname,
Inode, Größe, Modus, Eigentümer, mtime/ctime und vollständige Bytes werden
geprüft. Ein Dateiaustausch oder umbenannter Elternordner invalidiert das Ergebnis.
Die optionale Laufzeitprüfung bleibt vor und nach dem Öffnen wirksam.

Hardlinks sind hier zulässig; erweiterte Attribute werden nicht aufgelistet oder
für eine spätere Wiederherstellung eingelesen. `ReadOnlyTextDocument` ergänzt
verlustfreie Dekodierung und die vorhandene Grenze vollständiger Textzeilen.
Die ursprünglich angefragte Pfad-/Symlinkbindung wird zusätzlich überprüft.
Dateivergleiche einschließlich Ordnerpaaren und externem Helfer, lokale
Markdown-Referenzprüfungen sowie Bild-/PDF-/SVG-Vorschauen verwenden diese Basis.
Vergleichsberichte schützen weiterhin erfasste und aktuelle Quellidentitäten
gegen Überschreiben, auch nach Umbenennen oder über weitere Hardlinks.

`Change`, `Transaction` und der normale editierbare Dokumentpfad verlangen
weiterhin einen separat erworbenen Schreibsnapshot. Es gibt keine Konvertierung
von `ReadSnapshot` dorthin. Die strengeren Metadaten-/Hardlink-Prüfungen des
Schreibpfads bleiben unverändert. Referenzsprünge in noch nicht offene Dateien
vergleichen ihre Lesebasis mit der separat geladenen Schreib- oder Lesebasis
und prüfen die Quelle erneut. Auch Bildimport/-kopien mit späterer
Metadatenwiederherstellung bleiben bewusst im bestehenden Schreibverfahren.

## Vollständige schreibgeschützte Quelltexte ab 1.219.0

`Document::open` versucht zunächst die bestehende Schreibgrundlage. Fehlt sie
wegen Hardlinks, Verzeichnisrechten oder nicht abfragbaren beziehungsweise zu
großen Schreibmetadaten, darf ausschließlich ein eigener Lesesnapshot den
vollständigen Quelltext bereitstellen. Dieser wiederholt alle Datei-, Pfad-,
Laufzeit-, Abbruch- und Byteprüfungen. Veraltete oder abgebrochene Eingaben
bleiben Fehler. Der dekodierte UTF-8-Text ist ebenfalls auf 32 MiB begrenzt;
sonst verwendet die Anwendung die Abschnittsansicht. Reine vollständige
Vergleichsleser weisen diese Überschreitung ab.

Beide Quellausschnitte entstehen bereits schreibgeschützt. Schloss im Tab und
Hinweiszeile kennzeichnen den Zustand; Formatierungs- und Schreibaktionen
bleiben verborgen oder gesperrt. Kopieren, Finden einschließlich Trefferselektion,
Zeilen-/Spaltensprung, Gliederung, Vorschau und deren Positionssprünge sowie
Textdruck verwenden eigene Leseprüfungen. Die unveränderten Schreibprüfungen
bleiben an Bearbeitung, Ausschneiden, Einfügen, Ersetzen, Undo und Speichern.
Der gemeinsame Verlauf nimmt auch geprüfte Referenzsprünge in solche Tabs auf.

„Als Kopie bearbeiten“ erzeugt aus der sichtbaren Fassung einen neuen,
ungespeicherten Text ohne Quellpfad oder Schreibsnapshot. Kodierung und BOM
bleiben erhalten; große dekodierte Daten werden über `Arc` geteilt. Eine neue
Datei wird weiterhin über den vorhandenen exklusiven Save-new-Pfad gespeichert.
Die ursprüngliche Quelle erhält dadurch keine Schreibfreigabe.

Ein leichter Metadatenvergleich meldet externe Änderungen oder fehlende Quellen
im Hintergrund. Die sichtbare Fassung bleibt erhalten; „Datei neu öffnen“ lädt
einen neuen Tab. `verify_identity` dient nur diesem Hinweis und ersetzt weder
vollständige Byteprüfung noch Ergebnisfreigabe. Der Beobachter endet beim
Schließen des ursprünglichen Tabs, auch wenn ein anderer Aufrufer den Dokument-
`Rc` noch hält.

### Sitzungsreferenzen ab 1.220.0

Bei freiwillig aktivierter Sitzungssicherung werden vollständige schreibgeschützte
Quelltext-Tabs als eigene V2-Datensätze mit Dateipfad, Kodierung und Tabposition
gespeichert. Sie enthalten weder zwischengespeicherten Text noch Schreibsnapshot.
V1-Sicherungen bleiben lesbar; ohne Lese-Tabs bleibt das Format V1. Gemeinsam
höchstens 32 Tabs, eindeutige Positionen, absolute begrenzte Pfade und bekannte
Kodierungen werden vor dem Öffnen geprüft.

Der Freigabedialog erklärt, dass der aktuelle Plattenstand erneut gelesen wird.
Der Hintergrundpfad ruft unmittelbar `ReadOnlyTextDocument::open` auf; selbst
entfallene Hardlinks oder inzwischen verfügbare Schreibmetadaten erteilen keine
Schreibbasis. Reihenfolge und aktiver Tab bleiben erhalten. Fehlende, binäre,
zu große oder überlangzeilige Quellen werden einzeln gemeldet. Ungesicherte
Editorinhalte können trotzdem wiederhergestellt werden; die ursprünglichen
Sicherungen werden bei einem solchen Teilfehler nicht verbraucht. Ein erneuter
Versuch erfolgt über eine neue Prüfung. Abbruch und veraltete Fenster verwerfen
das Ladeergebnis. Eine bearbeitbare Kopie nimmt am normalen vollständigen
Inhaltswiederherstellungsverfahren teil; Abschnitte, Hex und andere Vorschauen
bleiben ausgeschlossen.

## Automatischer Startzustand ab 1.234.0

Die globale Start-Einstellung ist standardmäßig an. Nach den vollständigen
Schließen-/Speichernentscheidungen erfasst Fastra gespeicherte Dateipfade,
Projektpfad, Reihenfolge, aktiven Dateitab, Fenstergröße und Maximierung.
Ungesicherte Bytes werden nicht gespeichert; auch ein geänderter Dateitab wird
beim nächsten Start aus dem dann aktuellen Plattenstand geöffnet. Unbenannte
Dokumente, erzeugte Vergleiche und Fenster ohne Dateipfade bleiben draußen.
Die freiwillige Entwurfssicherung ist ein getrennter Vertrag und Speicher.

`startup.json` im privaten Konfigurationsverzeichnis verwendet den vorhandenen
atomaren Einstellungsstore. Rohbytes erhalten auch nicht als UTF-8 darstellbare
Dateinamen. Grenzen: 64 Fenster, insgesamt 1024 Dateipfade, 4096 Bytes je Pfad,
1 MiB Zustandsdatei. Abschalten leert die Fensterliste. Unbekannte Versionen,
beschädigte, unsichere oder gesperrte Dateien werden nicht überschrieben.
Ein Speicherfehler vor dem letzten Schließen erlaubt Abbrechen, Wiederholen
oder ausdrücklich Beenden unter Beibehaltung des alten Startzustands.

Ein reiner Hintergrunddienst öffnet keine Fenster und ersetzt den Zustand
nicht. Der erste normale Start lädt Dateien nacheinander im Hintergrund;
fehlende oder nicht reguläre Quellen und danach leere Fenster entfallen.
Explizite Öffnungsaufträge warten bis zum Ende und werden einmal zugestellt.
Eigene Datei-/Projektwahl, Home, neue Tabs, Eingaben und Tabwechsel entwerten
die betreffende Wiederherstellung. Beenden verwirft auch wartende Aufträge;
verspätete Ergebnisse dürfen keine Fenster oder Tabs wieder eröffnen.
Die vorhandene Linux-Regel für zusätzliche warme Öffnungsaufträge bleibt
bestehen; die projektbezogene Wiederverwendung vorhandener Fenster ist offen.

Unter X11 werden ausschließlich eigene Fenster über die optionale
[EWMH-Schnittstelle](https://specifications.freedesktop.org/wm/latest-single/)
positioniert. Nicht mehr sichtbare Positionen werden auf heutige Monitore
begrenzt. Unter Wayland bestimmt der Compositor die globale Position;
[GTK 4 bietet dort keine freie Fensterpositionierung](https://docs.gtk.org/gtk4/migrating-3to4.html).
Größe und Maximierung bleiben native GTK-Eigenschaften. Eine Wayland-Abnahme
ist damit nicht erklärt.

`linux/test.sh startup` prüft echtes Beenden mit Verwerfen und einen frischen
Prozess. Die Varianten `startup-mixed`, `startup-open`, `startup-disable`,
`startup-missing`, `startup-corrupt`, `startup-busy`, `startup-last-close`,
`startup-offscreen`, `startup-maximized` und `startup-interrupt-…` ergänzen
Ansichtstypen, Auftragsreihenfolge, Fehlerentscheidungen und eigene Eingaben.
Die native Prüfung verwendet synthetische Dateien, echte Tastatur-/Mauseingaben
und den vorhandenen nur lesenden Lifecycle-Beobachter. Andere isolierte
Selbsttests schalten nur in ihrem eigenen Testprofil die neue Startoption aus;
dadurch bleiben deren eigenständige Entwurfs-Recovery-Vorbedingungen erhalten.
