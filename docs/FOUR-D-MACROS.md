# 4D-Textmakros unter Linux

Über **Werkzeuge → 4D-Makros …** öffnet Fastra den lokalen Macros-v2-Katalog
für den aktiven, editierbaren `.4dm`-Tab. Normale Textmakros benötigen kein
Tool4D. Der Katalog lässt sich nach Quelle und Namen filtern. **Neu laden**
liest geänderte Quellen ausdrücklich erneut; Tastatureingaben lösen keine
Dateisystemsuche aus.

## Quellen

Die Suche verwendet die 4D-Projektwurzel des Dokuments, alternativ den gewählten
Projektordner. Projekt- und Komponentenordner können `Macros v2` oder
`Contents/Macros v2` enthalten. Komponenten kommen aus `Components`/`components`
und lokalen Pfadangaben in `Project/Sources/dependencies.json`. Gebaute `.4DZ`
werden nicht als Makro-XML geöffnet; dies entspricht der Mac-Makrosuche.

Benutzermakros liegen standardmäßig unter
`$XDG_DATA_HOME/fastra/4d/Macros v2`, andernfalls unter
`$HOME/.local/share/fastra/4d/Macros v2`. **Eigene Makros …** wählt einen anderen
Ordner. **4D-Ordner …** ergänzt ausdrücklich einen vorhandenen Installations-
oder Ressourcenordner. Dort werden die beiden Makroverzeichnisse sowie
`Resources/*.lproj/Macros.xml` und `Contents/Resources/*.lproj/Macros.xml`
berücksichtigt. Die bevorzugte Sprache fällt von Region über Schriftvariante
zur Basissprache zurück, anschließend auf Deutsch, Englisch und den ersten
vorhandenen Sprachordner. Linux durchsucht keine macOS-Library-Verzeichnisse.

Die Auswahl wird atomar in `$XDG_CONFIG_HOME/fastra/4d-macros.json` beziehungsweise
`$HOME/.config/fastra/4d-macros.json` gespeichert. **XDG-Vorgaben** setzt beide
zusätzlichen Ordnerwahlen zurück. Symbolische Links und Spezialdateien werden beim Lesen
nicht verfolgt. Ein defekter Fundort wird gemeldet; andere lesbare Quellen
bleiben verfügbar. Ein ausgeschöpftes Gesamtbudget verweigert den Katalog,
statt eine unbemerkt abgeschnittene Auswahl anzubieten.

## Vorschau und Übernahme

**Vorschau vorbereiten** expandiert das ausgewählte Textmakro im Hintergrund
und zeigt den vollständigen Vorher-/Nachher-Diff. **Übernehmen** ersetzt nur den
zugehörigen Editorinhalt; die Datei wird dabei nicht gespeichert. Die Änderung
ist ein Undo-Schritt. Die erste `<caret/>`-Marke setzt die Einfügemarke;
weitere Marken verschieben sie nicht. Ohne Marke steht sie nach dem eingefügten
Text.

Die Vorschau ist an Dokumentidentität, Dateipfad, Textrevision, vollständigen
Ausgangstext, Projektgeneration und Auswahl gebunden. Dokument-, Pfad-, Text-,
Auswahl- oder Projektwechsel erfordern eine neue Vorschau. Auch Projekt
A → B → A macht eine alte Vorschau ungültig. Eine Übernahme verlangt beide
sichtbaren Diff-Seiten; unvollständig angezeigte Ergebnisse bleiben gesperrt.

Unterstützt werden gemischter XML-Text mit Whitespace/CDATA, `<selection/>`,
`<text/>` für den gesamten Ausgangstext, `<method_name/>`, `<user_os/>`,
`<date format="0"/>` bis `8` und `<time format="0"/>` bis `6`.
Der Methodenname stammt aus dem Dateinamen ohne `.4dm` und wird nach NFC
normalisiert. Tatsächliche und XML-escaped `<method_name/>` in Methodenaufrufen
bleiben unterscheidbar vom normalen Textmakro. BOM/XML-Signatur und explizite
XML-Encodingangaben bestimmen die Dekodierung; ungültiges UTF-8 wird nicht
als andere Kodierung geraten.

Ein Namenssuffix ` /x` bietet Ctrl+X an. Der erste Eintrag gewinnt bei doppelten
Makrotasten. Zentrale App- und Editorbefehle bleiben reserviert, darunter
Ctrl+O/L/S/P/Q/W/N/F/G/H und die üblichen Bearbeitungstasten. Alt-, Super- und
Meta-Kombinationen werden nicht von Makros übernommen. Ein Makrokürzel öffnet
dieselbe vollständige Vorschau wie die Mausbedienung.

## Grenzen und Runtime-Makros

Unbekannte Platzhalter, ungültige Formatnummern, Clipboard-Platzhalter und
nicht unterstützte Methoden bleiben mit Begründung sichtbar. Sie werden nie
als unvollständiger Text eingesetzt. Mehrere `<method>`-Aufrufe bleiben
gesperrt: Ein späterer leerer Aufruf darf keinen früheren Aufruf verdecken.
Trennlinien und reine Anzeigeeinträge bleiben ebenfalls nicht ausführbar.

Bekannte Komplettieren-Varianten werden als **Runtime-Makro** erkannt und
unter Linux sichtbar gesperrt. Der Mac-Pfad ist eine eigene Schnittstelle:
Ein konfiguriertes Engine-Projekt muss `MacroRun` enthalten; Tool4D startet
es mit `--startup-method MacroRun` und
`--user-param input|output|variant|method`. Dazu gehören Detokenisierung,
Retokenisierung, eine serialisierte Watch-Datei-Transaktion sowie die
Auswertung von `OK`, `UNVERAENDERT` und `FEHLER` in der Statusdatei.
Der vorhandene Linux-LSP ist lesend und ersetzt diesen Vertrag nicht.
Die Textmakrofunktion stellt deshalb keinen ausführbaren MacroRun-Ersatz dar.

Arbeitsgrenzen: 4096 Verzeichniseinträge pro Suche, 256 XML-Quellen, 8 MiB je
XML, 4096 Makros/131072 Teile/4 Mi UTF-16-Einheiten pro XML und insgesamt
8192 Makros/262144 Teile/8 Mi UTF-16-Einheiten. Der Dokumenteingang ist auf
4 MiB, das expandierte Ergebnis auf 8 MiB und die vollständige Diffanzeige
auf zusammen 4 MiB begrenzt. Bei Überschreitung erfolgt keine Übernahme.

## Prüfung

`cargo test -p fastra-core four_d_macros` prüft den reinen Parser und Renderer.
Die eingecheckten Mac-Goldens stammen aus den originalen Swift-Quellen mit
Apple Swift 6.3.3/Foundation auf macOS 26.0: 240 Datum-/Zeitwerte für
`en_US_POSIX`, `de_DE`, `fr_FR`, fünf Zeitpunkte und alle Formate, jeweils UTC,
sowie sieben Parserfälle einschließlich Namespaces und zwei bytegebundene
Encodingfälle (UTF-16 und Latin-1). Die JSON-Datei bleibt byteidentisch zum
Mac-Oracle; die beiden XML-Dateien sind aus dessen Base64-Blöcken dekodiert.

`cargo test -p fastra-linux four_d_macros` prüft Quellsuche, defekte und
gefährliche Quellen, Budgets und Cache-Identitäten.
`cargo test -p fastra-linux editor_shortcuts` schützt reservierte Befehle.
Der Debug-Fenstertest `FASTRA_4D_MACROS_SELFTEST=1` verlangt eine isolierte
Anzeige (`FASTRA_ISOLATED_DISPLAY=1`) sowie eigene Fixture-, XDG- und
Screenshot-Verzeichnisse. Er prüft echte Quellen-/Makroauswahl, Vorschau und
Übernahme, ein Undo, Unicode-Caret, Ctrl+#, veraltete Auswahl und Projekt-ABA.
Deutsch/Englisch jeweils bei 680 und 1100 Pixel Breite laufen lassen und
Katalog und Diff visuell prüfen.
