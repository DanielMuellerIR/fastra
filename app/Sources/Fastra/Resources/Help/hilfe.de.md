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
Ersetzen `The *` macht aus „ring, The“ → „The ring“. Der immer sichtbare
Schalter „∗ wörtlich“ behandelt `*` als normales Zeichen. Er ist nur aktiv,
wenn RegEx aus ist und der Suchausdruck mindestens ein `*` enthält.

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
- Im Ordner-/Projekt-Bereich prüft Fastra vor dem ersten Schreiben noch einmal
  alle Dateien gegen die sichtbare Vorschau. Geänderte Dateien und betroffene
  Tabs mit ungespeicherten Änderungen blockieren den gesamten Vorgang. Planung,
  Backup und Schreiben laufen mit Fortschrittsanzeige im Hintergrund; ein
  Abbruch vor der kurzen Schreibphase verändert keine Zieldatei.
- Fastra schreibt atomar pro Datei und legt automatisch ein Backup an.
  „Rückgängig“ spielt nur tatsächlich angewendete Dateien bit-exakt zurück und
  bricht ab, wenn sich eine davon nach dem Ersetzen erneut geändert hat.

**Navigation:** Return bzw. ⌘G springt zum nächsten, ⇧⌘G zum vorherigen
Treffer; die Pfeiltasten wandern durch die Trefferliste, die dabei zum
aktiven Treffer scrollt. Escape blendet die Maske aus.

## Dateien vergleichen

**Suchen → Dateien vergleichen…** (⌃⌘D) stellt zwei Dateien nebeneinander —
ganz ohne Git. Links und rechts lassen sich per Auswahl-Dialog, per
Drag-and-drop oder aus offenen Tabs und zuletzt geöffneten Dateien belegen;
der aktive Tab ist links vorbelegt.

- **Zwei offene Tabs vorwählen:** Erst den aktuellen Dokument-Tab festlegen,
  dann mit gedrückter Shift-Taste einen zweiten normalen Text-Tab anklicken.
  Der aktuelle Tab bleibt mit der stärkeren grauen Fläche eindeutig aktiv;
  der Vergleichspartner erscheint schwächer grau. Im Rechtsklickmenü eines
  der beiden Tabs öffnet „Dateien vergleichen…“ den Dialog mit beiden
  Dokumenten bereits links und rechts ausgewählt. Ein weiterer Shift-Klick
  ersetzt bzw. entfernt den Partner, ein normaler Tab-Klick hebt die
  Paar-Auswahl auf.
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
- **Zeilen:** alphabetisch auf-/absteigend sortieren, Zeilen umkehren,
  Leerzeilen entfernen, Zeilen verbinden (mit/ohne Leerzeichen),
  Präfix/Suffix an Zeilen…, Zeilennummern hinzufügen/entfernen, Nur Zeilen
  mit Treffer behalten…, Zeilen mit Treffer löschen…, Nur doppelte Zeilen
  behalten, Mehrfach vorkommende Zeilen entfernen.
- **Zeichen:** Steuerzeichen entfernen, Anführungszeichen gerade richten,
  Anführungszeichen schwungvoll (englisch), Escape-Sequenzen auflösen,
  Zeichen tauschen, Wörter tauschen.
- **Unicode:** Leerzeichen vereinheitlichen, Diakritische Zeichen
  entfernen, Unicode zusammensetzen (NFC), Unicode zerlegen (NFD).

Zusätzlich im Menü **Text** und im Rechtsklickmenü: **Dokument
formatieren** (JSON/XML hübsch einrücken), **Dokument prüfen**
(Syntaxprüfung mit Fehlerposition) und **Dokument minifizieren**. Die drei
Einträge sind nur aktiv, wenn die Dateiendung des Tabs passt — formatiert
und minifiziert werden `json`, `xml`, `xsd`, `xsl`, `xslt` und `plist`,
geprüft zusätzlich `svg` und die 4D-Containerdateien. Ein neuer,
ungespeicherter Tab hat keine Endung; benenne ihn beim Sichern etwa
`daten.json`, dann sind die Einträge wählbar.

## Gehe zum Ziel

**Alt-Doppelklick** auf einen Namen springt zur Definition — nach dem
Vorbild des 4D-Methodeneditors:

- **4D (`.4dm`):** Ein Methodenname öffnet die Projektmethode
  (`Project/Sources/Methods/…`), ein Klassenname die Klassendatei;
  `Function`-Definitionen in der aktuellen Klassendatei springen lokal.
  Ist nichts davon auffindbar, öffnet Fastra die Projektsuche mit dem
  Namen — nie ein stiller Fehlschlag.
- **Markdown:** Relative Dateipfade in Links/Bildern öffnen im Editor,
  `http(s)`-/`mailto`-Adressen im Browser, `#anker` springen zur
  Überschrift in der Datei.

Die Alt-Drag-Spaltenauswahl bleibt unberührt (sie beginnt mit einem
Einzelklick). Nicht auflösbare Ziele melden sich mit einem kurzen
Aufblitzen und einem Hinweis in der Seitenleiste.

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

### Besondere Vorschau-Syntax

Fastra verwendet GitHub-Flavoured Markdown und ergänzt es in der Vorschau um
die folgenden lokalen Darstellungen.

**Sichtbare Leerzeilen:** Eine Quellzeile ausschließlich aus mindestens zwei
normalen ASCII-Leerzeichen (`U+0020 U+0020`) erscheint als genau eine
vollständig leere Textzeile. Im folgenden Beispiel steht `␠` zur Erklärung für
ein normales Leerzeichen; die Zeichen `␠` werden nicht mit eingegeben:

```text
Erster Absatz
␠␠
Zweiter Absatz
```

Eine leere Zeile oder genau ein Leerzeichen folgt weiterhin CommonMark. Zwei
Leerzeichen am Ende einer **nichtleeren** Zeile und ein Backslash bleiben
normale harte Umbrüche. In eingerückten oder mit Backticks/Tilden begrenzten
Codeblöcken gilt die Erweiterung nicht. Beim Kopieren wird die sichtbare
Leerzeile als normaler Zeilenumbruch übernommen.

**Textmarker:** Text zwischen zwei Gleichheitszeichen-Paaren wird mit einem
festen, zum hellen oder dunklen Erscheinungsbild passenden Hintergrund
hervorgehoben, zum Beispiel `==wichtig==`. Andere Markdown-Auszeichnungen
können darin verschachtelt werden; in Inline-Code und Codeblöcken bleiben die
Gleichheitszeichen wörtlich. Diese Schreibweise ist eine Fastra-Erweiterung und
gehört nicht zum GFM-Standard.

**Formeln (KaTeX):** Formeln stehen inline zwischen einzelnen Dollarzeichen,
zum Beispiel `$E = mc^2$`. Ein eigener Formelblock beginnt und endet mit je
zwei Dollarzeichen:

```text
$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$
```

**Mermaid-Diagramme:** Ein Codeblock mit der Sprache `mermaid` wird als Diagramm
gerendert. Andere Codeblöcke bleiben normaler, syntaxhervorgehobener Code:

````markdown
```mermaid
flowchart LR
  Start --> Prüfung
  Prüfung --> Ergebnis
```
````

KaTeX und Mermaid werden aus der App geladen und vollständig lokal ausgeführt;
die Vorschau benötigt dafür keinen Netzzugriff.

## Markdown schreiben

Bei Markdown-Tabs erscheint über dem Editor eine **Format-Toolbar**; die
gleichen Befehle liegen im Menü „Markdown“ und im Rechtsklickmenü. Sie
wirken als normale, mit ⌘Z widerrufbare Textänderungen auf die Auswahl
bzw. die Cursor-Zeile: Fett (⌘B), Kursiv (⌘I), Hervorheben (⇧⌘H),
Code (⇧⌘K),
Überschrift 1–3 (⌘⌥1–3), zurück zu normalem Text (⌘⌥0), Aufzählung
(⇧⌘8), nummerierte Liste (⇧⌘7), Zitat (⇧⌘9), Link (⌘K) und
„Tabelle einfügen…“ (kleiner Dialog: Spalten, Kopfzeile ja/nein).

Der Toolbar-Befehl **Harter Zeilenumbruch** fügt am Ende der Auswahl zwei
normale Leerzeichen und anschließend einen normalen Zeilenumbruch ein. Steht
der Cursor bereits direkt vor einem Zeilenumbruch, ergänzt bzw. vereinheitlicht
er nur die zwei Leerzeichen. So bleibt die zugrunde liegende Markdown-
Schreibweise sichtbar und mit ⌘Z widerrufbar.

**Formatiert als Markdown einfügen** (⇧⌘V) wandelt HTML- oder RTF-Inhalt aus
Browsern und Office-Programmen mit dem separat installierten Werkzeug
`md-clip` um. Fastra bindet Fenster, Tab, Editor und Auswahl beim Start der
Umwandlung. Wechselst du währenddessen das Ziel oder bearbeitest den Inhalt,
wird kontrolliert abgebrochen und nichts in ein anderes Dokument eingefügt.

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

## Soft Wrap

Der kompakte **Soft-Wrap-Schalter** steht in der Fußzeile direkt neben
dem Sprach-Chip. Er zeigt **Ein** oder **Aus** sichtbar an; ein Hauptklick
schaltet sofort um. Der separate Pfeil und ein Rechtsklick öffnen dieselben
Optionen. **Darstellung → Soft Wrap** (⇧⌘L) schaltet denselben Wert.

Soft Wrap wird **pro effektivem Dokumentformat** gespeichert und gilt
appweit für alle offenen und später geöffneten Dokumente dieses Formats.
Eine manuelle Sprachwahl bestimmt deshalb auch, welches Formatprofil gilt.
Im Optionsmenü entfernt „Für … auf Werkseinstellung zurücksetzen“ nur die
eigene Abweichung des aktuellen Formats.

Als **Umbruchziel** stehen Fensterbreite, die Seitenlinie (Page Guide) und
eine feste Spalte zur Wahl. Für feste Breiten gibt es die Vorgaben 72, 80,
100 und 120 sowie eine freie Eingabe von Spalte 20 bis 500. Die Zielwahl
schaltet Soft Wrap zugleich ein. Ist das Fenster schmaler als das gewählte
Ziel, wird am Fensterrand umbrochen.

Die **Seitenlinie** ist davon unabhängig einblendbar: im Soft-Wrap-
Optionsmenü, unter **Darstellung → Seitenlinie anzeigen** oder in den
Einstellungen unter **Editor**. Ihre appweite Spalte lässt sich dort
ebenfalls wählen; Vorgabe ist 80. Beim Umbruch bevorzugt Fastra
Wortgrenzen. Ein einzelnes langes Wort wird zeichenweise umbrochen, ohne
ein Unicode-Zeichen zu zerlegen.

Werkseitig ist Soft Wrap für **Reinen Text, Markdown, HTML und XML ein**.
Für **4D, JSON, CSV und andere Code-/Konfigurationsformate ist es aus**.
Ohne Soft Wrap bleiben lange Zeilen über den horizontalen Scrollbalken
erreichbar. Das Umschalten ändert weder Text noch Auswahl, Rückgängig-
Verlauf oder gespeicherte Datei. Die oberste angezeigte Textzeile bleibt dabei
ruhig an derselben Stelle.

## Rechteckauswahl

Mit **Alt-Drag** markiert Fastra denselben Spaltenbereich über mehrere
**logische Textzeilen**. Das funktioniert auch bei Soft Wrap: Eine lange
Zeile bleibt genau eine Rechteckzeile, selbst wenn sie sichtbar über mehrere
Umbruchfragmente läuft. Kurze und leere Zeilen, Tabs, CRLF und
zusammengesetzte Unicode-Zeichen werden nicht künstlich zerlegt.

**Kopieren, Ausschneiden, Löschen, Tippen und normales Einfügen** wirken auf
alle Teilbereiche. Eine einzelne Clipboard-Zeile füllt jede Rechteckzeile;
mehrere Clipboard-Zeilen werden der Reihe nach verteilt. Hat das Clipboard
weniger Zeilen, werden die übrigen Rechteckteile geleert. Ein Überschuss wird
unter dem Rechteck fortgesetzt. Jede solche Mehrfachänderung ist mit einmal
⌘Z vollständig widerrufbar.

Unter **Bearbeiten** und im Rechtsklickmenü steht **Spalte einfügen**
(⌃⌘V). Der Befehl setzt Clipboard-Zeilen untereinander an der linken
Rechteckkante oder — ohne Rechteck — am Cursor ein. Zu kurze Zielzeilen
werden bis zur Zielspalte aufgefüllt; ganze Tabstopps verwenden Tabs, wenn
das aktive Einrückungsprofil Tabs verwendet, ein Rest bleibt als Leerzeichen.

**Rechteckauswahl nach oben/unten** (⌃⇧↑/↓) erweitert oder verkleinert ein
Rechteck um eine logische Zeile. Zeichenbezogene Befehle wie Groß-/Klein-
schreibung, Anführungszeichen- und Unicode-Transformationen arbeiten auf
jedem Rechteckteil getrennt. Befehle für ganze Zeilen oder mögliche neue
Zeilenumbrüche sind während einer Rechteckauswahl gesperrt und erklären den
Grund, damit nichts außerhalb des sichtbaren Rechtecks geändert wird.

## 4D-Unterstützung

`.4dm`-Methoden werden mit einem eigenen 4D-Farbschema dargestellt
(Befehle, Keywords, Variablen, Kommentare wie im 4D-Editor). In einem
geöffneten Projekt erkennt Fastra zusätzlich Methoden aus
`Project/Sources/Methods` unabhängig von Groß-/Kleinschreibung und hebt sie
klar anders als Prozessvariablen hervor; `[Tabelle:1]` bleibt eine Tabelle.
Über das
Sprachmenü lässt sich 4D auch für andere Dateien manuell aktivieren.
`.4DProject`/`.4DForm` sind echte JSON-Dateien, `.4DCatalog`/
`.4DSettings` echtes XML — sie öffnen mit JSON- bzw. XML-Darstellung.

**Vervollständigung:** In `.4dm`-Methoden schlägt Fastra ab zwei
eingegebenen Zeichen Befehle (mit Syntax-Signatur) und Konstanten vor — Esc
oder ⌃Leertaste
öffnen die Liste auch manuell, ↑/↓ wählen, Return/Tab übernimmt, Esc
schließt. Die Namen, Signaturen und Befehlsnummern stammen aus der
offiziellen 4D-Dokumentation (CC BY 4.0, © 4D SAS — Details in den
Third-Party-Notices).

**`.4DForm` prüfen:** „Text → Dokument prüfen“ validiert Formulardateien
zusätzlich gegen das mitgelieferte Formular-Schema (MIT-lizenziert, von
Mathieu Ferry) und springt zur Fehlstelle samt JSON-Pfad.

**Export-Transformation:** Das Menü **Text** strippt Token-Suffixe
kanonischer 4D-Exporte (`ALERT:C41` → `ALERT`, auch `:Knn:mm`) bzw.
ergänzt Befehls-Token wieder. Konstanten-Nummern kennt keine
öffentliche Quelle — „Befehls-Token ergänzen“ lässt Konstanten deshalb
ehrlich unverändert.

**Struktur-Hinweise:** „Text → Dokument prüfen“ untersucht `.4dm`-Methoden
heuristisch auf Block-Balance (`If/End if`, `For each/End for each`,
`Case of/End case`, `Repeat/Until`, `While/End while`, `Function`-Blöcke)
sowie Klammer-, String- und Kommentar-Balance und springt zur Stelle.
Ehrlich gesagt: eine Heuristik, kein Compiler-Ersatz — verbindlich prüft
tool4d (nächster Abschnitt).

## 4D und tool4d

Fastra kann 4D-Code mit **tool4d**, der schlanken headless-Runtime von 4D,
auf Syntaxdiagnosen prüfen. tool4d ist laut 4D frei und ohne Lizenz nutzbar.
Fastra bündelt es bewusst nicht, lädt nichts herunter und startet keine
Installation.

**tool4d beziehen** — eine Quelle genügt:

- **4D-Downloadseite:** <https://product-download.4d.com> — Paket
  „tool4d“ passend zur eigenen 4D-Version laden und entpacken.
- **VS-Code-Extension „4D-Analyzer“** (Herausgeber „4D“): lädt tool4d
  automatisch nach, auf dem Mac unter
  `~/Library/Application Support/Code/User/globalStorage/4D.4d-analyzer/tool4d/…/tool4d.app`.

**Hilfe → tool4d finden…** prüft diese bekannten Orte (plus PATH und
Programme-Ordner), zeigt Fundort und Version an und merkt sich den Pfad.

**Dokument prüfen:** Ist eine gespeicherte `.4dm`-Methode Teil eines geöffneten
4D-Projekts und tool4d vorhanden, startet **Text → Dokument prüfen** eine
kurze lokale LSP-Prüfung. Fastra lauscht nur auf `127.0.0.1`, tool4d verbindet
sich dorthin; nach dem Ergebnis werden Verbindung und Prozess wieder beendet.
Liefert tool4d einen nicht-`null`-Diagnosebericht, erscheinen Fehler mit Zeile
und Spalte und der erste lässt sich anspringen. Ein `null`-Bericht bedeutet
ausdrücklich „kein verwertbares Ergebnis“, niemals „fehlerfrei“. Eine sichere
Projektprobe mit tool4d 21.1 bestätigte einen vollständigen Diagnosebericht
und Shutdown; ein früheres `null` war der macOS-Alias `/tmp`, daher
kanonisiert Fastra Dokument- und Workspace-URI. Ohne tool4d oder ohne
zugehöriges Projekt bleiben die ausdrücklich heuristischen Struktur-Hinweise
verfügbar; sie sind kein Compiler-Ersatz.

**Headless-Prüfung von Hand:** tool4d arbeitet projektbasiert (immer die
`.4DProject`-Datei, nie eine einzelne Methode). Der zuverlässigste
Gesamtcheck läuft im kompilierten Modus:

```
…/tool4d.app/Contents/MacOS/tool4d \
  --project "Pfad/zum/Projekt/Project/MeinProjekt.4DProject" \
  --opening-mode=compiled --dataless --skip-onstartup
```

Fehler erscheinen auf der Konsole; Exit-Code ≠ 0 bedeutet Probleme.

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

**Dateien filtern:** Das Filterfeld über dem Dateibaum filtert live nach
Dateinamen (Teilstring, Groß-/Kleinschreibung egal — bewusst kein
Fuzzy-Matching). Treffer erscheinen mit aufgeklappten Elternordnern,
alles andere ist ausgeblendet; der Zähler zeigt „N von M Dateien“.
Escape oder das X leeren den Filter und stellen den vorigen
Aufklappzustand wieder her. Der Filter durchsucht nur NAMEN — für
Inhalte gibt es „In Ordnern suchen…“ (⇧⌘F, auch als Link am leeren
Filterergebnis).

## Git

Ist das Projekt ein Git-Repository (und `git` installiert), zeigt die
Seitenleiste zusätzlich die Tabs **Änderungen** und **Graph**:

- Branch-Zeile mit Branch-Wechsel, Ahead/Behind und Fetch.
- **Änderungen:** Dateien bereitstellen/entnehmen, verwerfen, Commit
  direkt aus der Seitenleiste; Push und Pull laufen asynchron.
- **Graph:** der Commit-Graph mit Verzweigungen und Merges.
- Verlauf (`git log`) und Diffs öffnen als schreibgeschützte Tabs; ein
  Klick auf einen Commit-Hash zeigt dessen Details.
- Git-Diffs nutzen dieselbe zweispaltige Ansicht wie **Dateien
  vergleichen** — inklusive Differenzen-Liste unten und
  ⌥↑/⌥↓-Navigation (⌥⌘[/⌥⌘] funktionieren weiterhin).
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

UTF-32-Dateien mit BOM werden in beiden Byte-Reihenfolgen erkannt. Bei
BOM-freien älteren Textdateien unterscheidet Fastra Windows-1252-Zeichen wie
typografische Anführungszeichen und das Eurozeichen von Latin-1. Erkennt
Fastra das Format nicht sicher, bleibt die Datei unverändert.

Wurde eine geöffnete Datei außerhalb von Fastra geändert, fragt Fastra beim
Speichern ausdrücklich nach. Eine weitere Änderung unmittelbar vor dem
Schreibvorgang bricht das Speichern immer ab, statt den Plattenstand still zu
überschreiben.

## Fenster und Tabs

⌘T öffnet einen neuen Tab, ⌘N ein zweites, vollständig unabhängiges
Fenster (eigene Tabs, eigene Suche). ⌘S speichert, ⌘W schließt den Tab —
bei ungespeicherten Änderungen fragt Fastra nach. ⌘J springt zu einer
Zeilennummer.

Der Haus-Schalter links oben kehrt im aktuellen Fenster zum
Willkommensbildschirm zurück. Saubere Tabs werden dabei geschlossen. Gibt es
ungesicherte Inhalte, bestätigt eine erste Rückfrage zunächst nur den gesamten
Wechsel; Abbrechen lässt den Arbeitsbereich vollständig unangetastet. Erst nach
der Bestätigung fragt Fastra jede betroffene Datei einzeln nach dem Sichern.
Ein Abbruch dort hält Projekt und Tabs offen.

Willkommen kann neben neuen, noch unbenannten Tabs stehen, aber nie neben einer
gespeicherten Datei oder einem geöffneten Ordner. Beim Öffnen eines Ordners oder
beim Öffnen beziehungsweise ersten Sichern einer Datei schließt Fastra den
Willkommen-Tab automatisch.

Öffnest du eine Datei aus dem Finder, landet sie im Fenster, dessen Projekt
oder Repository sie enthält, und dieses kommt nach vorn. Passt kein Fenster,
nutzt Fastra ein leeres Fenster (etwa den Willkommensbildschirm); gibt es auch
das nicht, öffnet sie in einem neuen. Startet Fastra durch diesen Vorgang neu,
wird zuerst die gespeicherte Sitzung wiederhergestellt und die ausdrücklich
geöffnete Datei danach zusätzlich geöffnet.

Beim nächsten Start stellt Fastra standardmäßig die zuletzt geöffneten
Projektfenster, gespeicherten Dokumente, aktiven Tabs und Fensterpositionen
wieder her. Unter **Einstellungen → Start** lässt sich das abschalten.
Inhalte ungesicherter oder unbenannter Dokumente werden nie gespeichert oder
wiederhergestellt. Fenster ohne offene Dateien werden nicht wiederhergestellt:
Hast du alle Tabs geschlossen, begrüßt dich beim nächsten Start wieder der
Willkommensbildschirm. Bei abgeschalteter Sitzungswiederherstellung öffnet ein
Finder-Start nur die ausdrücklich angeforderte Datei.

Ein Shift-Klick auf einen zweiten normalen Text-Tab markiert beide für den
Dateivergleich, ohne den aktuellen Tab umzuschalten. Der aktuelle Tab bleibt
stärker, der zweite schwächer hervorgehoben; ein normaler Klick beendet die
Paar-Auswahl.
