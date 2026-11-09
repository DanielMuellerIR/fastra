# Ordnersuche und freigegebene Dateitransaktion

`fastra-search` baut eine unveränderliche Trefferbasis mit dem gemeinsamen
ICU-Suchkern. `PreparedSearch` kompiliert das Muster einmal und klont einen
begrenzten Matcher je Datei. Literal-, Wildcard-, Regex-, Ganzwort- und
Capture-Ersetzungen folgen demselben Kern wie die Einzeldokumentsuche.

Die Suche folgt keinen Verzeichnis- oder Dateisymlinks. Explizit gewählte
Wurzelpfade werden einmal kanonisiert. Rohpfade bleiben Dateischlüssel;
nicht als Unicode darstellbare Dateinamen werden ohne aktive Ausschlussmuster
verlustfrei durchsucht und geändert. Bei aktiven Unicode-Globfiltern werden
solche Pfade mit sichtbarem Hinweis ausgelassen, statt sie verlustbehaftet zu
vergleichen.
Überlappende Wurzeln erzeugen keine doppelten Dateieingaben. Verzeichnisse
werden über gehaltene Deskriptoren gelesen und mit Identität sowie Änderungs-
und Statuszeit erneut geprüft. Versteckte Komponenten werden standardmäßig
ausgelassen. `.gitignore` ist kein stiller zusätzlicher Filter.

Ausschlüsse übernehmen die kleine Mac-Globsyntax: `*` und `?` bleiben innerhalb
einer Pfadkomponente, `**` reicht über Slash. Ein Muster mit Slash prüft den
wurzelrelativen Pfad, sonst jede Komponente. `.json` bedeutet `*.json`.
Muster und Kandidaten werden für den Vergleich NFC-normalisiert. Der optionale
Filter bekannter Textendungen entspricht der Mac-Liste; die Oberfläche aktiviert
ihn standardmäßig.

Jede tatsächlich durchsuchte Textdatei bleibt samt Snapshot gebunden, auch
wenn sie keinen Treffer enthält. Apply nimmt ausschließlich die expliziten,
aufsteigend sortierten Trefferindizes dieser Vorschau an. Es führt keine neue
Suche aus. Vor dem Schreiben prüft es die Verzeichnisbasis und übergibt alle
gebundenen Dateieingaben an `fastra-io`; dessen letzter Preflight umfasst auch
abgewählte und wirkungslose Ersetzungen. Kodierung, BOM und vorhandene
Zeilenenden bleiben erhalten. Nicht darstellbare Ersetzungen brechen ab.

Die erste GTK-Ordneransicht zeigt vollständigen Vorher-/Nachher-Text je
Trefferdatei sowie eine Freigabe pro Treffer. Während Apply und Undo sind
Suchparameter und Trefferfreigaben gesperrt. Ungesicherte Änderungen an
betroffenen offenen Dokumenten verhindern Apply. Erfolgreiche Schreibvorgänge
aktualisieren saubere geöffnete Dokumente ausschließlich aus den durch die
Transaktion bestätigten Snapshots. Datei-Undo ist eine eigene sichtbare Aktion;
Sicherungsjournale bleiben für die Wiederaufnahme auf der Platte erhalten.

## Sprünge aus der Trefferliste

Trefferklicks und Trefferwechsel verwenden die Identität der sichtbaren
Vorschau, niemals den angezeigten Dateinamen. Quellmarkierungen und Scrollen
ändern weder die Auswahl noch Text, Änderungsstatus oder Undo. Das bewahrt
insbesondere die Grundlage einer Suche innerhalb der Auswahl. Neue Suchdaten
räumen alte Hervorhebungen synchron ab. Gezeichnet werden bis zu 2.000 Treffer
und zusätzlich der aktive Treffer; für leere Treffer zeichnet die gebundene
Quellansicht eine eigene sichtbare Einfügemarke.

Für offene Tabs bleiben Dokumentidentität und Revision maßgeblich. Dateien aus
Ordnern und Projekten werden erst beim ausdrücklichen Sprung geöffnet. Der
Worker liest höchstens 4 MiB, prüft die exakte ursprüngliche Snapshot-Bindung
und vergleicht den vollständig dekodierten Text mit der Vorschau. Eine
Projektbindung wird vor und nach dem Lesen geprüft. Die Oberfläche übernimmt
nur bei unveränderten Suchdaten und aktiver zugehöriger Fenstergruppe.
Passende offene Quellen werden wiederverwendet; abweichende oder gesperrte
Puffer bleiben erhalten. Es findet keine Formatumwandlung auf dem Suchsprung
statt: Gezeigt wird der tatsächlich durchsuchte Text.

`linux/test.sh search-navigation` prüft reale Knöpfe und Pfeiltasten, UTF-16,
CRLF, Scrollen, Null-Längen-Markierung und unveränderte Auswahl/Vorschau/Undo.
`linux/test.sh collection-navigation` prüft gleiche Tabnamen, Dateien ohne
Treffer vor den sichtbaren Dateien, Wiederverwendung, ungesicherte Puffer,
externe Dateiänderung sowie tatsächlich zugestellte verspätete Antworten nach
Suchänderung und unabhängigem Fensterfokus. Beide benötigen eine isolierte
oder freigegebene grafische Sitzung; modale Abläufe werden mit Fenstermanager
geprüft.

## Grenzen und Prüfumfang

Die erste Umsetzung begrenzt Textdateien auf 4 MiB und logische Zeilen auf
64 KiB. Binärdaten, unpassende Metadaten und größere Eingaben erscheinen als
übersprungene Dateien. Obergrenzen sind 10.000 Treffer, 10.000 gebundene Dateien,
10.000 Verzeichnisse, 100.000 Verzeichniseinträge, Tiefe 128, 30 Sekunden sowie
128 MiB gespeicherte Quell-, Snapshot-, Capture- und Ersetzungstexte. Ein
überschrittenes Gesamtlimit liefert einen Fehler und keine teilweise anwendbare
Vorschau. Der reguläre Transaktionsadapter akzeptiert ausschließlich ext4/Btrfs
auf einem gemeinsamen Dateisystem; siehe [Dateitransaktionen](F03-TRANSACTIONS.md).

Neun Backendtests prüfen selektive Ersetzung und Undo über Verzeichnisgrenzen,
UTF-8-/UTF-16-BOM und CRLF, externe Änderungen auch in nichttreffenden oder
abgewählten Dateien, veränderte Verzeichnisse, Generationen, Freigabereihenfolge,
NFC-Globs, überlappende Wurzeln, Symlinks/FIFO/Binärdaten, Abbruch, Treffer- und
Speicherlimits. Der Fenstertest ist separat über `FASTRA_FOLDER_SELFTEST=1`
mit eigenem Display, `FASTRA_ISOLATED_DISPLAY=1` und `FASTRA_UI_TEST_ROOT`
ausführbar. Er bestand den vollständigen Apply-/Undo-Pfad samt unveränderter
BOM und offenem Editor sowie die Stale-Abweisung. Die tatsächlichen Ansichten
wurden in DE/EN jeweils bei 760 und 1100 Pixeln aufgenommen und geprüft.

Der [Bereich Alle Tabs](F06-TABS.md) und der
[beobachtete Projektbaum](F10-PROJECT-WATCH.md) besitzen eigene Verträge.
Mehrere Wurzeln in der Suchoberfläche und die endgültige Desktopabnahme bleiben
weitere Portierungsarbeit; die [Roadmap](../../ROADMAP.md) hält offene Parität fest. Deskriptorprüfungen ersetzen keine
Isolation gegen einen absichtlich angreifenden Prozess unter derselben UID.
