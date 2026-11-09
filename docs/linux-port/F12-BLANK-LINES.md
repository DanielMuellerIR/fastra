# Linux: sichtbare Markdown-Leerzeilen und Kopieren

Der vorhandene Mac-Dialekt bildet eine ansonsten leere Zeile mit mindestens
zwei ASCII-Leerzeichen auf genau eine sichtbare Textzeile ab. Linux verwendet
nun dieselbe Klasse und Zeilenhöhe in Vorschau und Rich-Ansicht. Verschachtelte
Zitatmarker werden wie im bestehenden Mac-Code berücksichtigt. Leere Zeilen,
ein einzelnes Leerzeichen, Tabs und NBSP aktivieren diesen Zusatz nicht.

Die vorhandenen Parserereignisse bleiben die Grundlage. Kontrollierte zusätzliche
Ereignisse werden anhand der originalen Bytebereiche eingefügt; entfernt man sie,
ist die ursprüngliche Ereignis-/Rangefolge unverändert. Listen werden nicht vor
dem Parser aufgeteilt. Code, Roh-HTML und Tabellen erhalten keine zusätzlichen
Leerzeilen. LF, CRLF, CR, Unicode und globale Originalzeilen bleiben zugeordnet.
Rich-Gapblöcke verwenden dieselben globalen Formelregionen, damit eine darin
enthaltene Leerzeile nicht außerhalb ihres tatsächlichen Kontextes erscheint.
Das ist keine vollständige Portierung des Mac-Formeldialekts.

Globale Link- und Bilddefinitionen bleiben auch bei der Bearbeitung eines
Einzelblocks erhalten. Ohne Textmarker werden die bereits global aufgelösten
Ereignisse ergänzt; der Markerpfad übernimmt Definitionen aus demselben globalen
Parserstand. Eine Neuinterpretation des isolierten Blocks darf deren Kontext
nicht verlieren. Der Rotbeleg unterscheidet die neue Regression des ersten
Kandidaten von dem bereits bestehenden Marker-/Referenzfehler; beide sind
im freigegebenen Kern geschlossen.

Kopieren exportiert normale Umbrüche statt interner Leerzeilenklassen und
Quellpositionsattribute. Ein inzwischen mit Text gefülltes Element behält seinen
Inhalt; ausschließlich wirklich leere BR-Platzhalter werden ersetzt. Das gilt
auch für Ausschneiden und dessen Rücknahme. Die Listenserialisierung rückt nur
nichtleere Folgezeilen ein, damit ein struktureller Separator beim erneuten
Einfügen keine zusätzliche sichtbare Leerzeile erzeugt. Codeinhalte und
unveränderte Originalquellen werden gesondert geprüft.

Es gelten höchstens 500.000 Parserereignisse einschließlich Ergänzungen und
128 verschachtelte Tags. Rich behält zusätzlich seine bisherigen 2-MiB- und
10.000-Blockgrenzen. Überschreitungen liefern einen sichtbaren Fehler und keine
teilweise freigebbare Darstellung.

`./linux/test.sh rich-blank-lines` prüft echte Eingabe in eine Leerzeile,
Undo, Formatieren, Speichern, Tab schließen und Wiederöffnen sowie sechs
geometrisch vorhandene Zeilen und die erhaltene Liste. Die Clipboard-Prüfung
verwendet echte native Copy-/Paste-/Cut-Ereignisse und tatsächliche GDK-Daten.
Die versionsgebundene Gesamtabnahme wird im jeweiligen Paketprotokoll geführt.
Ein unlesbares Erstbild ist kein Sichtbeleg; eine passende neue Aufnahme muss
nach sichtbar positioniertem Testfenster erfolgen.
