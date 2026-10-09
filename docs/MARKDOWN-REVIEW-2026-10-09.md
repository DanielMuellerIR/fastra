# Markdown-Review vom 2026-10-09

Geprüft wurden Quelltextbearbeitung, WYSIWYG, Vorschau, Zwischenablage,
Listen, Einrückung, Zeilenenden, Bildverweise und die Verbindung von Text-Undo
mit Bilddateien. Ausgangspunkt war v1.138.5; die Korrekturen gehören zu
v1.138.6. Der Bericht beschreibt beobachtbares Verhalten und die zugehörigen
Regressionstests.

## Befunde und Korrekturen

**P1** bezeichnet mögliche ungültige Editorzustände oder falsche Dateiverweise.
**P2** bezeichnet einen Verlust oder eine unerwartete Umdeutung von Inhalt.

| ID | Priorität | Auslöser und bisheriges Verhalten | Korrektur und Beleg |
| --- | --- | --- | --- |
| M01 | P2 | Ein Listenbefehl auf `    - Kind` erkennt das vorhandene Präfix nicht und stapelt ein neues davor. | Einrückung und Inhalt getrennt bearbeiten. `markdownReview_nestedListConversion` prüft Leerzeichen und Tabs. |
| M02 | P2 | Beim Umwandeln einer Aufgabenliste bleiben `[x]` bzw. `[ ]` als gewöhnlicher Text stehen; ein Aufzählungsbefehl kann die ganze Auszeichnung entfernen. | Das vollständige Aufgabenpräfix entfernen und die gewünschte Listenform setzen. Aufgaben können auch mit nummerierten Präfixen erkannt werden. |
| M03 | P2 | Formatieren mehrerer CR-Zeilen behandelt sie als eine einzige Zeile. | Alle drei Markdown-Zeilenenden erkennen und jede ursprüngliche Endung erhalten, auch gemischt. `markdownReview_lineEndings`. |
| M04 | P2 | Ein harter Umbruch vor CRLF erzeugt ein zusätzliches LF; der Befehl erkennt leere CR-Zeilen nicht. | Vorhandenen Umbruch wiederverwenden, sonst die Dokumentendung einsetzen. `markdownReview_hardBreakLineEndings`. |
| M05 | P1 | Ausrücken zieht vier Zeichen von der Auswahl ab, obwohl nur ein oder gar kein Leerzeichen entfernt wird. Cursor und Auswahllänge können negativ werden. | Originalpositionen anhand tatsächlicher Änderungen abbilden. `NativeMarkdownReviewTests.shortIndent` verwendet den echten Editorcontroller. |
| M06 | P2 | Mehrere Cursor auf derselben Zeile rücken diese mehrfach ein; die Auswahlanpassung berücksichtigt pauschale Breiten. | Betroffene Zeilen deduplizieren, Änderungen rückwärts anwenden und Auswahlen für Undo hinterlegen. `multipleSelections`. |
| M07 | P2 | Der Return-Filter erkennt ausschließlich LF, obwohl der Editor CR oder CRLF einsetzt. | Einzelne CR-/LF-/CRLF-Mutationen vollständig behandeln. `NativeMarkdownReviewTests.newline`. |
| M08 | P2 | Die Suche nach der vorherigen Zeile landet auf der LF-Hälfte eines CRLF und übernimmt eine leere Einrückung. | Zusammengehöriges CRLF beim Rückwärtssuchen vollständig überspringen. Derselbe Return-Test prüft die vier übernommenen Leerzeichen. |
| M09 | P2 | Formatiertes Einfügen schneidet führende Einrückungen und nachlaufende Leerzeichen ab. | Konverterausgabe unverändert übernehmen; ausschließlich für die Leerheitsprüfung trimmen. `markdownReview_smartPasteWhitespace`. |
| M10 | P2 | Eine langsame Markdown-Konvertierung kann Inhalt aus einer inzwischen geänderten globalen Zwischenablage am ursprünglichen Ziel einsetzen. | Den Änderungszähler bei Aufruf festhalten und vor der Übernahme prüfen; verständlichen Fehler anzeigen. `markdownReview_changedClipboard`. |
| M11 | P2 | Nach WYSIWYG-Bearbeitung werden wörtliches `&copy;` oder `<b>` zu Entity bzw. HTML-Auszeichnung. | Textknoten vor der Markdown-Serialisierung passend maskieren. `literalTextAfterEdit` prüft erneut gerenderten Inhalt. |
| M12 | P2 | Wörtliches `1) Text` kann nach WYSIWYG-Bearbeitung zu einer nummerierten Liste werden. | Auch die CommonMark-Listenschreibweise mit schließender Klammer schützen. Derselbe WebKit-Test prüft, dass kein `<ol>` entsteht. |
| M13 | P2 | Die Serialisierung einer HTML-Tabelle mit `rowspan`/`colspan` ordnet Folgezeilen falschen Spalten zu. | Verbundene Zellen als sicheres HTML erhalten. Lokale Bildziele und Formelquellen vor dem Bereinigen zurückführen. `spanningTable`. |
| M14 | P2 | Ausschneiden verwendet WebKits Standardtransport und verliert Fastras Formel-/Diagrammquellen. | Kopieren und Ausschneiden teilen den Markdown-Transport. Die Löschung bleibt eine native Undo-Operation; Ansichtsattribute zählen nicht als Quelltextänderung. `cutFormula`. |
| M15 | P2 | Vorschau-Kopien enthalten nur interne `fastra-preview:`-Bildadressen, die andere Apps nicht auflösen können. | Freigegebene Bilddateien im Hintergrund als HTML-Data-URI und RTFD-Attachment übernehmen. `MarkdownClipboardImageReviewTests.transport` prüft die tatsächlichen Bildbytes. |
| M16 | P2 | Ein `src=` innerhalb von Alt-Text kann bei „Speichern unter“ statt des echten Bildpfads gelesen werden. Ein `>` im gequoteten Wert beendet den Tag zu früh. | Vollständige gequotete Attribute überspringen und Tag-Enden außerhalb von Quotes suchen. `sourceAttribute` und `quotedSourceInAlt`. Derselbe Attributscanner wird auch beim Clipboard-Export genutzt. |
| M17 | P2 | Bereits maskierte HTML-Attribute erhalten zusätzliche `&amp;`-Sequenzen; Bildpfade mit `&` werden dadurch falsch. | Entities einmalig mit dem Markdown-Parser decodieren, danach URL-/Attributsicherheit prüfen und kanonisch ausgeben. `entities` prüft zugleich ein entitycodiertes `javascript:`-Schema. |
| M18 | P1 | Text-Redo setzt einen Bildlink wieder ein, obwohl eine fremde Datei inzwischen den reservierten Namen belegt und die Bildwiederherstellung scheitert. | Datei-Nebenwirkungen vor Text-Redo vorbereiten. Bei Fehler bleiben Text und Redo-Stack erhalten; erfolgreiche Vorbereitungen werden zurückgenommen. `imageRedoCollisionKeepsTextAndRetry` und `redoPreflightRollsBackOnlyPreparations`. |
| M19 | P2 | Wörtliche Zeichenketten wie `FASTRAMATH0TOKEN` kollidieren mit deterministischen Formel-/Codeplatzhaltern. | Für jede Ersetzung einen eigenen UUID-basierten Platzhalter verwenden. `tokens` prüft den erhaltenen wörtlichen Text und jeweils genau einen Formel-/Codeknoten. |

## Geprüfte Grenzen

- Gewöhnliches Kopieren und Einfügen im Quelltext bleibt Klartext. Ein einzelnes
  `=` benötigt keinen Backslash. Der bereits in v1.138.5 korrigierte
  WYSIWYG-Escape-Pfad bleibt durch WebKit-Tests für Protokolllisten geschützt.
- Die Zwischenablage enthält weiterhin Klartext, HTML und RTF. Bei Bildern
  kommt RTFD hinzu; innerhalb Fastras bleibt das private Markdown-Paket erhalten.
- Nur zuvor für die Vorschau freigegebene lokale Bilder werden gelesen.
  Es gelten 32 MiB pro Bild und 64 MiB Bilddaten pro Kopie, einschließlich
  wiederholter Bildvorkommen. Fehlende bzw. zu große Bilder behalten ihren
  Alt-Text. HTML-Import lädt keine externen Bildadressen nach.
- Ein verspäteter Bildexport prüft den Clipboard-Zähler auch unmittelbar vor
  dem tatsächlichen Schreiben, nach der HTML-/RTF-Aufbereitung.
- Formeln, Diagramme und rohe HTML-Blöcke bleiben geschützte Elemente. Der
  Review führt keine Bearbeitung ihrer inneren Struktur im WYSIWYG-Modus ein.
- Checkout-Korrekturen liegen unter `app/Patches`, prüfen ihre Anker und die
  vollständige Anwendung und werden durch `build.sh` eingebunden. Die
  Abhängigkeitsversionen bleiben unverändert.

## Verifikation

Die vollständige Testsuite, Lokalisierungsprüfung, Bundle-Portabilität und
Fenster-Selbsttests werden für den Release-Stand ausgewertet. Die endgültigen
Ergebnisse stehen in diesem Abschnitt nach Abschluss der Release-Abnahme.

Ein Code-Review und Regressionstests decken die geprüften Fälle ab; sie sind
kein Beweis für die Fehlerfreiheit beliebiger Dokumente. Insbesondere werden
keine unbeschränkten Langzeit- oder Fremdprogrammtests behauptet.
