# F12: positionsgebundene GFM-Autolinks

Ab 1.187.0 verwenden Linux-Vorschau und Rich-Ansicht für automatische HTTP(S)-,
www- und Mail-Links denselben cmark-GFM-Pin wie die Mac-App:
`924936d0427cb25a61169739a7660230bffa6ea6` (Swift-Paket 0.8.0,
cmark 0.29.0.gfm.13). Die vorhandenen Renderer bleiben erhalten; cmark liefert
besitzende Linkatome und geprüfte Text-/Quellsegmente für die gemeinsame
Parseransicht. Es gibt keine nachträgliche Suche nach gleichlautenden Links.

Die Originalbereiche bleiben bei Entities, Escapes, Tabellen, Fußnoten und
LF/CRLF/CR gebunden. Vorhandene Links, Bilder und Code erzeugen keine
verschachtelten Autolinks. Formelsyntax innerhalb einer URL bleibt wörtlicher
URL-Inhalt. Rich akzeptiert sichere `mailto:`-Adressen auch im vorhandenen
Linkdialog; ASCII-Steuerzeichen und DEL bleiben gesperrt. Die vorhandene
Rich-Navigationspolicy öffnet weiterhin keine externen Ziele.

Die offline vendorten Quellen, vollständigen Lizenztexte, vier Patches sowie
Vorher-/Nachherhashes liegen unter `crates/fastra-linux/native/`. Das Cargo-
Buildscript prüft den vollständigen Dateisatz und alle Hashes, bevor es die
feste C-Dateiliste statisch übersetzt. Geänderte Quellen werden abgewiesen.
Die Parserarena bleibt während des gesamten Aufrufs unter einem Rust-Mutex;
Registryinitialisierung erfolgt einmalig. Der besitzende Ergebnisplan wird
auch bei Abbruch vollständig freigegeben.

Grenzen bleiben ausdrücklich: höchstens 4 MiB Quelltext, 16 MiB vorbereitete
Ansicht beziehungsweise Ausgabe, 100.000 Links und ein kooperatives
Arbeitsbudget. Grenz- und Abbruchfälle liefern keinen partiellen Plan. Das
Arbeitsbudget ist keine allgemeine harte Laufzeit- oder Speicherzusage für jeden
internen cmark-Schritt. Große Rich-Aufbereitung bleibt ein gesondertes
Reaktionszeitkriterium.

Offizielle Autolinkfälle, Originalbereiche, Math/Mark, Fußnoten und Rich-
Rückwege sind geprüft. Ein bestätigter quadratischer Kopierpfad bei vielen
entitycodierten Mailadressen wurde durch eine lineare Segmentübernahme ersetzt;
8.000/16.000/32.000 Adressen und gezielter Abbruch sind gegen das tatsächlich
gebaute C-Archive und unter ASAN/LSAN geprüft. Die bekannten veröffentlichten
Advisory-Fixes sind an den Pin gebunden; begrenzte Gegenfälle bestehen. Das ist
keine allgemeine Sicherheitsgarantie und keine vollständige
Markdown-Dialektgleichheit.
