# F09/F12: Textwerkzeuge und lokale Markdown-Vorschau

Stand: 2026-11-04. Teilstand neben dem ersten [Linux-Fenster](F07-LINUX.md),
keine vollständige F09-/F12- oder native Desktopabnahme. Die Mac-App und ihr
Renderer bleiben unverändert. Der Linux-Crate-Stand trägt Version 1.158.0.

## Textoperationen und Ansicht

Das native GTK-Menü „Text“ verwendet fensterbezogene Gio-Aktionen. Es bietet die
bereits im gemeinsamen Kern vorhandenen Zeilenoperationen: ICU-Root-Sortierung
auf-/absteigend mit numerischer Ordnung, drei Duplikatmodi, Umkehren, Leerzeilen,
nachlaufende Leerzeichen, Nummerierung, Präfix/Suffix, Verbinden und Regex-Filter.
Unicode-Befehle umfassen ICU-Root-Groß-/Kleinschreibung, NFC/NFD,
Leerzeichen-Normalisierung und das Entfernen unsichtbarer Steuerzeichen.
„ICU Root“ ist ausdrücklich beschriftet und keine Zusage gleicher Ergebnisse wie
bei einer sprachabhängigen Mac-Sortierung.

Ohne Auswahl gilt das ganze Dokument; Zeilenoperationen erweitern eine Auswahl
über die gemeinsame UTF-16-Logik auf ganze Zeilen. Die Berechnung läuft außerhalb
des UI-Threads. Dokument, Revision, Generation und Quelltext werden vor der
Übernahme erneut geprüft. Jede Aktion ist ein gemeinsames Editor-Undo und
schreibt keine Datei. Such-/Editieränderungen brechen alte Berechnungen ab.

„Auswahl falten“ setzt öffentliche unsichtbare Texttags auf ganze logische
Zeilen. „Alles entfalten“ entfernt sie wieder. Beide Ansichten desselben Buffers
teilen diese Faltung; Dateibytes ändern sich nicht. Während der Faltung sind
Zeilennummern verborgen, weil GtkSource sie sonst für unsichtbare Zeilen an
derselben Gutterposition übereinanderzeichnet. Entfalten stellt sie wieder her.
Ein syntaxgesteuerter oder ansichtslokaler Faltungsbaum ist noch offen.

Der Suchmodus startet jetzt mit den dokumentierten Platzhaltern. „Wörtlicher
Text“ bleibt separat verfügbar. „Nur ganze Wörter“ verwendet `SearchFlags` und
`PreparedSearch` aus dem Kern; jede Änderung invalidiert die alte Vorschau.
Die Suchgruppe lässt sich einklappen. Markdown klappt sie für mehr Editorfläche
ein; Ctrl+F und Ctrl+Return öffnen sie bei Bedarf wieder.

## Markdown-Host und Ressourcen

`markdown.rs` verwendet `pulldown-cmark` 0.13.1 mit CommonMark-/GFM-Ereignissen,
keine Regex-Umwandlung. Die vorhandenen lokalen Bibliotheken werden aus
`app/Sources/Fastra/Resources/MarkdownVendor` direkt in das Linux-Binary
aufgenommen: KaTeX 0.17.0, Mermaid 11.16.0, highlight.js 11.11.1 und dessen CSS.
Die kleine Linux-HTML-/CSS-/JS-Hülle übernimmt die Darstellungsregeln und sicheren
KaTeX-/Mermaid-Optionen des bestehenden Mac-Hosts. Es gibt weder CDN-Abhängigkeit
noch Laufzeitzugriff auf `.build` oder den Quellcheckout.

Die Vorschau entsteht erst nach ausdrücklichem Einschalten. Änderungen werden
kurz gebündelt; Markdown-Parse und Bildlesen laufen im Hintergrund. Eine späte
Antwort muss noch zur Dokumentrevision und Vorschaugeneration passen. Der
Aktualisieren-Knopf liest beispielsweise extern geänderte Bilder erneut.
Speichern aktualisiert auch die Basis relativer Bilder eines neuen Dokuments.

WebKitGTK6 läuft mit einer ephemeren Netzwerksitzung und seiner unveränderten
Sandbox. Ein eigenes Schema bedient ausschließlich die vier eingebetteten
Bibliotheksressourcen und die für genau diesen Renderstand aufgelösten Bilder.
Unbekannte Hosts, Pfade und Tokens werden abgewiesen. Die Vorschau selbst navigiert ausschließlich
innerhalb ihrer eigenen Adresse und Fragmente. Explizite Benutzeraktivierungen
von HTTP-/HTTPS-/Mailto-Links werden asynchron an den Systemhandler übergeben;
automatische Navigation und andere Protokolle bleiben gesperrt. DNS-Prefetch
ist deaktiviert. Berechtigungsanfragen werden abgewiesen. Die beiden begrenzten
Nachrichtenhandler für Quellpositionen und Codekopie stehen unter
[F12-SOURCE-CODE](F12-SOURCE-CODE.md); ein Dateischreibpfad fehlt.

Die CSP erlaubt nur dieses Schema für Bilder/Bibliotheken, einen frischen Nonce
für Fastras Initialisierung und Inline-Stile für KaTeX/Mermaid. Netzwerk-, Frame-,
Medien-, Objekt-, Worker-, Formular- und fremde Basisadressen sind gesperrt.
Dokument-HTML wird gegen die aktuelle Mac-Positivliste mit 55 Tags und engen
Attributregeln geprüft. Fragmente werden vollständig geprüft und kanonisch
neu erzeugt; verworfene Fragmente bleiben Text. Fremde Skripte und interne
Positions-/Codeattribute werden nicht übernommen. Rohe HTML-Preblöcke erhalten
keinen vertrauenswürdigen Codekopiereintrag. Die HTML-Attributdekodierung
berücksichtigt die achtstelligen numerischen Referenzen des gepinnten Mac-Parsers;
die getrennte CommonMark-Textdekodierung bleibt unverändert.

## Lokale Bilder und Grenzen

Bildpfade werden aus den geparsten Bildknoten aufgelöst; relative Pfade benötigen
eine gespeicherte Dokumentadresse. Ein echtes `#` wird vor Prozentdecodierung
abgetrennt, `%23` bleibt Bestandteil des Dateinamens. Pfade bleiben Unix-Pfade;
kein verlustbehafteter UTF-8-Umbau bestimmt eine Dateiidentität.

Geprüft werden regulärer Dateityp und Größe am geöffneten Deskriptor sowie die
Identität/Metadaten nach dem Lesen. FIFO und andere Spezialdateien blockieren
nicht. Erlaubt sind PNG, JPEG, GIF und WebP mit passender Signatur; SVG und
Netzbilder bleiben draußen. Pro Bild gelten 32 MiB, insgesamt höchstens 64 MiB
Lese-/Pufferbudget und höchstens 128 Bilder. Texte haben 4 MiB, erzeugtes HTML
16 MiB als Grenze. Die Bildadresse enthält einen SHA-256-Token über aufgelösten
Pfad, Änderungszeit, Größe und tatsächliche Bytes. Ein Bildwechsel kann daher
keine alte positionsbezogene WebKit-Cacheadresse wiederverwenden.

## Dialektprüfung und konkrete offene Unterschiede

Der Mac verwendet den gepinnten cmark-GFM-Parser mit Fastras `==…==`-Erweiterung,
HTML-Positivliste und eigenen Leerzeilenknoten. Der erste Linux-Renderer ist noch
kein Ersatz dieses Pfades. Das ist auch im Vorschau-Tooltip und der gebündelten
Hilfe ausdrücklich benannt.

| Fall im Linux-Korpus | Geprüfte Ausgabe / Grenze |
| --- | --- |
| Tabellen | echte `table`-Struktur |
| Aufgabenlisten | deaktivierte Checkboxen mit geprüftem Zustand |
| Durchstreichen | `del`-Element |
| Soft Break | unveränderter weicher Zeilenumbruch im Absatz |
| Code-Fence | Sprachklasse; lokales highlight.js im echten WebKit |
| Inline-/Blockformeln | geparste Math-Knoten; echtes KaTeX-MathML |
| Mermaid-Fence | echtes gerendertes SVG mit Strict-Modus |
| Fußnoten | Linux-Parser-Erweiterung; keine bestätigte Mac-Gleichheit |
| `==Markierung==` | gemeinsame Marker-Ausgabe; Rich bleibt getrennt geprüft |
| Nur Leerzeichen auf einer Zeile | sichtbare Leerzeilen ab zwei normalen Leerzeichen |
| Roh-HTML | enge Mac-Tag-/Attribut-Positivliste; keine vertrauenswürdigen internen Marker |

Ein vollständiger nativer Mac-/Linux-HTML-Gleichheitskorpus und die gesamte
Markdown-Abnahme bleiben offen. Klicknavigation und Codekopie stehen unter
[F12-SOURCE-CODE](F12-SOURCE-CODE.md), Formeln unter [F12-MATH](F12-MATH.md).
Bildbeobachtung, Druck und Rich sind getrennte Produktpfade mit eigenen
Prüfungen; ein Erfolg der statischen Vorschau belegt diese Funktionen nicht.

## Tatsächliche Prüfung und Paketierung

Geprüft wurden GTK 4.14.5, GtkSourceView 5.12.0, WebKitGTK 2.52.6, ICU 78.3 und
Rust 1.99.1 im isolierten Ubuntu-24.04-Builder. `webkit6` ist auf 0.6.1 gepinnt;
Build-/Laufzeit benötigen zusätzlich WebKitGTK6 ≥2.40 (Debian/Ubuntu:
`libwebkitgtk-6.0-dev` / `libwebkitgtk-6.0-4`; Arch: `webkitgtk-6.0`). Die
vorhandenen Linux-Paketmetadaten müssen diese Abhängigkeit übernehmen.

Der echte GTK-Selbsttest prüft Freigaben/Apply/Undo und Save weiterhin sowie
Ganzwort-Invalidierung, Textsortierung mit einem Undo, Bildbreite 1 → 2 nach
Dateiwechsel, einen frisch geöffneten zweiten WebView, MathML, Mermaid-SVG,
Tabellen, unveränderte Markdown-Dateibytes, CSP-Verletzungsnachweis und das Fehlen
einer Host-Bridge. Das Textmenü wurde zusätzlich tatsächlich geöffnet und per
Maus bedient; ein echtes Ctrl+Z stellte die vorherige Zeilenreihenfolge wieder
her. Falten/Entfalten wurde im echten Fenster visuell geprüft.

Die Fensterläufe verwenden eigenes Xvfb, private XDG-Verzeichnisse, GSettings im
Speicher und einen eigenen D-Bus ohne Desktop-Serviceaktivierung. Der Container
hat keinen Netzwerkzugang. Für WebKits verschachtelte Sandbox musste der
Testcontainer Namespace-Systemaufrufe und unverdecktes `/proc` erlauben
(`seccomp`, `apparmor` und `systempaths` jeweils `unconfined`); die WebKit-Sandbox
selbst blieb eingeschaltet. Die Prozesskette `bwrap → WebKitWebProcess` wurde
beobachtet. Das ist ein isolierter Nachweis, keine Cinnamon-/Wayland-Abnahme.

Die sichtbaren Ansichten wurden in DE/EN breit und bei Mindestbreite geprüft;
auch die dunkle Markdown-Ansicht und die tatsächlich geöffneten Hilfefenster
wurden visuell geprüft.
Markdown zeigt Quellen und Vorschau in einem balancierten, verstellbaren Split.
Die native Hilfe aus `linux/resources/help.de.txt` / `help.en.txt` beschreibt den
aktuell implementierten Teilumfang. Codec-/Großdateiarbeit eines folgenden
Blocks kann diese Dokumentgrenzen ändern und muss die Hilfe dann mitpflegen.

## Spätere Dialektergänzungen

Textmarker, Rich-Bearbeitung, Gliederung und Bildbeobachtung sind in den
späteren F12-/F15-Belegen beschrieben. [Sichtbare Leerzeilen und Kopieren](F12-BLANK-LINES.md)
ergänzen den ursprünglichen Stand; die obige historische Vergleichstabelle
ist keine aktuelle Liste fehlender Funktionen. [Klicknavigation und Codekopie](F12-SOURCE-CODE.md) ergänzen den Stand ab 1.176.0.
[Formeln und ursprüngliche Quellbereiche](F12-MATH.md) ergänzen ab 1.178.0 die normale Vorschau; Rich-Formelparität bleibt eine eigene offene Abnahme.
