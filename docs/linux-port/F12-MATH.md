# Linux-Markdown: Formeln und ursprüngliche Quellbereiche

Ab 1.178.0 stellt die normale Markdown-Vorschau Inline- und Blockformeln mit der
mitgelieferten KaTeX-Version dar. Unvollständige, verschachtelte und nicht
unterstützte Eingaben behalten ihre ursprüngliche Formelsyntax mit sichtbarem
Hinweis. Arbeitsmarker werden nicht zu Nutzertext. Ab 1.180.0 rendert auch die
Rich-Ansicht Formeln als geschützte Inline- oder Blockatome; ihr Umfeld bleibt
bearbeitbar. TeX und Delimiter werden im Quellmodus geändert.

Eine gemeinsame Parseransicht verarbeitet LF, CRLF und CR und bildet jeden
verwendeten Bereich auf die ursprünglichen UTF-8-Positionen zurück. Vorschau,
Codekopie, Quellnavigation, Rich-Quellbereiche, Bildreferenzen und Save As verwenden
dieselbe Abbildung. Die Originalquelle wird beim Rendern nicht normalisiert.
Code- und HTMLbereiche behalten ihre Grenzen; eine Formel darf sie nicht teilweise
überdecken. Vollständig eingeschlossener Code führt zu einem sichtbaren Quellhinweis.

Bild-/Linkziele, Titel und globale Referenzdefinitionen stammen aus dem
Originalparser. Formeln in sichtbaren Labels verändern weder ein gleichnamiges
wörtliches Ziel noch dessen Quellbereich. Nur ein ursprünglich als Collapsed-Link
erkannter Bereich nimmt die zugehörigen Abschluss-`[]` in den Rewritebereich auf.
Inline-, Full-, Shortcut- und escaped-Literalformen werden davon getrennt behandelt.

Drei unabhängig reproduzierte Reviewfunde zu Zielherkunft, Referenzen und
Codegrenzen sowie der zusätzliche Collapsed-Rewritefehler sind nach Nachreview
geschlossen. Gegenkontrollen umfassen Unicode und alle drei Zeilenenden, originale
Bild-/Linkbereiche, tatsächliche Bilddateien, Save-As-Rewrites, native Klartext-/
HTMLkopie und Klicknavigation. Die Desktop-/IME-Abnahme bleibt gesondert.


## Rich-Quelle und Zwischenablage

Die bereits vorhandene geschlossene Quellenregistry behält die ursprünglichen
Formeldelimiter, innere Leerzeilen und Zeilenenden. Auch verschachtelte
Quellhinweise bleiben registrierte Atome: Tabellen-Pipes werden nicht zusätzlich
escaped, äußere Display-Umbrüche gehen bei Nachbartextänderungen nicht verloren.
Der dazu unabhängig reproduzierte P2 wurde korrigiert und nachgeprüft.

Eigenes Markdown-Clipboard erhält die ursprüngliche Formelquelle zwischen
bestehenden und anfangs leeren Rich-Ansichten. Allgemeines HTML enthält MathML,
Klartext den sichtbaren Text. Kopie, Ausschneiden, Paste, Undo, Quellenwechsel,
Close-Fences, Save und Reopen sind zusammenhängende native Prüfflüsse. Der
Seitenrahmen lädt KaTeX lokal auch für anfangs leere Dokumente. CSP und bestehende
Ressourcen-/Bildgrenzen bleiben erhalten; es entstehen keine Netzwerkzugriffe.
