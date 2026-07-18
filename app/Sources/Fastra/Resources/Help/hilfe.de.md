# Fastra-Hilfe

Fastra ist ein nativer macOS-Texteditor für sichere, visuell überprüfbare
Suche und Ersetzung über Dateien und Ordner. Der Kern: **Vor jeder
Mehrfachänderung siehst du eine vollständige Vorschau** — Fastra schreibt
nie in Dateien, ohne dass du die Auswirkungen vorher gesehen hast.

## Suchen und Ersetzen

⌘F öffnet die Suchmaske (⇧⌘F direkt im Ordner-Bereich; ⌘E übernimmt die
aktuelle Auswahl als Suchbegriff). Die Suche läuft **live beim Tippen**
und zeigt jeden Treffer sowohl in der Trefferliste als auch als
Markierung im Dokument.

**Suchbereiche** (oben in der Maske):

- **Datei** — der aktive Tab.
- **Geöffnet** — alle offenen Tabs (auch ungespeicherte).
- **Ordner** — die aktivierten Ordner auf der Platte. Die Live-Suche
  startet ab 3 Zeichen; „Suchen“ bzw. Return erzwingen sie jederzeit.
- **Projekt** — der Projektordner, eingeschränkt über Datei-Sets und
  Ausschlussmuster.

**Platzhalter (Wildcards):** Ohne RegEx-Modus steht `*` für beliebigen
Text **innerhalb einer Zeile**, `**` auch **über Zeilengrenzen hinweg**.
Jeder Platzhalter wird automatisch zu einer Capture-Gruppe: Die Pillen
(`$1`, `$2` …) unter dem Ersetzen-Feld lassen sich **anklicken oder per
Drag-and-drop** ins Ersetzen-Feld ziehen. Beispiel: Suchen `*, the`,
Ersetzen `The *` macht aus „ring, The“ → „The ring“. Der Schalter
„∗ wörtlich“ behandelt `*` als normales Zeichen.

**RegEx:** Der RegEx-Schalter aktiviert reguläre Ausdrücke
(ICU-Syntax, wie `NSRegularExpression`). Capture-Gruppen erscheinen
ebenfalls als Pillen. „Aus Beispiel…“ leitet ein Muster aus einem
Vorher/Nachher-Beispiel ab.

**Optionen:** Groß-/Kleinschreibung, „Ganzes Wort“, „Wrap-around“ und
„Nur in Auswahl“ (sucht ausschließlich in der eingefrorenen Selektion).

**Ersetzen:**

- „Ersetzen“ ersetzt nur den aktiven Treffer und springt weiter.
- „Alle ersetzen · N“ (⌘Return) ersetzt alle Treffer des Suchbereichs.
- „Vorschau der Änderungen“ zeigt vor dem Ersetzen jede betroffene Zeile
  als Vorher/Nachher-Diff. Angewendet wird **exakt** die angezeigte
  Trefferbasis — das ist eine Sicherheitsgarantie.
- Im Ordner-/Projekt-Bereich schreibt Fastra atomar pro Datei und legt
  automatisch ein Backup an; „Rückgängig“ spielt die letzte
  Ordner-Ersetzung bit-exakt zurück.

**Navigation:** Return bzw. ⌘G springt zum nächsten, ⇧⌘G zum vorherigen
Treffer; die Pfeiltasten wandern durch die Trefferliste, die dabei zum
aktiven Treffer scrollt. Escape blendet die Maske aus.

## Dateien vergleichen

**Suchen → Dateien vergleichen…** (⌃⌘D) stellt zwei Dateien nebeneinander —
ganz ohne Git. Links und rechts lassen sich per Auswahl-Dialog, per
Drag-and-drop oder aus offenen Tabs und zuletzt geöffneten Dateien belegen;
der aktive Tab ist links vorbelegt.

- **Optionen:** Leerraum am Zeilenende, alle Leerraum-Unterschiede,
  Leerzeilen sowie Groß-/Kleinschreibung lassen sich beim Vergleich
  ignorieren. Aktive Optionen stehen sichtbar im Kopf der Ansicht.
- **Differenzen-Liste:** Unter dem Diff listet Fastra jeden Unterschied
  („Zeilen 12–14 geändert“, „Zeile 30 nur links“). Ein Klick springt
  dorthin; ⌥↑/⌥↓ wandern zum vorigen/nächsten Unterschied.
- **Lange gleiche Abschnitte** sind eingeklappt und lassen sich pro
  Abschnitt einblenden.
- **Mit gespeicherter Fassung vergleichen** vergleicht den ungespeicherten
  Editor-Inhalt des aktiven Tabs direkt mit dem Stand auf der Platte —
  praktisch vor dem Speichern.
- Identische Dateien meldet Fastra ausdrücklich; binäre, fehlende oder
  extrem große Dateien erklären sich mit einer verständlichen Meldung
  statt eines irreführenden Diffs.

Der Vergleich zeigt nur an — er ändert nie Dateien.

## Text-Transformationen

Alle Transformationen wirken auf die Selektion — ohne Selektion auf das
ganze Dokument. Erreichbar über das Menü **Text** und das
Rechtsklickmenü im Editor.

- **Buchstaben:** GROSSBUCHSTABEN, kleinbuchstaben, Wörter Groß.
- **Whitespace:** Leerzeichen am Zeilenende entfernen, Tabs → Leerzeichen,
  Leerzeichen → Tabs, Einrücken, Ausrücken, Zeilen hart umbrechen…
- **Zeilen:** Zeilen umkehren, Leerzeilen entfernen, Zeilen verbinden
  (mit/ohne Leerzeichen), Präfix/Suffix an Zeilen…, Zeilennummern
  hinzufügen/entfernen, Nur Zeilen mit Treffer behalten…, Zeilen mit
  Treffer löschen…, Nur doppelte Zeilen behalten, Mehrfach vorkommende
  Zeilen entfernen.
- **Zeichen:** Steuerzeichen entfernen, Anführungszeichen gerade richten,
  Anführungszeichen schwungvoll (englisch), Escape-Sequenzen auflösen,
  Zeichen tauschen, Wörter tauschen.
- **Unicode:** Leerzeichen vereinheitlichen, Diakritische Zeichen
  entfernen, Unicode zusammensetzen (NFC), Unicode zerlegen (NFD).

Zusätzlich im Text-Menü: **Dokument formatieren** (JSON/XML hübsch
einrücken), **Dokument prüfen** (Syntaxprüfung mit Fehlerposition) und
**Dokument minifizieren** — für unterstützte Formate wie JSON und XML.

## Ansichten: Text, Vorschau, Hex

Der Umschalter rechts in der Fußzeile erscheint, sobald eine Datei mehr
als eine Ansicht bietet:

- **Text** — der normale Editor.
- **Vorschau** — Markdown gerendert, Bilder, PDFs und SVGs dargestellt.
- **Hex** — der gespeicherte Stand der Datei als Hexdump; ungespeicherte
  Änderungen des Text-Tabs sind dort nicht enthalten. Binärdateien
  öffnen direkt in der Hex-Ansicht, sehr große Textdateien in einer
  abschnittsweisen Ansicht.

## Markdown

Bei Markdown-Dateien zeigt die geteilte Ansicht rechts die gerenderte
Vorschau: Tabellen, Codeblöcke mit Syntaxfarben, Formeln (KaTeX) und
Mermaid-Diagramme — vollständig lokal, ohne Netzzugriff. Ein **Klick in
die Vorschau** springt im Editor zur passenden Quellzeile. Kopieren aus
der Vorschau liefert echten Rich-Text (Überschriften, Listen, Fettung
bleiben erhalten).

## Markdown schreiben

Bei Markdown-Tabs erscheint über dem Editor eine **Format-Toolbar**; die
gleichen Befehle liegen im Menü „Markdown“ und im Rechtsklickmenü. Sie
wirken als normale, mit ⌘Z widerrufbare Textänderungen auf die Auswahl
bzw. die Cursor-Zeile: Fett (⌘B), Kursiv (⌘I), Code (⇧⌘K),
Überschrift 1–3 (⌘⌥1–3), zurück zu normalem Text (⌘⌥0), Aufzählung
(⇧⌘8), nummerierte Liste (⇧⌘7), Zitat (⇧⌘9), Link (⌘K) und
„Tabelle einfügen…“ (kleiner Dialog: Spalten, Kopfzeile ja/nein).

**Bilder einfügen:** Ein Bild aus der Zwischenablage (⌘V) legt Fastra
als Datei **neben dem Dokument** ab (`dokumentname-JJJJ-MM-TT-hhmmss.png`;
PNG/JPEG/GIF behalten ihr Format, alles andere wird PNG) und verlinkt es
relativ an der Cursorposition. Eine **Bilddatei per Drag-and-drop** in
den Markdown-Editor wird unverändert in den Dokumentordner kopiert
(Namenskollision → Suffix; byte-identische Datei wird nicht doppelt
abgelegt) und ebenfalls relativ verlinkt — andere Dateien öffnen wie
gewohnt in einem Tab. Nach dem Einfügen scrollt die Vorschau zur
Einfügestelle. Ungespeicherte Dokumente haben noch keinen Ordner —
deshalb zuerst speichern (⌘S).

## Sprachen und Syntaxfarben

Fastra erkennt die Sprache an der Dateiendung, bei endungslosen Dateien
am Inhalt. Der Sprach-Chip in der Fußzeile öffnet das Sprachmenü: Die
manuelle Wahl gewinnt immer vor der Automatik, „Automatisch“ kehrt zu
ihr zurück.

## 4D-Unterstützung

`.4dm`-Methoden werden mit einem eigenen 4D-Farbschema dargestellt
(Befehle, Keywords, Variablen, Kommentare wie im 4D-Editor). Über das
Sprachmenü lässt sich 4D auch für andere Dateien manuell aktivieren.
`.4DProject`/`.4DForm` sind echte JSON-Dateien, `.4DCatalog`/
`.4DSettings` echtes XML — sie öffnen mit JSON- bzw. XML-Darstellung.

## XPath-Leiste

Für XML-artige Dokumente blendet ⇧⌘X die XPath-Leiste ein: XPath-Abfrage
eintippen, Fastra zählt die Treffer und springt beim Navigieren an die
Fundstellen im Dokument.

## Projekt und Seitenleiste

Beim Öffnen einer Einzeldatei zeigt die Seitenleiste automatisch den
passenden Ordner — liegt die Datei in einem Git-Repository, dessen
Wurzelordner. Der Kopf der Seitenleiste zeigt den Projektnamen (Tooltip:
voller Pfad); **⌘-Klick auf den Namen** öffnet ein Menü der
Nachbarordner zum schnellen Projektwechsel, das Rechtsklickmenü bietet
„Im Finder zeigen“ und mehr. **⌘-Klick auf einen Dokument-Tab** zeigt
das macOS-Pfadmenü der Datei. Der Dateibaum kann Dateien und Ordner
anlegen, umbenennen und in den Papierkorb legen.

## Git

Ist das Projekt ein Git-Repository (und `git` installiert), zeigt die
Seitenleiste zusätzlich die Tabs **Änderungen** und **Graph**:

- Branch-Zeile mit Branch-Wechsel, Ahead/Behind und Fetch.
- **Änderungen:** Dateien bereitstellen/entnehmen, verwerfen, Commit
  direkt aus der Seitenleiste; Push und Pull laufen asynchron.
- **Graph:** der Commit-Graph mit Verzweigungen und Merges.
- Verlauf (`git log`) und Diffs öffnen als schreibgeschützte Tabs; ein
  Klick auf einen Commit-Hash zeigt dessen Details.
- Merge-Konflikte bekommen eine eigene Leiste mit sicheren
  Auflösungsschritten.

Fastra ist dabei ein dünnes Frontend über das installierte `git` —
destruktive Operationen verlangen eine sichtbare Bestätigung.

## Encoding und Zeilenenden

Die Fußzeile zeigt Encoding und Zeilenende des aktiven Tabs:

- **Encoding-Chip:** „Neu öffnen mit Encoding“ lädt die Datei mit einem
  anderen Encoding neu von der Platte.
- **Zeilenenden-Chip:** wählt LF, CRLF oder CR — die Umstellung wirkt
  beim nächsten Speichern.

## Fenster und Tabs

⌘T öffnet einen neuen Tab, ⌘N ein zweites, vollständig unabhängiges
Fenster (eigene Tabs, eigene Suche). ⌘S speichert, ⌘W schließt den Tab —
bei ungespeicherten Änderungen fragt Fastra nach. ⌘J springt zu einer
Zeilennummer.
