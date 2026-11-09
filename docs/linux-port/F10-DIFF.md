# F10: Datei- und Ordnervergleich

Stand: 2026-11-08. `crates/fastra-diff` enthält den reinen Textvergleich,
gebundene Blockübernahme und den lesenden Linux-Ordnervergleich. Der native
Linux-Host bindet diese Rechnung an Dokumente, Vorschauen und Editor-Undo.
Die bestehenden Mac-Produktpfade bleiben eigenständig.

## Algorithmus und Abhängigkeiten

Der Kern portiert den vorhandenen Fastra-Algorithmus aus `MyersDiff.swift` und
`PatienceDiff.swift`: lineare Suchvektoren, dieselbe Suchrichtung und
Gleichstandsentscheidung, gemeinsame Ränder und bei großen Bereichen eindeutige
Zeilenanker mit längster aufsteigender Teilfolge. Es gibt keine quadratische
LCS-Matrix. Ein gemeinsames Arbeitsbudget und Cancellation gelten auch innerhalb
der Vorwärts-/Rückwärtssuche und des Anchor-Aufbaus; bei Überschreitung entsteht
kein teilweise erfolgreiches Ergebnis.

Geprüfte Alternativen sind die offiziellen APIs von
[similar](https://docs.rs/similar/latest/similar/algorithms/index.html) und
[imara-diff](https://docs.rs/imara-diff/latest/imara_diff/). Deren dokumentierte
Heuristiken beziehungsweise Deadline-Fallbacks belegen nicht die vorhandene
Fastra-Blockzuordnung. Deshalb wird keine austauschbare Hunk-Gleichheit behauptet
und keine dieser Diff-Abhängigkeiten eingeführt. Der bereits vorhandene
abbrechbare Algorithmus wird mit konkreten Originalreferenzen weitergeführt.

Neu hinzu kommt ausschließlich die eigentliche NFC-Abhängigkeit
[`unicode-normalization = 0.1.25`](https://github.com/unicode-rs/unicode-normalization),
mit Unicode-17.0.0-Tabellen und im Lockfile gebundenem `tinyvec`. `sha2 0.10.9` und
`libc 0.2.176` sind die schon verwendeten Workspace-Versionen. NFC dient nur
Vergleichsschlüsseln: Originalbytes werden nie normalisiert. Case-Ignore benutzt
pro Scalar die volle Kleinschreibung wie die geprüfte Swift-Referenz. Der
kontextabhängige Sigma-Sonderfall von Rusts `str::to_lowercase` wäre hier falsch:
Die Referenz hält `ΟΣ` und `ος` auch mit Ignore-Case auseinander. Dies ist
bewusst getrennt von der ausdrücklich als Root-Casing benannten F09-Operation.
Eine vollständige Gleichheit sämtlicher Unicode-Tabellenversionen auf dem Mac
wird aus den geprüften Fällen nicht abgeleitet.

## Vergleich und Übernahmevertrag

`Comparison::compare` übernimmt zwei `TextSnapshot`s mit Dokumentkennung,
Revision und Text, dazu Vergleichsgeneration, Optionen, Grenzen und Cancellation.
Das Ergebnis ist unveränderlich. Die Optionen decken nachgestellten/gesamten
Whitespace, Leerzeilen und Groß-/Kleinschreibung ab. Ignorierte Leerzeilen bleiben
als unveränderte Zeilen sichtbar; nur die Vergleichsteilnahme entfällt.

Zeilen tragen bytegenaue Inhalts-/Terminatorbereiche und vorab berechnete
UTF-16-Grenzen. LF, CR, CRLF, NEL sowie Unicode-Line-/Paragraph-Separator werden
erkannt; CRLF bleibt ein Terminator. Ein letzter Terminator erzeugt wie im
Swift-Kern eine virtuelle Endleerzeile. Ausgerichtete Zeilen besitzen
1-basierte Nummern; Blöcke nennen einen halboffenen Bereich von Anzeigezeilen.

Wie im bestehenden logischen Vergleich erzeugt CRLF statt LF allein keinen
Inhaltsblock. Das neue Ergebnis verschweigt diesen Byteunterschied nicht:
`byte_identical` und `Row::terminators_differ` halten ihn ausdrücklich fest.
Auch kanonisch gleiche, byteverschiedene Unicode-Eingaben bleiben dadurch
unterscheidbar. Die Übernahme benutzt ausschließlich Originalbereiche und
Terminatoren der ausgewählten Quelle; unberührte Zielbytes bleiben erhalten.

`prepare_transfer` bindet **beide** Dokumentkennungen, Revisionen und Texte sowie
die Vergleichsgeneration. Block-IDs müssen gültig und streng aufsteigend sein.
Leere Freigabe, doppelte/umgeordnete IDs, ungültige Grenzen oder überlappende
Rohbereiche werden abgewiesen. EOF-Ergänzungen/-Löschungen einschließlich einer
fehlenden Verbindung nach einer unterminierten Zeile folgen dem Swift-Vertrag.

Der unveränderliche `TransferPlan` enthält den sichtbaren vollständigen Zieltext
und die einzelnen Byte-/UTF-16-Ersetzungen. `apply` prüft beide Quellen und die
Generation erneut und liefert **einen** neuen Text für einen gemeinsamen
Host-Undo. Es schreibt weder Quellen noch Ziele. Der Host muss den aktuellen
Zustand auf seiner Besitz-Queue liefern und den UI-Übergang serialisieren;
Datei-Snapshots, Encoding, Speichern und Undo-Verwaltung bleiben Host-Aufgaben.
Viele ausgewählte Blöcke verwenden bereits berechnete UTF-16-Grenzen statt
wiederholter Scans ab Dateianfang.

`report` liefert einen begrenzten Textbericht der fertigen Vergleichsbasis mit
escaped Labels, Optionen, Blockzeilen und expliziten Terminatorunterschieden.
Er schreibt keine Datei und ist ausdrücklich **kein Unified-Patchformat**.

## Grenzen

Die Standardobergrenzen sind 32 MiB je Text und Transferausgabe, 200.000 logische
Zeilen je Seite, 30.000 Zeilen je nicht verankertem Myers-Bereich, 50 Millionen
Arbeitseinheiten, 512 MiB konservativ geschätztes Arbeitsmaterial und 64 MiB
Bericht. Der Aufrufer darf diese Werte nur reduzieren. Gekoppelte Grenzen können
eine Eingabe schon vor einer einzelnen nominellen Maximalgröße abweisen. Die
Speicherprüfung schätzt die dominanten Texte, Schlüssel, Maps, Suchvektoren,
Zeilen und Blöcke vor der Suche; sie ist keine Behauptung eines gemessenen
RSS-Limits des Allocators. Es gibt keine still gekappten Rows oder Blöcke.

NFC kann einen langen Lauf kombinierender Zeichen intern sortieren, bevor der
nächste Iteratorwert zurückkehrt. Deshalb wird vor diesem Bibliotheksschritt
der kanonisch dekomponierte Nichtstarter-Lauf auf 4.096 Zeichen begrenzt. Auch
diese Grenze liefert einen erklärten Fehler statt veränderter Unicode-Daten.

## Lesender Linux-Ordnervergleich

`compare_folders` ordnet Einträge über rohe relative Pfadbytes zu. Kanonisch
gleiche Dateinamen und Nicht-UTF-8-Namen bleiben unterscheidbar. Verzeichnisse
werden über eigene Handles und `openat(O_NOFOLLOW | O_NONBLOCK)` durchlaufen;
Symlinks und Spezialdateien bleiben sichtbar nicht prüfbar. Inhalte werden mit
SHA-256 gestreamt; NUL oder ungültiges UTF-8 kennzeichnen binäre/nicht als
UTF-8-Text nutzbare Paare, ohne sie als Zeilendiff auszugeben. UTF-8-Erkennung
funktioniert über Chunkgrenzen hinweg.

Ergebnisse unterscheiden nur links/rechts, identisch, verschieden und nicht
prüfbar. Ein Gegenstück unter einem nicht prüfbaren Vorfahren gilt nicht sicher
als fehlend. Verzeichnisstatus wird aus Nachfahren in O(Einträge × Tiefe)
fortgeschrieben, auch bei lexikalisch dazwischenliegenden Namen wie `a!` und
`a/child`. Identität, Modus, Größe, mtime und ctime aller Quellen sowie die
Wurzeln werden abschließend erneut geprüft. Ein ausgetauschtes Wurzelverzeichnis
entwertet sämtliche betroffenen Paarbehauptungen; geänderte Struktur erlaubt
keine sicher fehlenden Einträge. Das ist eine lesende Momentaufnahme, keine
Dateisperre oder Freigabe für spätere Schreibaktionen.

Standard: 20.000 Einträge und 100.000 besuchte Einträge für den gemeinsamen
Auftrag, Tiefe 64, 4.096 Pfadbytes, 256 MiB je Datei, 2 GiB Gesamtlesebudget und
128 MiB geschätzte Eintragsdaten. Versteckte Einträge sind standardmäßig
entsprechend dem Mac-Vergleich ausgenommen, können aber explizit eingeschlossen
werden. Harte Budgetüberschreitung liefert eine Grenze ohne Teilerfolg;
Einzelfehler bleiben als nicht prüfbare Zeilen sichtbar. Kein eigener Filter-
oder Schreibpfad wird eingeführt.

## Ausgeführte Belege

**20 Rust-Tests bestanden**: elf für Textvergleich, Plan und Bericht, acht für
Ordnerprüfung sowie ein deterministischer Abbruchtest direkt innerhalb der
bereits betretenen Myers-Suche. Clippy mit `-D warnings` und Formatprüfung sind
grün. Sämtliche Dateien/Ordner sind neu erzeugte temporäre Fixtures.

**252 echte Swift-Referenzvergleiche** aus den unveränderten Modulen prüfen
Zeilenpaarung, Blockart/-bereich und jeden wirksamen Einzelblock in beiden
Übernahmerichtungen: Ausgabebytes, Ersetzungsbytes und UTF-16-Bereich. Enthalten
sind 200 deterministisch erzeugte Wiederholungsfolgen, alle Optionen, kanonische
Unicode-Fälle, leere Eingaben und EOF-Verbindungen über sechs Terminatorformen.
Zwei weitere echte Swift-Zusammenfassungen mit **je 40.000 Zeilen** prüfen den
Patience-Pfad für verteilte Änderungen und eine Rotation von 20.000 Zeilen.
Die kleine Zusammenfassung bewahrt Rows-/Zeilenzahlen und sämtliche Blockgrenzen;
sie behauptet keine vollständige Intraline-Abnahme dieser großen Fälle.

Die Originalmodule liefen mit Swift 6.2.1/Foundation im isolierten Linux-Container.
Nur unbenutzte UI-/Quelltypen und Intraline-Highlighting wurden für den
Referenztreiber gestubbt; verglichene Rows/Blöcke/Übernahmen stammen aus dem
Originalcode. Das ist keine native Mac-Abnahme. Reproduktion der JSON-Goldens:

```sh
swiftc -parse-as-library app/Sources/Fastra/FileDiff.swift \
  app/Sources/Fastra/FileDiffLineMap.swift app/Sources/Fastra/MyersDiff.swift \
  app/Sources/Fastra/PatienceDiff.swift app/Sources/Fastra/FileDiffTransfer.swift \
  crates/fastra-diff/tests/fixtures/reference.swift -o /tmp/fastra-diff-reference
/tmp/fastra-diff-reference
/tmp/fastra-diff-reference --large
cargo test --locked -p fastra-diff
cargo clippy --locked -p fastra-diff --all-targets -- -D warnings
```

Weitere Tests belegen 2.000 gemeinsam übernommene Blöcke mit Emoji, unveränderte
Außenbytes, jede Stale-Achse, Quellwechsel zwischen Read und Validierung,
Wurzelaustausch, Binärdateien, fehlende Einträge, Symlinks/FIFOs, raw Pfadnamen,
UTF-8-Chunkgrenzen und die konkreten Rechen-/Speicher-/Ausgabegrenzen.

## Noch offen

F10 ist begonnen, nicht als gesamte Produktfunktionsgruppe abgeschlossen.
Ordner-Filter/Progress, Übersichtsleiste, gemeinsame Scrollfläche, Tabpaar-Vorwahl,
direkter Vergleich mit der gespeicherten
Fassung und der globale Vergleichskurzbefehl bleiben offen.
Der externe Vergleichshelfer hat weiterhin seine bisherige Darstellung. UniFFI
und die gemeinsame native Mac-Bundle-Abnahme bleiben ebenfalls offen. Der unten beschriebene
GTK-Host ergänzt Vorschau, Editor-Undo und Dateiquell-/Encoding-Anbindung. Unified-Patch-Ausgabe ist
nicht exponiert, weil logische Vergleichsoptionen allein keine bytegenaue
Patchbasis garantieren.

Der bestehende externe Helfervertrag wurde gelesen: Version 1, strikte
Wire-Feldmenge, Deadline und idempotente Zustellung über den lokalen Mach-Port.
Die [Linux-Anbindung](../EXTERNAL-DIFF.md#linux) ergänzt ab 1.182.0 den vorhandenen
Aufrufvertrag über den lokalen Sitzungs-D-Bus. Sie verwendet getrennte readonly
Fenster ohne Editor-/Save-/Projekt- oder Sitzungsanbindung. UUID-Identität, Deadline,
Kaltstart und tatsächliche readonly Ansichten werden nativ geprüft.

## Nativer Linux-Host ab 1.209.0

Der kompakte modale Quelldialog folgt der Mac-Aufteilung: zwei Felder mit
Dateiauswahl, offenen Tabs, zuletzt geöffneten Dateien und vier persistenten
Ignore-Optionen. Der aktive editierbare Tab ist links vorbelegt. Dateiquellen
werden über den Dokumentcodec geladen; Abschnitte, Hex und schreibgeschützte
Dokumente sind keine übernehmbaren Ziele. Die Optionen werden über den
versionierten Store mit feldweisen, gegen den aktuellen Stand geprüften
Änderungen gespeichert. Unbekannte Store-Versionen werden nicht überschrieben.

Das Ergebnis liegt in einem eigenen schreibgeschützten Tab mit zwei
GtkSourceViews. Die Darstellung enthält ausgerichtete echte Zeilennummern,
Graphem-Intraline-Markierungen, eine virtuelle Differenzenliste und gemeinsame
Navigation. Unveränderte Bereiche lassen drei angrenzende Kontextzeilen sichtbar;
ab fünf weiteren Zeilen erhalten sie eine aufklappbare Steuerzeile. Verborgene
Zeilen, künstliche Ausrichtungsleerstellen und Steuerzeilen gehören nicht zur
Kopierausgabe. Soft Wrap wirkt auf beide Spalten; unterschiedliche Umbruchhöhen
werden über Zeilenabstände ausgeglichen. Text, Markierungen und Listen werden
in begrenzten Main-Loop-Schritten aufgebaut, die Rechnung selbst auf Workern.

Die Übernahme arbeitet in beiden Richtungen ausschließlich in ein ausdrücklich
als Quelle gewähltes offenes Dokument. Ein Dateipfad wird niemals nachträglich
an einen gleichnamigen Tab gebunden. Dokumentidentität, Revision, Pfad und
Mitgliedschaft bleiben bis zum Apply gebunden. Dateien werden vor Vorschau und
Übernahme erneut vollständig verifiziert; gleicher Umfang und zurückgesetzte
mtime reichen nicht als unveränderter Nachweis. Die vollständige Vorschau
kennzeichnet exakte Unicode- und Terminatorunterschiede. Diese Erläuterungen
werden nicht in den Zieltext eingefügt. Quelltext besitzt eine native Undo-Aktion;
Rich behält seine WebView, seinen Modus und die native Undo-/Redo-Historie.
Eine begrenzte Kontextablage erhält auch unsichtbare Referenzdefinitionen und
Bildidentitäten über Rich-Undo. Ein Fehler übernimmt keinen abweichenden Text.
Abbrechen während der Vorbereitung erhält den fertigen Vergleich.

Der Bericht exportiert die beim Öffnen des nativen Speicherdialogs abgeschlossene
Vergleichsbasis vollständig als lokalisierten UTF-8-Text. Vor und unmittelbar
vor der atomaren Übernahme der Berichtsdatei werden Quellen, aufgelöste
Symlink-Pfade und Geräte-/Inode-Aliase als Ziel abgewiesen. Der Bericht ist kein
Unified Patch. Die Auswahl einer normalen Datei als Vergleichsquelle ist keine
Schreibfreigabe für diese Datei.

Die Ansicht verwendet die Kernbudgets von 32 MiB und 200.000 logischen Zeilen
je Seite statt der früheren Hostgrenzen von 4 MiB und 5.000 Zeilen. Zusätzliche
Rechen- und Speicherbudgets bleiben wirksam. Für ein Übernahmeziel gelten
weiterhin dessen eigene Grenzen: native Quellzeilen bis 64 KiB, Rich bis 2 MiB
und 10.000 Blöcke; die begrenzte Rich-Kontext- und Bildablage meldet einen Fehler
statt alte Undo-Daten still zu verwerfen. Die Grenzen des
[externen Vergleichshelfers](../EXTERNAL-DIFF.md#linux) bleiben separat beschrieben.

Der [native Ordnervergleich](F10-FOLDER-COMPARE.md) verwendet beim Öffnen
eines Textpaars dieselbe schreibgeschützte Ergebnisansicht.

### Spaltenteilung und Tastatur ab 1.210.0

Die Teilung gilt gemeinsam für Ergebnis-Tabs und Übernahmevorschauen. Sie bleibt
bei Größenwechseln proportional und begrenzt jede Seite auf mindestens 96 Pixel.
Ein neun Pixel breiter Griff verarbeitet Mausbewegungen; Doppelklick
setzt die Halbierung zurück. GTKs ursprüngliche Capture-Draggesten sind für
diesen Griff deaktiviert, bleiben wegen interner Referenzen aber angehängt.
Die native Tastatur- und AccessibleRange-Anbindung bleibt bestehen. F8 fokussiert
den Trenner, Pfeiltasten ändern den sichtbaren Anteil um fünf Prozentpunkte,
Pos1 setzt ihn zurück. Die physische Screenreader-Abnahme bleibt separat offen.

Der Anteil wird in Hundertstelprozent in Version 2 der Vergleichsablage
gespeichert. Version 1 wird beim Lesen ohne Änderung ihrer Bytes übernommen und
bei der nächsten tatsächlichen Speicherung aktualisiert. Feldweise CAS-Änderungen
erhalten Ignore-Optionen und rohe Dateipfade. Die GUI bindet Rückmeldungen an
die aktuelle Teilungsrevision; eine noch laufende ältere Leseantwort darf eine
frische Bewegung nicht zurücksetzen. Unbekannte Versionen bleiben erhalten.

Alt+↑/↓ bewegt die Auswahl mit Umlauf und scrollt sowohl die echten Quellspalten
als auch die virtuelle Differenzenliste. Der Fokus bleibt beim bisherigen
Bedienelement. Der Umbruch verwendet das eigene Profil `file-comparison`,
unabhängig von normalen Textdokumenten. Ohne Umbruch bleibt die native
Textfläche in der Spaltenbreite; ihre horizontale Scrollleiste ist ausgeblendet.

### Export nach Quellenumbenennung ab 1.211.0

Der Export erfasst zusätzlich zu den Quellpfaden die Dateiidentitäten der fertigen Vergleichsbasis. Dateiquellen liefern sie aus ihrem offenen Lesedokument, Speicherquellen aus dem beim Vergleich erfassten Snapshot. Der aktuelle Dokument-Snapshot ergänzt den Schutz nach einem Speichern unter neuem Namen. Vor dem Schreiben und unmittelbar vor dem atomaren Ersetzen werden Zielidentität und erreichbare Quellpfade erneut geprüft. Umbenannte Quellen und deren Aliase bleiben gesperrt; ein fehlender alter Quellordner verhindert kein unabhängiges Berichtsziel. Andere Auflösungs- und Lesefehler bleiben sichtbar.

### Gemeinsame Scrollfläche und Übersicht ab 1.212.0

Ergebnis und Übernahmevorschau verwenden eine gemeinsame horizontale Scrollfläche mit mindestens 919 Pixel Inhaltsbreite. Die Teilung gehört zum gescrollten Inhalt. Beide nativen Quellspalten behalten ihre synchronen vertikalen Anpassungen, zeigen aber ausschließlich eine gemeinsame externe vertikale Scrollleiste. Rechts steht die 20 Pixel breite Übersicht mit denselben Sampling-Regeln wie auf dem Mac: höchstens 160 Markierungen, Randpunkte bleiben bei regulärem Sampling erhalten und der aktuelle Unterschied ersetzt nötigenfalls den nächsten inneren Punkt. Bestehende Marker werden wiederverwendet; der aktuelle bleibt vor überlappenden Nachbarn anklickbar.

Die virtuelle Differenzenliste trennt Symbole und Beschriftungen, verwendet 22 Pixel Kopfhöhe und 24 Pixel Zeilenhöhe und passt ihre Inhaltsfläche zwischen 24 und 132 Pixel an ein Viertel der verfügbaren Vergleichshöhe an. Quellscrollen wählt den zuletzt an der oberen Kante vorbeigelaufenen Block. Explizite Sprünge sperren das Nachführen bis zur nächsten tatsächlichen Scroll- oder Navigationseingabe. Dadurch ändern GTKs verspätete Layoutkorrekturen die ausdrücklich gewählte Differenz nicht.

Ein explizites Sprungziel wird bei späteren GTK-Layoutkorrekturen erneut sichtbar gehalten, bis eine echte Scroll-, Zeiger- oder Navigationseingabe das Nachführen übernimmt. Die native Höhenmessung und Ausrichtung behalten ihre bisherigen Regeln.

Zeichenrechtecke dürfen nicht über ihre obere und untere Glyphenposition in eine Absatzhöhe umgerechnet werden: Emoji und andere Ersatzschriften können innerhalb derselben visuellen Zeile andere Oberkanten besitzen. Die native Unicode-Prüfung verwendet deshalb echte umgebrochene ZWJ-, CJK- und kombinierende Zeichen und prüft die folgenden Absatzkanten in beiden Spalten. Die Höhenberechnung bleibt bei GTKs Absatzhöhen und den bereits angewendeten Ausrichtungsabständen.

### Vergleichseinstiege ab 1.213.0

Die Paarwahl hält schwache Dokumentreferenzen auf aktiven Tab und Partner. Jede Auswertung prüft Zugehörigkeit und Textmodus erneut; nur zwei verschiedene, weiterhin geöffnete Dokumente ergeben ein Paar. Der Kontextbefehl verlangt außerdem, dass sein eigener Tab Mitglied dieses Paars ist. Die Vorbelegung folgt der sichtbaren Reihenfolge. Normale Aktivierung und echte Notebook-Wechsel verwerfen die Auswahl; Shift-Klick wird vor dem Kindknopf abgefangen und aktiviert keinen anderen Editor. Das Schließen und erneute Öffnen eines gleichen Pfads erzeugt keine neue Bindung an die alte Auswahl.

Der normale Menübefehl und Ctrl+Alt+Shift+D bleiben bei „aktiver Tab links“. Das Hauptfenster und sein Suchfenster verwenden jeweils dieselbe gebundene Editorinstanz. Ctrl+Alt+D bleibt für Desktop-Befehle frei. Der Direktvergleich gegen die gespeicherte Fassung verwendet denselben gebundenen Hintergrund- und Vorschaupfad mit Dateiquelle links und Speicherquelle rechts. Er setzt die Vergleichsregeln lokal auf Standardwerte, ohne die Einstellungsablage umzuschreiben. Rich-Quellen werden über den vorhandenen dokumentgebundenen Synchronisationspfad erfasst; Übernahmen behalten ihren nativen Editor und Undo-Verlauf.

Die nativen Prüfmodi `linux/test.sh diff-entrypoints`, `diff-entrypoints-rich`, `diff-saved` und `diff-saved-rich` verwenden echte Shift-/Kontextklicks und Tastatureingaben. Sie prüfen die sichtbare Reihenfolge, die globale Aktion unabhängig von der Paarwahl, geschlossene Dokumentidentitäten sowie den Direktvergleich mit voller Übernahmevorschau und einer nativen Rücknahme. Die Rücknahme im Rich-Modus muss einen sichtbaren Absatz fokussieren: Unsichtbare Undo-Hilfsabsätze sind kein gültiges Klickziel.

### Externe schreibgeschützte Fenster ab 1.214.0

Auch der externe Helfer nutzt `view::View` samt Darstellung, Faltung, Übersicht, Navigation und sicherem Kopieren. `readonly::ReadOnly` besitzt weder Workspace noch Dokumentreferenzen und blendet Übernahmeaktionen aus. Quellen und Bericht stammen aus derselben abgeschlossenen Berechnung. Der Export teilt den nativen Speicherdialog und beide Identitätsprüfungen vor der atomaren Übernahme mit normalen Vergleichs-Tabs; umbenannte und verlinkte Quelldateien bleiben geschützt. Ein geschlossener Controller verwirft seinen Bericht, bricht das Rendern ab und nimmt keine späten Ergebnisse mehr an.

Der externe Aufrufvertrag und seine eigenen Datei-/Zeilen-/Berichtsgrenzen bleiben bestehen. Fenster verwenden standardmäßig Soft Wrap; die gemeinsame Spaltenteilung wird weiterhin gespeichert. „Fastra beenden“ liegt im Fenstermenü und führt durch die bestehenden Schließentscheidungen aller Editorfenster. `linux/test.sh external-diff-view` prüft den tatsächlichen Helferaufruf ohne Editorfenster, reale Navigation/Faltung/Kopie und den nativen Berichtsexport; `linux/external-diff-test.sh` bleibt die separate Protokollprüfung.
