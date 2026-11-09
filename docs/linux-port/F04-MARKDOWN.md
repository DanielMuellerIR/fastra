# F04: Markdown und externe Werkzeuge

WebKitGTK 6.0 / Runtime 2.52.6 führt die vorhandenen KaTeX-0.17.0-,
Mermaid-11.16.0-, Turndown-7.2.0- und visuellen Editor-/Tabellenskripte aus.
Die Probe benutzt eine eigene kleine HTML-Hülle, die unveränderten JS-Ressourcen
und einen kleinen nativen Scheme-Handler mit fester Ressourcenliste
und eine lokale Message-Bridge. Formel, Mermaid-SVG und Bild werden wirklich
aufgebaut. Der Wechsel der Bildidentität lädt statt eines 1-Pixel-Bildes das
2-Pixel-Bild. Die CSP meldet den absichtlich versuchten HTTPS-Abruf als blockiert;
zusätzlich hatte die äußere Umgebung keinen Netzwerkanschluss. WebKits eigene
Sandbox blieb aktiv. Erforderliche verschachtelte Namespace-/Loopback-Rechte
wurden ausschließlich der isolierten äußeren Testumgebung gegeben.

Ein Absatz mit Umlaut und Emoji wird bearbeitet, per nativem WebKit-Undo
zurückgesetzt und als UTF-8 gespeichert. Ein neuer Prozess liest dieselbe Datei
und öffnet sie mit den vorhandenen Editor-Skripten. Das ist ein begrenzter
WYSIWYG-Pfad, keine Freigabe aller Formatierungs-, Tabellen-, Clipboard- und
geschützten Blockfälle. Die produktive Scheme-/Bridge-Grenze muss in F12/F15
weiterhin gegen fremde Nachrichten und Dateibäume geprüft werden.

## Formatierungsleiste und Quelltextbefehle

Seit 1.193.0 teilen Quelltext und Rich-Editor die Reihenfolge und Symbole der
15 Mac-Befehle. Die Quelltextleiste scrollt horizontal; Gliederung und
Darstellungsoptionen bleiben erreichbar. Zusätzliche Rich-Aktionen stehen im
Mehr-Menü. Tabellen bieten 1 bis 50 Spalten mit anfangs drei Spalten und
Kopfzeile. Der Quelltext erzeugt beschriftete Markdown-Kopfzellen; Rich übernimmt
die leeren Zellen und optionale zusätzliche Datenzeile der Mac-Rich-Ansicht.

`fastra-core::markdown_formatting` erhält UTF-16-Auswahlen, Einrückungen,
bestehende Aufgabenhäkchen und CR/LF/CRLF. Berechnung und Ausgabeprüfung laufen
im Hintergrund. Die Übernahme prüft das konkrete Quellfenster, Dokument,
Revision, Quellansicht und Auswahl erneut. Ein fremder oder veralteter Auftrag
schreibt nichts. Die bisherigen Inlinebefehle ändern weiterhin nur ihre Marker,
damit unabhängige Auswahlen der zweiten Quellansicht erhalten bleiben.

`linux/test.sh markdown-formatting` prüft die sichtbaren Befehle, Unicode,
geteilte Quelle, natives Undo, Ctrl+K, Tabellen-Abbruch und verweigerte veraltete
Antworten. `linux/test.sh rich-formatting` prüft den wirklichen Tabellenknopf,
Anfangswerte, ungültige Spaltenzahlen, Abbruch, Rich-Tabellenstruktur und Undo
über das Mehr-Menü. `markdown-inline`, `rich-clipboard` und `rich-find` ergänzen
die vorhandenen Editorprüfungen. Für modale Desktop-Abläufe gehört zur
isolierten X11-Prüfung ein echter Fenstermanager; ein nackter X-Server bildet
die Fokusrückgabe beim Schließen eigener Dialoge nicht ab.

Die [gemeinsame Gliederung](F12-NAVIGATION.md) und
[Rich-Textbausteine](F09-WORKFLOWS.md#textbausteine-in-quelltext-und-rich) verwenden
die Mac-Bedienung. Weitere Markdown-Paritätspunkte stehen in der [Roadmap](../../ROADMAP.md).

Die eigene 4D-Tokenisierung, Indexierung, Completion und einfache Makrovorlagen
sind von externer Ausführung zu trennen (`FourDTokenizer`,
`FourDProjectMethodIndex`, `FourDMacroEngine`, `Tool4DLSP`). Die offizielle
[tool4d-Dokumentation](https://developer.4d.com/docs/Admin/cli) bietet Windows
und macOS; ein gleichwertiges lokales Linux-Backend ist hier nicht nachgewiesen.
Daher bleiben tool4d-LSP-Diagnosen und ausführbare 4D-Makros offen. Es wurde weder
eine entfernte Mac-Runtime noch Wine als stiller Ersatz eingeführt.
