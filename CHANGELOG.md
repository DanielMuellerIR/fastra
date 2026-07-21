# Changelog

Alle nennenswerten Änderungen an Fastra werden hier dokumentiert.

Format orientiert sich an [Keep a Changelog](https://keepachangelog.com/de/1.1.0/).
Versionsschema: `v0.x` bis zum produktiven Funktionsumfang, `v1.0` beim Release.

---

## [Unreleased]

## [v1.45.0] — 2026-07-21

### Hinzugefügt

- Fastras Markdown-Vorschau kennt nun eine bewusst enge Erweiterung für
  sichtbare Leerzeilen: Eine Quellzeile nur aus mindestens zwei normalen
  ASCII-Leerzeichen erzeugt genau eine vollständig leere Textzeile. Leere
  Zeilen und Zeilen mit genau einem Leerzeichen behalten die CommonMark-
  Semantik; harte Umbrüche und wörtliche Codeblöcke bleiben unverändert.

### Intern

- Die Erweiterung ergänzt ausschließlich kontrollierte interne HTML-Blöcke im
  bereits geparsten cmark-Baum. Dadurch bleiben GFM-Listen, Blockzitate,
  Tabellen, Formeln, Bilder, Quellzeilensprünge und die sichere HTML-Grenze
  erhalten. Unit- und WebKit-DOM-Tests schützen Rendering und Kopiertext.

## [v1.44.5] — 2026-07-20

### Behoben

- Öffnet man aus dem Finder eine Datei, während nur der Willkommensbildschirm
  offen ist, erscheint sie jetzt in genau diesem Fenster statt in einem
  zweiten. Allgemein nimmt ein leeres Fenster (Willkommensbildschirm oder nur
  leere „Ohne Titel"-Tabs, ohne ungesicherte Arbeit) eine geöffnete Datei auf,
  bevor ein neues Fenster entsteht.

## [v1.44.4] — 2026-07-20

### Behoben

- Nach dem Schließen aller Tabs und Neustart erscheint wieder der
  Willkommensbildschirm. Zuvor kam der zuletzt geöffnete Ordner mit einem
  leeren „Ohne Titel"-Tab zurück; ein Fenster ohne offene Dateien wird jetzt
  nicht mehr wiederhergestellt.

### Geändert

- Öffnet man aus dem Finder eine Datei, die zu einem weiter hinten liegenden
  Fenster gehört, kommt direkt das passende Fenster nach vorn — nicht mehr
  zuerst das bisherige Vorderfenster und dann das passende (weniger Unruhe).

## [v1.44.3] — 2026-07-20

### Behoben

- Beim Wiederherstellen der letzten Sitzung blitzt kein leerer „Ohne Titel"-
  Tab mehr auf, bevor die gespeicherten Dateien erscheinen.
- Das „Fenster"-Menü listet jetzt auch das Startfenster, nicht nur zusätzlich
  geöffnete Fenster.
- Eine aus dem Finder geöffnete Datei landet im Fenster, dessen Projekt oder
  Repository sie enthält (auch wenn dieses hinten liegt), und holt es nach
  vorn. Passt kein offenes Fenster, entsteht ein neues. Zuvor ging jede
  Öffnung ins vorderste Fenster, unabhängig vom angezeigten Projekt.
- Öffnet eine Datei in einem passenden Fenster, kommt genau dieses Fenster
  nach vorn — nicht mehr versehentlich ein anderes.

## [v1.44.2] — 2026-07-20

### Behoben

- Der Splitter der linken Seitenleiste (und der rechten Markdown-Vorschau)
  verschiebt sich beim Ziehen nur noch im eigenen Fenster. Zuvor bewegte er
  sich in allen offenen Fenstern gleichzeitig, weil die Breite prozessweit
  geteilt war. Jede gezogene Breite gilt jetzt pro Fenster; der zuletzt
  eingestellte Wert dient weiterhin als Startbreite neu geöffneter Fenster.

## [v1.44.1] — 2026-07-20

### Behoben

- Das kleine X zum Schließen eines Dokument-Tabs besitzt nun eine deutlich
  größere, zuverlässige Mausfläche. Steht der Zeiger auf dem X, wird es
  hervorgehoben und ein Klick schließt den gemeinten Tab, statt nur den Tab
  auszuwählen oder folgenlos zu bleiben.

### Intern

- Auswahl und Schließen eines Tabs sind nicht mehr als verschachtelte SwiftUI-
  Buttons aufgebaut. Ein In-App-Selbsttest prüft mindestens 22 × 22 Punkte
  Klickfläche und einen echten Randklick auf einen inaktiven Tab.

## [v1.44.0] — 2026-07-20

### Hinzugefügt

- Zeilen lassen sich über das Text- und das Rechtsklickmenü ausdrücklich
  alphabetisch auf- oder absteigend sortieren. Die Sortierung wirkt auf die
  Auswahl oder das ganze Dokument, bleibt bei gleichen Zeilen stabil und
  erhält einen abschließenden Zeilenumbruch.
- Fastra stellt beim nächsten Start standardmäßig die zuletzt geöffneten
  Projektfenster, gespeicherten Dokumente, aktiven Tabs und Fensterpositionen
  wieder her. Unter **Einstellungen → Start** lässt sich das abschalten.
  Inhalte ungesicherter oder unbenannter Dokumente werden bewusst nie
  gespeichert oder wiederhergestellt.

### Behoben

- Eine Auswahl oder Einfügemarke gehört jetzt zum jeweiligen Dokument-Tab.
  Beim Öffnen oder Wechseln auf eine andere Datei wird sie nicht mehr auf
  deren gleichlautenden Zeichenbereich übertragen. Dadurch formatieren,
  prüfen und transformieren Dokumentbefehle nicht versehentlich nur einen
  aus dem vorherigen Tab geerbten Teilbereich.
- Beim Beenden einer Sitzung mit mehreren Dokumentfenstern bleiben alle noch
  offenen Fenster im Wiederherstellungs-Snapshot, auch wenn AppKit ein hinteres
  Fenster während des Beenden-Vorgangs bereits unsichtbar geschaltet hat.
  Wirklich geschlossene Fenster bleiben weiterhin ausgeschlossen.

### Intern

- Die Sitzungsdatei enthält ausschließlich Pfade und Fensterzustand; AppKits
  undurchsichtige eigene Fensterwiederherstellung ist zugunsten dieses
  kontrollierten Formats deaktiviert.
- Unit-Tests prüfen Sortierrichtungen, abschließende Zeilenumbrüche,
  verschwundene Dateien, tab-eigene Selektionen, Mehrfenster-Snapshots und den
  Ausschluss ungesicherter Inhalte. Ein
  Cold-Start-Selbsttest stellt zwei echte Fenster mit drei gespeicherten Tabs
  wieder her; ein Editor-Selbsttest bedient beide Sortierrichtungen über den
  echten Menübefehlspfad und prüft beim Dateiwechsel die echte Einfügemarke.
- Ein gelegentlicher Computer-Use-Menüvolltest besitzt nun eine dokumentierte
  Prüffolge sowie eine wegwerfbare Test-App mit eigener Bundle-ID, Testdateien
  und ausschließlich lokalem Git-Remote.

## [v1.43.4] — 2026-07-20

### Behoben

- „Zeilen verbinden“ lässt auch eine per ⌘A vollständig ausgewählte CSS- oder
  Textdatei bei ausgeschaltetem Soft Wrap sichtbar. Nach Verbinden,
  Rückgängig und Wiederholen liegt der stabile Cursor am Dokumentanfang, statt
  eine einzige sehr lange Vollauswahl als fehlerhaften Layoutanker zu behalten.

### Geändert

- Lokale Debug-, Ad-hoc- und nur Developer-ID-signierte Test-Builds bleiben im
  Projekt-Root. Ausschließlich ein erfolgreich notarisiertes, gestapeltes und
  von Gatekeeper akzeptiertes Bundle darf nach `/Applications` installiert
  werden. Dadurch bleibt die macOS-Code-Identität produktiver Installationen
  stabil und Ordnerfreigaben werden nicht bei jedem Test-Build erneut abgefragt.

### Intern

- Der Editor-Selbsttest bildet nun den gemeldeten Fall mit 61 CSS-Zeilen,
  echter Vollauswahl und ausgeschaltetem Soft Wrap ab.
- Regressionstests schützen die Installationsgrenze vor künftigem Rückfall.
- Der Installationslauf protokolliert weder Zertifikatsbezeichnung noch den
  lokalen Notary-Profilnamen.

## [v1.43.3] — 2026-07-20

### Behoben

- „Zeilen verbinden“ hält auch bei langen Markdown-Dokumenten Text, Gutter und
  Cursor sichtbar, statt nach der Ganzdokument-Transformation leer zu wirken.
- Rückgängig und Wiederholen stellen bei diesen Textoperationen die passende
  Cursor-/Auswahlposition wieder her. Dadurch entsteht nach ⌘Z kein leerer
  Bildschirm oberhalb von Zeile 1 und nicht mehr das ganze alte Dokument als
  unerwartete Auswahl.

### Intern

- Ein echter Editor-Selbsttest prüft Verbinden, Undo und Redo nicht nur am
  Modelltext, sondern auch an den tatsächlich sichtbaren Soft-Wrap-Fragmenten.

## [v1.43.2] — 2026-07-20

### Behoben

- „Alles auswählen“ (⌘A) markiert nun auch optisch die letzte Textzeile
  vollständig, wenn eine Datei mit einem Zeilenumbruch endet. Das gilt ebenso
  bei Soft Wrap und für LF-, CRLF- sowie CR-Zeilenenden.

### Intern

- Ein enger CodeEditTextView-Patch unterscheidet die rechte Auswahlkante der
  letzten Textzeile von der Cursorposition in der nachfolgenden leeren
  Dateiende-Zeile. Ein echter Auswahlgeometrie-Test schützt alle drei
  Zeilenendvarianten.

## [v1.43.1] — 2026-07-20

### Intern

- GitHub Actions führt die Swift-Tests seriell aus, damit reale Prozesse und
  asynchrone Main-Queue-Übergaben auf Hosted Runnern nicht um gemeinsame
  Worker-Pools konkurrieren und dadurch fälschlich ihre Testfristen reißen.
- Ordner-Leerstand und inhaltsbasierte Spracherkennung besitzen injizierbare
  Arbeits-/Rückgabe-Scheduler; ihre Tests prüfen dieselben Zustandsübergänge
  ohne zeitabhängiges Polling. Der tool4d-SIGKILL-Test wartet auf echte
  Kernel-/Prozesssignale, und Soft-Wrap-Store-Tests verwenden vollständig
  getrennte Benachrichtigungszentren.

## [v1.43.0] — 2026-07-20

### Hinzugefügt

- **Zwei Dokument-Tabs für einen Vergleich auswählen:** Ein Shift-Klick auf
  einen zweiten normalen Text-Tab lässt den aktuellen Tab eindeutig aktiv und
  markiert genau einen Vergleichspartner schwächer. Ein weiterer Shift-Klick
  ersetzt oder entfernt diesen Partner; ein normaler Tab-Klick kehrt zur
  Einzelauswahl zurück. Sehr lange Dateinamen werden in der Mitte gekürzt,
  statt einen überbreiten Tab zu erzeugen.
- **Vergleich direkt aus der Tab-Leiste:** Das Rechtsklickmenü beider
  markierter Tabs bietet „Dateien vergleichen…“. Der bestehende Dialog öffnet
  sich mit beiden Dokumenten in sichtbarer Tab-Reihenfolge bereits links und
  rechts ausgewählt; Leerraum-, Leerzeilen- und Groß-/Kleinschreibungsoptionen
  bleiben vor dem Start frei wählbar.

### Intern

- Modelltests schützen Primärtab, Höchstzahl, ungeeignete Tabarten,
  Aufräumen und Dialog-Vorbelegung. Der Fenster-Selbsttest `tabcompare`
  führt einen echten Shift-Klick aus, beobachtet beide Markierungsrollen,
  prüft die zwei Dialogfelder und räumt per normalem Klick wieder auf.

## [v1.42.0] — 2026-07-19

Etappe 3 des Soft-Wrap-Pakets: Rechteckauswahl auf logischen Zeilen.

### Hinzugefügt

- **Rechteckauswahl unter Soft Wrap:** Option-Drag behandelt jede logische
  Textzeile genau einmal; sichtbare Umbruchfragmente werden nicht zu
  zusätzlichen Rechteckzeilen. Kurze und leere Zeilen, Tabs, CRLF sowie
  zusammengesetzte Unicode-Zeichen bleiben sicher.
- **Sichtbare Spaltenbefehle:** „Spalte einfügen“ (⌃⌘V) setzt
  Zwischenablage-Zeilen untereinander an der linken Rechteckkante oder am
  Cursor ein und füllt kurze Zielzeilen tabstopp-bewusst auf.
  „Rechteckauswahl nach oben/unten“ (⌃⇧↑/↓) erweitert oder verkleinert die
  Auswahl auf logischen Zeilen.

### Geändert

- Copy, normales Paste, Tippen, Backspace/Delete und Cut bearbeiten alle
  Teilbereiche als eine Undo-Aktion. Eine Clipboard-Zeile füllt das ganze
  Rechteck; mehrere Zeilen werden zeilenweise verteilt. Fehlen Clipboard-
  Zeilen, werden verbleibende Rechteckteile geleert; ein Überschuss läuft
  unter dem Rechteck weiter.
- Zeichenbezogene Transformationen arbeiten unabhängig auf jedem
  Rechteckteil. Befehle für ganze Zeilen oder mögliche Zeilenumbrüche sind
  während einer Rechteckauswahl gesperrt und erklären den Grund.

### Intern

- Versionierter CodeEditTextView-Patch mit harten Upstream-Markern sowie
  Selbsttests `colsel`, `colselwrap` und `colpaste` für Punktauswahl,
  Soft-Wrap-Logik, Unicode/Tab/CRLF, kurze Zeilen, Zwischenablage und
  exakt eine Undo-Gruppe pro Aktion.

## [v1.41.2] — 2026-07-19

### Behoben

- Beim Einschalten von Soft Wrap bleibt der Dokumentausschnitt jetzt ruhig.
  Die oberste sichtbare Textzeile bleibt erhalten, ohne während des
  Layoutaufbaus wiederholt auf- und abzuspringen.

### Intern

- Der CodeEdit-Patch ersetzt zeitversetzte Scrollkorrekturen durch höchstens
  24 Layoutschritte im selben Runloop und setzt nur die stabile Endposition
  sichtbar. `softwrapanchor` beobachtet nun alle 20 ms beide
  Umschaltrichtungen in einem Dokument mit 2.400 langen Zeilen und schlägt
  bereits bei einer sichtbaren Zwischenabweichung fehl.

## [v1.41.1] — 2026-07-19

### Behoben

- Beim Ein- und Ausschalten von Soft Wrap bleibt die oberste sichtbare
  logische Textzeile identisch. Auch in langen Dokumenten springt der
  Fensterausschnitt nicht mehr durch die geänderte Höhe der Umbruchfragmente.

### Intern

- Der CodeEdit-Patch verankert die tatsächliche oberste Textzeile und führt
  das asynchrone Layout begrenzt auf sie zurück, ohne das gesamte Dokument
  synchron auszulegen. Der Fenster-Selbsttest `softwrapanchor` prüft beide
  Umschaltrichtungen sowie Text, Auswahl, Dirty- und Undo-Zustand.

## [v1.41.0] — 2026-07-19

Etappe 2 des Soft-Wrap-Pakets: Umbruchziele und Seitenlinie.

### Hinzugefügt

- **Drei Umbruchziele pro Format:** Fensterbreite, appweite Seitenlinie oder
  feste Spalte. Für feste Breiten stehen 72, 80, 100 und 120 sowie eine
  freie Eingabe von 20 bis 500 bereit. Die Zielwahl schaltet Soft Wrap ein;
  ein schmaleres Fenster bleibt immer die harte Obergrenze.
- **Unabhängige Seitenlinie:** Sichtbarkeit und Spalte sind appweit über
  Soft-Wrap-Optionen, Darstellung-Menü und Einstellungen erreichbar. Linie
  und Umbruch verwenden dieselbe Schrift-, Zoom- und Inset-Geometrie.

### Geändert

- Der Umbruch bevorzugt Wortgrenzen und fällt bei langen Einzelwörtern auf
  vollständige Zeichen zurück. Auch extrem schmale Breiten erzeugen
  mindestens ein vollständiges Unicode-Graphem pro Fragment.
- Ziel-, Breiten-, Fenster- und Zoomwechsel verändern weder Text, Auswahl,
  Dirty-Zustand noch Undo-Verlauf. Profilformat v1 wird verlustfrei auf v2
  migriert.

### Behoben

- Die vorhandene Seitenlinie lag durch halbierte Zeichen-/Inset-Werte an der
  falschen Spalte und zeichnete zudem außerhalb ihrer lokalen View-Bounds.
- Die 4D-Theme-Regressionstests laden ihre Referenzwerte wieder aus
  gebündelten öffentlichen Test-Fixtures statt aus entfernten Planungsdateien.

### Intern

- Reproduzierbarer CodeEdit-Patch für feste Layoutbreiten, exakte
  Seitenliniengeometrie und Unicode-Fortschritt; reale Layout-/Render-Tests
  sowie In-App-Selbsttest `softwrapmodes` für Zielwechsel, Resize und Zoom.

## [v1.40.0] — 2026-07-19

Etappe 1 des Soft-Wrap-Pakets: Formatprofile und Bedienung.

### Hinzugefügt

- **Schneller Soft-Wrap-Schalter in der Fußzeile.** Der sichtbare Ein/Aus-
  Zustand steht direkt neben dem Format-Chip. Hauptklick schaltet sofort;
  separater Pfeil und Rechtsklick öffnen dieselben nativen Optionen mit
  formatspezifischem Zurücksetzen auf die Werkseinstellung. Der vorhandene
  Menüpunkt unter „Darstellung“ schaltet und spiegelt denselben Wert.
- **Persistente Profile pro effektivem Dokumentformat.** Reiner Text,
  Markdown, HTML und XML starten mit Soft Wrap; 4D, JSON, CSV und andere
  Code-/Konfigurationsformate ohne. Abweichungen gelten appweit für offene
  und später geöffnete Dokumente desselben Formats. Ein ausdrücklich
  vorhandener früherer globaler Wert wird einmalig nur für Reinen Text
  übernommen.

### Geändert

- **Eine zentrale Formatidentität** steuert nun Format-Chip, Editor-Grammatik,
  Soft-Wrap-Profil und Hauptmenüstatus. Manuelle Sprachwahl gewinnt vor
  Datei-/Inhaltserkennung; die 4D-Containerformate werden als 4D, JSON oder
  XML nach ihrem tatsächlichen Inhalt behandelt.
- Die frühere globale Soft-Wrap-Einstellung wurde entfernt. Umschalten
  reconciliert die reale Editor-TextView sofort, ohne Text, Auswahl,
  Dirty-Zustand, Undo-Verlauf oder Datei zu verändern. Ohne Soft Wrap bleibt
  horizontales Scrollen erhalten.

### Intern

- Versionierter, mit isolierten `UserDefaults` testbarer Profil-Store samt
  Migration und fensterübergreifender Benachrichtigung; Vollständigkeitstest
  erzwingt für jede auswählbare Sprache eine bewusste Default-Klasse.
- Neuer Fenster-Selbsttest `softwrapprofiles` prüft Markdown-/4D-Defaults,
  Live-Reconcile, neue und bestehende 4D-Tabs sowie den echten
  Hauptmenüpfad. `hscroll` läuft wieder verbindlich in der Gesamtsuite.

## [v1.39.0] — 2026-07-19

### Hinzugefügt

- **Projektmethoden im 4D-Highlighting.** Fastra liest die Namen aus
  `Project/Sources/Methods` nebenläufig und case-insensitiv ein, aktualisiert
  den Index bei Projekt-Dateiänderungen und färbt diese Methoden mit der
  eigenen 4D-Methodenfarbe (hell/dunkel, fett/kursiv). Prozessvariablen,
  Tabellen einschließlich `[Tabelle:ID]` und echte Strings bleiben getrennt.
- **tool4d-LSP-Diagnosepfad.** „Text → Dokument prüfen“ startet bei
  gespeicherter `.4dm`-Methode in einem geöffneten 4D-Projekt ein bereits
  vorhandenes tool4d über dessen lokalen LSP-Modus. Fastra bündelt und lädt
  tool4d weiterhin nicht. Der JSON-RPC-Lauf ist auf `127.0.0.1` begrenzt,
  übergibt Workspace und sichtbaren Editorstand und beendet Verbindung und
  Kindprozess nach jedem Lauf sicher. Nicht-`null`-Diagnoseberichte zeigen
  Zeile/Spalte; `null` bleibt bewusst ein Fehler statt ein grüner Check. Die
  Dokument-URI wird wie der Workspace kanonisiert, damit der macOS-Alias
  `/tmp` ↔ `/private/tmp` nicht zu einem falschen `null` führt.
- **Hilfe-Fenster mit ⌘W.** Das Schließen der vorderen Hilfe lässt alle
  Dokument-Tabs unverändert; der Fenster-Selbsttest belegt dies mit zwei
  Hintergrund-Tabs und einem echten ⌘W-Ereignis.

### Intern

- Pull-Diagnosen (`textDocument/diagnostic`) mit `publishDiagnostics`-Fallback,
  Mock-LSP- und echter Prozess-Abbruchtest sowie optionaler Integrations-
  Selbsttest `tool4dlsp` für lokal installiertes tool4d mit ausdrücklich
  übergebener sicherer Projektkopie.
- Der CodeEdit-Theme-Patch erhält einen optionalen Methoden-Slot mit sicherem
  Default für alle bestehenden Sprachen. `highlight4d` beobachtet zusätzlich
  Projektmethode, Prozessvariable und String im echten Editor.

## [v1.38.2] — 2026-07-19

### Behoben

- **4D-Vervollständigung beim Tippen.** Nach dem ersten Zeichen konnte der
  Editor eine absichtlich noch leere 4D-Anfrage intern als aktiv behalten.
  Der zweite Buchstabe aktualisierte dadurch nur eine unsichtbare Liste.
  Eine verworfene Anfrage wird jetzt sauber geschlossen; ab zwei Zeichen
  erscheint die Vorschlagsliste wieder wie dokumentiert.

### Intern

- Neuer Fenster-Selbsttest `completion4d`: Lädt eine echte `.4dm`-Datei,
  prüft das Auto-Popup nach `AL` sowie ⌃Leertaste, ↓, gezielten Klick und
  Doppelklick in der echten CESE-Vorschlagstabelle.

## [v1.38.1] — 2026-07-18

### Behoben

- **„Dokument prüfen“ und „Dokument minifizieren“ im Rechtsklickmenü.**
  Beide lagen bisher nur im Menü **Text**, obwohl „Dokument formatieren“
  im Kontextmenü stand — wer sie dort suchte, fand sie nicht. Rechtsklick
  und Menüleiste teilen sich jetzt denselben Apply-Pfad; im Kontextmenü
  wirken sie auf die angeklickte TextView. Die Einträge bleiben wie bisher
  ausgegraut, wenn die Dateiendung des Tabs nicht unterstützt wird.
- **Hilfe:** Der Abschnitt „Text-Transformationen“ nennt jetzt das
  Rechtsklickmenü, die unterstützten Dateiendungen und den häufigsten
  Grund für ausgegraute Einträge (neuer Tab ohne Endung). Die englische
  Hilfe nannte „Check document“ statt des echten Menütitels
  „Validate Document“.

## [v1.38.0] — 2026-07-18

Etappe 7 des Wunschpakets 2026-07c: Alt-Doppelklick „Gehe zum Ziel“
nach dem Vorbild des 4D-Methodeneditors.

### Hinzugefügt

- **Alt-Doppelklick springt zur Definition.** Gesten-Entscheidung: Es
  bleibt beim Alt-Doppelklick des Vorbilds — die Alt-Drag-Spaltenauswahl
  beginnt mit einem Einzelklick und kollidiert nicht (`colsel`-Selbsttest
  bleibt grün); CESEs ⌘-Hover-Springen braucht tree-sitter-Identifier und
  funktioniert für 4D/Markdown nicht.
- **4D (`.4dm`):** Methodenname → Projektmethode
  (`Project/Sources/Methods/<Name>.4dm`, auch mehrwortige Namen),
  Klassenname → `Project/Sources/Classes/<Name>.4dm`,
  `Function`-Definitionen in der aktuellen Datei springen lokal.
  Projektwurzeln werden über die Vorfahren der aktiven Datei UND die
  Seitenleisten-Projektwurzel gefunden. Fallback: Projektsuche mit dem
  Namen (Suchdialog, Ordner-Bereich) — nie ein stiller No-Op.
- **Markdown:** relative Dateipfade in Links/Bildern öffnen im Editor,
  `http(s)`/`mailto` im Browser, `#anker` springen zur Überschrift
  (gleiche Slug-Regeln wie die Hilfe); auch Autolinks und nackte URLs.
- **Generische Provider-Schnittstelle** (`GoToTargetProvider`) mit genau
  diesen zwei Providern — weitere Sprachen sind bewusst späterer Ausbau.
  Nicht auflösbare Ziele melden sich dezent: Beep, kurzes Aufblitzen am
  Wort, Hinweis in der Seitenleiste.

### Intern

- Pure Ziel-Auflösung mit Fixture-Tests (Methoden-/Klassen-/Function-
  Ziele, Linkarten, Anker, Registry); Fenster-Selbsttest `gototarget`
  mit ECHTEN synthetischen Alt-Doppelklicks über die Event-Queue.

## [v1.37.0] — 2026-07-18

Etappe 6 des Wunschpakets 2026-07c: 4D-Werkzeuge aus den Katalogen.
Quellen-Lizenzen sind dokumentiert und attribuiert
(THIRD-PARTY-NOTICES.md + Hilfe): 4D-Doku
CC BY 4.0 (abgeleitete Fakten), formsSchema.json MIT.

### Hinzugefügt

- **4D-Vervollständigung mit Signatur-Hilfe:** In `.4dm`-Methoden (nur
  bei aktiver 4D-Sprache) schlägt der Editor beim Tippen Befehle samt
  Syntax-Signatur und Konstanten vor (CESE-CodeSuggestion-System:
  Esc/⌃Leertaste öffnen manuell, ↑/↓ wählen, Return/Tab übernimmt —
  macOS-übliches Verhalten). Unaufdringlich: automatisch erst ab zwei
  getippten Zeichen; die Übernahme ersetzt das getippte Teilwort als
  normaler, mit ⌘Z widerrufbarer Edit. Der Generator
  (`app/tools/generate-4d-symbols.py`) zieht dafür zusätzlich
  Syntax-Signaturen und Befehlsnummern aus den Befehlsseiten
  (1247 Signaturen, 1252 Nummern).
- **`.4DForm`-Schema-Validierung:** „Dokument prüfen“ validiert
  Formulardateien nach der JSON-Syntax zusätzlich gegen das gebündelte
  `formsSchema.json` (MIT, © Mathieu Ferry) — mit Fehlerposition,
  JSON-Pfad und Sprung zur Stelle. Eigener minimaler Schema-Prüfer
  (`JSONSchemaLite`, exakt die vom Schema genutzten Konstrukte; im
  Zweifel keine Meldung: `oneOf` wird bewusst wie `anyOf` geprüft).
- **Transformation „tokenisierter Export ↔ Klartext“** im Text-Menü:
  „4D: Token-Suffixe entfernen“ strippt `:Cnnn`/`:Knn:mm` token-basiert
  (Strings/Kommentare bleiben unangetastet); „4D: Befehls-Token
  ergänzen“ fügt Befehlsnummern wieder an. Konstanten-Nummern kennt
  keine öffentliche Quelle — Konstanten bleiben beim Ergänzen ehrlich
  unverändert (steht so im Menütitel).

### Intern

- Neue pure Logik `FourDCompletionLogic` (Präfix-Erkennung mehrwortiger
  Befehle, Matching), `JSONSchemaLite` (inkl. Pfad→Position-Läufer) und
  `FourDTokenTransform` (Roundtrip-getestet); insgesamt 39 neue Tests.

## [v1.36.0] — 2026-07-18

Etappe 5 des Wunschpakets 2026-07c: 4D-Struktur-Hinweise.

### Hinzugefügt

- **„Dokument prüfen“ für `.4dm`-Methoden:** heuristischer Check auf
  Basis des vorhandenen 4D-Tokenizers — Block-Balance (`If/End if`,
  `For each/End for each`, `Case of/End case`, `Repeat/Until`,
  `While/End while`, `For/End for`, `Function`-Grenzen in Klassen,
  `Else`-Zuordnung), Klammer-Balance (`()`, `[]`, `{}` außerhalb von
  Strings, Kommentaren und `[Tabellen]`), String- und
  Kommentar-Balance. Ein Klick springt zur Stelle.
- **Ehrlich als „Struktur-Hinweise“ benannt** — kein Compiler-Ersatz,
  auch nicht im Erfolgsfall („keine Auffälligkeiten“ statt „gültig“;
  Verweis auf tool4d). Im Zweifel keine Meldung statt einer falschen:
  Schlüsselwörter zählen nur am Zeilenanfang (`4D.Function` bleibt
  Typ-Annotation), `Begin SQL`-Blöcke werden nicht gedeutet, Klammern
  nur über das ganze Dokument bilanziert.

### Intern

- Neue pure Prüf-Logik `FourDStructureCheck` mit 21 Fixture-Tests
  (valide Methoden/Klassen erzeugen KEINE Hinweise; kaputte Fälle
  finden die richtige Zeile).

## [v1.35.0] — 2026-07-18

Etappe 4 des Wunschpakets 2026-07c: tool4d-Ersteinrichtungshilfe.
Fastra bündelt tool4d weiterhin nicht, lädt nichts herunter und führt
nichts aus — Hilfe ja, versteckte Netzwerkaktionen nein.

### Hinzugefügt

- **4D-Erst-Kontakt-Hinweis:** Beim ersten Öffnen einer `.4dm`- oder
  `.4DProject`-Datei erscheint der dezente, nicht-modale Hinweis
  („4D erkannt — Fastra kann mit tool4d beim Prüfen der Syntax helfen“)
  mit Sprung in den neuen Hilfe-Abschnitt. Einmal pro Nutzer; beide
  Buttons („Einrichtung anzeigen“ / X) quittieren dauerhaft
  (Mechanik des Markdown-Assist-Hinweises aus v1.31.0).
- **Hilfe-Abschnitt „4D und tool4d“** (Deutsch + Englisch, gestrafft aus
  `docs/tool4d.de.md`): was tool4d ist, Bezugsquellen (Download-Seite,
  VS-Code-Extension „4D-Analyzer“), headless-Prüfbefehl, Lizenzlage.
- **„Hilfe → tool4d finden…“:** prüft die bekannten Orte (PATH,
  Programme-Ordner, globalStorage der 4D-Analyzer-Extension), zeigt
  Fundort und Version (aus dem Bundle-Info.plist gelesen — nie durch
  Ausführen ermittelt) oder erklärt die Bezugsquellen mit Button
  „Download-Seite öffnen“. Der Fundort wird als Grundlage der späteren
  Prüf-Integration (Etappe 8) gemerkt, aber nicht ausgeführt.

### Intern

- Pure, mit Fixtures getestete Pfad-Discovery `Tool4DDiscovery`
  (PATH-Reihenfolge, höchste Extension-Version, Version ohne
  Programmstart); Fenster-Selbsttest `tool4dhint` (Hinweis erscheint
  genau einmal, echter Klick öffnet die Hilfe am Anker; isolierte
  Selbsttest-Defaults verbrauchen das echte Nutzer-Flag nicht).

## [v1.34.0] — 2026-07-18

Etappe 3 des Wunschpakets 2026-07c: Suchfunktion in der Projektansicht.

### Hinzugefügt

- **Dateinamens-Filter in der Projekt-Seitenleiste:** dauerhaft sichtbares
  kompaktes Filterfeld über dem Dateibaum (bewusst keine versteckte
  Ausklapp-Lupe — zentrale Funktionen bleiben sichtbar und mit der Maus
  erreichbar). Filtert live nach Dateinamen: case-insensitiver
  Teilstring, bewusst kein Fuzzy-Matching; Unicode-Case-Faltung
  inklusive („STRASSE“ findet „Straße“).
- Treffer erscheinen mit aufgeklappten Elternordnern, Nicht-Treffer sind
  ausgeblendet. Escape oder das X leeren den Filter und stellen den
  vorigen Aufklappzustand unverändert wieder her (der gespeicherte
  Zustand wird während des Filterns nie angefasst).
- Zähler „N von M Dateien“ unter dem Feld; wird der Scan an der
  Sicherheitsgrenze (50.000 Dateien) gekappt, steht das sichtbar dabei.
- Leeres Ergebnis → verständlicher Leerzustand statt leerem Baum, mit
  Link „Im Inhalt suchen…“, der den Suchdialog mit Ordner-Bereich
  öffnet (der Filter durchsucht nur NAMEN — Volltext bleibt Sache des
  Suchdialogs).
- Scan läuft asynchron (debounced, abbrechbar) und wiederholt sich bei
  externen Dateiänderungen (FSEvents) idempotent; FSEvents setzen das
  Filterfeld nicht mehr zurück (Baum-Identität hängt jetzt nur noch am
  Baum, nicht am Feld).

### Intern

- Neue pure Filterlogik `FileTreeFilter` mit Unit-Tests (Teilstring,
  Umlaute, versteckte Dateien, Eltern-Aufklappung, Kappung,
  Symlink-Zyklen-Schutz; Pfad-Kanonisierung wie `contentsOfDirectory` —
  `resolvingSymlinksInPath` wäre falsch, es entfernt `/private`);
  Fenster-Selbsttest `sidebarfilter` (echtes Ein-/Ausblenden gerenderter
  Zeilen, Zähler, Zustands-Wiederherstellung).

## [v1.33.0] — 2026-07-18

Etappe 2 des Wunschpakets 2026-07c: Git-Diffs rendern über denselben
Dual-Pane-Renderer wie „Dateien vergleichen“ — eine Optik, eine
Tastatur-Navigation, eine Differenzen-Liste. Der Git-spezifische Unterbau
(`GitDiffRequest`/`GitDiffParser`, Hunk-Folding, Mehr-Datei-Diffs,
Commit-Metadaten, Unified-Fallback für Merge-Diffs) bleibt unverändert;
ein Abbildungs-Test belegt: gleiche Eingabe → gleiche Zeilen-Ausrichtung
wie beim früheren Renderer.

### Geändert

- **Git-Diff-Tabs haben jetzt die Differenzen-Liste unten** (wie „Dateien
  vergleichen“): ein Eintrag je zusammenhängendem Unterschied mit
  Zeilenangaben, bei Mehr-Datei-Diffs mit Dateinamen davor; Klick springt
  dorthin.
- **Navigation vereinheitlicht:** ⌥↑/⌥↓ springen auch im Git-Diff zum
  vorigen/nächsten Unterschied; die bisherigen ⌥⌘[/⌥⌘]-Shortcuts bleiben
  als Zweitbelegung erhalten. Der Zähler heißt jetzt in beiden Ansichten
  „Unterschied X von Y“ und zählt zusammenhängende Unterschiede statt
  Git-Hunks; die Übersichts-Leiste rechts markiert entsprechend
  Unterschiede (der Datei-Diff bekommt sie damit ebenfalls).
- Ausgeklappte Falt-Bereiche im Datei-Diff behalten ihren
  Einklapp-Knopf (Verhalten wie im Git-Diff).

### Intern

- Neuer gemeinsamer Renderer `DualPaneDiffView` plus pure Abbildung
  `GitDiffDisplay` (Git-Modell → gemeinsames Anzeige-Modell) mit
  Verhaltensgleichheits-Tests; der bisherige `GitSideBySideDiffView`
  entfällt.

## [v1.32.0] — 2026-07-18

Etappe 1 des Wunschpakets 2026-07c: Diff-Kern & Datei-Diff dual-pane
nach dem BBEdit-Vorbild „Find Differences“/„Compare Against Disk File“
(User Manual 16.0.1, S. 130–134).

### Hinzugefügt

- **„Dateien vergleichen…“ (Suchen-Menü, ⌃⌘D):** Dialog mit Links/Rechts-
  Auswahl (Dateiauswahl-Button, Drag-and-drop-Feld, Popup mit offenen Tabs
  und zuletzt geöffneten Dateien; aktiver Tab links vorbelegt) und den
  Vergleichsoptionen „Leerraum am Zeilenende“, „alle Leerraum-
  Unterschiede“, „Leerzeilen“ und „Groß-/Kleinschreibung“ (Voreinstellung:
  nichts ignorieren; Wahl bleibt gemerkt). Fehlende, binäre oder als
  Ordner gewählte Pfade melden sich verständlich direkt am Feld.
- **Dual-Pane-Differenzansicht ohne Git:** eigener, UI-freier Diff-Kern
  (`FileDiff`, Myers-Diff über Foundations `CollectionDifference` mit
  Intraline-Hervorhebung) — funktioniert komplett ohne installiertes Git.
  Beide Spalten scrollen synchron (eine Liste, Muster Git-Diff), lange
  unveränderte Abschnitte sind mit Kontext eingeklappt und pro Abschnitt
  einblendbar. Kopfzeile mit beiden Dateinamen (Tooltip: voller Pfad) und
  den aktiven Optionen.
- **Differenzen-Liste unten (BBEdit-Vorbild):** ein Eintrag je Unterschied
  („Zeilen 12–14 geändert“, „Zeile 30 nur links“, „Zeile 7 nur rechts“);
  Klick wählt den Unterschied und scrollt beide Spalten dorthin, ⌥↑/⌥↓
  springen zum vorigen/nächsten Unterschied.
- **„Mit gespeicherter Fassung vergleichen“ (Suchen-Menü):** vergleicht
  den ungespeicherten Editor-Inhalt des aktiven Tabs direkt mit dem
  Plattenstand derselben Datei — nur aktiv bei ungespeicherten Änderungen.
- **Ehrliche Grenzen statt stiller Verfälschung:** identische Dateien
  werden ausdrücklich gemeldet („Keine Unterschiede — N Zeilen identisch“
  samt aktiver Optionen); Binärdateien, nicht lesbare Dateien, Dateien
  über 32 MiB, über 200.000 Zeilen oder mit mehr als 30.000 Zeilen
  Unterschiedsbereich zeigen eine verständliche Erklärung statt eines
  Diffs. Ignorierte Leerzeilen bleiben sichtbar, zählen aber nicht als
  Unterschied.
- **Hilfe-Abschnitt „Dateien vergleichen“** (Deutsch + Englisch) und
  Fenster-Selbsttest `filediff` (echtes Sheet, echte gerenderte
  Unterschiede, echter Klick auf die Differenzen-Liste mit beobachtetem
  Scroll-Sprung).

### Intern

- Neuer Diff-Kern `FileDiff` mit 35 Unit-Tests (Ausrichtung, alle
  Optionen, Leerzeilen-/Unicode-Fälle, Falten, Grenzen, Ladepfad);
  Vergleichs-Tabs verhalten sich wie Git-Tabs (read-only, kein Speichern,
  kein Ansichts-Umschalter) und recyceln sich bei gleichem Vergleich.

## [v1.31.0] — 2026-07-18

Etappe 5 des Wunschpakets 2026-07b: Assistiertes Markdown-Schreiben.
Fastra ersetzt damit TextEdit für „Text + Bilder, weiter bearbeitbar“ —
ohne WYSIWYG-Umbau.

### Hinzugefügt

- **Formatierungsbefehle auf den Quelltext** (nur bei Markdown-Tabs):
  Format-Toolbar über dem Editor (bei schmaler Spalte horizontal
  scrollbar), „Markdown“-Menü mit Shortcuts und Rechtsklick-Submenü —
  Fett (⌘B), Kursiv (⌘I), Code (⇧⌘K), Überschrift 1–3 (⌘⌥1–3), zurück zu
  Text (⌘⌥0), Aufzählung (⇧⌘8), nummerierte Liste (⇧⌘7), Zitat (⇧⌘9),
  Link (⌘K), „Tabelle einfügen…“ (Dialog: Spalten, Kopfzeile). Alles
  normale, mit ⌘Z widerrufbare Textedits auf Auswahl bzw. Cursor-Zeile;
  Listen-/Zitat-/Überschrift-Befehle ersetzen einander statt zu stapeln.
- **Bild einfügen per Paste (⌘V):** Bilddaten aus der Zwischenablage
  landen als Datei neben dem Dokument
  (`dokumentname-JJJJ-MM-TT-hhmmss.png`; PNG/JPEG/GIF behalten ihr
  Format, alles andere wird verlustfrei PNG) und werden relativ an der
  Cursorposition verlinkt. Definierte Reihenfolge: Bilddateien vom
  Pasteboard vor rohen Bilddaten vor normalem Text-Einfügen; ⌘⇧V bleibt
  die explizite Rich-Text-Konvertierung (SmartPaste).
- **Bild einfügen per Drag-and-drop:** Eine Bilddatei wird unverändert in
  den Dokumentordner kopiert (Kollision → Suffix; byte-identische Datei
  wird wiederverwendet statt doppelt abgelegt; Dateien im Dokumentbaum
  werden nur verlinkt) und relativ verlinkt. Browser-Drags ohne lokale
  Datei (rohe Bilddaten) verhalten sich wie Paste. Klare Abgrenzung: Im
  Markdown-Editorbereich gewinnt „einfügen“ für Bilder, andere Dateien
  und der Rest des Fensters behalten „öffnen“.
- **Ohne Speicherort keine stille Ablage:** Ungespeicherte Dokumente
  zeigen die verständliche Meldung „Erst speichern“ (⌘S).
- **Vorschau folgt dem Einfügen:** Nach jedem Bild-Einfügen scrollt die
  integrierte Vorschau zur Einfügestelle (`data-srcline` rückwärts
  genutzt); lokale relative Bilder rendert sie bereits über den
  vorhandenen Asset-Pfad.
- **Erst-Nutzungs-Hinweis:** Beim ersten Formatbefehl oder Bild-Einfügen
  erscheint ein dezenter, nicht-modaler Hinweis mit Sprung in den neuen
  Hilfe-Abschnitt „Markdown schreiben“ (Anker-API aus Etappe 4).
- Selbsttest `mdassist` (Toolbar layoutet, Bild-Paste end-to-end mit
  Datei/Link/Vorschau-Scroll, Drop-Abgrenzung einfügen vs. öffnen) sowie
  Unit-Tests für Formatbefehle, Namensvergabe, Kollisions-/Dedup-Logik
  und Relativpfade.

## [v1.30.0] — 2026-07-18

Etappe 4 des Wunschpakets 2026-07b: Hilfe.

### Hinzugefügt

- **Fastra-Hilfe (⌘?):** Neues Hilfe-Menü mit mitgelieferter Hilfe in
  Deutsch und Englisch (Wahl nach App-Sprache). Die Hilfe erklärt kompakt
  alles Nicht-Selbsterklärende: Suchen & Ersetzen (Wildcards `*`/`**`,
  RegEx, Capture-Pillen, Suchbereiche, Vorschau→Apply), alle 31
  Text-Transformationen plus Formatieren/Prüfen/Minifizieren, die
  Ansichten Text/Vorschau/Hex, Markdown-Vorschau, Sprachwahl,
  4D-Unterstützung, XPath-Leiste, Projekt-Seitenleiste, Git sowie
  Encoding/Zeilenenden. Bewusst ohne Bilder (Ausbau-Idee in `ROADMAP.md`),
  kein Apple-Help-Buch (Indexer-/Caching-Ärger) — gerendert read-only über
  den vorhandenen lokalen Markdown-Renderer.
- **Eigenes Hilfe-Fenster statt Tab:** Die Hilfe bleibt neben dem Dokument
  lesbar, nimmt nicht an der Tab-/Projektverwaltung teil und ist über eine
  Anker-API (`HelpWindow.show(anchor:)`) abschnittsgenau ansteuerbar —
  vorbereitet für die Erst-Nutzungs-Hinweise aus Etappe 5.
- **Pflege-Mechanismus `app/help-audit.sh`:** Commit-basierter Wächter nach
  dem Muster des Lokalisierungs-Audits. Eine Markerdatei
  (`app/help-reviewed-commit`) hält den zuletzt hilfegeprüften Commit; das
  Skript listet produktrelevante Commits seither. Im Normallauf ein
  Hinweis, im Release-Lauf (`--release`, in `release.sh` verdrahtet) ein
  harter Fehler. Die inhaltliche Bewertung bleibt bewusst Agenten-Arbeit
  (Regel in `AGENTS.md` ergänzt).
- Selbsttest `help`: Hilfe lädt aus dem gepackten Bundle (beide Sprachen),
  rendert echte Überschriften (DOM-Beobachtung) und der Anker-Sprung
  scrollt real. Unit-Tests für Anker-Slugs, Abschnitts-Anti-Drift und
  `help-audit.sh` gegen temporäre Repo-Fixtures.

## [v1.29.0] — 2026-07-18

Etappe 3 des Wunschpakets 2026-07b: Sprachmenü & 4D wählbar.

### Hinzugefügt

- **4D manuell wählbar:** Das Sprachmenü in der Fußzeile bietet jetzt auch
  „4D“ an. Die Wahl aktiviert den 4D-Highlight-Provider samt 4D-Theme
  unabhängig von der Dateiendung — und lässt sich über „Automatisch“ oder
  eine andere Sprache wieder verlassen. Die Endungs-Automatik (.4dm) bleibt
  unverändert; manuelle Wahl gewinnt wie bisher.
- **Eigen-Sprachen-Registry:** Eine zentrale Beschreibung aller Sprachen
  außerhalb von CodeEditLanguages (derzeit nur 4D: Anzeigename, Endungen,
  Grammatik-Unterbau, Themes, Highlight-Provider). Sprachmenü und
  Editor-Routing speisen sich aus dieser einen Quelle; ein
  Anti-Drift-Unit-Test stellt sicher, dass jede unterstützte Sprache
  (gebündelte Grammatiken + Registry) im Menü wählbar ist und die bewusst
  versteckten Hilfs-Grammatiken dokumentiert bleiben.
- `.4DProject`/`.4DForm` (JSON) und `.4DCatalog`/`.4DSettings` (XML)
  behalten ihr bisheriges Routing — das sind echte JSON-/XML-Dateien.
- Selbsttest `highlight4d` prüft zusätzlich den manuellen Override an einer
  Nicht-.4dm-Datei (Farben erscheinen und verschwinden real im Editor).

## [v1.28.0] — 2026-07-18

Etappe 2 des Wunschpakets 2026-07b: Suchdialog.

### Hinzugefügt

- **Live-Markierung aller Treffer im Editor (BBEdit „Show matches“):**
  Solange die Suchmaske offen ist, markiert der Editor im Datei-Scope alle
  Treffer der Live-Suche als flache, helle Hervorhebungen (über den
  vorhandenen EmphasisManager des gepinnten Editors, eigene Gruppe
  `fastra.search` — kein CESE-Patch). Die Anzeige folgt der debounced
  Live-Suche und dem Scrollen (neu ausgelegte Zeilen werden gedrosselt
  nachgezeichnet) und räumt sich bei Musterwechsel, Scope-Wechsel,
  Tab-Wechsel und Dialogschluss. Reine Anzeige: kein Einfluss auf Undo,
  Dirty-Zustand, Ersetzen oder die Trefferbasis der Vorschau. Obergrenze
  sind die materialisierten Treffer (2 000); beim Kappen sagt der bestehende
  Hinweis in der Maske jetzt zusätzlich, dass nur die ersten N markiert
  sind. Ordner-/Projekt-/Geöffnet-Scope markieren weiterhin nur über die
  Trefferliste.
- Neuer Fenster-Selbsttest `searchmark`: beobachtet die echten
  Emphasis-Layer (auch nach einem Sprung ans Dokumentende), das
  Mitscrollen der Trefferliste und das Aufräumen nach Dialogschluss.

### Geändert

- **Trefferliste scrollt zum aktiven Treffer:** Bei Navigation (Return,
  Pfeiltasten, Voriger/Nächster, Klick) zentriert die Liste den aktiven
  Treffer. Beim bloßen Neu-Suchen (Muster getippt) springt sie bewusst
  nicht.
- **Nur noch ein hervorgehobener Button pro Scope:** „Alle ersetzen · N“
  verliert seine Sonder-Hervorhebung und wird ein normaler Button —
  Cmd+Return und Trefferzahl bleiben. Den blauen Default-Look trägt damit
  automatisch genau der Button, der an Return hängt („Nächster“ im Datei-/
  Geöffnet-Scope, „Suchen“ im Ordner-Scope).

## [v1.27.0] — 2026-07-18

Etappe 1 des Wunschpakets 2026-07b: Navigation & Chrome.

### Hinzugefügt

- **Gemeinsamer Seitenleisten-Kopf auf allen drei Tabs:** Der Kopf
  (Projektname + Schließen-X) erscheint jetzt auch auf „Änderungen“ und
  „Graph“, nicht mehr nur im Dateien-Tab. Neu für alle Tabs: Tooltip mit dem
  vollen Pfad auf dem Namen sowie ein Rechtsklickmenü mit „Im Finder
  zeigen…“ und „Projektansicht schließen“. Der Dateien-Tab behält
  zusätzlich sein Vollmenü (Neue Datei/Ordner, Terminal).
- **Cmd-Klick auf den Projektnamen wechselt zum Nachbarprojekt:** Ein Menü
  zeigt alle Ordner im selben Elternordner (nur Ordner, versteckte
  ausgeblendet, alphabetisch, aktueller mit Häkchen); die Auswahl wechselt
  das Projekt wie „Ordner öffnen“. Das Listing läuft asynchron; ein nicht
  lesbarer Elternordner zeigt eine verständliche Meldung statt eines leeren
  Menüs.
- **Cmd-Klick auf einen Dokument-Tab zeigt das macOS-Pfadmenü:** Datei
  zuoberst (zeigt sie im Finder), darunter jeder Elternordner (öffnet ihn im
  Finder) — Ersatz für das Cmd-Klick-Menü der ausgeblendeten Titelzeile.
  Ungespeicherte Tabs haben kein Menü.
- Neuer Fenster-Selbsttest `sidebarheader` (Kopf sichtbar, Umschalter in der
  Fußzeile, Umschalter verschwindet ohne Datei).

### Geändert

- **Git-Root beim automatischen Ordner-Öffnen:** Öffnet man eine Einzeldatei
  ohne offenes Projekt, zeigt die Seitenleiste jetzt den Wurzelordner des
  Git-Repositorys (auch Worktrees) statt stur den Elternordner; ohne Repo
  bleibt es beim Elternordner. Wer einen Unterordner ausdrücklich als
  Projekt öffnet, behält ihn unverändert.
- **Ansichts-Umschalter (Text/Vorschau/Hex) in der Fußzeile:** Der
  Umschalter sitzt jetzt kompakt rechts in der Statusleiste statt in einer
  eigenen Zeile über dem Editor — eine Zeile mehr Platz für den Inhalt.
  Sichtbarkeit (nur bei mehreren Ansichten), Menüpunkte und Shortcuts
  unverändert.

### Dokumentiert

- **Befund Fenstertitel-Wegfall:** Die Titel-Pipeline
  (`MainWindowTitle.swift`) ist nicht tot — `window.title` speist weiterhin
  Mission Control, Dock, Fenster-Menü und VoiceOver. Entfallen sind nur die
  Proxy-Icon-Funktionen der versteckten Titelzeile: das Cmd-Klick-Pfadmenü
  (ersetzt durch das Tab-Pfadmenü) und der Datei-Drag aus der Titelzeile
  (bewusst ersatzlos, mögliche Alternative in `ROADMAP.md`).

## [v1.26.0] — 2026-07-18

### Hinzugefügt

- **Klick in der Markdown-Vorschau springt in den Editor:** Ein Klick auf eine
  Textstelle der Vorschau scrollt den Editor an die zugehörige Quellzeile und
  setzt den Cursor dorthin. Blöcke tragen dafür ihre Quellzeile im gerenderten
  HTML; innerhalb eines Absatzes wird die Zeile über die Zeilenumbrüche vor der
  Klickstelle aufgelöst, sodass auch ein langer Absatz zeilengenau bleibt.
  Codeblöcke zeigen auf ihre erste Codezeile statt auf die Fence-Zeile.
  Die Spalte ist eine Näherung: Der gerenderte Text enthält kein Markup, ist
  also kürzer als die Quelle — bei Fließtext trifft sie gut, sonst landet der
  Cursor etwas zu früh in der richtigen Zeile.
- Links in der Vorschau öffnen weiterhin den Standardbrowser, und eine gezogene
  Textauswahl löst keinen Sprung aus.

### Behoben

- **XPath-Leiste sprang nicht, wenn man sofort nach dem Öffnen tippte:** Der
  Index entsteht asynchron. Wer schneller war, verlor den Sprung ganz — die
  Leiste zeigte die Treffer an, der Editor blieb aber stehen. Der verpasste
  Sprung wird jetzt nachgeholt, sobald der Index steht. Ein späterer
  Index-Neubau nach einer Dokumentänderung springt weiterhin nicht von selbst.
  Betraf vor allem große Dateien, bei denen der Indexbau länger dauert.
- **Dunkler Balken am rechten Rand der Vorschau nach einem Hell-/Dunkel-Wechsel
  im laufenden Betrieb:** Die Farbe für den Bereich außerhalb der Seite wurde
  nur beim Erzeugen der WebView gesetzt und fror damit WebKits eigene Ableitung
  aus dem Dokument ein. Sie folgt jetzt jedem Wechsel.
- **Vorschau begann sichtbar tiefer als die erste Editorzeile:** Der obere
  Abstand des ersten Blocks trennte nichts und entfällt nun — besonders
  auffällig bei einer H1, deren Abstand sich auf die doppelte Schriftgröße
  bezieht.

### Geändert

- Blockelemente der Vorschau tragen jetzt ein `data-srcline`-Attribut. Beim
  Kopieren wird es entfernt, damit in Pages oder Mail nichts davon ankommt.

### Entfernt

- **Separates Markdown-Vorschaufenster:** Der Controller war zuletzt ohne
  Aufrufer — kein Menüeintrag, kein Shortcut — und von der integrierten
  Vorschau neben dem Editor vollständig abgelöst.

## [v1.25.0] — 2026-07-17

### Hinzugefügt (Wunschpaket Juli 2026, Etappe 6 — Lint, Minify, tool4d)

- **„Text → Dokument prüfen“:** native Validierung für JSON und XML
  (inkl. plist, xsd, xsl, svg und 4D-Containerdateien) mit Fehlerposition
  (Zeile/Spalte, multibyte-sicher übersetzt) und Meldung in Nutzersprache;
  ein Klick springt zur Fehlerstelle. Bewusst keine gebündelten Linter für
  JavaScript, CSS oder HTML (Größe/Lizenz/Wartung außer Verhältnis).
- **„Text → Dokument minifizieren“:** JSON kompakt über die vorhandene
  Formatter-Infrastruktur (Schlüssel werden — konsistent zum Formatieren —
  sortiert); XML bewusst konservativ: nur Einrückungs-Whitespace (mit
  Zeilenumbruch) zwischen Tags entfällt, einzelne Leerzeichen zwischen
  Inline-Elementen sowie CDATA und Kommentare bleiben unangetastet.
  Roundtrip-Tests (minify → format) sichern die Semantik.
- **tool4d-Anleitung statt Integration:** `docs/tool4d.de.md` und
  `docs/tool4d.md` beschreiben Bezug (product-download.4d.com bzw.
  4D-Analyzer-Extension) und headless-Syntaxprüfung. Die direkte Anbindung
  ist dokumentiert zurückgestellt (projektbasiertes tool4d, LSP-Aufwand,
  Nutzungsbedingungen ungeklärt — siehe ROADMAP.md); tool4d wird niemals
  gebündelt.

## [v1.24.0] — 2026-07-17

### Hinzugefügt (Wunschpaket Juli 2026, Etappe 5 — XPath-Navigation)

- **Schwebende XPath-Leiste** (⇧⌘X bzw. „Suchen → XPath-Navigation…“) für
  XML-artige Dokumente (.xml, .xsd, .xsl, .xslt, .plist, .svg-Quelltext,
  .4DCatalog, .4DSettings): Beim Tippen springt der Editor live zur ersten
  Fundstelle, Enter/Pfeile navigieren weiter; Kind-Element- und
  Attributnamen werden aus dem Dokument vorgeschlagen.
- **Dokumentiertes XPath-Teilset:** absolute/relative Pfade, `//`, `*`,
  `[n]`, `[@attr]`, `[@attr='wert']`, `@attr`, `text()` — alles andere
  meldet die Leiste verständlich als nicht unterstützt (README).
- **Eigener Index mit Quell-Offsets:** ein SAX-artiger Ein-Pass-Scanner
  arbeitet direkt auf UTF-16-Code-Units (Foundations XPath liefert keine
  Textpositionen; byteorientierte Zeilen-/Spaltenangaben wären bei
  Umlauten/Emoji falsch). Der Index entsteht asynchron im Hintergrund und
  wird bei Dokumentänderungen debounced erneuert; bei kaputtem XML bleibt
  der letzte gültige Index aktiv und der Fehler erscheint dezent in der
  Leiste. Neuer Selbsttest `xpath` (Panel-Öffnen + echter Editor-Sprung).

## [v1.23.0] — 2026-07-17

### Hinzugefügt (Wunschpaket Juli 2026, Etappe 4 — 4D-Unterstützung)

- **4D-Methoden (.4dm) mit Syntax-Highlighting:** ein eigener, leichter
  Tokenizer über CodeEditSourceEditors `HighlightProviding`-Protokoll —
  bewusst KEINE neue tree-sitter-Grammatik (Bundle wächst nur um ~24 KB).
  Erkannt werden Kommentare (`//`, `/* */`), Strings, Zahlen,
  Schlüsselwörter, mehrwortige englische Befehle und Konstanten
  (case-tolerant, Longest-Prefix, inkl. `:C…`/`:K…`-Suffixe), `$lokale`
  Variablen und `$1`-Parameter, `<>interprozess`, Prozessvariablen,
  `[Tabellen]` samt Feldern, Methodenaufrufe und Klassensyntax.
- **Befehls-/Konstantenlisten** (1270 Befehle, 2306 Konstanten) werden als
  eigene, generierte Datenstruktur aus der lokalen 4D-Dokumentation
  abgeleitet (`tools/generate-4d-symbols.py`) — reine Namenslisten, keine
  Doku-Inhalte.
- **4D-Farbthemes hell/dunkel** pro Dokument: Zeigt der Editor eine
  .4dm-Datei, gelten eigene statische Themes nach öffentlich gebündelten
  Referenzwerten (nur Vordergrundfarben und Bold/Italic; Underline kennt
  das CESE-Attributmodell nicht —
  dokumentierter Verzicht, ebenso errors/plug_ins). Ein kleiner
  `EditorTheme`-Patch in `build.sh` entkoppelt dafür drei ungenutzte
  Farb-Slots; alle bestehenden Sprachen sehen exakt unverändert aus
  (Standard-Themes belegen die Slots mit den bisherigen Sammelfarben).
- **Endungs-Mapping:** `.4DProject`/`.4DForm` → JSON-Grammatik,
  `.4DCatalog`/`.4DSettings` → XML-Pfad (HTML-Grammatik); Footer zeigt
  passende Format-Labels. Neuer Selbsttest `highlight4d` beobachtet die
  echten 4D-Vordergrundfarben im gepackten Bundle — hell UND dunkel.

## [v1.22.0] — 2026-07-17

### Hinzugefügt (Wunschpaket Juli 2026, Etappe 3 — Spracherkennung)

- **Inhaltsbasierte Spracherkennung für ungespeicherte Tabs:** Tabs ohne
  Dateiendung erhalten ihr Syntax-Highlighting jetzt aus dem Inhalt —
  konservativ und nur bei hoher Konfidenz (JSON, XML, HTML, Markdown, CSS,
  JavaScript), zusätzlich Shebang-/Modeline-Skripte über die bislang
  ungenutzte Editor-Erkennung. Nach einer Block-Einfügung (Paste) wird
  sofort analysiert, beim Tippen erst nach 0,8 s Ruhe und nur bei
  substanzieller Änderung; analysiert werden höchstens die ersten ~64 KB,
  immer im Hintergrund. Eine einmal gesetzte Erkennung flackert nicht
  (Wechsel nur bei starker Gegenevidenz). Nach dem Speichern gewinnt wie
  bisher die Dateiendung.
- **Manueller Sprachumschalter im Footer:** Der Format-Chip ist jetzt ein
  Menü. Die manuelle Wahl gewinnt immer (vor Endung und Erkennung) und
  beendet die Automatik für den Tab; „Automatisch“ schaltet sie wieder ein.
- Gespeicherte Dateien ohne Endung (z. B. Skripte) erkennen ihre Sprache
  jetzt ebenfalls per Shebang/Modeline.

## [v1.21.0] — 2026-07-17

### Hinzugefügt (Wunschpaket Juli 2026, Etappe 2 — Ansichten & Vorschau)

- **Ansichts-Umschalter Text/Vorschau/Hex:** Bietet eine Datei mehrere
  Ansichten, erscheint über dem Editorbereich ein Umschalter; zusätzlich
  gibt es Menüpunkte im „Darstellung“-Menü (⌃⌘1/2/3). Damit ist der
  vorhandene Hex-Modus für jede gespeicherte Datei manuell erreichbar.
  Die manuelle Wahl gilt pro Tab.
- **Read-only-Bildvorschau** für PNG, JPEG, GIF, HEIC, TIFF und WebP über
  ImageIO — große Bilder werden direkt auf Vorschaugröße dekodiert
  (Downsampling, nie das Vollbild im Speicher); die Kopfzeile zeigt echte
  Pixelmaße und Dateigröße. Bild- und PDF-Dateien öffnen standardmäßig in
  der Vorschau statt im Hex-Modus.
- **Read-only-PDF-Vorschau** über PDFKit mit Blättern und Zoom.
- **SVG** öffnet standardmäßig als gerenderte Vorschau; „Text“ zeigt den
  Quelltext im normalen Editor mit XML-Highlighting, Hex bleibt wählbar.
- Öffnet man einen Text-Tab mit ungespeicherten Änderungen im Hex-Modus,
  weist eine Hinweiszeile darauf hin, dass Hex den Plattenstand zeigt.
  Nach einem Hex-Schreibvorgang gleicht Fastra offene Text-Tabs derselben
  Datei über die vorhandene Extern-Änderungs-Erkennung ab.
- Hex-Bearbeitung bleibt unverändert Opt-in (Bestätigung, Änderungsvorschau,
  zweite Bestätigung); der veraltete Kommentar „Bearbeitung ist bewusst
  deaktiviert“ wurde korrigiert. Neuer Selbsttest `previewrender` beobachtet
  das echte Rendering (Pixelfarbe der Bildvorschau, Umschalter-Wirkung,
  PDF-Seite im PDFKit-Dokument).

## [v1.20.0] — 2026-07-17

### Hinzugefügt (Wunschpaket Juli 2026, Etappe 1 — UX-Verbesserungen)

- **⌘N im Willkommenszustand:** Zeigt das aktive (und einzige) Fenster nur den
  Willkommen-Tab, legt ⌘N jetzt wie ⌘T einen neuen Tab im selben Fenster an,
  statt ein zweites, fast identisches Fenster zu stapeln. In allen anderen
  Zuständen bleibt ⌘N unverändert das Fenster-Kommando. Neuer Selbsttest
  `welcomenew`; der `newwindow`-Selbsttest startet dafür aus einem normalen
  Editor-Zustand.
- **Elternordner beim Einzeldatei-Öffnen:** Öffnet man eine einzelne Datei
  (Menü, Doppelklick, Drag) und im Fenster ist kein Ordner geladen, erscheint
  der unmittelbare Elternordner der Datei als Projekt in der Seitenleiste.
  Der Editor-Fokus bleibt auf der Datei; bereits offene fremde Tabs bleiben
  bestehen. Ist schon ein Ordner offen, ändert sich nichts.
- **Standard-Speicherort:** Der „Sichern unter…“-Dialog schlägt als Zielordner
  den in der Seitenleiste markierten Ordner vor, sonst den Projektordner,
  sonst gilt das Systemverhalten. Ordner lassen sich dafür jetzt in der
  Seitenleiste per Klick markieren (Klick auf eine Datei hebt die Markierung
  auf).
- **Leere Ordner ohne Aufklapp-Chevron:** Ordner ohne sichtbaren Inhalt
  (gleiche Filterregeln wie beim Aufklappen) zeigen nur das Ordnersymbol und
  bleiben selektierbar. Die Leer-Prüfung läuft asynchron im Hintergrund und
  blockiert auch auf langsamen Volumes nichts.
- **Sichtbarer Ordnerwechsel nach Schließen:** Werden alle zum geöffneten
  Ordner gehörenden Tabs geschlossen und alle verbliebenen Dateien liegen
  unter einem anderen Ordner, wechselt die Seitenleiste auf diesen Ordner —
  nur ohne aktive Such-/Ersetzungsvorschau, nie wenn dabei ein Tab schließen
  müsste, und immer mit kurzem, nicht-modalem Hinweis in der Seitenleiste.

### Behoben

- Erscheint die Projekt-Seitenleiste programmatisch (neu: Elternordner-Öffnen),
  liefen ihre Git-Statusabfragen bisher mitten im SwiftUI-Layout-Pass. Der
  allererste Git-Verfügbarkeitscheck spinnt dabei den RunLoop (`xcode-select`
  mit `waitUntilExit`) — unter Last stürzte die App mit SIGSEGV ab. Die
  Abfragen starten jetzt erst im nächsten Main-Loop-Durchlauf.
- Der `gitactions`-Selbsttest löste Aktionen teils in dem kurzen Fenster aus,
  in dem der exklusive Git-Koordinator-Slot der Vorgänger-Aktion noch belegt
  war — die Aktion verpuffte still (in der echten UI ist der Menüpunkt dann
  deaktiviert). Der Test wartet jetzt wie ein Nutzer auf das aktive Menü.

## [v1.19.2] — 2026-07-17

### Behoben

- Neue Dokumentfenster über ⌘N übernehmen jetzt zuverlässig die Größe des
  zuletzt benutzten Dokumentfensters. SwiftUI setzte den zuvor übernommenen
  AppKit-Rahmen beim ersten Layout noch auf seine knappe Inhaltsgröße zurück;
  Fastra stellt den gewünschten Rahmen nach diesem einmaligen Layout-Schritt
  wieder her. Die technische Mindestgröße bleibt unverändert, damit Fenster
  weiterhin bewusst sehr klein gezogen werden können. Suchdialoge und
  Markdown-Vorschaufenster dienen nicht versehentlich als Größenvorlage.
- Der echte `newwindow`-Selbsttest setzt das Ausgangsfenster auf eine markante
  Größe und vergleicht nach ⌘N den tatsächlich sichtbaren `NSWindow`-Rahmen.

## [v1.19.1] — 2026-07-17

### Behoben

- SwiftUI baute das App-Menü kurz nach dem Start erneut auf und entfernte dabei
  den bereits eingefügten Sparkle-Eintrag. Fastra synchronisiert „Nach Updates
  suchen …“ jetzt nach dem Menüaufbau, bei Menüänderungen und beim Aktivieren der
  App idempotent neu. Der gepackte Selbsttest wartet gezielt bis nach diesem
  späten Wiederaufbau; ein Unit-Test schützt zusätzlich vor doppelten Einträgen.

## [v1.19.0] — 2026-07-17

### Hinzugefügt

- **Signierte Updates direkt in Fastra:** Der neue Menüpunkt „Nach Updates
  suchen …“ prüft einen signierten Appcast, lädt das notarisiert veröffentlichte
  DMG und installiert erst nach ausdrücklicher Zustimmung. Version 1.19.1
  ersetzt 1.19.0 als einmalig manuell zu installierenden Bootstrap, weil dort
  der sichtbare Menüpunkt den späten SwiftUI-Menüaufbau noch nicht überstand.

### Datenschutz und Sicherheit

- Sparkle 2.9.4 ist exakt gepinnt. App, DMG und Sparkles innere Helfer werden
  mit Developer ID signiert und von Apple notarisiert; Update-Archiv und Feed
  erhalten zusätzlich eine eigene Ed25519-Signatur. Signierte Feeds und die
  Prüfung vor dem Entpacken sind verpflichtend, Delta-Updates deaktiviert.
- Automatische Prüfungen senden kein Hardware- oder Systemprofil. Fastra
  kontaktiert nur den dokumentierten GitHub-Pages-Feed; die Installation bleibt
  immer zustimmungspflichtig.

### Qualitätssicherung

- Build, lokaler Installationspfad und Release verwenden eine gemeinsame,
  explizite Signierreihenfolge von eingebetteten Mach-O-Dateien über Sparkles
  Autoupdate und Updater bis zum äußeren App-Bundle. Der neue Selbsttest
  `updates` prüft den echten Menüpunkt und alle sicherheitsrelevanten Plist-Werte
  im gepackten Bundle.

## [v1.18.1] — 2026-07-16

### Behoben

- Der Splitter zwischen Dokumentinhalt und Markdown-Vorschau ließ sich nur
  begrenzt bewegen: Die Vorschau war auf 760 Punkte gedeckelt, weshalb der
  Dokumentinhalt in einem breiten Fenster nie schmal gezogen werden konnte —
  obwohl dasselbe schmale Layout beim Verkleinern des Fensters entstand. Die
  Vorschau darf jetzt so breit werden, wie das Fenster es zulässt; dem
  Dokumentinhalt bleiben mindestens 240 Punkte. Die gewünschte Breite bleibt
  beim Verkleinern des Fensters erhalten und kehrt beim Aufziehen zurück.
- Die Rückfrage zum automatischen Fetch sagte zu, dass „weder Dateien noch der
  aktuelle Branch“ geändert werden. `git fetch` schreibt aber sehr wohl in den
  `.git`-Ordner: Remote-Tracking-Refs, `FETCH_HEAD` und neue Objekte. Der Text
  sichert jetzt genau das zu, was tatsächlich gilt — Projektdateien und aktueller
  Branch bleiben unverändert.

## [v1.18.0] — 2026-07-16

### Hinzugefügt

- **Koordinierter Git-Status und Auto-Fetch:** Status, Branches und Graph werden
  als zusammengehöriger Repository-Snapshot geladen. Fastra koordiniert
  kollidierende Befehle über Fenster und verknüpfte Worktrees hinweg. Fetch kann
  manuell oder bei aktiver App zeitgesteuert laufen; letzter Erfolg und Fehler
  bleiben in der Seitenleiste sichtbar.
- **Sicherer Pull:** Rebase, Merge und nur Fast-Forward sind ausdrückliche
  Strategien. Vor dem Pull prüft Fastra Upstream, Arbeitsbaum, Konflikte und
  laufende Merge-/Rebase-/Cherry-pick-/Revert-Vorgänge, fragt bei lokalen
  Änderungen nach und validiert den Zustand unmittelbar vor dem Befehl erneut.
- **Reduzierter Side-by-side-Git-Diff:** Text-Patches erscheinen auf Wunsch in
  einer gemeinsamen, synchron ausgerichteten Zeilenliste mit Intra-Zeilen-
  Hervorhebung, Faltungen, Hunk-Navigation über ⌥⌘[ und ⌥⌘] sowie einer
  Übersichtsleiste. Root-, Index-, Arbeitsbaum-, Commit- und Datei-Diffs nutzen
  jeweils eine typisierte Vergleichsbasis.
- **Konflikthilfe im normalen Editor:** Normale und diff3-Marker lassen sich
  blockweise ansteuern; oberer, unterer oder beide Blöcke werden über die native
  Editor-Mutation übernommen und bleiben mit Befehl-Z rückgängig. Binäre, nicht
  sicher dekodierbare und nur abschnittsweise geladene Dateien zeigen stattdessen
  eine klare Grenze. Merge, Rebase, Cherry-pick und Revert lassen sich nach
  erneuter Prüfung fortsetzen oder abbrechen; Rebase unterstützt zusätzlich Skip.
- **Kuratierte Git-Aktionen:** Neuer Branch, Stash mit oder ohne unversionierte
  Dateien, Stash Pop, Cherry-pick und Revert ergänzen die vorhandenen Aktionen.
  Force Push ist ausschließlich mit einem exakten `--force-with-lease`-Ziel und
  eigener Bestätigung verfügbar. Git-Identität kann repository-lokal oder nach
  einer zweiten Bestätigung global als zusammengehöriges Name/E-Mail-Paar
  konfiguriert werden.
- **Nativer Terminalaufruf:** „Terminal im aktuellen Ordner …“ übergibt die
  Projekt- beziehungsweise Dateiverzeichnis-URL direkt an Terminal.app, ohne
  Shell- oder AppleScript-Konstruktion.

### Geändert

- Git-Status verwendet `git status --porcelain=v2 --branch -z`; Status-, Graph-
  und Diff-Protokolle behandeln NUL-getrennte rohe Pfade verlustfrei. Nicht als
  UTF-8 adressierbare Pfade bleiben sichtbar, sperren aber gezielt nur die nicht
  verlustfrei mögliche Einzeldateiaktion.
- HEAD im Graphen folgt ausschließlich der exakten Status-OID und bleibt auch
  bei Detached HEAD und Merge-Commits eindeutig. Graph-Dateien und Metadaten
  werden bytebasiert aus einem begrenzten `git log -z`-Protokoll gelesen.
- Ahead/Behind erklärt, mit welchem Remote-Tracking-Stand verglichen wird. Die
  Git-Einstellungen steuern Fetch-Intervall, Aktivierungs-Fetch, Remote-Auswahl,
  Prune und Pull-Strategie, ohne Git-Konfiguration still zu verändern.
- Git-Aktionen teilen einen app-weiten Busy-Zustand; Menüs, Konfliktleiste und
  Graph-Kontextaktionen besitzen lokalisierte Hilfetexte und passende
  Accessibility-Beschriftungen beziehungsweise -Hinweise.

### Sicherheit

- Große Textdateien behalten ihr erkanntes Encoding und ihre ursprüngliche BOM
  bis in die abschnittsweise Ansicht. UTF-8-Skalare sowie UTF-16-Codeunits und
  Surrogatpaare werden an 256-KiB-Grenzen nicht mehr getrennt; jede Seite wird
  streng und ohne erfundene Ersatzzeichen dekodiert. Auch eine ausdrückliche
  Encoding-Wahl umgeht die read-only-Grenze für Dateien über 32 MiB nicht.
- BOM-loses UTF-16 wird nicht mehr aus Nullbyte-Parität erraten, weil dieselben
  Bytes ebenso 16-Bit-PCM-/UInt16-Binärdaten sein können. Solche Dateien öffnen
  automatisch fail-closed als Hex; bekanntes BOM-loses UTF-16 bleibt über die
  ausdrückliche Aktion „Neu öffnen mit Encoding“ verfügbar.
- Git-Prozesse laufen ohne Shell, ohne interaktive Credential-/Askpass-Abfrage,
  mit begrenzter Ausgabe und Zeitlimit. Bei Abbruch oder Timeout werden auch
  von Git gestartete Hooks und Helper derselben Prozessgruppe beendet. Eine
  eigene priorisierte Deadline-Queue hält diese Fristen auch unter hoher
  paralleler Last zuverlässig ein.
- „Als gelöst markieren“ schreibt nicht über `git add` aus einem möglicherweise
  veralteten Arbeitsbaum. Fastra prüft gespeicherte Bytes, Attribute,
  Konvertierungskonfiguration, Indexstufen und HEAD mehrfach, erzeugt den Blob
  mit den für den Pfad gültigen Git-Filtern und setzt genau einen Stage-0-Eintrag,
  während Git selbst Index- und Ref-Locks hält. Die Aktion commitet oder pusht
  nicht.
- Vor jeder Textauflösung fragt Fastra die pfadspezifischen Attribute mit
  `git check-attr -z` ab. Von Git durch `binary`, `-text`, `-diff` oder den
  binären Merge-Treiber klassifizierte Konflikte bleiben auch bei reinem
  UTF-8-Arbeitsbauminhalt im Terminalpfad; dieselbe Prüfung sperrt den finalen
  Stage-0-Pfad erneut.
- Identitätsabhängige Commits und Identitätsschreibvorgänge teilen eine
  app-weite Schranke. Include- und `includeIf`-Werte werden bei Reads beachtet;
  Teilfehler beim paarweisen Schreiben rollen auf den vorherigen Stand zurück.
- Push mit Lease bindet Quell-OID, Remote, Ziel-Ref und erwartete entfernte OID
  vor der Bestätigung fest. Ein nacktes `--force` wird nicht angeboten.

### Qualitätssicherung

- Neue Pure-, Prozess- und Repository-Integrationstests decken bytebasierte
  Pfade, Status/Graph/Diff, Koordination, Fetch/Pull, Konfliktmarker, Undo,
  Git-Locks, Filter und Encodings, laufende Operationen, Zusatzaktionen,
  Force-with-Lease, Identity-Includes und Abbruch-/Timeout-Races ab. Reale Git-
  Tests verwenden ausschließlich temporäre Repositories und lokale Bare-Remotes.
- Lokalisierungs-Audit und Tests erfassen zusätzlich dynamische Git-Aktions-
  und Erfolgstexte. Die getrennte visuelle Abnahme in Deutsch und Englisch,
  Light, Dark und erhöhtem Systemkontrast prüfte Tastatur, Tooltips, den von
  VoiceOver genutzten Accessibility-Baum und den echten Editor-Delegate.
- Verifizierter Abschlusslauf: 969 Swift-Tests in 28 Suiten, Lokalisierungs-
  Audit, Debug-Build, portable App samt gepacktem Lokalisierungs-Selbsttest und
  26 In-App-Selbsttests bestanden jeweils mit Exit 0. Release-Build, Signatur,
  Notarisierung und Veröffentlichung waren nicht Teil dieses Laufs.

## [v1.17.3] — 2026-07-15

### Behoben

- Eine frische Installation startet nicht mehr mit dem automatisch erzeugten
  Musterdokument `contacts.md`, das wie eine unbekannte fremde Datei wirken
  konnte, sondern immer mit dem erklärenden Willkommensbildschirm ohne
  vorbelegte Such- oder Ersetzungsdaten.
- Das DMG-Fenster berücksichtigt den höheren Finder-Chrome aktueller
  macOS-Versionen und zeigt seinen Hintergrund bis zur unteren Anleitung
  vollständig statt abgeschnitten.

### Geändert

- Der reproduzierbar erzeugte DMG-Hintergrund verwendet für den Programmtitel
  Sora SemiBold und beschreibt Fastra als „Native macOS text editor“.

## [v1.17.2] — 2026-07-15

### Behoben

- Neue Dokumentfenster über ⌘N übernehmen weiterhin ausreichend große
  Vorderfenster, starten nach kleinen oder fehlerhaft restaurierten Frames aber
  mindestens in der normalen Größe 1100 × 720 statt in der knappen technischen
  Mindestgröße.

## [v1.17.1] — 2026-07-15

### Behoben

- Notarisierte Installationen und Releases prüfen das lokale notarytool-Profil
  jetzt vor dem teuren Build. Auf einem neuen Mac führt ein interaktiver,
  clone-lokaler Bootstrap durch die Keychain-Einrichtung, ohne Credentials,
  Apple-ID oder internen Profilnamen ins öffentliche Repository zu schreiben.
  Nichtinteraktive Läufe brechen früh mit einer sicheren Einrichtungsanleitung
  ab, statt erst beim Upload nach dem Build zu scheitern.

## [v1.17.0] — 2026-07-15

### Hinzugefügt

- Die lokale Markdown-Vorschau zeigt relative Rasterbilder aus dem Ordner der
  geöffneten Markdown-Datei, TeX-Formeln in `$…$` und `$$…$$`, Mermaid-Diagramme
  aus `mermaid`-Code-Blöcken sowie Syntaxhervorhebung in übrigen Code-Blöcken.
- KaTeX, Mermaid und highlight.js werden mit ihren Lizenzen im App-Bundle
  mitgeliefert. Die Vorschau benötigt dafür weder ein CDN noch eine andere
  Netzverbindung.

### Geändert

- Die Suchdialog-Screenshots in beiden READMEs erscheinen mit 84,2 Prozent der
  Dokumentfensterbreite. Damit entspricht ihre Darstellung wieder dem realen
  Fensterbreitenverhältnis von 640 zu 760 Punkten.
- Release- und Installationsskript können den lokalen Notary-Profilnamen aus
  `fastra.notaryProfile` in der nicht veröffentlichten `.git/config` lesen;
  eine explizite `NOTARY_PROFILE`-Umgebungsvariable hat weiterhin Vorrang.

### Sicherheit

- Ein internes URL-Schema liefert ausschließlich freigegebene Render-Ressourcen
  und lokale Rasterbilder bis 32 MiB. Remote-Bilder, freie Dateipfade und SVG-
  Ressourcen bleiben gesperrt; eine Content Security Policy unterbindet
  Netz-Subressourcen, Frames und Medien.
- Mermaid läuft im strikten Sicherheitsmodus ohne HTML-Beschriftungen; KaTeX
  rendert ohne vertrauenswürdige Befehle als natives MathML.

### Qualitätssicherung

- Zehn Markdown-Unit-Tests sichern GFM, Bildpfade, Netzsperre, Formelsemantik,
  Code-Ausnahmen, CSP, Bibliotheken und Mermaid-Verdrahtung. Alle 784 Swift-Tests
  sind erfolgreich.
- Der neue In-App-Selbsttest `markdown` beobachtet im echten WebKit-DOM ein
  dekodiertes lokales Bild, KaTeX-MathML, Mermaid-SVG und hervorgehobenen Code.
  Die Portabilitätsprüfung kontrolliert zusätzlich die Render-Bibliotheken im
  gepackten Ressourcenbundle.

## [v1.16.17] — 2026-07-15

### Behoben

- Ein mit ⌘N geöffnetes leeres Dokumentfenster erhält jetzt zuverlässig
  den Tastaturfokus und einen gültigen Einfügepunkt. Text kann dadurch sofort
  getippt oder aus der Zwischenablage eingefügt werden.

### Qualitätssicherung

- Der Mehrfenster-Selbsttest prüft nach einem echten ⌘N das neue Key-Window,
  dessen reale Editor-TextView als First Responder und den Einfügepunkt am
  Dokumentanfang.

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
