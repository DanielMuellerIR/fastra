# Native Zeilen-/Spaltennavigation

„Werkzeuge → Zu Zeile/Spalte springen …“ beziehungsweise Strg+L öffnet einen
an den aktuellen Quelltab gebundenen Dialog. Eine positive Zeile oder
`Zeile:Spalte` genügt; Return springt, Escape beziehungsweise „Abbrechen“ schließt.
Die Auswahl wird zum Cursor. Text, gespeicherte Dateien und Undo bleiben erhalten.
Ein anderer Tab, Rich-/Readonly-Modus, gefaltete Quelle oder laufendes Speichern
verweigert den Sprung. Der Quelltab kann nach Rückkehr erneut angefordert werden.

Die reine Rechnung folgt dem originalen `GotoLineParse` und den unverändert
extrahierten `BufferSearch.collectLineStarts`/`nsRange`-Funktionen. Zeile und
UTF-16-Spalte beginnen bei eins; Zeilen-/Textende begrenzen größere Werte.
LF, CR, CRLF, NEL sowie U+2028/U+2029 gehören zur Referenzsemantik. Liegt eine
Spalte zwischen den beiden UTF-16-Einheiten eines Zeichens, setzt GTK den Cursor
sichtbar erklärt an dessen Anfang. Es wird kein ungültiger Textiter erzeugt.
Auch sehr große Eingabewerte werden ohne Integerüberlauf begrenzt.

Die Berechnung läuft auf einem Worker, höchstens 32 MiB Quelltext. Der Parser
begrenzt Eingaben auf 256 UTF-8-Bytes; das native Eingabefeld auf 128 Zeichen.
Vor Veröffentlichung werden Dokumentobjekt, aktive Ansicht, Revision,
Cursor, native Auswahl, Rechteck-Auswahlgenerationen und Auftrag erneut geprüft.
Eine neue Rechteckauswahl kann deshalb auch bei unverändertem Endcursor keinen
alten Sprung freigeben. Ausblenden des Hauptfensters schließt das Werkzeug und
bricht die Berechnung ab. Es gibt keine Datei-/Projektöffnung oder Textmutation.

24 tatsächliche Swift-Parserfälle und 392 Quellpositionen stehen unter
`crates/fastra-core/tests/fixtures/swift-navigation.json`. Die Referenz lief mit
Swift 6.2.1/Foundation auf Linux; sie ist keine neue native macOS-Abnahme.
Die beiden Coretests prüfen außerdem Surrogatgrenzen, große Werte und Abbruch.
Der native Test `linux/test.sh goto` prüft echten Menü-/Knopfklick,
Tastatureingabe, Strg+L, Escape, Unicode/CRLF, erhaltenes Undo, ungültige Eingabe
und die konkreten Stale-/Fensterschutzfälle auf einem privaten Display.
