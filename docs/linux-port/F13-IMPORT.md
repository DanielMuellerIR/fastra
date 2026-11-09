# F13: Rust-Verbraucher des bestehenden PMT-Vertrags

Stand: 2026-11-05. `fastra-import` implementiert auf Linux einen lokalen
Verbraucher des bestehenden Poor-Man's-Text-CLI-Vertrags. Keine Producer-Änderung,
keine neue Protokollversion und keine eigene Format-/Konvertierungsengine.
Vertragsgrundlage: PMT `docs/FASTRA-CONTRACT.md`, Dokumentationsstand 5,
und die vorhandenen Fastra-Module `MarkdownImport`/`MarkdownImportService`.
Die native Linux-Anbindung verlangt eine sichtbare vollständige Vorschau und eine getrennte Zustimmung. Die native Mac-Abnahme bleibt offen.

## Ablauf und Eigentum

`Importer::catalog` fragt `--formats --json` ab. Verfügbarkeit,
Werkzeuganforderungen, Hauptcontainer und zusätzliche Container stammen aus
PMT. Datei und Paket sind getrennte Fähigkeiten; Produktversionen werden nicht
als Protokollversion oder Featureliste interpretiert. Fehlendes Werkzeug bleibt
als kontrollierter Prozessfehler erkennbar. Ein begrenzter Hostcache bindet die Abfrage an die tatsächliche Werkzeugidentität.

`prepare` erhält Quelle, Ziel-Elternordner, `OwnerBinding`, Prozessbudget,
Baumgrenzen und Cancellation. Es legt dort einen eigenen privaten Staging-Ordner
an und startet ausschließlich `--json --output <eigenes-out> -- <quelle>` als
Argumentliste. Nicht-UTF-8-Pfade werden vor dem Start abgewiesen, auch nach der
Kanonisierung. Die Quelldatei oder das Quellpaket wird niemals verschoben oder
überschrieben. Ziel und Zwischenstand liegen auf demselben Dateisystem.

Nur Exit 0 **und** vollständiges `ok:true`-JSON erlauben die nächste Stufe.
Andere Exit-Codes, `ok:false`, defektes/zu großes JSON, Capture-Fehler, Abbruch
oder Timeout geben keine veröffentlichbare Vorschau zurück. Rohes stdout/stderr
und Tool-Fehlermeldungen bleiben verfügbar. Fehlende/null optionale Felder sind
zulässig; unbekannte Ergebnisfelder bleiben in `Conversion::extra` erhalten.
Sammlungen, Warnungen, strukturierte Diagnosen, Quellidentität, Mappings,
Ausgabemanifest, Bericht und Metadaten werden nicht still entfernt.

Zuerst wird die vom Producer angelegte `out`-Wurzel selbst per
`fstatat(AT_SYMLINK_NOFOLLOW)` als echter Ordner bestätigt und mit `openat`
geöffnet. Erst danach werden Inhalte betrachtet. Der gesamte Baum wird
verzeichnisrelativ geprüft: keine Symlinks, FIFOs, Sockets, Gerätedateien,
mehrfach verlinkten regulären Dateien oder Dateisystemwechsel. `O_NOFOLLOW` und
`O_NONBLOCK` verhindern Umleitung und FIFO-Blockaden zwischen Typprüfung und
Öffnen. Die Namen müssen UTF-8 sein. Änderungen beim Kopieren werden an
Identität, Typ, Linkzahl, Größe und Zeitstempeln erkannt.

Der vollständige Baum wird begrenzt und mit SHA-256 in eine eigene, erst nach
Prozessende angelegte Kopie übertragen. Es werden auch nicht in `assets`
aufgeführte Dateien und leere Ordner bewahrt. Jede gemeldete Markdown-/Asset-/
Berichtsdatei und jedes Sammlungsdokument muss als reguläre Datei im geprüften
Baum vorliegen. Gemeldetes `input`/`outputDirectory` darf nicht auf einen anderen
Ort verweisen. Ein vorhandenes Ausgabemanifest wird gegen echte Bytes und
Hashes geprüft. Mappingpositionen werden pro Ausgabedatei einmal begrenzt
geprüft; UTF-8-Bytebereiche müssen auf Scalargrenzen liegen und ohne Überlauf
nach UTF-16 umrechenbar sein. Markdown-Einstieg und Dokumente müssen UTF-8-Text
sein. Angaben zur **Quell**identität bleiben Producer-Angaben; der Verbraucher
behauptet daraus keine selbst verifizierte Quellgleichheit.

`PreparedImport::preview` ist unveränderlich. `adopt` verlangt den aktuellen
Dokumentbezeichner, die Dokumentrevision, das Projekt und die Importgeneration.
Jede Abweichung liefert `StaleOwner`, auch bei sonst unverändertem Ergebnis.
Der Host muss diese Werte auf seiner Besitz-Queue unmittelbar vor Adoption
lesen und den Übergang zum Öffnen serialisieren; ein vom Host veraltet
übergebener Wert kann außerhalb der UI nicht selbst ermittelt werden.

Vor der Veröffentlichung werden Identitäten und der vollständige Hash-/
Verzeichnisbestand der privaten Kopie erneut geprüft. Linux
`renameat2(RENAME_NOREPLACE)` veröffentlicht genau einmal in einen neuen Ordner.
Kollisionen einschließlich vorhandener Symlinks weichen auf `-2`, `-3` … aus;
es gibt keine vorherige „exists, danach überschreiben“-Lücke. Der tatsächlich
gemeldete **relative** Einstieg bleibt erhalten: etwa `result-2/index.md` für
eine Sammlung. `Publication` enthält Ziel, richtigen Öffnungspfad, Owner und
die vollständige Vorschau mit Diagnosen.

Dieses Teilpaket veröffentlicht bewusst immer einen vollständigen Ordner.
Es flacht einen einzelnen Markdown-Text nicht auf `<name>.md` ab und verwirft
keine zusätzlichen Berichte oder unbekannten Dateien. Diese Layoutwahl wird
nicht als schon abgenommener Ersatz für das bestehende Mac-Produkt aktiviert.

Dateien und kopierte Verzeichnisse werden vor dem Rename synchronisiert,
anschließend beide Rename-Eltern. Ein Fehler nach bereits erfolgreichem Rename
liefert `PublishedButNotDurable` **mit dem veröffentlichten Ort**, keine falsche
Behauptung, es sei nichts übernommen worden. Eine Absage nach dem Rename löscht
keinen bereits veröffentlichten Ordner. Bei Fehlern davor fällt nur eigenes
Staging weg. Wurde dessen Wurzel durch einen fremden Ordner ersetzt, wird dieser
bewusst nicht rekursiv bereinigt; die kontrollierte Nichtbereinigung ist sicherer
als das Löschen fremder Inhalte.

## Gemeinsamer Prozessbesitz und Grenzen

`fastra-process` enthält den aus F11 herausgelösten Prozessbesitz. Git behält
seine öffentliche API und reicht seine bereinigte Umgebung ausdrücklich an den
gemeinsamen Runner weiter. PMT nutzt denselben Besitz-, Abbruch-, Timeout- und
Capture-Pfad. Es gibt keine Shell oder UI-Callbacks. Der direkte Gruppenleiter
bleibt bis zum letzten Gruppensignal unreaped, damit keine wiederverwendete
Prozessgruppen-ID getroffen werden kann. Siehe [F11](F11-GIT.md).

Gepinnt sind `libc 0.2.176`, `tempfile 3.23.0`, `sha2 0.10.9` sowie die vorhandenen
Serde-Versionen. Standardgrenzen: 4 MiB JSON, 10.000 Einträge, Tiefe 32,
4.096 Pfadbytes, 128 MiB je Datei, 32 MiB je Markdown-Datei und 512 MiB Gesamtbaum.
Der Aufrufer darf diese Grenzen reduzieren. Binärassets werden gestreamt,
Markdown nur begrenzt für Text-/Mappingprüfung geladen. Prozesslaufzeit und
Gesamtdauer inklusive Kopie/fsync sind unterschiedliche Budgets; Cancellation
gilt auch während der Übernahmeprüfung.

Prozessgruppen sind keine Sandbox gegen beliebigen aktiven Code derselben UID.
Ein absichtlich aus der Gruppe ausgebrochener Producer-Nachkomme oder ein anderer
Prozess desselben Benutzers kann nicht über bloß gemerkte PIDs verfolgt werden.
Der Ansatz prüft fehlerhafte/bösartige Ergebnisbäume und arbeitet in privatem
Staging, behauptet aber keine Isolation gegen sämtliche gleichberechtigten
Angreifer. Fsync-Erfolg ist kein Stromausfalltest; Netzdateisysteme und
Wechseldatenträger sind damit nicht freigegeben.

## Ausgeführte Prüfung

**17 Importtests**, **9 Git-Tests** und **8 gemeinsame Prozessprüfungen** bestanden;
Clippy mit `-D warnings` ist grün. Alle Quellen, Bäume und lokalen Remotes der
Tests sind eigene temporäre Fixtures. Die echten Mac-Producer-Fixtures
`producer-catalog.json` und `producer-mbox.json` stammen aus PMTs P01-Goldens
(Producer-Quellreferenz `17328f17`; dort ist die Binary-Zuordnung ausdrücklich
eingeschränkt). Sie prüfen den vorhandenen JSON-Vertrag, keine neue Mac-Abnahme.

Getestet sind vollständige Sammlung trotz `assets:[]`, relative Assets nach
Kollisionssuffix und frischem Öffnen in einem unabhängigen Prozess, sämtliche
Owner-Achsen, parallele No-Replace-Adoptionen, veränderte private Kopie,
ersetztes Staging/Ziel, Symlink-Wurzel/-Mitglieder, Hardlinks, FIFO/Socket,
Nicht-UTF-8-Namen, fremde/fehlende Berichtspfade, Hashabweichung, ungültige
Mappinggrenzen, JSON-/Exit-/Ausgabelimits, Größen-/Tiefen-/Eintragsgrenzen,
Abbruch vor Adoption sowie Timeout/Abbruch mit TERM-resistenten Nachkommen.
Fremde Marker und bestehende Kollisionen bleiben bytegleich erhalten.

Zusätzlich wurde die **reale lokale Linux-Kombination** isoliert ohne Netzwerk
geprüft: PMT 0.41.8 meldet 29 Formate; eine frische CSV ergibt eine Datei/ein
Dokument mit `table.md`, eine frische MBOX ergibt drei Dateien/zwei Dokumente
mit `index.md`. Beide Übernahmen sind nach Abschluss lesbar; Quellbytes bleiben
unverändert. Producer und zugehöriger Prozesswächter wurden unverändert in den
Testbereich kopiert, keine Producer-Dateien bearbeitet. Binary-Identität:

- CLI SHA-256: `9c3daae11aebaafe4ae955ff1cb7e4e565c4ca9573c5a7dd1f7da8f026bdef94`.
- Prozesswächter SHA-256: `94d8a506595bc1581f98ec4e588215cf25858789cf95f7071af966f95bc332fb`.

Die Zuordnung dieser vorhandenen Binaries zu einem bestimmten Source-Commit
wurde nicht neu behauptet. Der erste MBOX-Versuch ohne den benötigten Wächter
lieferte kontrolliert Exit 69; mit dem zugehörigen Helfer bestand der Lauf.
Reproduktion auf einem Host mit passendem lokalen PMT-CLI und dessen Runtime:

```sh
cargo test --locked -p fastra-import -p fastra-git -p fastra-process
cargo clippy --locked -p fastra-import -p fastra-git -p fastra-process --all-targets -- -D warnings
cargo run --locked -p fastra-import --example check_cli -- /absolute/path/to/poormans-text
```

## Aktueller Hostumfang und offene Abnahme

Die native Öffnungsintegration, Katalogcache, Live-Fortschritt und lokalisierte
Diagnosen sind umgesetzt. Datei- und Paketangebote verwenden ausschließlich
PMTs Formatkatalog. Der Nutzer kann ausdrücklich die Originalquelle oder einen
nativen Ordner öffnen. Ein Aufruf installiert oder startet keine Konvertierung
ohne diese Wahl. Einzelheiten und die Abbruchgrenze stehen im
[Hostvertrag](F13-HOST.md).

Frühere CLI-Proben oben sind historische Belege ihrer angegebenen Binaries.
Die aktuelle Paarung verwendet den unveränderlichen Producer 0.41.19 aus
Quellcommit `e2f0b8866aa3acc9b9dd8bf474ffd11d031f4adb`; der portable Einstieg
und die tatsächliche RTF-Übernahme sind in [F13-HOST](F13-HOST.md) beschrieben. Weitere Producer-Versionen
werden erst nach eigener Artefaktbindung gewertet. Backendqualität von PDF,
Tabellen und OCR bleibt PMTs eigene Produktabnahme; eine freigegebene
Importschnittstelle bescheinigt diese Qualität nicht. Native Mac-Bundle- und
App-zu-App-Prüfungen bleiben ein gesondertes Gate.

## Nativer Linux-Host

Ein modales GTK-Werkzeugfenster bietet lokale Werkzeug-, Quellen- und Zielwahl,
den vollständigen Formatkatalog, Vorbereitung, vollständigen Dateibaum samt
Dokumenteinstiegen und den gebundenen Markdown-Inhalten, Warnungen und ungekürzten Diagnosen sowie eine getrennte
Schaltfläche „Übernehmen / Adopt“. Ein Spinner kennzeichnet laufende Arbeit;
Abbruch beendet den eigenen Prozessbaum. Es wird kein Werkzeug installiert.

Die Vorbereitung bindet Dokumentidentität, Revision, Projekt und Generation.
Adoption prüft den tatsächlichen Besitzer erneut; das anschließende asynchrone
Öffnen prüft denselben Besitzer unmittelbar vor dem Hinzufügen des Tabs.
Schreibgeschützte Abschnitts-/Hex-Dokumente werden abgewiesen. Das Fenster bleibt
während der Veröffentlichung modal; die Quelle wird nicht beschrieben.

Hostgrenzen: 500 Einträge, 64 MiB Gesamtdateien, 32 MiB pro Datei, 4 MiB Markdown,
1 MiB Protokoll-JSON und 2 MiB vollständiger Vorschautext. Ein überschrittenes
Limit verhindert eine unvollständige Vorschau. Der Host zeigt den bestehenden Produzentenfortschritt; jede Konvertierung und Übernahme bleibt ausdrücklich gewählt.

Private GTK-Läufe prüften DE/EN bei 640/1080 Pixeln: Katalog, Vorschau ohne
Veröffentlichung, verweigerte Adoption nach echter Dokumentrevision, erneute
Vorbereitung, bewusste Gesamtübernahme und Öffnen des richtigen Einstiegs. Alle
Sammlungsdokumente blieben vorhanden; die Quelle blieb bytegleich. Zusätzlich
bestand derselbe Hostablauf mit PMT 0.41.8 und einer synthetischen MBOX mit zwei
Nachrichten. Der native Mac-Bundle-Nachweis bleibt ein eigener Abnahmeschritt.

Die vollständigen Vorschautexte bleiben im versiegelten Importzustand gebunden.
Sie besitzen ein gemeinsames Backendbudget von 32 MiB. Die GTK-Anzeige weist
mehr als 2 MiB vollständigen Vorschautext, Zeilen über 16 KiB und U+0000 ab;
dann bleibt Übernehmen gesperrt. Eine zusätzliche Regression prüft das gemeinsame
Textbudget, der echte Fensterlauf prüft alle gebundenen Dokumenttexte vor Adoption.
