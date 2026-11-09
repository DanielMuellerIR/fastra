# Lokale Rich-Markdown-Bilder unter Linux

Die sichtbaren Befehle im Bildmenü, das formatierte Clipboard und lokale
Dateidrops verwenden dieselbe Prüfung und Dateivorschau. Ein gespeichertes
Markdown-Dokument ist vor dem Einfügen von Bilddateien erforderlich. Die
Zustimmung legt ausschließlich die angezeigten neuen Dateien in `images/` an;
das Markdown-Dokument wird erst mit **Speichern** geschrieben. Vorhandene
Dateien werden niemals überschrieben. Kollidiert ein angezeigter Zielname nach
der Vorschau, wird der Vorgang angehalten.

PNG, JPEG, GIF und WebP behalten ihre vollständigen Bytes. TIFF und HEIC werden
mit dem vorhandenen isolierten Bildwerkzeug nach PNG konvertiert; Metadaten
können sich ändern. Mehrseitige TIFF-/HEIC-Eingaben werden abgewiesen. Die
Bildvorschau zeigt den ersten Frame mit Transparenz auf Weiß und nennt daneben
alle Bildmaße, die Framezahl, Bytezahl, den vollständigen Zielnamen und SHA-256.
Einfügeinhalt und bisherige Markdown-Quelle sind vollständig auswählbar.

Das Clipboard bevorzugt das eigene Markdown-Paket, lokale Dateien, Bilddaten,
HTML, RTF und zuletzt Klartext. HTML wird durch dieselbe begrenzte Whitelist wie
formatiertes Text-Clipboard geprüft. Eingebettete Raster-Datenbilder dürfen erst
nach Bildprüfung und Dateivorschau übernommen werden. Externe Bildadressen und
undokumentierte RTFD-Clipboardpakete werden kontrolliert abgewiesen. Lokale
RTFD-Dateipakete bleiben über den vorhandenen Importkatalog erreichbar. Pfade in
fremden Clipboard-Metadaten erlauben keine impliziten Dateilesezugriffe: Ein
Markdown-Bildpaket muss die referenzierten Bildbytes vollständig enthalten.

Der native Mac-Droppfad verarbeitet lokale Datei-URLs. Linux übernimmt diese
Dateilisten am vorhandenen Desktop-Dispatcher; nur Koordinaten innerhalb der
aktiven Rich-WebView gehen an die Bildvorschau. Gemischte Drops übernehmen die
Bilder zuerst und öffnen die übrigen Dateien beziehungsweise den normalen Ordner
anschließend regulär. Rohdaten-MIMEs ohne lokale Dateien sind kein zusätzlicher
Drop-Pfad. Sie bleiben über **Einfügen** erreichbar.

## Grenzen und Rücknahme

Text und HTML sind auf 2 MiB begrenzt, HTML zusätzlich auf 20.000 Elemente. Ein
Bild darf höchstens 32 MiB, ein Bildsatz insgesamt 64 MiB enthalten. Es werden
höchstens 32 neue Bilddateien pro Aktion angenommen. Die vollständige Dateivorschau
nennt auch Konvertierungen. Das Gesamtbudget wird bereits vor weiteren Reads und Decoderläufen sowie beim
Lesen konvertierter Ausgaben geprüft. Die Bildprüfung begrenzt Canvasflächen, Framezahlen,
Ausgabe, Laufzeit und Speicher im vorhandenen Sandbox-Runner. Fehler führen nicht
zu einem Klartextfallback.

Die Einfügestelle ist an Dokument, vollständigen Quellstand, Revision,
UI-Generation und DOM-Auswahl gebunden. Eine zwischenzeitliche Auswahlbewegung,
auch zurück zur vorherigen Position, verlangt einen neuen Einfügevorgang.

Rückgängig nimmt Bildnamen nur zurück, wenn gespeicherte Nachbardokumente und
alle anderen eigenen geöffneten Dokumente keine geschützten Verweise enthalten.
Auch ausgeblendete Fenster und versteckte Markdown-Nachbarn zählen. Unbekannte oder nicht vollständig prüfbare
Verweise erhalten die Dateien vorsorglich. Nach dem Speichern ohne den Verweis
wird eine zuvor aufgeschobene Rücknahme erneut geprüft.

Zurückgenommene Bild-Inodes werden unter `.fastra-image-undo-…` erhalten und nicht
automatisch gelöscht. Dadurch bleiben Änderungen über bereits offene Handles
anderer Bildprogramme erhalten. Wiederholen verwendet die erhaltenen Inodes und
verweigert geänderte Dateien oder Namenskollisionen. Das Bildmenü zeigt bekannte
Rücknahmepfade. Vor dem Wechsel zum Quelleditor werden eigene Bildnamen für dessen
Undo wiederhergestellt; unreferenzierte Dateien können deshalb weiter vorhanden
sein. Bei einer unvollständigen Rücknahme enthält der Receipt die zuletzt
bekannten tatsächlichen Platzierungen, auch wenn einige Namen bereits live sind.

RTF-only-Clipboard öffnet den vorhandenen PMT-Importdialog mit ausdrücklicher
Warnung vor Formatierungs- und Textmarkerverlust. Es wird weder still als Klartext
eingefügt noch durch eine zweite RTF-Engine verarbeitet. Die Konvertierung benötigt
die im Importdialog ausgewiesenen lokalen Werkzeuge. Diese Übergangslösung
importiert ein eigenes Dokument; sie behauptet keine verlustfreie Inline-RTF-
Bearbeitung. Lokale Bilddateien werden in der offenen Rich-Ansicht ungefähr alle 1,5 Sekunden
im Hintergrund auf Änderungen geprüft. Änderungen einschließlich atomarem Austausch,
Löschen, Wiederherstellung und Symlinkwechsel durchlaufen erneut die begrenzte
Bildprüfung. Die Ansicht ersetzt ausschließlich die Bildadresse; Markdown,
Auswahl, Scrollposition und Rücknahme bleiben erhalten. Fehlende oder ungültige
Bilder zeigen keine alten Bytes; der Quellverweis bleibt bestehen. Während einer
Bild- oder Clipboardaktion wartet die Aktualisierung. Laufende Bildprüfungen können
die Aktualisierung verzögern. Die Materialisierung beim Speichern-unter in ein
anderes Verzeichnis ist ein eigener Vorgang.


Ein nach erfolgreichem Dateischreiben, aber vor der Einfügung angenommener
Abbruch wird durch einen eigenen Rücknahmepfad abgeschlossen. Geänderte
Referenzquellen werden vor und nach diesem Pfad geprüft; nötige Rückbenennung
und tatsächliche Recoveryorte bleiben sichtbar. Fehlgeschlagene oder abgebrochene
Einfügungen werden nicht durch einen späteren Moduswechsel erneut veröffentlicht.

Bei einzelnen echten Drops unter WebKitGTK 2.52.6 erschien weiterhin eine
GDK-Statusdiagnose nach bereits abgeschlossenem Drop. Die geprüften Vorgänge
belegen jeweils genau einen COPY-Abschluss ohne Quellverschiebung und korrekte
Cancel-/Apply-/Undo-/Redo-Zustände. Der
[Upstreambericht 299208](https://bugs.webkit.org/show_bug.cgi?id=299208) beschreibt
einen verwandten asynchronen Pfad. Die geprüfte Version ist neuer als dessen
Fix; eine gemeinsame Ursache ist damit nicht bewiesen. Dieser Diagnosehinweis
wird nicht als behobener Toolkitfehler ausgegeben.

Bereits die erste Anzeige und jede Einfügung binden die geprüften Bildbytes an
eine versionierte Adresse. Trifft eine alte Kopiermeldung erst nach einem
Bildwechsel ein, wird sie abgewiesen. Interne Adresswechsel verändern keinen
ursprünglichen Markdown-Block.
