# Manueller Menüvolltest

Dieser gelegentliche Computer-Use-Test ergänzt Unit- und In-App-Selbsttests.
Er soll nach größeren Funktionspaketen einmal realistisch alle sichtbaren
Menüpfade bedienen. Er gehört bewusst nicht in jeden Build-Lauf.

## Sicherheitsgrenzen

- Vor dem Test müssen `swift test`, `localization-audit.sh`, `build.sh` und die
  vollständigen In-App-Selbsttests ausgewertet sein. Exit 2 ist ein
  Umgebungs-Skip und kein grüner Test.
- Der Nutzer gibt den Vordergrund ausdrücklich frei. Während des Laufs bedient
  Computer Use Maus und Tastatur; anschließend wird die Test-App mit ⌘H
  ausgeblendet.
- `app/prepare-manual-menu-test.sh` erzeugt im Projekt-Root einen neuen
  `.fastra-menu-test.*`-Ordner. Darin liegen eine ad hoc signierte App mit
  eigener Bundle-ID, Testdateien sowie ein ausschließlich lokales Git-Remote.
- Die Test-App wird niemals nach `/Applications` kopiert. Persönliche
  Projekte, App-Einstellungen, Git-Remotes und ungesicherte Nutzerdokumente
  bleiben unberührt.
- Öffnende oder potenziell externe Aktionen werden nur gegen die Fixture
  ausgeführt. Gefährliche Git-Aktionen werden entweder im lokalen Remote
  vollständig geprüft oder ihr Bestätigungsdialog bewusst abgebrochen.

## Protokoll

Für jeden Eintrag wird `PASS`, `FAIL`, `korrekt deaktiviert` oder
`Dialog bewusst abgebrochen` festgehalten. Nach jeder Textmutation werden
sichtbarer Text, Zeilennummern, Cursor, Undo und Redo geprüft. Ein leerer
Editor, verschwundene Zeilennummern, unerwarteter Scrollraum oder ein
wirkungsloser Menüpunkt ist ein Fehler, auch wenn das Datenmodell intern noch
korrekt aussieht.

## Prüffolge

### 1. Grundbedienung und App-Menü

- Editor anklicken, Cursor setzen, Tab wechseln, Fensterampeln und ⌘Tab prüfen.
- **Über Fastra**, **Einstellungen**, **Nach Updates suchen**, **Fastra-Hilfe**
  und **tool4d finden** öffnen; Dialoge wieder schließen.
- In **Einstellungen → Start** prüfen, dass die Wiederherstellung bei frischer
  Testidentität standardmäßig an ist.

### 2. Ablage und Bearbeiten

- Neues Dokumentfenster, neuer Tab, Datei öffnen, Ordner öffnen, zuletzt
  benutzt, von Festplatte neu laden, schließen.
- Speichern und Speichern unter einschließlich Abbrechen und Überschreiben.
- Undo, Redo, Ausschneiden, Kopieren, Einfügen, Alles auswählen.
- Formatiert als Markdown einfügen, Spalte einfügen sowie Rechteckauswahl nach
  oben und unten. Fehlende passende Zwischenablage muss verständlich und ohne
  Datenverlust behandelt werden.
- Terminal im aktuellen Fixture-Ordner öffnen und wieder schließen.

### 3. Darstellung

- UI vergrößern/verkleinern/zurücksetzen und Dokumentschrift
  vergrößern/verkleinern/zurücksetzen.
- Text-, Vorschau- und Hex-Ansicht an passenden und unpassenden Dateien.
- Soft Wrap, Seitenlinie, Minimap, Seitenleiste und Markdown-Vorschau jeweils
  ein- und ausschalten; Zustand und Menümarkierung müssen zusammenpassen.

### 4. Suchen

- Suchen & Ersetzen in Datei und Ordner, Auswahl als Suchbegriff, Ausblenden
  mit Escape sowie mehrfaches ⌘F ohne zweite oder aufblitzende Find-Leiste.
- XPath-Navigation an `valid.xml`; an unpassenden Dateien korrekt deaktiviert.
- Zwei Dateien vergleichen sowie eine geänderte gespeicherte Datei mit ihrer
  Plattenfassung vergleichen.

### 5. Text

Jede Mutation zunächst auf einer Auswahl, danach ohne Auswahl auf dem ganzen
Dokument prüfen. Nach jedem Eintrag Undo und Redo ausführen.

- Dokument formatieren, prüfen und minifizieren an gültigem sowie ungültigem
  JSON/XML; unpassende Endungen müssen deaktiviert sein.
- Großbuchstaben, Kleinbuchstaben, Wörter groß; Endleerraum entfernen;
  Tabs → Leerzeichen; Leerzeichen → Tabs.
- Steuerzeichen entfernen, Anführungszeichen gerade/schwungvoll,
  Escape-Sequenzen auflösen; einrücken und ausrücken.
- Zeilen umkehren, Leerzeilen entfernen, alphabetisch aufsteigend und
  absteigend sortieren, mit und ohne Leerzeichen verbinden, Präfix/Suffix,
  Zeilennummern hinzufügen/entfernen.
- Zeichen und Wörter tauschen; passende/unpassende Zeilen behalten/löschen;
  nur doppelte Zeilen behalten; mehrfach vorkommende Zeilen entfernen.
- Harter Umbruch; Leerzeichen vereinheitlichen; Diakritika entfernen;
  Unicode NFC/NFD.
- 4D-Token entfernen und Befehls-Token ergänzen an der Fixture-Methode.

### 6. Markdown

An `README.md` jeweils Quelle und Vorschau prüfen:

- Fett, kursiv, Hervorheben (`==Text==`), Code.
- Harter Zeilenumbruch: zwei Leerzeichen plus normaler Umbruch; bei bereits
  vorhandenem Umbruch dürfen weder ein drittes Leerzeichen noch eine zusätzliche
  Leerzeile entstehen. Tooltip kontrollieren.
- Überschrift 1–3 und normaler Absatz.
- Aufzählung, nummerierte Liste, Zitat.
- Link und Tabelle einfügen.

Alle Befehle müssen außerhalb eines Markdown-Tabs korrekt deaktiviert sein.

### 7. Git

Nur im erzeugten Fixture-Repository und seinem lokalen Bare-Remote:

- Verlauf und Diff anzeigen, Verlauf durchsuchen.
- Alles committen und letzten Commit ergänzen.
- Fetch, Push, Pull (Fast-Forward) und Pull mit ausdrücklich gewählter
  Strategie.
- Zum vorherigen Branch wechseln und einen neuen Branch erstellen.
- Getrackte Änderungen stashen, Änderungen einschließlich unversionierter
  Dateien stashen und letzten Stash anwenden.
- Force Push with Lease bis einschließlich Sicherheitsbestätigung prüfen; nur
  gegen das lokale Remote ausführen.
- Git-Identitätsdialog öffnen, repositorylokale Vorauswahl prüfen und ohne
  unnötige Änderung schließen.
- Fortsetzen, Überspringen und Abbrechen nur in einer eigens erzeugten
  Konflikt-/Rebase-Fixture prüfen; sonst korrekt nicht vorhanden oder
  deaktiviert.

### 8. Sitzungswiederherstellung

1. Zwei Fenster mit `session-a.txt`, `session-b.txt` und weiteren gespeicherten
   Tabs öffnen, Fenster versetzen und unterschiedliche Tabs aktivieren.
2. Zusätzlich ein unbenanntes Dokument mit Text und eine gespeicherte Datei
   mit ungesicherter Änderung offen lassen.
3. Fastra beenden und bei beiden Rückfragen **Nicht sichern** wählen.
4. Test-App neu starten: Fenster, Projekt, gespeicherte Tabs, aktive Tabs und
   Rahmen müssen zurückkommen. Das unbenannte Dokument und die ungesicherte
   Änderung dürfen nicht zurückkommen.
5. Wiederherstellung unter **Einstellungen → Start** ausschalten, erneut
   beenden und starten: Es darf keine vorige Sitzung erscheinen.

## Abschluss

- Fehler mit Screenshot, betroffener Menüfunktion, Ausgangsdatei und
  beobachtetem Undo-/Redo-Zustand festhalten.
- Test-App mit ⌘H ausblenden und beenden.
- Nur den vom Vorbereitungsskript ausgegebenen `.fastra-menu-test.*`-Ordner
  entfernen. Das normale `Fastra.app` im Projekt-Root und `/Applications`
  bleiben unangetastet.
