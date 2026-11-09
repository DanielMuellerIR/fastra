# F09: native 4D-Vervollständigung

Die Vervollständigung verwendet die reine ursprüngliche Präfix-/Matchinglogik aus
`FourDCompletion.swift`, die bereits abgeleiteten Swift-Unicode-Fakten sowie die
vorhandene lexikalische Kommentar-/String-Erkennung. Es gibt keine zusätzliche
Such-, Unicode- oder 4D-Laufzeitengine. 1270 kanonische Befehle, deren verfügbare
Signaturen und 2306 Konstanten werden als generierte Fakten direkt eingebettet;
der vorhandene Tokenkatalog bleibt unverändert. Der Ressourcenpfad funktioniert
auch ohne Checkout oder Buildverzeichnis. Attribution siehe
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).

## Vertrag

Automatisch gilt die ursprüngliche Mindestlänge zwei, manuell eins, bei bereits
offener Liste ebenfalls eins. Höchstens 200 Treffer werden in der Reihenfolge
Befehl, Projektmethode, geteilte Komponentenmethode, Konstante angezeigt. Die
Original-Befehlsreihenfolge bleibt erhalten; Projekt-/Komponentenindizes liefern
sortierte Namen. Projektmethoden verdecken Komponentenmethoden gleichen Namens.

Die Präfixerkennung bleibt wie Swift an UTF-16-Zellen gebunden: einzelne
Leerzeichen zwischen Wörtern und ein abschließendes Leerzeichen gehören zum
Mehrwortpräfix; $, Punkt, [ und > schließen es an der Grenze aus. Anfangsziffern
und anfänglicher Unterstrich sind keine Befehlspräfixe. Surrogate gelten wie im
Bestand nicht als Namenszeichen. Matching ist kanonisch und case-tolerant, aber
schneidet keine Grapheme an: `i` ist kein Präfix des kleingeschriebenen `İ`.
Kommentar-/Stringgrenzen und Mehrzeilen-Blockkommentare werden vor dem Matching
geprüft. Eine Auswahl sperrt den Anbieter.

Jede Quellansicht besitzt einen nativen GTK-Popover mit Maus-, Pfeil-, Return-,
Tab- und Escape-Bedienung. Escape öffnet bei geschlossener Liste wie im
Mac-Bestand manuell und schließt eine offene Liste. Die Pfeilwahl scrollt den gewählten Eintrag sichtbar;
eine neu aufgebaute Liste beginnt bei der ersten vollständigen Zeile. Sichtbare
Werkzeuge-Menüeinträge öffnen Vorschläge oder aktualisieren den Projektindex,
auch wenn noch kein Projektvorschlag gefunden werden kann. Ctrl+Leertaste ist
ein zusätzlicher Einstieg. Der vollständige Mehrwortpräfix wird in einer
GtkSource-Undo-Gruppe ersetzt. Es gibt keinen direkten Datei-Schreibvorgang.

Der Anbieter ist ausschließlich im Format `fastra-4d` aktiv und prüft Besitzer-
fenster, aktiven Dokumentzeiger, Quellrevision, Cursor, Auswahl, Schreibschutz,
Rich-/Hex-/Nur-Lesezustand, Projektbindung und Indexgeneration erneut vor jeder
Übernahme. Veraltete Completions werden verworfen. Berechnung und Indexarbeiten
laufen auf Workern; schnelle Eingabewechsel brechen frühere Jobs ab. Ein
Index-Refresh sperrt auch zuvor angebotene Projekt-/Komponententreffer.

## Projekt- und Komponentenindex

Dateien werden ausdrücklich per „4D-Projekt-/Komponentenindex aktualisieren“
gelesen, niemals pro Tastendruck. Danach wird ausschließlich im gehaltenen
Snapshot gefiltert. Projektänderungen benötigen eine neue Indexaktualisierung.
Der bisherige Projektquellenleser wird über seine sicheren Lesehelfer wieder-
verwendet, nicht durch eine zweite Indexengine ersetzt.

Die gemeinsame `four_d_components::discover`-Schnittstelle liefert deterministisch
`.4dbase`-Verzeichnisse und `.4DZ`-Archive aus `Components` und `components`.
`discover_with_budget` kann mit einem bereits verbrauchten Discoverybudget
weiterarbeiten; weitere deklarierte Makropfade bleiben beim Makro-Aufrufer.
Die Completiondiscovery bildet den ursprünglichen FourDComponentIndex ab und
interpretiert selbst keine dependencies.json.

Unterstützt werden beide Quellordner `Project/Sources/Methods` und
`Sources/Methods`, gebaute Bundles unter `Contents/*.4DZ` sowie nackte Archive.
Nur echte shared-Attribute bieten Methoden an. Quellarchive haben Vorrang vor
kompilierten Katalogen. Für `methodAttributes.json` können
`Contents/Documentation/Methods` oder `Documentation/Methods` Signaturen liefern;
fehlende Dokumentation erfindet keine Parameter. Bei Komponenten-Kollisionen
gewinnt der alphabetisch erste Komponentenname. Der Katalog ist ein Snapshot;
der Besitzer-/Projektwechsel kann ihn nicht in ein anderes Fenster übertragen.

Grenzen: 4000 Index-/Directoryeinträge, 2000 Methoden je Projekt-/Komponentenliste,
1 MiB pro Quell-/Katalog-/Dokudatei, 16 MiB gelesene Komponentenquellen insgesamt,
64 MiB Archive und 4 MiB aktiver Quelltext. Verzeichnisbudgets werden vor dem
nächsten Iteratorzugriff geprüft; an der exakt erschöpften Grenze wird geschlossen
abgebrochen. Dateien werden mit gehaltenen Deskriptoren ohne Symlinkverfolgung
und mit Identitätsprüfung gelesen. Archive werden ausschließlich gelesen, nie
extrahiert oder ausgeführt. Verschlüsselung, Links, doppelte/unsichere Pfade,
andere Kompression als stored/deflate sowie CRC-/Datenfehler sperren den Index;
es gibt keine unbemerkte Teilübernahme. Ein kleiner Quoten-Preflight prüft alle
lesbaren EOCD-Kandidaten auf höchstens 4000 deklarierte Einträge und 32 MiB
Verzeichnis sowie nicht unterstützte ZIP64-Endverzeichnisse, bevor zip-rs sein
Metadatenverzeichnis allokiert. Mehrdeutige übergroße Endrecords werden ebenfalls
abgelehnt. Ein abbrechbarer Read/Seek-Wrapper begrenzt auch die Parserphase;
ZIP-Parsing, CRC und Dekompression bleiben vollständig in der Bibliothek. Zusätzlich
zählt der Read-Wrapper während `ZipArchive::new` die tatsächliche gesamte
Metadateneingabe einschließlich Suche, Headern, Namen, Extras, Kommentaren und
Fallback-Kandidaten bis höchstens 32 MiB; Seek setzt diese Quote nicht zurück.
Eine gefälschte EOCD-Verzeichnisgröße kann sie nicht umgehen. Erst nach erfolgreich
abgeschlossenem Konstruktor wird diese Quote deaktiviert; die separaten Nutzdaten-
und Eintragsgrenzen bleiben aktiv. 4DZ-Namensbytes werden wie im Mac-Bestand
als UTF-8 gelesen, auch wenn das ZIP-UTF8-Bit fehlt. Ungültige Bytes werden
abgelehnt; es gibt keine stille CP437-/Lossy-Umdeutung.

Der etablierte ZIP-Adapter nutzt `zip = 4.6.1` ohne Standardfeatures und
`flate2 = 1.1.5` mit reinem Rust-Backend. Ein eigener ZIP-Parser wurde bewusst
vermieden. Der Native-Testcontainer besitzt keine libarchive-Runtime. ZIP 9.3.0
würde den bestehenden libc-Pin verändern; 4.6.1 benötigt dagegen nur Rust 1.82
und bleibt mit den bestehenden Pins kompatibel. Es wird keine zusätzliche
System-Runtime oder Interpreterabhängigkeit eingeführt. Die neuen Cargo-Lizenztexte
sind im zentralen Third-Party-Hinweis enthalten.

## Belege

Der Generator `tools/linux-probes/four-d-completion/reference.py` erzeugt fertige
Standalone-Swift-Oracles aus unveränderten Originalquellen. `--kind prefixes`
prüft alle Cursorpositionen der Unicode-/Kommentar-/Stringbeispiele,
`--kind matches` vollständige geordnete Treffer und Signaturen,
`--kind symbols` sämtliche kanonischen Symbolfakten. Mit `--catalog-json` wird
nur ein tatsächlich erzeugter Faktenkatalog als TSV geschrieben.

179 Präfix-/Kontextvektoren und alle Symbolfakten wurden tatsächlich mit Swift
6.2.1/Corelibs-Foundation auf Linux und Swift 6.3.3 auf arm64/macOS 26 ausgeführt;
die Ausgaben stimmen bytegenau überein. 13 vollständige Matchingfälle prüfen
zusätzlich Unicode-Präfixgrenzen, Namenkollisionen, Reihenfolge, Signaturen und
200er-Grenze; auch diese 13 vollständigen Payloads stimmen im tatsächlich
ausgeführten nativen macOS-Lauf bytegenau mit dem Linux-Swift-Lauf überein.
Diese reinen Oracles belegen keine allgemeine macOS-UI-Parität.

Coretests prüfen Originalwerte, Auswahl-/Mindestlängen- und Abbruchverhalten.
Native Indextests prüfen Quellen, Kollisionen, stored/deflate, kompilierte
Kataloge, exportierte Doku, name-only, CRC, Pfadtraversal, Größe, Abbruch und
Symlinks sowie ein bereits verbrauchtes Discoverybudget. Der Native-Test
`FASTRA_4D_COMPLETION_SELFTEST=1` benutzt echte XTest-Klicks und -Tasten für
Autoeingabe, Werkzeuge-Einstieg, Ctrl+Leertaste, Pfeilscrollen, Return/Tab,
Mausübernahme, Escape und genau einen Undo-Schritt. Er prüft außerdem
Kommentar/String/Auswahl, Projekt-/Komponentenvorrang, veralteten Tab/Quellstand,
verstecktes Besitzerfenster, andere Sprache und nicht editierbare Quellansicht.
Deutsch und Englisch bei 760/1280 Pixeln samt Aufnahmen prüfen. Eine echte
Mint-/Wayland-Abnahme bleibt separat offen.
