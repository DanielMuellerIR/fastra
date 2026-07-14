# Changelog

Alle nennenswerten Änderungen an Fastra werden hier dokumentiert.

Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.1.0/).
Versionsschema: `v0.x` bis zum produktiven Funktionsumfang, `v1.0` beim Release.

---

## [Unreleased]

## [v1.16.16] — 2026-07-15

### Behoben

- Return im Suchfeld aktiviert den ersten Treffer, ohne den Tastaturfokus an
  den verdeckten Dokumenteditor abzugeben. Das Suchfenster bleibt aktiv; Pfeil
  hoch/runter navigiert durch die Treffer und Return springt zum nächsten.
  Suchsprünge scrollen und selektieren weiterhin im zugehörigen Dokument,
  können dort aber keine nachfolgenden Tastatureingaben mehr auslösen.

### Qualitätssicherung

- Der `navmatch`-Selbsttest prüft den echten Return-Pfad vom Suchfeld zur
  Trefferliste, einen zweiten Return zur Weiternavigation, den unveränderten
  Dokumentinhalt und den beim Suchfenster verbleibenden Tastaturfokus.

## [v1.16.15] — 2026-07-14

### Behoben

- Trefferklicks und Sprungbefehle aus einer Suchmaske wirken bei mehreren
  Dokumentfenstern nur noch auf den zugehörigen Editor. Eigene Suchdialoge je
  Fenster können dadurch gleichzeitig offen bleiben, ohne Auswahl, Fokus oder
  Scrollposition eines anderen Dokuments zu verändern.

### Qualitätssicherung

- Ein neuer In-App-Selbsttest öffnet zwei Dokumentfenster mit je eigener
  Suchmaske und prüft die tatsächliche Selektion, sichtbare Zielzeile und den
  unveränderten Editor des anderen Fensters.

## [v1.16.14] — 2026-07-14

### Behoben

- Der Release-Workflow signiert ausführbare Mach-O-Ressourcen in SwiftPM-Bundles
  nun explizit mit Developer ID, Secure Timestamp und Hardened Runtime. Dadurch
  akzeptiert Apples Notarisierung auch das gebündelte `rg` und seine PCRE2-Dylib.

## [v1.16.13] — 2026-07-14

### Hinzugefügt

- Ein GitHub-Actions-Workflow führt bei Änderungen an `main` und bei Pull
  Requests die vollständigen Swift-Tests sowie die Lokalisierungsprüfung aus.

### Geändert

- Der Programmname erscheint auf der Willkommen-Seite, links oben in der App
  und im Über-Dialog einheitlich in Sora SemiBold mit einem kleinen
  hochgestellten Sternchen. Die Schrift wird samt SIL-OFL-Lizenz gebündelt;
  alle übrigen UI-Texte bleiben in der macOS-Systemschrift.

## [v1.16.12] — 2026-07-14

### Geändert

- Die Willkommen-Seite zeigt unter dem Programmnamen jetzt dezent die
  Versionsnummer und das zugehörige ISO-Datum. Der lateinische Wahlspruch und
  die bisherige Texteditor-Beschreibung entfallen dort.

## [v1.16.11] — 2026-07-14

### Hinzugefügt

- Der Root-Aufruf `./install.sh` startet jetzt denselben vollständigen
  Release-, Notarisierungs- und Installationsablauf wie `app/install.sh`.
  `NOTARY_PROFILE` und Optionen wie `--no-notarize` werden unverändert
  durchgereicht.

## [v1.16.10] — 2026-07-14

### Geändert

- Der „Über Fastra"-Dialog folgt jetzt der Anordnung des Favenio-Dialogs: Der
  lateinische Wahlspruch steht — mit deutscher Übersetzung nach Favenio-Muster
  („mit größter Leichtigkeit zu den Sternen") — direkt unter der Version und
  oberhalb der Tagline; die Abstände sind kompakter.

## [v1.16.9] — 2026-07-14

### Hinzugefügt

- Auf das Fastra-Fenster oder App-Symbol gezogene Ordner werden als Projekt
  geladen. Ist kein Dokumentfenster offen, erzeugen Datei- und Ordner-Öffnen
  automatisch ein neues Fenster.

### Geändert

- Beim Öffnen eines Projekts schließt Fastra saubere Datei-Tabs außerhalb des
  neuen Ordners. Ungesicherte Tabs, unbenannte Notizzettel und Dateien aus dem
  neuen Ordner samt Unterordnern bleiben erhalten.
- Die Willkommen-Seite zeigt abhängig von Fensterhöhe und UI-Skalierung nur
  vollständig passende Einträge der zuletzt benutzten Projekte.

### Behoben

- Dateinamen und Pfade der Änderungen-Ansicht nutzen den Platz bis kurz vor
  dem weiter rechts stehenden Git-Status. Hover-Aktionen überlagern den Text
  erst bei Bedarf, statt dauerhaft unsichtbare Breite zu reservieren.
- Der Seitenleisten-Hintergrund endet im Inhalt und im Fenster-Chrome exakt an
  der Splitterlinie; rechts davon beginnt ohne hellen beziehungsweise dunklen
  Überstand die Editorfläche.
- Der Markenname auf der Willkommen-Seite wird bei kleinen Fenstern und großer
  UI-Skalierung nicht mehr über den oberen Fensterrand hinausgeschoben.

### Qualitätssicherung

- Vier neue Tests sichern Ordner-Drops, Projektwechsel über Verzeichnisgrenzen
  und die höhenabhängige Willkommen-Liste. Alle 776 Swift-Tests sind erfolgreich.

## [v1.16.8] — 2026-07-14

### Behoben

- Die Änderungen-Ansicht gibt dem wichtigen Dateinamen jetzt Vorrang vor dem
  ergänzenden Ordnerpfad. Bei wenig Platz wird zuerst der Pfad an seinem Anfang
  gekürzt; nur wenn nötig endet der Dateiname kurz vor dem Git-Status mit einer
  Ellipse, statt bereits in seiner Mitte abgeschnitten zu werden.

## [v1.16.7] — 2026-07-14

### Behoben

- Die nativen macOS-Ampelknöpfe werden vertikal an Fastras tatsächlich
  sichtbarer, per UI-Zoom skalierter Titelleiste ausgerichtet. Bei vergrößerter
  Oberfläche kleben sie nicht mehr optisch am oberen Fensterrand; der Abstand
  zum Programmnamen entspricht dadurch dem übrigen Fenster-Chrome.

### Qualitätssicherung

- Ein neuer Geometrietest sichert die Ampelposition bei normaler und skalierter
  Titelleistenhöhe. Alle 772 Swift-Tests sind erfolgreich.

## [v1.16.6] — 2026-07-13

### Geändert

- Haupt- und zusätzliche Dokumentfenster verwenden dieselbe Startgröße und
  eine bedienbare Mindestgröße von 760 × 400 Punkten.
- Der Schalter für die linke Seitenleiste ist kompakter; der Markenblock sitzt
  höher und besitzt keine Trennlinie mehr zur Titelleiste.

### Behoben

- ⌘N übernimmt keine unbedienbar kleine Fenstergröße mehr.
- Bei schmalen Fenstern bleibt die linke Seitenleiste vollständig sichtbar.
  Der komprimierbare Hauptbereich schiebt sie nicht mehr aus dem linken
  Fensterrand; Programmname und Tab-Leiste bleiben erreichbar.

### Qualitätssicherung

- Zwei neue Tests sichern Mindestgröße, Kaskadenversatz und die Übernahme
  ausreichend großer Vorderfenster. Alle 771 Swift-Tests sind erfolgreich.

## [v1.16.5] — 2026-07-13

### Behoben

- Zusammenlaufende Graph-Lanes bleiben bis zum gemeinsamen Commit vollständig
  sichtbar; die Neben-Lane endet nicht mehr eine Zeile vorher im Nichts.
- Seitlich wechselnde Graph-Linien treffen und verlassen Commit-Knoten an der
  passenden linken beziehungsweise rechten Kante statt am oberen oder unteren
  Rand.

### Qualitätssicherung

- Der Merge-Regressionstest prüft nun beide eingehenden Lanes direkt am
  gemeinsamen Commit. Alle 769 Swift-Tests und der App-Build sind erfolgreich.

## [v1.16.4] — 2026-07-13

### Behoben

- Bei Merge-Historien bleibt die blaue HEAD-Lane auch dann bis zur gemeinsamen
  Vorgeschichte erhalten, wenn `git log` den Nebenast zuerst ausgibt. Die
  Neben-Lane mündet am gemeinsamen Vorfahren ein, statt dessen Farbe bis zum
  Root-Commit zu übernehmen.

### Qualitätssicherung

- Ein neuer Graph-Regressionstest bildet die beobachtete Topo-Reihenfolge nach.
  Alle 769 Swift-Tests und der App-Build sind erfolgreich.

## [v1.16.3] — 2026-07-13

### Geändert

- Die Seitenleiste ist mindestens 180 Punkte breit. „Fastra“ bleibt immer
  vollständig sichtbar; bei wenig Platz wird zuerst das Datum vollständig
  ausgeblendet und erst danach darf die Version gekürzt werden.

### Behoben

- Jeder neu erzeugte Editor synchronisiert nach seinem ersten Auto-Layout die
  tatsächliche Minimap-Breite mit dem rechten Text-Inset. Zeilen umbrechen
  dadurch sofort vor der Minimap und nicht erst nach einem manuellen Resize.
- Alte gespeicherte Seitenleistenbreiten unterhalb des neuen Minimums werden
  beim Anzeigen normalisiert, sodass der erste Splitter-Drag nicht springt.

### Qualitätssicherung

- Drei neue Minimap-Tests prüfen die Inset-Regel sowie einen echten
  CodeEditSourceEditor-Controller mit sichtbarer Minimap. Alle 768 Swift-Tests
  sind erfolgreich.

## [v1.16.2] — 2026-07-13

### Geändert

- Aufgeklappte Graph-Commits zeigen neben dem vollständigen Dateinamen den
  Autor statt des Verzeichnispfads. Der Dateiname erhält dabei Vorrang vor
  nachrangigen Metadaten.
- Die Symbole des Seitenleisten-Umschalters sind rund 20 Prozent kleiner; die
  gesamte Segmentfläche reagiert nun auf Klicks.

### Behoben

- Die blaue Graph-Lane ist fest für den ausgecheckten Branch reserviert. Auch
  wenn `git log --all` einen neueren Neben-Branch zuerst liefert, bleibt die
  darunterliegende `main`- beziehungsweise HEAD-Historie wie in VS Codium blau.

### Qualitätssicherung

- Ein neuer Lane-Test bildet einen Neben-Branch oberhalb von HEAD nach. Alle
  765 Swift-Tests sind erfolgreich.

## [v1.16.1] — 2026-07-13

### Geändert

- Der Seitenleisten-Umschalter verwendet kompakte Symbole für Dateien,
  Änderungen und Graph. Der Markenblock zeigt den Programmnamen etwas kleiner,
  Version und Datum dagegen besser lesbar.

### Behoben

- Der linke Splitter konsumiert seine Mausgeste nun in einer eigenen
  AppKit-Fläche und verschiebt beim Verbreitern der Seitenleiste nicht länger
  gleichzeitig das Hauptfenster.
- Kopieren aus der Markdown-Vorschau schreibt neben Klartext und HTML auch
  natives RTF in die Zwischenablage. Dadurch übernimmt Pages Überschriften,
  Listen und Hervorhebungen als formatierten Text.

### Qualitätssicherung

- Neue Regressionstests sichern die Trennung zwischen Splitter- und
  Fenster-Drag sowie die RTF-Repräsentation. Alle 764 Swift-Tests sind
  erfolgreich.

## [v1.16.0] — 2026-07-13

### Hinzugefügt

- Die linke Seitenliste und die integrierte Markdown-Vorschau lassen sich über
  direkte Schalter in der obersten Fensterzeile ein- und ausblenden. Der
  Seitenleistenkopf zeigt Fastra samt Version und Versionsdatum.
- Die Markdown-Vorschau erlaubt Textauswahl über mehrere Blöcke hinweg. Beim
  Kopieren landen Klartext und semantisches HTML gemeinsam in der Zwischenablage;
  Überschriften, Listen, Tabellen, Links und Hervorhebungen bleiben dadurch in
  Rich-Text-Zielen formatiert.

### Geändert

- Das Hauptfenster verwendet keinen sichtbaren nativen Titelbalken mehr. Tabs
  und Bereichsschalter sitzen direkt neben den macOS-Ampelknöpfen; der
  Fastra-/Versionsblock gehört allein zur Seitenleiste und der Editor beginnt
  ohne leere zweite Kopfzeile unmittelbar unter den Tabs.
- Fenster-Chrome, Tabs, Seitenleisten, Editor und Vorschau verwenden eine
  ruhige neutrale Hell-/Dunkelpalette mit blauem Akzent. Die frühere gelbe
  Markenfarbe wurde entfernt; aktive Tabs erscheinen als kompakte Pillen.
- Der lokale Markdown-Renderer stellt alle verwendeten GFM-Erweiterungen als
  HTML dar, speichert keine Website-Daten und lädt keine externen Bilder.

### Behoben

- Alle vertikalen Splitter messen Ziehbewegungen nun in globalen Koordinaten,
  behalten den Ausgangswert eines Drags und besitzen eine mittige 11-Punkt-
  Trefferfläche. Dadurch zappeln sie nicht mehr, lassen sich beidseitig leicht
  greifen und halten den Links-rechts-Cursor zuverlässig sichtbar.
- Die AppKit-Eigenschaften des eigenen Fenster-Chromes werden nur bei einer
  tatsächlichen Wertänderung gesetzt. Das verhindert einen AttributeGraph-
  Absturz beim Start beziehungsweise beim Wechsel des Erscheinungsbilds.

### Qualitätssicherung

- Drei neue Rich-Text-Tests sichern GFM-Tabellen, die zweifache Clipboard-
  Repräsentation und das Blockieren externer Bilder. Alle 762 Swift-Tests und
  der Lokalisierungs-Audit mit 225 verwendeten Schlüsseln sind erfolgreich.

## [v1.15.0] — 2026-07-13

### Hinzugefügt

- Die Vorlagenverwaltung speichert eigene Such- und Ersetzungsvorlagen und
  importiert oder exportiert sie als JSON. Aus einem Vorher-/Nachher-Beispiel
  lässt sich zudem ein Platzhalter-Muster ableiten.
- Markdown-Dokumente erhalten standardmäßig eine integrierte rechte Vorschau;
  sie folgt der Dokument-Skalierung und bietet eine getrennte Leseschriftwahl.
- Hex-Dateien bleiben zunächst schreibgeschützt. Ein bewusster Bearbeitungsmodus
  zeigt vor dem atomaren Speichern alle geänderten Bytes und verlangt eine
  Bestätigung.
- ⌘−, ⌘+ und ⌘0 skalieren die Oberfläche dauerhaft; die Varianten mit ⇧
  skalieren ausschließlich die Dokument-Schrift. JSON und XML lassen sich
  verlustarm formatieren.

### Verbessert

- Folder-Suchen verwenden das mitgelieferte ripgrep zur Dateiauflistung und
  behalten bei Fehlern den bisherigen Dateisystem-Fallback bei. Methodik und
  Messwerte stehen in `docs/ripgrep-benchmark.md`.
- XML wird beim Öffnen zentral erkannt, im Footer ausgewiesen und erhält die
  verfügbare strukturbezogene Syntaxhervorhebung. Live-Vorschau, Inline-Diff,
  dynamische Such-Tokenfarben und stabile persistente Splitter ergänzen die
  Suche und Vorschau.
- Einstellungen öffnen ausreichend groß, bleiben verkleinerbar und schließen
  mit ⌘W ausschließlich ihr eigenes Fenster.

### Qualitätssicherung

- Neue Tests sichern Vorlagen, Dateisuche, Hex-Änderungen, Dokumenttypen,
  Skalierungen, Splitter und Formatierung. 759 Swift-Tests sowie 24
  In-App-Selbsttests sind erfolgreich.

## [v1.14.5] — 2026-07-13

### Behoben

- Der Footer zeigt in geöffneten Dokumenten keinen Trefferstatus, solange
  noch kein Suchausdruck eingegeben wurde.

## [v1.14.4] — 2026-07-13

### Verbessert

- Das Fastra-App-Icon nutzt die verfügbare Icon-Fläche jetzt vollständig aus;
  der bisherige transparente Rand ließ es neben anderen Apps unnötig klein wirken.

## [v1.14.3] — 2026-07-13

### Geändert

- Jeder erfolgreiche `build.sh`-Lauf kopiert Fastra anschließend nach
  `/Applications/Fastra.app`; auch Debug-Builds sind damit sofort startbereit.

## [v1.14.2] — 2026-07-13

### Hinzugefügt

- `Fn`+← und `Fn`+→ (Home/End) springen im fokussierten Editor an den
  Anfang beziehungsweise das Ende der Datei. Mit ⇧ wird die Auswahl erweitert.

### Behoben

- Der Footer zeigt im Willkommen-Tab keinen irreführenden Trefferstatus mehr,
  bevor eine Suche überhaupt sinnvoll ist.

## [v1.14.1] — 2026-07-13

### Hinzugefügt

- Das Kontextmenü der Projekt-Dateiliste kann Dateien, Ordner und den
  Projektordner mit „Im Finder zeigen…“ direkt im Finder auswählen.

## [v1.14.0] — 2026-07-13

### Hinzugefügt

- Ein Doppelklick auf einen Commit im Git-Graph öffnet wieder dessen
  vollständigen Diff; der Einzelklick zum Auf- und Zuklappen der Dateiliste
  bleibt parallel erhalten.
- Ein Doppelklick auf eine Datei in der Git-Änderungen-Ansicht öffnet ihren
  abschnittsgenauen Diff. Bereitgestellte, offene und unversionierte Dateien
  werden dabei passend gegen Index, Working-Tree oder eine leere Datei verglichen.

### Verbessert

- Der vollständige Commit-Diff zeigt vor den einzelnen Patches eine kompakte
  Liste der betroffenen Dateinamen und Änderungszahlen.

### Qualitätssicherung

- Zwei neue Argumenttests sichern die Commit-Dateiliste und alle drei Arten
  von Datei-Diffs; 733 Unit-Tests und der Lokalisierungs-Audit sind erfolgreich.

## [v1.13.1] — 2026-07-13

### Behoben

- Zeilen in der Git-Änderungen-Ansicht behalten beim Einblenden ihrer
  Hover-Aktionen jetzt ihre Höhe und Textposition bei.

## [v1.13.0] — 2026-07-13

### Hinzugefügt

- Commits im Git-Graph lassen sich inline aufklappen. Die Dateiliste zeigt
  Pfad und Git-Status; ein Doppelklick öffnet ausschließlich den Diff dieser
  Datei aus dem gewählten Commit im Hauptbereich.
- Der Commit-Tooltip zeigt Autor, relatives und exaktes Datum, Betreff,
  Datei-/Einfügungs-/Löschungszahlen sowie den Kurz-Hash.

### Verbessert

- Der Graph folgt enger der VS-Code-/Codium-Darstellung: Hauptlane blau,
  Nebenäste orange, Merge-Knoten als Ring und kompaktere Kurven. Jede Zeile
  reserviert nur noch die tatsächlich belegten Lanes.
- Autor und Betreff stehen gemeinsam in einer Zeile; die separate Datumsspalte
  entfällt zugunsten eines längeren sichtbaren Commit-Texts.
- Auch Merge-Commits liefern ihre Dateiliste und Änderungszahlen relativ zum
  ersten Eltern-Commit.

### Qualitätssicherung

- Parser-Tests decken Zeitstempel, Dateistatus und Numstat-Zahlen ab; ein
  weiterer Test sichert den dateispezifischen Diff-Aufruf und die Merge-Option.
- 731 Unit-Tests, Lokalisierungs-Audit, App-Build und Graph-Screenshot sind
  erfolgreich.

## [v1.12.2] — 2026-07-13

### Behoben

- Fastra und die betroffenen Editor-Module suchen ihre SwiftPM-Ressourcen in
  einer gepackten App nun zuerst im standardkonformen Ressourcenordner.
  Zuvor kaschierte ein absoluter lokaler Build-Pfad den Verpackungsfehler auf
  dem Build-Mac; auf anderen Macs stürzte Fastra beim Start sofort ab.

### Qualitätssicherung

- Jeder Debug- und Release-Build blendet vor Abschluss alle lokalen
  SwiftPM-Build-Fallbacks aus und muss den fensterlosen Lokalisierungsstart
  bestehen. `install.sh` wiederholt dieselbe Prüfung mit der tatsächlich nach
  `/Applications` kopierten App und meldet erst danach Erfolg.

## [v1.12.1] — 2026-07-13

### Behoben

- Der Git-Graph begrenzt seinen Inhalt nun fest auf die Seitenleistenbreite.
  Lange Branch-Namen können beim Scrollen zu älteren Verzweigungen keine
  endlose SwiftUI-Layout-Neuberechnung mit stark wachsendem Speicherverbrauch
  mehr auslösen.

## [v1.12.0] — 2026-07-12

### Hinzugefügt

- **Vollständige englische Lokalisierung zusätzlich zu Deutsch:** Statische
  SwiftUI-Texte, dynamische Status-/Zählertexte, AppKit-Menüs und -Dialoge,
  Tooltips, Git-Rückmeldungen, Suchvorlagen, Regex-Lernhilfen, der
  Erststart-Demo-Inhalt und Finder-Metadaten folgen automatisch der
  macOS-Sprachreihenfolge.
- Der zentrale `L10n`-Zugriff lokalisiert auch Enum-Rohwerte und formatierte
  Meldungen, die SwiftUI nicht selbst extrahieren kann. Das Haupt-App-Bundle
  und das SwiftPM-Modulbundle erhalten beide ihre benötigten Tabellen.
- `localization-audit.sh` vergleicht alle statisch erkannten SwiftUI-Schlüssel
  mit 498 englischen Einträgen und prüft Format-Platzhalter. Drei Unit-Tests
  sichern dynamische Werte, alle Vorlagen und Regex-Hilfen; der fensterlose
  Selbsttest `localization` prüft die tatsächliche App-Verpackung. Ein echter
  englischer Suchfenster-Screenshot wurde visuell abgenommen.

### Verbessert

- Treffer-/Dateizähler verwenden nun auch im Englischen korrekte Singular-
  und Pluralformen.

## [v1.11.0] — 2026-07-12

### Hinzugefügt

- **Vollständige Side-by-side-Diff-Vorschau:** Vorher- und Nachher-Dokument
  werden zeilenweise synchron ausgerichtet; Einfügungen, Löschungen,
  Ersetzungen und unveränderte Kontextzeilen bleiben in zwei gleich breiten
  Panels nachvollziehbar. Mehrzeilige Ersetzungen sind abgedeckt, die Anzeige
  wird bei 5.000 Zeilen mit ehrlichem Gesamtzähler begrenzt.
- **Konfigurierbarer Extrahieren-Dialog:** Treffer lassen sich mit
  Zeilenumbruch, Komma, Semikolon, Tab oder eigenem Trennzeichen in ein neues
  Dokument oder die Zwischenablage schreiben. Optional stehen CSV-artiges
  Quoting, Deduplizierung und Transformation durch das Ersetzungsmuster bereit.
- **Vollständiger Projekt-Scope:** Pro Projekt persistente Datei-Sets können
  Ordner und Einzeldateien kombinieren. Eigene Dateitypfilter und
  projekt-relative Glob-Ausschlüsse begrenzen die Suche; ungültige Pfade
  bleiben außerhalb des Projekts und überlappende Wurzeln erzeugen keine
  doppelten Treffer.
- Unit-Tests prüfen Diff-Ausrichtung und -Kappung, alle Extraktionsoptionen,
  Konfigurationspersistenz und -reparatur, Globs, direkte Dateien und
  überlappende Wurzeln. Der `project`-Selbsttest prüft Datei-Set und Ausschluss
  über den echten Workspace/SearchRunner-Pfad.

## [v1.10.0] — 2026-07-12

### Hinzugefügt

- **Native Hex+ASCII-Ansicht für Binärdateien:** Eine Null-Byte-Probe routet
  Binärdateien automatisch in einen schreibgeschützten, adressierten Hex-View.
  Pro Seite werden nur 4 KiB gelesen und 256 Zeilen virtualisiert; Fastra
  benötigt keine zusätzliche HexFiend-Abhängigkeit.
- **Abschnittsweises Laden großer Textdateien:** Dateien über 32 MiB öffnen in
  einer schreibgeschützten 256-KiB-Seitenansicht mit freier Navigation. Der
  Speicherbedarf bleibt unabhängig von der Dateigröße begrenzt; Speichern ist
  gesperrt, damit ein Teilbuffer niemals die Originaldatei überschreibt.
- **Gutter-Dimmen:** Zeilennummern treten in nicht-vorderen Dokumentfenstern
  zurück und erhalten beim Fokuswechsel sofort wieder volle Deckkraft.
- Die bereits von der gepinnten CodeEditTextView-Version unterstützte
  Rectangle Selection per ALT-Drag ist nun als verbindliches Verhalten
  dokumentiert und ihr bestehender Mehrfachselektions-Selbsttest läuft in der
  Standardsuite.
- Neue Selbsttests `filemodes`, `colsel` und `gutterdim` prüfen das echte
  Workspace-Routing, die echte Editor-Mehrfachselektion und den echten
  CodeEditSourceEditor-Gutter. Unit-Tests sichern Binärerkennung,
  Großdatei-Schwelle und seitenweises Lesen ab.

## [v1.9.0] — 2026-07-12

### Hinzugefügt

- **Live-Dateibaum über FSEvents:** Externe Änderungen durch Terminal, Git oder
  andere Programme aktualisieren auch tiefe, aufgeklappte Projektordner ohne
  Polling. Ein rekursiver Integrationstest sichert das echte macOS-Ereignis ab.
- **Dateibaum-Kontextmenü:** neue Dateien und Ordner anlegen, Einträge
  umbenennen und nach nativer Bestätigung in den Papierkorb verschieben.
  Namen werden zentral validiert; Fehler erscheinen verständlich im Dialog.
- Der Aufklappzustand wird pro Projekt gespeichert und beim nächsten Öffnen
  wiederhergestellt.
- Die Branch-Zeile bietet alle lokalen Branches als Liste an und wechselt
  asynchron per `git switch`. Der bestehende Git-End-to-End-Selbsttest prüft
  nun Branch-Laden, Auswahl und echten Wechsel.
- Push, Pull und Fetch zeigen nach Erfolg für drei Sekunden eine nicht-modale
  Bestätigung in der Seitenleiste. Fehler zeigen weiterhin die echte
  Git-Ausgabe.

### Behoben

- Parallele Statusabfragen verwenden `--no-optional-locks`, damit ein beim
  Projektöffnen laufendes `git status` nicht mehr kurz mit Commit-, Stage- oder
  anderen schreibenden Aktionen um `index.lock` konkurriert.

## [v1.8.0] — 2026-07-12

### Hinzugefügt

- **Globale UI-Skalierung über ⌘+, ⌘− und ⌘0:** Editor, Suchfelder,
  Seitenleiste, Datei-/Änderungs-/Graph-Ansichten, Tab-Leiste, Footer,
  Willkommensseite, Vorschauen und Hilfsfenster verwenden eine gemeinsame,
  persistente Zoomstufe. Native SwiftUI-Controls wechseln passend zwischen
  kleinen, regulären und großen Kontrollgrößen.
- Semantische Schriftrollen und ein zentraler `uiScale`-Environment-Wert
  ersetzen die zuvor in `Theme.swift` und Einzelansichten verteilten festen
  SwiftUI-Schriften. Eingebettete AppKit-Textansichten und der SourceEditor
  ziehen live mit, ohne Text, Auswahl oder Undo-Historie neu aufzubauen.
- Unit-Tests sichern Normalstufe, Grenzwerte und monotone Skalierung ab.

### Geändert

- Tab-Leiste, Footer, Suchfelder und die wichtigsten eigenen Control-Rahmen
  skalieren ihre Höhe zusammen mit der Schrift; die Zoomstufe ist auf einen
  layoutstabilen Bereich von −3 bis +5 begrenzt und bleibt über App-Starts
  erhalten.

## [v1.7.0] — 2026-07-12

### Hinzugefügt

- **Git-Graph in der Seitenleiste** (dritter Modus neben „Dateien" und
  „Änderungen", nur bei Git-Repos): zeigt die Commit-Historie mit echten
  VS-Code-artigen Multi-Lane-Verzweigungslinien — parallele Branches liegen in
  eigenen, farbigen Spalten, Merges gabeln und laufen sichtbar wieder zusammen.
  Jede Zeile trägt Branch-/Tag-Pillen (HEAD-Branch fett, Tags mit Symbol),
  Betreff, Autor und Datum; ein Klick öffnet den Commit als Diff-Tab. Die
  Historie lädt asynchron beim Projekt-Öffnen und nach jedem Commit neu.
- Die Graph-Kernlogik (`git log`-Parser + Lane-Zuweisung) liegt rein und ist
  durch Unit-Tests abgedeckt (linear, Verzweigung + Merge, geteilter Parent,
  Root, Refs-Parsing). Neuer Screenshot-Selbsttest `graphshot` für die visuelle
  Abnahme.

## [v1.6.1] — 2026-07-12

### Behoben

- **„Text-Geist" bei langen umgebrochenen Zeilen beseitigt:** Wörter werden
  nach Paste oder Datei-Laden nicht mehr mehrfach gezeichnet, und Text läuft
  nicht mehr rechts aus dem Editor. Ursache war ein Fehler in
  CodeEditTextView: Der absolute Endindex eines CoreText-Zeilenumbruchs wurde
  als Bereichslänge verwendet. Ab dem zweiten Fragment überlappten die
  gezeichneten Bereiche dadurch immer stärker. Checkout-Patch 4i rechnet nun
  korrekt `Länge = Endindex - Startindex`; der Patch verifiziert sich beim
  Build selbst.
- Der In-App-Selbsttest `ghosttext` prüft die tatsächliche CoreText-Nutzlast,
  Fragmentbreiten und doppelt belegte Dokumentbereiche nach Laden und Resize.
  Er gehört jetzt zur standardmäßig ausgeführten Selbsttest-Suite.

## [v1.6.0] — 2026-07-12

### Hinzugefügt

- Minimap-Schalter im Menü „Darstellung"; die Minimap ist standardmäßig aus.
- Ziehbarer, persistenter Splitter für die Breite der Projekt-Seitenleiste.
- Per ⌘N erzeugte Zusatzfenster erscheinen im Menü „Fenster".

### Geändert

- Willkommensseite und Fenstertitel sind sachlicher formuliert; der
  Willkommenszustand heißt im Tab ebenfalls „Willkommen".
- ⌘N öffnet direkt einen leeren Editor statt weiterer Willkommensseiten.
- Das Schließen des letzten Fensters beendet Fastra nicht mehr; die App bleibt
  für ein neues Fenster aktiv.

## [v1.5.1] — 2026-07-12

### Hinzugefügt

- **Erster Push legt den Upstream selbst an:** Hat der aktuelle Branch noch
  keinen Upstream, macht die „Push"-Aktion automatisch `push -u origin HEAD`,
  statt die kryptische „has no upstream branch"-Meldung zu zeigen. Selbsttest
  `gitactions` deckt den Fall ab.

## [v1.5.0] — 2026-07-12

Projekt- & Git-Ausbau, Etappe 2 (Git-Sichtbarkeit + kuratierte Aktionen).

### Hinzugefügt

- **Git-Status in der Projekt-Seitenleiste:** Bei einem Git-Projekt zeigt der
  Kopf den aktuellen Branch mit Ahead/Behind-Zählern und einem Auffrisch-Knopf;
  geänderte Dateien im Dateibaum werden eingefärbt und mit einem Kürzel
  markiert (M/U/A/D/R/!), Ordner mit geändertem Inhalt bekommen einen Punkt.
  Alles über das `git`-CLI (`GitRunner`), asynchron, nie den Main-Thread
  blockierend. Auto-Auffrischung beim Zurückwechseln in die App und nach
  Speichern.
- **git wird dialogfrei erkannt** (`GitRunner`): Homebrew- bzw. das echte
  CLT-git werden direkt angesprochen, nie der `/usr/bin/git`-Stub (der sonst
  den Command-Line-Tools-Installationsdialog auslöst). Fehlt git komplett,
  bleibt die gesamte Git-UI still weg — keine Meldung, kein Dialog.
- Selbsttest `git` (fensterlos, echtes Temp-Repo end-to-end) + Diagnose-Shot
  `gitshot`; Unit-Tests für Status-Parsing und git-Pfad-Auflösung.
- **Verlauf als read-only-Tab** (`git log --graph`): Commit-Zeilen sind
  anklickbar und öffnen den Commit per `git show` in einem weiteren Tab.
  Öffnen über das Uhr-Symbol in der Branch-Zeile.
- **Diff als read-only-Tab** (`git diff HEAD`): Unified-Diff mit Färbung
  (hinzugefügt grün, entfernt rot, Hunk-/Datei-Header und Commit-Metadaten
  betont). Öffnen über das ±-Symbol in der Branch-Zeile. Beide Git-Tabs sind
  gegen ⌘S/Speichern-unter abgesichert und pro Art dedupliziert.
- **Kuratierte Git-Aktionen** (Popup in der Branch-Zeile + „Git"-Menü in der
  Menüleiste, gleiche Einträge): Alles committen, Letzten Commit ergänzen
  (amend --no-edit), Push, Pull (Fast-Forward), Pull (mit Merge), Fetch,
  Verlauf durchsuchen (Pickaxe `log -S`) und Zum vorherigen Branch (`switch -`).
  Jeder Punkt trägt einen dezenten Hilfe-Text als Tooltip. Aktionen laufen
  asynchron; Erfolg frischt Status + offene Git-Tabs auf, Fehler zeigt die
  wörtliche git-Ausgabe. Selbsttest `gitactions` prüft Push/Pull/Amend/Switch/
  Pickaxe end-to-end gegen ein lokales bare-Remote.

### Behoben

- **Regression aus v1.4.0:** Die dortige URL-Kanonisierung (`/var` →
  `/private/var`) hatte drei bestehende Unit-Tests in Temp-Verzeichnissen rot
  gemacht (ein force-unwrap crashte den Testlauf und maskierte es beim
  Abschluss). Test-Helper an die kanonische Tab-URL angeglichen.

## [v1.4.0] — 2026-07-12

Projekt- & Git-Ausbau, Etappe 1 (siehe ROADMAP.md → „Projekt- & Git-Ausbau").

### Hinzugefügt

- **Willkommensbildschirm:** Erscheint statt des Editors, wenn nichts geöffnet
  ist (Folgestart mit leerem unbenanntem Tab; der Demo-Tab des Erststarts hat
  Vorrang). Bietet „Neue Datei", „Datei öffnen…", „Ordner öffnen…" und die
  Liste der zuletzt benutzten Projekte — ein Klick lädt das Projekt.
  Sichtbarkeits-Bedingung pur in `WelcomeLogic` (getestet); Tab-Klick, ⌘T
  oder jede Öffnen-Aktion blenden ihn aus.
- **Projekte:** Ein Projekt ist ein Ordner — explizit über „Ordner öffnen…"
  (⇧⌘O, neuer Menüpunkt) gewählt oder automatisch still gemerkt, sobald eine
  Datei aus einem Git-Repository geladen wird (`.git`-Erkennung aufwärts,
  auch `git worktree`-Dateien). Persistenz in `fastra.recentProjects`
  (JSON, max. 12, Muster RecentSearchFoldersStore).
- **Hierarchische Datei-Seitenleiste:** Bei geladenem Projekt zeigt die
  Seitenleiste den Dateibaum (Ordner zuerst, Finder-Sortierung, Versteckte
  übersprungen; lazy pro Ebene, kein Vollscan). Klick auf Datei lädt sie in
  einen Tab (inkl. Aktiv-Markierung), Klick auf Ordner klappt auf/zu; die
  „GEÖFFNET"-Liste rückt kompakt darunter. Schließen-Knopf blendet den
  Baum wieder aus.
- Selbsttest `project` (fensterlos, end-to-end) + Diagnose-Shots
  `welcomeshot`/`projectshot`; ~30 neue Unit-Tests (ProjectStore, FileTree,
  WelcomeLogic, URL-Kanonisierung).

### Behoben

- **Datei-URLs werden beim Öffnen kanonisiert** (`/var` ≠ `/private/var`,
  `canonicalPathKey`): Vorher konnten Tab-Dedup und die Aktiv-Markierung im
  Projektbaum an unterschiedlichen URL-Formen derselben Datei scheitern.
  `resolvingSymlinksInPath` reicht dafür nicht (lässt `/private`-Aliasse
  dokumentiert stehen).

## [v1.3.0] — 2026-07-10

### Hinzugefügt

- **Doppelstern `**` im Platzhalter-Modus:** ein Lauf aus zwei oder mehr
  Sternen ist EINE Fanggruppe, die auch über Zeilenumbrüche fängt (z.B.
  `BEGIN**END` sammelt den kompletten Block dazwischen ein). Der Einzelstern
  bleibt wie gehabt zeilenintern; auch im Ersetzen-Feld zählt `**` als EIN
  Verweis. Der Hinweis „Ersetzen hat mehr ∗ als Suchen" zählt jetzt Läufe.
  (Vorher war `**` ein entartetes Doppel-`(.+)`.)
- Diagnose-Selbsttest `searchshot` (Screenshot-Helfer: Suchmaske im leeren
  Ausgangszustand, analog `wildcardshot`).

### Geändert

- **Spendenaufruf vorerst deaktiviert** (Hauptschalter
  `DonationPrompt.isEnabled = false`, Daniel-Entscheidung 2026-07-10):
  Banner erscheint nicht mehr; Logik, View, Start-Zähler und Tests bleiben
  vollständig erhalten, Reaktivierung = ein Flag. Finale Entscheidung vor
  Release (siehe todo.md).

### Behoben

- **Placeholder in den Suchen-/Ersetzen-Feldern sitzt jetzt exakt auf der
  Position des getippten Texts** (war vertikal zentriert und dadurch einen
  Tick tiefer sowie 2 px weiter links).

## [v1.2.0] — 2026-07-10

### Behoben

- **Editor-Syntax-Highlighting färbt wieder** (betraf auch v1.0: Sprache
  wurde erkannt, Code blieb aber monochrom). Root Cause: CodeEditLanguages
  baute den Highlight-Query-Pfad doppelt (`…/Resources/Resources/…`) — die
  `highlights.scm`-Dateien wurden nie gefunden. Fix als build.sh-Patch 4h
  (layout-robuste Pfad-Auflösung). Neuer Selbsttest `highlight` zählt die
  echten Vordergrundfarben im Editor-TextStorage und wacht über Regressionen.
- **Suchen-/Ersetzen-Felder im Dark Mode lesbar:** Feld-Hintergrund, Text-,
  Platzhalter-, Insertion-Point- und Fehler-Farben der RegEx-Felder sind
  jetzt dynamisch (hell/dunkel) statt hartkodiert weiß/Ink.

### Hinzugefügt

- **Vorlagen-Liste mehr als verdoppelt (16 → 38):** zwei neue Kategorien
  „Wörter & Zeilen" (u.a. „Ein Wort", „Zwei Wörter (tauschen)",
  „Nachname, Vorname → Vorname Nachname", „Doppeltes Wort", Anführungs-
  zeichen/Klammern-Inhalt) und „Leerraum & Aufräumen" (mehrfache
  Leerzeichen, Zeilenende-Leerraum, Einrückung, Tabulatoren, Leerzeilen);
  dazu Ergänzungen in den bestehenden Kategorien (Hex-Farbe, Versions-
  nummer, Dateiname, ISO-Zeitstempel, HTML-Kommentar, englische Dezimal-
  zahl, Prozent, Euro-Betrag). Bestehende Vorlagen bleiben oben; viele
  neue bringen eine sinnvolle Standard-Ersetzung mit (z.B. Namen tauschen).

## [v1.1.0] — 2026-07-10

### Hinzugefügt

- **Dark Mode.** Warmes dunkles Design passend zum Cream/Ink/Gold-Light-Theme:
  alle Farb-Tokens in `Theme.swift` sind jetzt dynamisch (helle + dunkle
  Ausprägung, aufgelöst über die effektive Appearance), der Code-Editor
  bekommt ein eigenes dunkles Theme (`fastraThemeDark`), die Token-Färbung
  im RegEx-Eingabefeld hat dunkle Farbvarianten. Goldgelb bleibt in beiden
  Modi der Marken-Akzent.
- **Einstellungen → Erscheinungsbild (⌘,):** Dark Mode „Automatisch"
  (folgt dem macOS-System), „Hell" oder „Dunkel" — wirkt sofort auf alle
  Fenster und ist persistent (`AppearanceSetting`). Das app-weite Erzwingen
  von Hell (v1.0-Behelf gegen weiß-auf-weiß) entfällt.
- 7 neue Unit-Tests (Einstellungs-Mapping, Theme-Unterscheidung, Minimap-
  Colorspace-Wächter, dynamische Farbauflösung hell/dunkel). 624/624 grün,
  Selbsttest-Suite 15/15 PASS; Kontrast-Wächter (`contrast`) zusätzlich im
  erzwungenen Dark Mode grün.

## [v1.0.0] — 2026-07-10

Erster produktiver Release. Umfasst alle Build-Stände v0.10.x aus dem Branch
`sprint_to_v1` (BBEdit-Nachbau Teil 1–5, Bundle-Verschlankung auf ~53 MB,
Suchdialog-QA, Mehrfenster-Betrieb); von Daniel abgenommen.

### Behoben (2026-07-10, v0.10.15 Build-Stand)

- **⌘W und das Tab-X schließen beim letzten Tab das Dokumentfenster**, statt
  einen leeren Fensterrahmen mit null Tabs stehen zu lassen. Bei mehreren Tabs
  bleibt das bisherige Verhalten unverändert: nur der gewählte Tab schließt.
- Ein leeres unbenanntes Dokument schließt ohne Rückfrage — auch wenn es durch
  Tippen und anschließendes Löschen technisch noch als geändert markiert ist.
  Ein unbenanntes Dokument mit Inhalt verwendet weiterhin die sichere
  Rückfrage Sichern/Abbrechen/Nicht sichern. Gespeicherte, leer bearbeitete
  Dateien bleiben ebenfalls rückfragepflichtig, weil Disk-Inhalt betroffen ist.
- Die zentrale Schließen-Logik gilt gleichermaßen für ⌘W, Tab-X und den roten
  Schließen-Knopf zusätzlicher Dokumentfenster. Vier neue Unit-Regressionstests
  sowie der erweiterte `newwindow`-Selbsttest decken Entscheidung und echtes
  NSWindow-Schließen ab. 617/617 Unit-Tests grün.

### Hinzugefügt (2026-07-10, v0.10.14 Build-Stand)

- **⌘N öffnet ein neues Dokumentfenster** mit genau einem leeren, unbenannten
  Dokument. Jedes Fenster besitzt einen eigenen `Workspace`; Tabs,
  ungesicherter Inhalt und Suchzustand werden nicht zwischen Fenstern geteilt.
- Globale Befehle wie ⌘F, ⌘S, ⌘O, Smart-Paste und Markdown-Vorschau folgen dem
  aktiven Dokumentfenster. Such- und Vorschaufenster behalten dabei die
  Zuordnung zu ihrem Ursprungsdokument.
- ⌘Q und die Erkennung extern geänderter Dateien berücksichtigen alle offenen
  Dokumentfenster. Zusätzliche Fenster schützen ungesicherte Tabs auch beim
  Schließen über den roten Fensterknopf.
- Neuer In-App-Selbsttest `newwindow`: löst den echten ⌘N-Menübefehl aus,
  prüft das zweite sichtbare Fenster und beweist durch getrennte Änderungen,
  dass beide Dokumente unabhängig sind. Ein Fokuswechsel mit echtem ⌘T prüft
  zusätzlich das Command-Routing. 613/613 Unit-Tests, 15/15 Selbsttests und
  Debug-App-Build grün.

### Behoben (2026-07-10, v0.10.13 Build-Stand)

- Smart-Paste leert stdout und stderr von `md-clip` jetzt fortlaufend und
  nicht blockierend. Große Konvertierungen können damit nicht mehr den
  Pipe-Puffer füllen und vor dem Prozessende hängen bleiben.
- Der Fehlerpfad wartet nicht mehr auf Pipe-EOF. Ein von Pandoc oder einem
  anderen Unterprozess geerbter stderr-Descriptor kann Smart-Paste deshalb
  nicht mehr nach dem Ende von `md-clip` blockieren.
- Beim 10-Sekunden-Timeout werden beide Pipe-Descriptoren zuverlässig
  geschlossen. Ignoriert `md-clip` SIGTERM, beendet Fastra den Prozess nach
  kurzer Schonfrist per SIGKILL.
- Drei echte Prozess-Regressionsfälle ergänzen die Suite: 200-kB-stdout,
  geerbter stderr-Descriptor und SIGTERM-resistenter Timeout. 613/613
  Unit-Tests grün; Debug-App-Build erfolgreich.

### Behoben (2026-07-10, v0.10.12 Build-Stand)

- Der kontextuelle Schalter „∗ wörtlich" wird im Datei-Scope nicht mehr am
  rechten Rand der Suchmaske abgeschnitten, sondern erscheint vollständig in
  einer eigenen, an den Eingabefeldern ausgerichteten Optionszeile.
- Der Detailkopf im Such-Scope „Geöffnet" zeigt jetzt den Namen des Tabs, aus
  dem der aktive Treffer tatsächlich stammt. Zuvor konnte dort bis zum ersten
  Treffer-Klick fälschlich der Name des gerade aktiven Tabs stehen.
- Capture-Group-Pillen werden auch im Platzhalter-Modus korrekt ausgewertet:
  `$2 $1` setzt in Vorschau und Ersetzung wieder die Inhalte der beiden durch
  `*` erzeugten Gruppen ein, statt die Zeichenfolge wörtlich auszugeben.
- Das Ersetzen-Feld nimmt Pillen-Drops jetzt über seine vollständige sichtbare
  Höhe an, einschließlich des unteren Zeilenrands.
- Die Trefferliste zeigt Zeilennummern ohne das missverständliche Präfix „Z",
  das in der kleinen Monospace-Schrift wie eine „2" aussehen konnte.
- Das Hauptfenster verwendet wieder die native macOS-Titelzeile mit dem Namen
  der aktiven Datei. Ein CMD-Klick auf Dateisymbol oder Titel zeigt AppKits
  hierarchisches Pfadmenü; dessen Ordner lassen sich im Finder öffnen.

### Bundle-Größe drastisch reduziert — Apple-Silicon-only (2026-07-08, v0.10.12)

- **App-Bundle von 489 MB auf ~53 MB (−89 %)** — kleiner als BBEdit (68 MB).
- **Kein Intel/x86_64 mehr** (Daniel-Entscheidung): Fastra wird nur für Apple Silicon (arm64) gebaut.
- **Totes Grammatik-XCFramework nicht mehr ins Bundle kopiert:** `CodeLanguagesContainer`
  (CodeEditLanguages, `.binaryTarget`) ist ein statisches ar-Archiv (~375 MB, universal), das
  zur Build-Zeit ins Binary gelinkt und zur Laufzeit nie geladen wird — reines totes Gewicht.
- **Exotische Sprach-Grammatiken ausgeschnitten** (build.sh-Patch 4g): Verilog, OCaml
  (+Interface), Julia, Haskell, Scala, Agda, Elixir, Zig (~50 MB). Dart + alle Mainstream-
  Sprachen behalten Syntax-Highlighting; ausgeschnittene Sprachen werden als Plaintext behandelt.
- **Release-Build strippt Debug-Symbole** und signiert danach ad-hoc neu (Pflicht auf Apple Silicon).
- Verifiziert: 599/599 Unit-Tests, 14/14 In-App-Selbsttests grün; Signatur gültig, arm64-only.

### BBEdit-Nachbau Teil 5 — Suche & Dateimodell (2026-07-04, v0.10.11)
> Quelle: systematischer Neu-Durchgang durchs BBEdit User Manual **16.0.1** (Kap. 3, 5, 7, 8) auf noch nicht übernommene, zum Kern passende Funktionen. Fünf Features übernommen; bewusst NICHT übernommen: Pattern Playground (unsere Live-Vorschau + Pillen decken das ab), Live-Match-Highlighting im Editor (CESE-Framework-Grenze, v1.1+), Folds/Spell/Completion/Multi-Window (außerhalb „light editor").
- **Case-Transformationen im Ersetzungsmuster** (Kap. 8 S. 216): `\U`/`\L` (alles Folgende GROSS/klein bis `\E`), `\u`/`\l` (nur nächstes Zeichen) — wirken auf den ERSETZTEN Text inkl. `$N`-Backrefs. Beispiel: `(\w+), (\w+)` → `\U$2\E $1` macht aus „Müller, Daniel" → „DANIEL Müller". Neue pure Logik `CaseTemplate` (Segment-Parser + Zustandsmaschine, NSRegularExpression expandiert die Backrefs pro Segment); greift in Treffer-Vorschau, „Alle ersetzen" und Ordner-Apply. Plain-/Platzhalter-Modus bleibt strikt literal.
- **Treffer extrahieren (BBEdit „Extract", S. 168/193):** Button neben „Treffer kopieren" — sammelt alle Treffer zeilengetrennt in ein NEUES unbenanntes Dokument (dirty, Schließen-Rückfrage greift). Ist das Ersetzen-Feld gefüllt, wird jeder Treffer erst transformiert (`$1` → reine Gruppen-Liste); leer = roh. Im Datei-Scope ungekappt (alle Treffer, nicht nur die 2000 materialisierten der Live-Liste).
- **Such-Scope „Geöffnet" ist jetzt echt** (BBEdit „Open text documents", Kap. 7 S. 184): Suche über ALLE offenen Tabs in-memory (auch ungespeicherte), live beim Tippen, Trefferliste pro Tab gruppiert, Klick/⌘G aktiviert den Ziel-Tab und springt zum Treffer. „Alle ersetzen" ersetzt in allen Tabs (nur im Speicher, geänderte Tabs werden dirty; ⌘S speichert wie gewohnt). Der Scope war seit v0.5 angelegt, aber nie implementiert und zuletzt ausgeblendet.
- **Extern geänderte Dateien werden erkannt** (BBEdit „Reload from Disk" / „Automatically refresh documents", Kap. 3 S. 59): Beim Zurückwechseln in die App wird jeder offene Tab gegen die Platte geprüft. Sauberer Tab → lädt still neu; Tab mit ungespeicherten Änderungen → Rückfrage „Behalten / Neu laden" (Behalten merkt sich die Entscheidung, fragt nicht bei jedem App-Wechsel erneut). Eigenes Speichern löst keinen Fehlalarm aus. Neu im „Ablage"-Menü: **„Von Festplatte neu laden"** für den aktiven Tab.
- **Unicode-Transforms im „Text"-Menü** (Kap. 5 S. 156): „Leerzeichen vereinheitlichen" (alle Unicode-Space-Varianten wie NBSP/schmale Spaces → ASCII-Space), „Diakritische Zeichen entfernen" (á→a, ü→u), „Unicode zusammensetzen (NFC)" und „Unicode zerlegen (NFD)". Der No-Op-Schutz vergleicht bei NFC/NFD scalar-exakt (Swifts `String ==` gilt kanonisch äquivalent — sonst wäre die Normalisierung immer ein „No-Op").
- Qualität: +52 Unit-Tests (598 gesamt grün), neuer fensterloser Selbsttest `openscope` (echter SearchRunner-Async-Pfad), komplette Selbsttest-Suite 14/14 PASS.

### Behoben (2026-06-27, v0.10.9)
- **Beenden abgebrochen: ursprünglich aktiver Tab bleibt aktiv** (Code-Review-Befund): Beim ⌘Q-Beenden sicherte `confirmCloseAllDirtyForQuit` pro Dirty-Tab über `mayCloseTab`, das im „Sichern"-Zweig `activeTabID` kurz auf den gerade gesicherten Tab umsetzt. Wurde das Beenden bei einem späteren Tab abgebrochen, blieb fälschlich der zuletzt gesicherte Tab aktiv statt des ursprünglich aktiven (anders als `closeTab`, das `previousActive` rettet). Jetzt wird wie bei `closeTab` der ursprünglich aktive Tab gemerkt und am Ende — egal ob beendet oder abgebrochen — wiederhergestellt. +1 Repro-Test (535 gesamt grün).

### Schließen-/Beenden-Rückfrage bei ungespeicherten Änderungen (2026-06-25, v0.10.8)
> BBEdit-Verhalten (Daniel-Befund bei der GUI-Abnahme): ein leeres/unverändertes Dokument schließt sofort, ein Dokument mit ungesicherten Änderungen fragt erst.
- **Tab schließen (⌘W / Tab-X / „Andere Tabs schließen"):** bei ungespeicherten Änderungen erscheint die BBEdit-Rückfrage **Sichern / Abbrechen / Nicht sichern**. „Abbrechen" lässt alles unverändert, „Nicht sichern" verwirft, „Sichern" schreibt (bzw. öffnet „Sichern unter…" bei unbenanntem Dokument) und schließt erst bei Erfolg — ein abgebrochenes Speichern-Panel hält den Tab offen, damit nichts verloren geht. Saubere Tabs schließen weiterhin ohne Rückfrage. Zentrale Logik `Workspace.closeTab` für alle drei Schließen-Wege.
- **App beenden (⌘Q):** beendet nicht mehr stillschweigend bei ungesicherten Tabs, sondern führt pro betroffenem Tab dieselbe Rückfrage (`applicationShouldTerminate` → `Workspace.confirmCloseAllDirtyForQuit`); „Abbrechen" bricht das Beenden ab. (Automatisches Speichern ohne Rückfrage wäre das riskantere Verhalten — bewusst die Rückfrage-Variante wie BBEdit-Default.)
- Die Modal-Entscheidung ist über `Workspace.confirmCloseHandler` injizierbar → der komplette Schließen-/Beenden-Pfad ist unit-getestet (+13 Tests, 534 gesamt grün), der Dialog selbst per GUI-Abnahme.

### BBEdit „Text"-Menü-Basics, Teil 4 (2026-06-25, v0.10.7)
> Quelle/Vergleich: BBEdit User Manual, Kap. 5 „Text Transformations". Drei weitere Transforms, schwerpunktmäßig die RegEx-nahen — passen besonders gut zum Fastra-Kern.
- **Zeilen mit Treffer behalten/löschen (BBEdit „Process Lines Containing"):** ein RegEx-basierter Zeilenfilter. „Nur Zeilen mit Treffer behalten" wirft alles weg, was das Muster NICHT enthält; „Zeilen mit Treffer löschen" entfernt die Treffer-Zeilen. Muster wird im Dialog abgefragt (RegEx, per Default Groß-/Kleinschreibung egal). Ein versehentlicher Voll-Wipe des Dokuments wird verhindert (würde der Filter alle Zeilen entfernen → kein Effekt, Beep). Neue pure Logik `LineFilter`.
- **Process Duplicate Lines (BBEdit „Process Duplicate Lines"):** zwei neue Modi neben dem bestehenden „Duplikate entfernen" (das je das erste Vorkommen behält) — „Nur doppelte Zeilen behalten" (zeigt jede mehrfach vorkommende Zeile einmal, in Reihenfolge des ersten Auftretens; macht Dubletten in Logs/Listen sichtbar) und „Mehrfach vorkommende Zeilen entfernen" (lässt nur die einmaligen Zeilen stehen). Sorgfältige Behandlung des Datei-End-Newlines (Phantom-Leerzeile zählt nicht als Inhalt).
- **Zeilen hart umbrechen (BBEdit „Hard Wrap"):** bricht jede Zeile greedy an Wortgrenzen auf eine im Dialog abgefragte Spaltenbreite (Default 72) um — das Gegenstück zu „Zeilen verbinden". Wörter werden nie zerschnitten (ein überlanges Einzelwort bleibt ungebrochen auf eigener Zeile); führende Einrückung bleibt an der ersten Zeile, Mehrfach-Whitespace zwischen Wörtern kollabiert zu einem Leerzeichen; CRLF und Datei-End-Newline bleiben erhalten.
- Alle drei pur, Undo-fähig, erreichbar im Menüleisten-„Text"-Menü UND im Editor-Rechtsklick-Submenü. +48 Unit-Tests (521 gesamt grün). Menü-Dispatch per Selbsttest `textop` belegt; parallel implementiert (3 Agenten) + adversarial reviewt (Befunde eingearbeitet: ein Process-Duplicate-Test mit falscher Erwartung, ein zu schwacher Hard-Wrap-Invarianten-Test, das `.+ERROR`-Muster eines Filter-Tests — alle korrigiert).

### Behoben (2026-06-25, v0.10.7)
- **Neuer Tab / Editor bekommt sofort den Tastaturfokus** (GUI-Abnahme-Befund): Nach ⌘T (sowie Tab-Wechsel / fertig geladener Datei) war die Editor-Textfläche nicht First Responder — ein direktes ⌘V verpuffte, bis man einmal in den Text klickte. Der frisch gemountete Editor fokussiert sich jetzt selbst (`EditorView.focusActiveEditor` in `.onAppear`), aber NUR wenn das Hauptfenster ohnehin Key ist → die schwebende Suchmaske behält bei offenem Suchfeld ihren Fokus (kein Fokus-Klau). Jump-Fokus-Pfade (Selbsttests `navmatch`/`jump`) unverändert grün, 521 Unit-Tests grün.

### BBEdit „Text"-Menü-Basics, Teil 3 (2026-06-25)
> Quelle/Vergleich: BBEdit User Manual 14.6.9, Kap. 5 „Text Transformations" — Semantik 1:1 übernommen.
- **Anführungszeichen schwungvoll (BBEdit „Educate Quotes"):** die kontextsensitive Umkehrung von „Straighten Quotes" — gerade `"`/`'` werden zu typografischen `“ ”` / `‘ ’`. Öffnend vs. schließend entscheidet sich am Zeichen DAVOR (Textanfang/Whitespace/öffnende Klammer → öffnend, sonst schließend); ein Apostroph mitten im Wort (don't, it's) wird korrekt zu `’`. Englischer Stil wie BBEdit; längenstabil, Emoji/Surrogatpaare bleiben unversehrt.
- **Zeichen tauschen / Wörter tauschen (BBEdit „Exchange Characters/Words"):** vertauscht zwei benachbarte Zeichen (bzw. Wörter) je nach Cursor/Selektion — der klassische „Buchstaben verdreht"-Fix. Vier Regeln wie BBEdit: Cursor mitten in der Zeile → links/rechts tauschen; am Zeilenanfang → die zwei folgenden; am Zeilenende → die zwei vorangehenden; bei Selektion → erstes und letztes Element. Arbeitet auf Graphem-Grenzen (Emoji bleiben heil), bewegt nie einen Zeilenumbruch.
- **Zeilennummern hinzufügen/entfernen (BBEdit „Add/Remove Line Numbers"):** stellt jeder Zeile ihre laufende Nummer voran (rechtsbündig auf die Breite der größten Nummer aufgefüllt, ein Trenner-Leerzeichen, Nummerierung relativ zum Block ab 1); Entfernen strippt einen führenden Nummern-Lauf (tolerant gegen fremd-nummerierte Dateien, Zeilen ohne Nummer bleiben stehen). CRLF bleibt erhalten.
- **Escape-Sequenzen auflösen (BBEdit „Convert Escape Sequences"):** ersetzt in einem Durchlauf `\n \r \t \f \\`, Hex (`\xNN`, `\x{…}`), Unicode (`\uNNNN`, `\u{…}`), HTML-Entities (numerisch vollständig, benannte kuratiert inkl. dt. Umlaute) und Prozent-Escapes (`%NN` als UTF-8-Bytefolge, mehrbyte-fähig). Malformte/unbekannte Sequenzen und ungültige Skalarwerte bleiben literal stehen — Texthygiene für Logs/4D-Exporte.
- Alle vier pur (`TextOperations`), Undo-fähig, erreichbar im Menüleisten-„Text"-Menü UND im Editor-Rechtsklick-Submenü. +53 Unit-Tests (473 gesamt grün).

### BBEdit „Text"-Menü-Basics, Teil 2 (2026-06-25)
> Quelle/Vergleich: BBEdit User Manual 14.6.9, Kap. 5 „Text Transformations" — Semantik 1:1 übernommen.
- **Steuerzeichen entfernen (BBEdit „Zap Gremlins"):** entfernt unsichtbare Steuerzeichen (C0-Bereich inkl. NUL sowie DEL) aus Selektion bzw. ganzer Datei — Tab, Zeilenumbruch und Wagenrücklauf bleiben erhalten. Texthygiene für Logs/4D-Exporte; arbeitet pro Unicode-Scalar (Emoji bleiben unversehrt).
- **Anführungszeichen gerade richten (BBEdit „Straighten Quotes"):** wandelt geschwungene Quotes (“ ” „ ‟ ‘ ’ ‚ ‛) in gerade `"` / `'` — gegen aus Word/Web kopierte Quotes, die CSV/JSON/SQL brechen.
- **Zeilen verbinden (BBEdit „Remove Line Breaks"):** zwei Varianten — „mit Leerzeichen" (Fließtext) und „ohne Trenner" (Daten-/Spalten-Zusammenzug). Ein abschließendes Datei-End-Newline wird geschluckt (kein Trenner am Ende), CRLF-Eingabe erzeugt kein verirrtes `\r`.
- Alle drei pur (`TextOperations`), Undo-fähig, erreichbar im Menüleisten-„Text"-Menü UND im Editor-Rechtsklick-Submenü. +13 Unit-Tests.

### Behoben (2026-06-25)
- **Absturz der inline Live-Vorschau bei Tab-/Datei-Wechsel:** Beim Wechsel auf einen kürzeren oder leeren Buffer rief die Live-Vorschau `ReplacePreview.build` kurz mit STALE Treffern (Ranges des alten Inhalts) gegen den neuen, kürzeren Text auf → `lineRange(for:)` lief out of bounds und die App stürzte ab. `ReplacePreview.build` filtert solche Treffer jetzt defensiv heraus (schützt auch das „Vorschau der Änderungen"-Sheet). +2 Regressions-Tests. **Gefunden per fenstergezieltem GUI-Screenshot-Test** (`-selftest wildcardshot`).
- **„PLATZHALTER"-Label brach in zwei Zeilen um** (breiter als die 80-pt-Label-Spalte, anders als „GRUPPEN") → eine Zeile erzwungen + bei Bedarf leicht skaliert.

### Suchdialog: Performance + Treffer-Navigation (RC-Abnahme, 2026-06-22)
- **Trefferliste virtualisiert (`List` statt nicht-lazy `VStack`):** Bei vielen Treffern (echter Fall: 36.905) rief jeder Treffer-Klick einen Neuaufbau ALLER bis zu 2000 Zeilen auf dem Main-Thread hervor → Beachball, träges CMD+W, träge Hauptfenster-Klicks (der geteilte Workspace re-rendert den offenen Dialog mit). `List` (NSTableView-backed) rendert nur sichtbare Zeilen und aktualisiert die aktive-Treffer-Markierung zuverlässig (anders als der früher problematische LazyVStack). `HitGroup` bekam eine stabile Identität (vorher `UUID()` pro Render).
- **Treffer-Sprung scrollt bei großen Dokumenten wieder hin:** Klick/CMD+G markierte den Treffer, scrollte aber nicht dorthin (41k-Zeilen-Datei). Ursache: CESEs `scrollSelectionToVisible()` läuft ins Leere, wenn die Ziel-Zeile noch nicht ausgelegt ist (boundingRect `.zero`). Fix app-seitig: nach dem Sprung über `scrollToRange` scrollen, Ziel aus der ZEILENNUMMER gerechnet (nicht aus der Selektion, die zum async-Zeitpunkt noch nicht gesetzt ist). Abgesichert durch neuen Selbsttest `scrolljump` (Sprung Zeile 1900 → Treffer im sichtbaren Bereich; prüft zugleich aufsteigende Trefferliste).
- **Bedeutungslose Scope-Zahlen entfernt:** Die Badges an „Datei/Geöffnet/Ordner" (8/51/51) waren hartcodierte Prototyp-Reste, an nichts gekoppelt — raus. Die echte Treffer-Zahl steht weiter bei „Treffer (N)".
- **Start ohne offenen Suchdialog:** `showSearchDialog` startet jetzt `false` (war Test-Default); CMD+F / CMD+SHIFT+F öffnen ihn. Die fenster-abhängigen Selbsttests (cmdw/fields/navmatch) öffnen die Maske selbst.

### Tab-Verhalten (RC-Abnahme, 2026-06-22)
- **Leeres Startdokument wird beim Datei-Öffnen abgeräumt (BBEdit-Verhalten):** Öffnet man eine Datei, während das leere unbenannte „Ohne Titel"-Dokument offen ist, verschwindet dieses jetzt — es ist wertlos. Getippter/„dirty" Inhalt bleibt dagegen IMMER erhalten. Pure Logik `Workspace.tabsRemovingEmptyScratch` + 8 Tests (inkl. loadFile-Integration).

### Editor-Fixes aus der RC-Abnahme (2026-06-22)
- **Gutter-Durchschuss behoben:** Die Zeilennummern-Spalte zeichnete über den oberen Rand des Editor-Bereichs hinaus ins Tab-/Header-Band (CESEs Gutter ist ein Floating-Subview, der ohne Clipping über seinen ScrollView hinausragt). Fix: `.clipped()` am Editor in `EditorView`. Der zunächst vermutete Titelleisten-Auto-Inset war NICHT die Ursache (der Überstand blieb mit `contentInsets = 0` unverändert); der 0-Inset bleibt dennoch als sinnvolle Konfig für den versteckten Titelleisten-Modus (keine Phantom-Polsterung über dem Text).
- **Drag-Selektion über die Gutter-Spalte repariert:** Schnelles Linksziehen über die Zeilennummern fror die Selektion ein, statt bis Spalte 1 zu wachsen. Ursache: CESEs `mouseDragged` clampt die Drag-Position auf `max(0, …)` — im Gutter-Inset-Bereich liefert `textOffsetAtPoint` dort `nil`, und das `guard … else { return }` bricht den Drag ab. Fix als sechster `build.sh`-Checkout-Patch (CodeEditTextView): Clamp auf `max(layoutManager.edgeInsets.left, …)` → der Punkt mappt auf den Zeilenanfang statt nil. (Maus-Interaktion, nicht unit-testbar — per echtem Drag verifiziert.)

### Feature J (Platzhalter-Suche `*`) — Schritt 1 (2026-06-22)
- **Pure Übersetzungslogik `WildcardPattern`** (`*` → gierige Gruppe `(.+)` auf der Such-Seite, `$N` auf der Ersetzen-Seite; alles andere wörtlich via `escapedPattern`/`escapedTemplate`) + 21 Tests. **Noch NICHT in die Such-Engines verdrahtet** — `*` wird in der App weiterhin wörtlich gesucht; das Anschließen (inkl. Mini-Schalter „`*` wörtlich nehmen") ist Schritt 2.

### Feature J (Platzhalter-Suche `*`) — Pillen + Live-Vorschau (2026-06-24)
- **Platzhalter-Pillen:** Im Plain-Modus mit `*` zeigt der Suchdialog jetzt eine `PLATZHALTER`-Zeile mit einer nummerierten Pille `$1…$N` pro Stern — dieselbe Low-Friction-Mechanik wie die Capture-Group-Pillen: aufs Ersetzen-Feld ziehen ODER anklicken fügt `$N` ein. (`wildcardGroupsRow` + `WildcardPill` in `FloatingSearchDialog`, Wiederverwendung von `RegexFieldTextView`-Drop + `replaceFieldController`.)
- **Inline Live-Vorschau Vorher→Nachher:** Direkt unter den Feldern erscheint beim Tippen ein kompakter Vorher→Nachher-Streifen (erste 3 betroffene Zeilen + „… und N weitere") — in den Buffer-Scopes, sobald Ersetzen-Text und Treffer da sind. Wiederverwendung der getesteten `ReplacePreview.build`-Logik (gleiche Quelle wie das große „Vorschau der Änderungen"-Sheet); live korrekt, weil `replacePattern` ein Such-Trigger ist.
- **Aus dem Multi-Agent-Review:** `ReplacePreview.Row` bekommt eine stabile Identität (Zeilennummer statt frischer `UUID()` je `build` → kein ForEach-Identitäts-Flackern bei der live mittippenden Vorschau — dieselbe Falle wie früher bei `HitGroup`). Die Pillen-Zeile bleibt textfrei wie ihr RegEx-Pendant `groupsRow`.
- 405 Unit-Tests grün; Selbsttest `wildcard` um den End-to-End-`replacedText`-Check erweitert (`The *` → „The ring"), `pilldrop`/`replaceall`/`fields` weiter PASS.

---

## [v0.9] — 2026-06-11 (Release Candidate)

### Empty States + Kontrast-Fixes (2026-06-11, v0.8-Rest/v0.9)
- **Leer-Zustände gestaltet:** Hinweis im leeren Editor („Datei öffnen (⌘O), Text eingeben oder Datei hierher ziehen“, nicht-interaktives Overlay), Platzhalter für leere Markdown-Vorschau, „Kein Treffer ausgewählt.“ im Treffer-Detail, Ordner-Scope-„Keine Treffer“ vom Datei-Scope unterscheidbar.
- **Footer zeigt echte Daten:** Der seit der Prototyp-Phase hardcodierte Demo-Text („51 Treffer · 4 Dateien“ / „Multi-File“) ist durch echte Treffer-/Datei-Zahlen je Scope ersetzt (pure `FooterLogic.searchSummary`, 6 neue Tests — 285 gesamt).
- **Kontrast:** Neues Theme-Token `accentReadable` (dunkles Bernstein, ~4:1 auf Weiß) für kleine Akzente (Icons, Strokes, Dirty-Punkt, Indikator) — das helle Goldgelb hatte dort nur ~1,4:1, bleibt aber als Flächen-/Button-Farbe erhalten (Branding). Pill-Kontur auf neutrales Grau.

### Asynchrones Datei-Laden ohne UI-Block (2026-06-11, v0.9)
- Datei-I/O + Encoding-/Line-Ending-Erkennung laufen im Hintergrund (`FileLoader` + `Task.detached`); der Tab erscheint sofort mit Lade-Spinner, die UI bleibt bedienbar. Generation-Guard verhindert Races (Tab schließen/erneut laden während des Ladens). Treffer-Sprung nach Datei-Wechsel wartet jetzt auf die Lade-Completion (behebt latentes Race).
- Messung (`-selftest loadperf`, Debug-Build): 10/50/100 MB → größte Main-Thread-Lücke 48/54/50 ms (Akzeptanz: < 250 ms). Bekannte Grenze: das Einsetzen des Inhalts in den Editor (CESE-Mount) blockiert weiterhin proportional zur Dateigröße — laut Scope-Entscheidung akzeptiert, Chunk-Loading ist v1.1+.

### Selbsttest-Infrastruktur repariert — „kein Hauptfenster"-Bug gelöst (2026-06-11)
- **Root Cause:** AppKit interpretiert unbekannte POSITIONALE Argumente (`--selftest-…`) als „zu öffnende Datei" — SwiftUI erzeugt dann nie das WindowGroup-Hauptfenster (App startet fensterlos, Main-Thread idle). Früher kaschierte die Fenster-Restauration aus dem Saved State das Problem; die `-ApplePersistenceIgnoreState YES`-Konvention legte es frei. Der Code der v0.7/v0.8-Etappen war unschuldig.
- **Fix:** Selbsttest-Auswahl jetzt via `-selftest <name>` (NSArgumentDomain) oder Umgebungsvariable `FASTRA_SELFTEST=<name>`; die alte Aufrufform wird erkannt und FAILt sofort mit Migrations-Hinweis. Fensterbasierte Tests POLLEN bis 15 s auf ihr Fenster (statt 2-s-Guard) und liefern bei Timeout einen Fenster-Dump.
- **Neu: `selftest.sh`** — Runner für alle In-App-Selbsttests; kapselt sämtliche Umgebungs-Fallen (Persistence-Flag, Bildschirm-Lock-Check, externe Aktivierung für den fokus-pflichtigen cmdw-Test) und liefert agententaugliche Exit-Codes (0 = PASS, 1 = echter FAIL, 2 = nur Umgebungs-FAILs).
- **Neu: `-selftest windows`** — Diagnose-Dump aller NSApp.windows über 10 s (das Messinstrument, das den Root Cause fand).

### Weitere Befunde aus der GUI-Verifikation (2026-06-11)
- Doppeltes „Darstellung"-Menü beseitigt — Markdown-Vorschau hängt jetzt im System-View-Menü (`CommandGroup(after: .sidebar)`).
- Demo-Erststart startet im Datei-Scope: neue Nutzer sehen sofort die Demo-Treffer statt „Kein Ordner ausgewählt.".
- Selbsttest-Defaults-Leak geschlossen: `recentSearchFolders` lief an der injizierten Suite vorbei hart über `.standard` — Selbsttests müllten Temp-Ordner in die echte Ordnerliste.
- DonationPrompt-Test-Flaky deterministisch gefixt (Double-Rundung beim Epochen-Wechsel von `timeIntervalSince1970`, isoliert gemessen).
- Verifikation: 285/285 Unit-Tests (6 Läufe), Selbsttest-Suite 8/8 PASS (4 Läufe, 0 Flakes), release.sh-ad-hoc-DMG real gebaut und gemountet.

---

## [v0.8] — 2026-06-11

### Phase 5 — Markdown, Editor-Extras, Polish (Sprint-Etappe 3)
- **Markdown-Vorschau** (⌘⇧M): Read-only-Fenster via swift-markdown-ui 2.4.1 (GFM, `.gitHub`-Theme), folgt dem aktiven Tab live.
- **Smart-Paste** (⌘⇧V): formatierter Clipboard-Inhalt wird über das installierte `md-clip`-CLI (stdout-Modus, GPL-sauber) als Markdown eingefügt; saubere Degradation mit Installations-Hinweis.
- **„Über Fastra"-Dialog** mit Version aus dem Bundle; ersetzt das Standard-About.
- **Donation-Banner** (dezent, über dem Footer): ab dem 10. Start, 90 Tage Ruhe nach „Später"; pure `DonationPrompt`-Logik mit Tests.
- **Editor-Kontextmenü**: Zeilen sortieren, Duplikate entfernen, Smart-Paste — Undo-fähig über `TextView.replaceCharacters` (pure `LineOperations`, 14 Tests).
- Entschieden → v1.1: Rectangle Selection, Gutter-Dimmen (Begründungen in `_log/decisions.md`).

---

## [v0.7] — 2026-06-11

### Phase 3 — Drag & Drop Capture Groups (Sprint-Etappe 2)
- **RegexTokenizer**: tree-sitter-regex 0.25.0 via SwiftTreeSitter → flache Token-Liste (Anker/Klasse/Quantifier/Literal/Gruppe …) mit UTF-16-Ranges + Capture-Group-Struktur; pure Logik mit ~55 Tests.
- **Inline-Token-Highlighting** im Find-Feld: NSTextView-basiertes `RegexFieldView` färbt Tokens direkt im `textStorage` (kein Cursor-Sprung); bei RegEx=aus keine Färbung.
- **Capture-Group-Pills live** aus der Tokenisierung; Drag liefert `$N` ins Replace-Feld (Drop an Caret-Position), Klick fügt ein.
- **Geführte Gruppen-Definition** am Treffer-Detail: Selektion snappt auf Token-Grenzen (`GroupBuilder.propose`), App setzt `(…)` im Pattern; „Gruppe löschen" via `GroupRemoval`; Verweigerung beept statt still zu ändern.
- **Gruppen-Visualisierung** (Hybrid): farbige Pills + farbige Beitrags-Hinterlegung der Gruppen im Treffer-Detail (Re-Match-Ranges, `SelectableMatchText`).

---

## [v0.6] — 2026-06-11

Phase 4: echte RegEx-Suche (aktiver Buffer + Ordner), Apply-Engine mit
Undo-Backup, Navigations-Shortcuts — plus die am 2026-06-03 gemeldeten
Bugfixes. (Frühe v0.6-Detail-Historie steht teils noch unter [v0.5] unten:
Der Changelog wurde damals nicht getrennt, die Versions-Trennung kam erst
am 2026-06-03. Code-Wahrheit: alles ab Commit nach `v0.5`-Tag ist v0.6.)

### Phase 4 — Suche, Navigation, Apply
- **Echte Buffer-Suche** auf dem aktiven Tab (`BufferSearch`, debounced via `SearchRunner` 120 ms): Treffer mit Range/Zeile/Spalte/Ersetzungstext. Trefferliste, Counter, Detail-Bereich, „Alle ersetzen" live. Roter Fehlerstreifen mit `NSRegularExpression`-Meldung bei kaputtem Pattern.
- **Ordner-Suche** (`FolderSearch` + `Task.detached`): Treffer pro Datei, Click/CMD+G öffnet die Ziel-Datei automatisch. Recent-Folders-Persistenz (UserDefaults), Dateityp-Filter (~40 Textformate), Binärdatei-Schutz (BOM vor Null-Byte-Heuristik).
- **Navigation:** CMD+G / CMD+SHIFT+G (Treffer vor/zurück, Wrap-around), CMD+J Zu-Zeile-Springen (`GotoLineParse`, versteht `42` und `42:8`).
- **Apply-Sicherheits-Gate** (`ApplyEngine`): Dry-Run-`plan(...)` ohne Datei-Zugriff; Schreibseite atomar via `FileManager.replaceItemAt` mit SHA-256-Backup unter `~/Library/Application Support/Fastra/undo/`, bit-exaktes `undo(_:)`, Auto-Cleanup > 30 Tage. Folder-Apply mit > 200 MB-Schwellen-Warnung + „Rückgängig". 20 dedizierte Tests.

### Find-Panel-Aufblitzen — deterministisch beseitigt (2026-06-03)
- Bei schnellem CMD+F (Editor fokussiert) blitzte das Editor-Find-Panel manchmal kurz auf, bevor die Reconciliation es schloss. Der Monitor-Reinstall-auf-flagsChanged half nur „meistens" (Race-Condition). **Finaler Fix:** `build.sh` patcht den resolved CodeEditSourceEditor-Checkout so, dass dessen CMD+F-Handler das Panel gar nicht erst öffnet (`showFindPanel()` → `return event`). CMD+F geht ausschließlich an unsere Suchmaske — Aufblitzen unmöglich, unabhängig von der Monitor-Reihenfolge. Reconciliation + Monitor-Reinstall bleiben als Sicherheitsnetz. `--selftest-findbar` pollt jetzt ~1,2 s auf transientes Aufblitzen. (Doku: LESSONS-LEARNED F.9, CLAUDE.md → QA-Strategie.)

### Such-Eingabefelder editierbar + Datei-Drag&Drop (2026-06-03)
- **Find-Feld endlich tippbar:** war ein statisches `Text` mit fest verdrahtetem E-Mail-Demo-Highlight (ignorierte die echte Eingabe komplett) → echtes `TextField`. Das Replace-Feld war nie kaputt; der gemeldete „nicht änderbar"-Befund war Verwechslung mit dem toten Find-Feld daneben (per neuem `--selftest-fields` belegt — prüft beide Felder real auf Editierbarkeit + Tastatureingabe). Inline-Token-Highlighting (tree-sitter) bleibt v0.7.
- **Datei-Drag&Drop in den Editor:** Datei(en) auf den Editor ziehen lädt sie in Tabs (`DropHandling` pur + `onDrop`, Akzent-Rahmen als Feedback). 5 `DropHandlingTests`. (Nicht zu verwechseln mit dem Capture-Group-DnD ins Replace-Feld → v0.7.)
- **Editor-Inhalt beim Tab-Wechsel:** behob latenten Bug (Drop legte Tab an, zeigte aber alten Inhalt) — CodeEditSourceEditor setzt seinen Text nur einmal in `makeNSViewController` und schiebt Binding-Änderungen nicht zurück. Fix: SourceEditor per `.id(activeTab.id)` an die Tab-ID koppeln → Neuerzeugung beim Tab-Wechsel lädt den neuen Inhalt (galt auch für Folder-Treffer-Klicks). Regressions-Test `--selftest-tabswitch`.
- **„Ordner hinzufügen…":** toter Button verdrahtet — NSOpenPanel mit Mehrfach-Auswahl, neue Ordner landen oben + aktiviert, dedupliziert (`Workspace.prependingFolders`, 5 `FolderAddTests`).
- Info.plist-Version 0.1.0 (verwaist) → 0.6.0.

### Plain-Text-Modus: Replace-String jetzt wirklich literal (2026-06-03)
- **Latenter Bug:** Bei abgeschaltetem RegEx-Modus war die Find-Seite korrekt literal (escapt via `buildRegex`), die **Replace-Seite aber nicht** — `BufferSearch.find` und `ApplyEngine.planSingle` reichten den Replace-String immer als RegEx-Template an `NSRegularExpression.replacementString`. Ein Plain-Text-Replace wie `$5.00` oder `C:\neu` wurde als (leerer) Backref bzw. Escape-Sequenz gedeutet — Datenverfälschung, die dem dokumentierten `SearchOptions.replace`-Vertrag widersprach.
- **Fix:** zentraler `ApplyEngine.replacementTemplate(for:)` — RegEx-Modus reicht roh durch, Plain-Modus neutralisiert `$`/`\` via `NSRegularExpression.escapedTemplate`. Beide Such-Pfade nutzen ihn (Single Source). 5 neue Tests (`BufferSearchTests`, `ApplySafetyTests`), 126/126 grün.

### Sprint-Etappe 1 — v0.6-Abschluss (2026-06-11, Branch `sprint_to_v1`)
- **Gesamt-Treffer-Cap für die Ordner-Suche** (Freeze-Schutz): `FolderSearch.find` bricht dateiübergreifend sauber ab, sobald 10.000 Treffer erreicht sind — keine weiteren Dateien werden gelesen. Kein silent truncation: oranger Hinweis-Streifen in der Maske („Trefferliste auf 10.000 gekappt — Suchbegriff verfeinern."). 3 neue FolderSearchTests.
- **`--selftest-search`** (neu): treibt Workspace + SearchRunner End-to-End — Buffer-Scope (bekannter Text, Treffer-Anzahl + Zeile/Spalte des ersten Treffers), Live-Ordner (echter Temp-Ordner, Debounce-Polling, `folderTotalMatches`) und Negativ-Pfad. Fängt die „0 Treffer trotz vorhandener"-Klasse, die reine Unit-Tests nicht sehen.
- **`--selftest-contrast`** (neu): Weiß-auf-weiß-Wächter — sammelt alle `NSTextField` in Such- und Hauptfenster ein und prüft Textfarbe gegen effektiven Hintergrund (WCAG-Luminanz, Schwelle 2.0). FAIL bei 0 geprüften Feldern (Test-Selbstschutz). Grenze: SwiftUI-`Text`-Views bridgen nicht immer zu `NSTextField` — der Test fängt primär die Eingabefeld-Klasse des ursprünglichen Dark-Mode-Bugs.
- **Demo-Inhalt nur noch beim ersten Start:** `DemoData.consumeFirstLaunch` (UserDefaults-Flag) — der allererste Start lädt wie bisher Demo-Tab + vorbelegtes E-Mail-Pattern (Interview-Erkenntnis 4: leerer Start verhindert Einstieg), jeder weitere Start beginnt mit leerem unbenanntem Tab ohne Pattern. Selbsttest-Läufe nutzen eine isolierte, pro Lauf geleerte UserDefaults-Suite — deterministisch UND ohne das echte Erststart-Flag zu verbrauchen. 3 neue FirstLaunchTests.
- **Gutter-Dimmen → v1.1 verschoben:** `GutterView.backgroundColor` ist in CodeEditSourceEditor `internal`; ein sechster Checkout-Patch für einen Nice-to-have wäre unverhältnismäßig (Entscheidung in `_log/decisions.md`).

### `--selftest-cmdw` entflaked (2026-06-04)
- Der CMD+W-Schließen-Selbsttest schlug sporadisch fehl (häufiger im Release). Ursache war nicht die Funktion — CMD+W schließt die Suchmaske zuverlässig — sondern der Test selbst: er prüfte den Fenster-Zustand EINMAL nach fixen 0,6 s. Schloss das Fenster geringfügig später, gab es einen falschen FAIL. Fix wie beim Findbar-Test: App via `NSApp.activate` nach vorn holen (CMD+W routet nur ans Key-Window) und über ~1,5 s engmaschig pollen (`pollForClose`) — PASS, sobald das Fenster unsichtbar wird. Verifiziert: 12/12 PASS (alle Tick 1, schließt < 30 ms), übrige Selbsttests weiter grün.

---

## [v0.5] — 2026-05-27

Etappe „Suchmasken-Konzept umsetzen: Datenstruktur + Vorlagen". (Der
Abschnitt „v0.6-Vorbereitung — Apply-Sicherheits-Gerüst" weiter unten
gehört streng genommen schon zu v0.6 — historisch hier protokolliert.)

### Behoben
- **Zombie-Find-Bar bei CMD+F (deterministisch behoben):** Der „Zombie" ist CodeEditSourceEditors eigenes Find-Panel (interner keyDown-Monitor bei fokussiertem Editor). Die Reihenfolge konkurrierender NSEvent-Monitore ist nicht zuverlässig steuerbar. Fix: Wir beobachten `editorState.findPanelVisible` (vom Editor zurückgeschrieben) — wird es `true`, setzen wir es sofort `false` (Panel schließt) und öffnen stattdessen unsere Suchmaske. Verworfen: NSApplication-Subclassing zur sendEvent-Interception (ersetzt unter SwiftUI die interne `AppKitApplication` → ganze App maus-tot) und Monitor-Reihenfolge-Tricks (flaky).
- Neuer In-App-Selbsttest `Fastra --selftest-findbar` (`SelfTest.swift`): postet echtes CMD+F im laufenden App-Prozess und prüft, ob das Editor-Find-Panel auftaucht. Fängt genau die App-weite Event-Bug-Klasse, die reine Unit-Tests nicht abdecken.

### Element-Picker
- `[+]`-Button neben dem Find-Feld öffnet ein Popover mit kategorisierten RegEx-Bausteinen (Anker · Zeichenklassen · Zeichengruppen · Quantifizierer · Gruppen), jeder mit Klartext-Hinweis. Auswahl hängt den Token ans Find-Pattern an. Pure Daten in `RegexElements`, abgedeckt durch `RegexElementsTests` (keine leeren Felder, eindeutige Symbole, einfügbare Token kompilieren). Inline-Autocomplete (`\` `[` `(`) folgt später.
- Popover-Lesbarkeit: Symbole in lesbarem Blau (statt Gelb) auf opakem Hintergrund.

### Footer (Cursor & Statistik)
- Cursor-Position live im Footer: Label kompakt „Z … · Sp …". Bei Selektion wird die *bewegte* Kante (am Mauszeiger) gezeigt — über eine Anker-Heuristik, da `CursorPosition` keine Zieh-Richtung liefert. Aktualisiert dynamisch beim Ziehen in beide Richtungen.
- Footer wird gedimmt (45 % Deckkraft), wenn das Hauptfenster nicht vorn ist (Suchmaske/andere App) — statt Inhalte auszublenden (BBEdit-Verhalten). Editor behält seine Cursor-Position.
- Footer-Statistik (Zeichen/Wörter/Zeilen) bezieht sich auf die Selektion, falls eine besteht, sonst auf die ganze Datei (mit „Sel"-Marker). Berechnung läuft asynchron auf einem Hintergrund-Thread (Generation-Token verwirft veraltete Ergebnisse) — blockiert große Dateien nicht.

### Regressions-Schutz (Tests)
- Shortcut-Routing in reine, getestete Funktion `KeyRouting.route` extrahiert — `sendEvent` UND der Fallback-Monitor nutzen dieselbe Logik (keine Divergenz mehr).
- Footer-Logik (bewegte Kante, Statistik) in pure Helfer `CursorFooter` / `DocumentStats` extrahiert.
- Find-Bar-Abwehr (`disableFindBars`, `purge`, `isFindRelated`) testbar gemacht.
- Neue Test-Suites `KeyRoutingTests`, `FooterLogicTests`, `FindBarSuppressionTests` — Gesamtsuite 30 Tests, < 0,1 s.
- Manuelle Smoke-Checkliste + Root-Cause in `AGENTS.md` (Abschnitt QA-Strategie) dokumentiert.

### Hinzugefügt
- `Patterns/Pattern.swift` — `PatternTemplate`-Datenstruktur mit `PatternCategory`, `groupLabels`, `defaultReplacement`.
- `Patterns/BuiltInPatterns.swift` — 16 kuratierte RegEx-Vorlagen in 4 Kategorien (Identifikatoren, Datum & Zeit, Text-Strukturen, Zahlen) inkl. Dateipfad-Trennung (Ordner + Dateiname).
- `Tests/FastraTests/PatternTests.swift` — Swift-Testing-Suite mit 7 Test-Suites: Compile-Check, Example-Match, Group-Label-Konsistenz, ID-Eindeutigkeit, Replacement-Ref-Validität, Kategorie-Filter-Konsistenz. ~50 Test-Cases, < 5 ms.
- Test-Target `FastraTests` in `Package.swift`.
- Detail-Spezifikation des Suchmasken-Konzepts (Element-Picker hybrid, Vorlagen-Strategie offen, Debounce-Werte, Detail-Bereich fest unten) im PM-Dokument festgeschrieben.
- Test-Policy in `AGENTS.md`: selbstständige Test-Initiative, Manuell-Tests aktiv anstoßen, Automatisierung im Rahmen ohne Rückfrage.

### Geändert
- `build.sh` SwiftLint-Plugin-Patch für CodeEditSourceEditor von sed auf perl umgestellt — das sed-Multiline-Pattern brach unter macOS mit neuerer CESE-Version. Perl-Variante ist robuster.
- Git-Tags für v0.1, v0.2, v0.3 nachträglich auf die korrekten Commits gesetzt (CHANGELOG-konform).

### Suchmasken-Layout (Grobschnitt, statisch — Logik in v0.6/v0.7)
- Vollständiges Maskenlayout in SwiftUI: Vorlage-Dropdown (immer aktiv, aktiviert RegEx automatisch), Suchbereich-Pills mit Tooltips, Find-Feld mit Token-Highlighting + Element-Picker-Stub, Such-Optionen-Toggle-Zeile (RegEx / Groß=klein / Ganzes Wort / Wrap-around), Replace-Feld, Capture-Group-Pills, Sofort-Trefferliste mit Datei-Gruppierung, „Treffer kopieren"-Button, Pfeil-Navigation, Treffer-Detail mit farbigen Group-Highlights, Action-Zeile (Abbrechen · Vorschau der Änderungen · Alle ersetzen).
- Suchmaske als eigenes normales NSWindow (kein Floating-Panel) via `SearchPanelController`. Hauptfenster bleibt bedienbar. Position und Größe persistieren via `setFrameAutosaveName`.
- Wachsende Maske: Bei Scope „Ordner" klappt animiert ein Bereich mit Recent-Folders-Liste auf (Checkbox + Minus-Button), „Ordner hinzufügen…", Dateityp-Filter („Bekannte Textformate" / „Alle Dateien"). Bei „Datei"/"Geöffnet" bleibt kompakt.
- Mindestgrößen knapp gehalten: kompakt 424 px (~3 Treffer), Ordner 624 px (~4 Treffer), Breite ≥ 640 px. Window wächst beim Scope-Wechsel automatisch, schrumpft nie. On-Screen-Validierung schützt gegen Off-Screen-Frames aus Multi-Monitor-Setups.
- Diff-Panel aus dem Hauptfenster entfernt — Editor nimmt 100 % ein. Wiederkehr in v0.9/v1.1+.

### Tastatur
- CMD+F öffnet im Datei-Modus, CMD+SHIFT+F im Ordner-Modus, ESC blendet aus.
- **CMD+W** schließt die Suchmaske, wenn sie vorn ist (sonst schließt es wie gewohnt den aktiven Tab). Routing in `KeyRouting`, abgedeckt durch Unit-Test + In-App-Selbsttest `--selftest-cmdw`.

### v0.6-Vorbereitung — Apply-Sicherheits-Gerüst
- `FileScanner.isBinary` / `isBinaryFile` — Null-Byte-Heuristik (8000-Byte-Fenster wie Git) für den Binär-Schutz; liest nur den Dateianfang.
- Reproduzierbarer Test-Korpus (`Tests/FastraTests/Support/TestCorpus.swift`): 10 Dateien mit verschiedenen Encodings (UTF-8, Latin-1, UTF-16LE+BOM, Win-1252), Line-Endings (LF/CRLF/CR), leer und 2 Binärdateien.
- `ApplySafetyTests`: grüne Bausteine (Binär-Erkennung inkl. dokumentiertem UTF-16-Sonderfall, Line-Ending-Erkennung, Korpus-Integrität) plus `withKnownIssue`-Markierung für das noch offene Apply-Gate (Dry-Run, Byte-Vergleich, mtime-Unverändertheit, atomare Writes, bit-exaktes Undo). Noch KEIN Apply-Code.
- **Apply-Engine Dry-Run-Stufe** (`Sources/Fastra/ApplyEngine.swift`): pure `ApplyEngine.plan(files:options:)`-Funktion, die Such-/Ersetzen-Pläne berechnet OHNE eine einzige Datei zu verändern. Modell-Typen: `SearchOptions`, `ReplacePlan`, `PlannedFileChange`, `PlannedMatch`, `SkipReason`. Encoding bleibt erhalten (BOM-Erkennung vor Null-Byte-Heuristik → UTF-16 wird nicht fälschlich als binär verworfen). Binärdateien landen als `.binary`-Skip im Plan, niemals stillschweigend. Ungültige RegEx → alle Dateien `.invalidPattern`, kein Apply möglich.
- 12 neue Dry-Run-Tests in `ApplySafetyTests`: mtime-Unverändertheit, Treffer-Vollständigkeit, Binär-Skip, UTF-16-Round-Trip mit BOM, Latin-1-Byte-Erhalt, Leere-Datei-Idempotenz, CRLF-Erhalt, Plain-Text-Meta-Escape, ungültige RegEx, Case-Sensitivity, Whole-Word, Capture-Backref-Auflösung.
- **Apply-Engine Schreibseite + Undo**: `ApplyEngine.apply(plan:backupRoot:cleanupOlderThan:)` schreibt pro Datei atomar via `FileManager.replaceItemAt(_:withItemAt:)`. Vor jedem Apply wandern die Original-Bytes ALLER zu verändernden Dateien in einen Session-Ordner unter `~/Library/Application Support/Fastra/undo/session-<ISO-ts>-<uuid8>/` — schlägt der Backup-Schritt fehl, wird nichts geschrieben. Manifest (`manifest.json`) mit SHA-256-Hash jeder Original-Datei. `ApplyEngine.undo(_:)` spielt das Backup atomar zurück (Hash-Check vor Restore). `ApplyEngine.cleanupBackups(maxAge:)` läuft automatisch vor jedem Apply und löscht Session-Ordner älter als 30 Tage (konfigurierbar). Fremde Dateien im Backup-Root bleiben unangetastet.
- 8 Schreib-/Undo-Tests in `ApplySafetyTests`: newBytes werden geschrieben, Backup enthält Original-Bytes mit korrektem Hash, bit-exaktes Undo über mehrere Dateien, fremde Dateien unverändert (Inhalt + mtime), Plan mit invalidPattern wird abgelehnt, Manifest-Round-Trip, Cleanup entfernt alte Sessions ohne fremde Ordner anzufassen, keine Temp-Datei-Leichen neben Originalen. Gesamtsuite 60/60 grün, <0,1 s.
- CMD+F-Routing über NSApplication-Subklasse `FastraApplication`, die `sendEvent` überschreibt — vor jeder Key-Equivalent-Verarbeitung. Beendet einen langen Eskalations-Pfad (Local-Monitor → Find-Menü-Purge → NSTextView-Find-Bar deaktivieren → schließlich NSApp-Subklasse).
- `CommandGroup(replacing: .textEditing) { }` plus aktive Bereinigung der Edit-Menü-Hierarchie um find-bezogene Selektoren (`performTextFinderAction:`, `performFindPanelAction:`).

### Build
- `Fastra.app`-Bundle aus `build.sh` heraus — Menüleiste funktioniert (CMD-Shortcuts mussten sonst durchs Terminal).
- `build.sh` killt laufende Fastra-Instanz vor dem Build (verhindert halb-überschriebene Binaries).

### Geändert
- „Groß-/Kleinschreibung" → „Groß = klein" (kompakter Label, Bedeutung invertiert via abgeleitetem Binding, Tooltip erklärt).
- Alle Optionen-Toggles mit `.fixedSize(horizontal: true)` gegen mehrzeiligen Umbruch.

### Offen in v0.5 (Implementierung)
- Element-Picker als Popover-Komponente (`[+]`-Button neben Find-Feld).
- Token-Snap-Logik (Mapping Detail-Selektion → RegEx-Tokens) — Knochenarbeit.
- Cursor-Position im Footer durchreichen.
- Demo-Inhalt / Beispiel-Pattern beim ersten Start.

### Maskenlayout-Grobschnitt
- `FloatingSearchDialog` jetzt mit allen statischen Bausteinen aus dem Konzept: Vorlage-Dropdown (immer aktiv, schaltet RegEx automatisch ein), Such-Optionen-Toggle-Zeile mit Tooltips, Trefferliste mit Datei-Gruppierung, Treffer-Detail-Bereich mit farbigen Group-Highlights.
- **Wachsende Maske:** Bei Scope „Ordner" klappt animiert ein Bereich mit Recent-Folders-Liste (Checkbox + Minus-Button), „Ordner hinzufügen…"-Button und Dateityp-Filter („Bekannte Textformate" / „Alle Dateien") auf. Bei „Datei" und „Geöffnet" bleibt die Maske kompakt.
- **Draggable Floating Panel** via `NSPanel` mit `.nonactivatingPanel`-Style — Hauptfenster bleibt während der Suche bedienbar.
- **„Treffer kopieren"-Button** (Clipboard-Icon) links der Navigations-Pfeile: alle Treffer LF-getrennt ins Clipboard. Roh, ohne Dedup. Voller Extrahieren-Dialog auf v1.1+.
- **„Projekt"-Scope aus v1.0 entfernt** (Variante B): Definition noch offen, kommt in v1.1+ zurück. Nur noch drei Tabs: Datei / Geöffnet / Ordner.

### Geändert
- **Vorschau der Änderungen** (vormals „Preview"-Button) als Stub stehen gelassen — die ausgewachsene Side-by-side-Diff-Implementierung verschoben auf v0.9 oder v1.1+, weil die Sofort-Trefferliste in der Maske den primären Bedarf weitgehend erfüllt. Entscheidung über endgültigen Verbleib des Buttons nach Nutzer-Feedback.

### Konzept-Erweiterungen (Daniel, 2026-05-26)
- Such-Optionen als BBEdit-Stil-Toggles in der Suchmaske (Abschnitt B.5 im Suchmasken-Konzept). **Default `RegEx = aus`** — Haltung: „Editor mit RegEx-Superkraft", nicht „RegEx-Tool, das auch suchen kann".
- Tooltips für **alle** Schalter, deutsch formuliert.
- BBEdit als Referenz-Editor bei UI-Zweifeln (`AGENTS.md`/Zusammenarbeit).
- Wettbewerbs-Positionierungs-Tabelle in `AGENTS.md`: drei Alleinstellungen identifiziert (geführte Capture-Group-Def, Capture-Group-DnD, Markdown Smart-Paste).

---

## [v0.4] — 2026-05-26

Etappe „Projektdoku konsolidiert, Suchmasken-Konzept gestartet".

### Hinzugefügt
- `Produktmanagement/Suchmasken-Konzept-v1.0.md` — verdichtete PM-Beschreibung des erweiterten Suchmasken-Konzepts (Element-Dropdowns, Vorlagen-Picker, Sofort-Treffer in der Maske, Treffer-Detail-Bereich mit Token-Snap für Capture-Group-Definition).
- `CHANGELOG.md` (diese Datei).
- Versions-Header in `AGENTS.md`.
- Selbstständige Versionierungs- und Auto-Commit-Policy in `AGENTS.md`.
- Abschnitte „Brand & Visuelles", „Funktionsumfang v1.0", „Daten-Fluss", „v1.1+ Roadmap", „QA-Strategie", „Monetarisierung" in `AGENTS.md` (zuvor nur im Blueprint).

### Geändert
- Tone of Voice präzisiert: dezenter Humor nur in Name, Icon und ggf. Über-Dialog — nicht in der normalen GUI.
- Dark Mode auf v1.1+ verschoben, kein eigenes Akzentfarben-System für v1.0 (System-Accent reicht).
- Designentscheidungen „On-demand Preview als Default" und „Inline-Gruppen-Highlighting statt Tray" wieder auf „offen" gesetzt — hängen am Suchmasken-Konzept.
- Phasen-Tabelle um Scope-Spalte erweitert.
- Todos neu nach Versionen `v0.5` bis `v1.0` einsortiert.

### Entfernt
- `Fastra_Blueprint_V2.md` aus dem Root — nach `Archiv/Fastra_Blueprint_V2-archiviert.md` verschoben. Inhalte vollständig in `AGENTS.md` überführt.
- Interne Marketing-Notiz — passt nicht zum gewünschten seriösen Tone.
- Gold-Gelb-Akzent als Pflicht-Designtoken.
- `CLAUDE.md` aus dem Root (war bereits gelöscht, jetzt im Commit nachgezogen).

---

## [v0.3] — 2026-05-22

Etappe „AGENTS.md als agent-agnostische Single Source of Truth".

### Hinzugefügt
- `AGENTS.md` als zentrales Projektdokument für Tech-Stack, DNA, Roadmap und Erkenntnisse — modell- und agent-unabhängig.

### Commit-Referenz
- `442ad7a` — docs: add AGENTS.md as agent-agnostic single source of truth

---

## [v0.2] — 2026-05-21

Etappe „Nutzer-Research und Zielgruppen-Update".

### Hinzugefügt
- Nutzerinterviews in ein einheitliches Format migriert.
- Zielgruppen-Analyse und Discovery-Dokumente aktualisiert.

### Commit-Referenz
- `a25addc` — feat: migrate user interviews + update target-group docs

---

## [v0.1] — 2026-05-21

Initiale Etappe.

### Hinzugefügt
- Projekt-Baseline mit Ordnerstruktur.
- Drei Prototyp-Varianten (Variante-1 Vorschau, Variante-2 Keyboard, Variante-3 Mac-Native).
- Phase 1 (Shell & Styling) und Phase 2 (Editor + Datei-I/O) auf Variante-1.

### Commit-Referenz
- `7506baa` — chore: initial commit — project baseline with folder cleanup
