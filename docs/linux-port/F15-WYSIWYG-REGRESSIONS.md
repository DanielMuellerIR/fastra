# WYSIWYG: Leerblöcke, Formatgrenzen und Ausschnitt

Die gemeinsamen WebKit-Skripte behandeln semantisch leere Absätze mit geerbten
Fett-/Kursiv-/Textmarker-Wrappern wie leere Absätze. Return erzeugt dadurch keine
isolierten Formatzeichen. Vollständiges Löschen entfernt den Cursorabsatz und
verwaiste Leerraumblöcke aus dem Quelltext. Verdeckte Referenzdefinitionen sowie
unveränderte Blockbytes und Nachlaufzeilen bleiben erhalten. Undo stellt den
vorherigen Zustand wieder her; wiederholter Neuaufbau vervielfacht keine Blöcke.

Geschützte Leerzeichen erzwingen nicht mehr grundsätzlich Inline-HTML. Die
wirklichen CommonMark-Delimitergrenzen entscheiden: `**Bold&nbsp;**` ist möglich;
ein Fall wie `Before<strong>&nbsp;Bold&nbsp;</strong>after` behält das notwendige
HTML. Verschachtelte Fett-/Kursiv-/Textmarkerformate dürfen ebenfalls Markdown
bleiben. Das Kopierfragment trägt die sichtbare Textmarkerfarbe direkt als
Inline-Stil und entfernt interne Blockkennungen. Die native RTF-Übernahme auf
macOS ist zusätzlich mit der echten Zwischenablage geprüft.

Der Mac-Host merkt den tatsächlichen visuellen Ausschnitt pro Dokument und
Quellrevision. Scrollmeldungen und der synchronisierte Aktionssnapshot gehören
zur bestehenden WebKit-Sitzung. Der Wiederaufbau wartet begrenzt auf Layout;
eigene Eingaben entwerten eine ausstehende Wiederherstellung. Fremde Dokumente,
Fenster oder alte Revisionen dürfen den gespeicherten Ausschnitt nicht nutzen.

## Nachweis und offene Zuordnung

`tools/linux-probes/wysiwyg-report/run.py` prüft zehn synthetische Fälle mit
echtem GTK/WebKit. Sie bestehen nach Integration; dieselben Fälle mit dem
ursprünglichen Skript scheitern siebenmal. Einfaches Fett-Kopieren ohne
zusätzliches Leerzeichen, unveränderte Blockbytes und der Schutz gegen fremde
Clipboard-Metadaten waren bereits korrekt. Ein historischer Bericht aus
Version 1.157.0 allein belegt daher weder einen behobenen einfachen
Fett-Kopierfehler noch einen vorhandenen Fehler zwischen mehreren Fenstern.

Vier native Linux-Rich-Läufe bestehen auf Deutsch/Englisch bei 760/1180 Pixeln,
hell/dunkel: Formatierung, Tabellen, Undo/Redo, NBSP/Unicode, BOM und geschützte
Blöcke, tatsächliche Speichersynchronisierung sowie verworfene alte Antworten.
Drei Rich-Units und Clippy mit `-D warnings` bestehen ebenfalls.

Der vollständige Mac-Build und 13 gezielte WebKit-Testgruppen bestehen,
einschließlich echter RTF-Zwischenablage, einfacher Fett-Kopie in einen zweiten
Editor, verschachtelter Formatierung, Textmarker, wiederholter Roundtrips sowie
Löschen/Undo und Ausschnittbindung. Eine echte alte Scrollmeldung wird nach
Quellwechsel über die native WebKit-Brücke zugestellt und verworfen. Die einfache
Fett-Kopie erzeugt dabei kein zusätzliches geschütztes Leerzeichen; der historische
Einzelfehler bleibt am aktuellen Stand nicht reproduziert.
Der sichtbare WYSIWYG-/Split-Wechsel in der regulären, notarisiert installierten
Mac-App bleibt als eigene Produktabnahme offen.
Die anschließende Linux-Clipboardformatierung, bearbeitbare Textmarker und
Ausschnittanbindung sind unter [Rich-Markdown](F15-RICH-EDITOR.md) beschrieben.
Native RTF-, Bild- und Dateipaketimporte verwenden die gesondert dokumentierten
[Pfade für Bilder und RTF](rich-assets.md) und die lokale
[PMT-Anbindung](F13-HOST.md). Die später ergänzten gemeinsamen Bildskripte
benötigen weiterhin ihre erneute Mac-Fensterabnahme.
