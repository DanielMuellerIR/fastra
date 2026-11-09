# Linux: ausdrückliche Zeilenendenwahl

Der Formatbereich bietet LF, CRLF und CR. Die initiale Erkennung folgt dem
bestehenden Mac-Vertrag: CRLF vor CR vor LF. Eine Auswahl ändert noch keinen
Quelltext und keine Undo-Historie. Sie ist eine ungesicherte Dokumentänderung;
die bisher gespeicherte Wahl hebt die Vormerkung auf. Ohne ausdrückliche Wahl
bleiben gemischte Zeilenenden beim Speichern erhalten.

## Speichern und Vorschau

Erst Save konvertiert den gebundenen Textstand, prüft Editorgrenzen und kodiert
mit der vorhandenen Kodierung und BOM. Vorhandene Snapshot-/Dateiidentitätsprüfungen
bleiben wirksam. Save As verwendet den konvertierten Text bereits für die
vollständige Zielvorschau und verlangt beim Überschreiben die eigene Bestätigung.
Abbruch oder Fehler behalten die Vormerkung und den ungesicherten Quelltext.

Ein erfolgreicher Save übernimmt die Konvertierung als einen nativen Undo-Schritt.
Unicode-Auswahlpositionen werden über die geänderten CRLF-Längen abgebildet.
Neuere Quelltexteingaben während des Workers werden nicht ersetzt; sie bleiben
mit ihrer Formatabsicht ungesichert. Eine leere Datei behält die ausdrücklich
gespeicherte Zeilenendenwahl für spätere Spaltenpaste.

## Rich, Schließen und Wiederherstellung

Rich synchronisiert und hält die Eingabe vor dem Worker an. Der Abschluss
validiert den gesicherten Stand und bei einem neu aufgebauten Editor dessen
Bereitschaft. Ein weiterer Save löst die laufende Sperre nicht. Schließen bindet
die erwartete Revision vor und nach der eigenen Konvertierung; ein fremder
Zustandswechsel bleibt ein Abbruchgrund. Eine wirkungslose Konvertierung löst
keine Sperre eines vorbereiteten Mehrtab-Schließvorgangs.

Die Sitzungsdatei speichert die gesicherte und vorgemerkte Wahl optional. Alte
Sitzungsdateien ohne diese Felder bleiben lesbar; ungültige Codes werden
abgewiesen. Eine vorgemerkte Wahl bleibt auch dann ungesichert, wenn Text-Undo
bereits den alten gespeicherten Quelltext erreicht hat.

## Prüfumfang

Native isolierte Tests prüfen Quelltext und Rich, LF/CRLF/CR, UTF-16 mit BOM,
Unicode-Auswahl, Undo/Redo, Save As mit Abbruch und Überschreiben, Änderungen
während des Speicherns, Dateikonflikte, Einzel-/Mehrtab-/Fenster-/Appschließen
und einen echten Prozessabbruch mit anschließender bestätigter Wiederherstellung.
Die drei im unabhängigen Review reproduzierten Sicherheitsbefunde sind nach
Korrektur geschlossen. Diese Prüfung ersetzt keine native macOS-Abnahme.
