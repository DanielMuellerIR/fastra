# F07: native Umbruchprofile

Ab 1.187.0 speichern Linux-Formatprofile Fensterbreite, Seitenlinie oder feste
Spalte 20–500 sowie linksbündige, am ersten Einzug ausgerichtete oder zusätzlich
eingerückte Folgezeilen. Die sichtbare Breite bleibt die Obergrenze. Die
zusätzliche Stufe entspricht der Einrückungsbreite bei Leerzeichen, sonst der
Tabbreite. Keine dieser Einstellungen verändert Dateizeichen.

Die Darstellung verwendet native GtkTextView-Absatzränder und Pango. Sie setzt
die Funktion `pango_fastra_wrap_capability_v1()` mit der exakten Kennung
`0x46570002` voraus. Fehlt sie, werden keine Umbruch-Tags angelegt; die neuen
Controls bleiben ausgeblendet und der Hinweis erklärt den weiter aktiven
Fensterumbruch. Eine Versionsnummer allein aktiviert nichts. Der
[optionale Laufzeitkandidat](F01-NATIVE-RUNTIME.md) liefert den passenden
Tab-Wrap-Fix; beliebige ältere Pango-Bibliotheken dürfen nicht vor neue
Systembibliotheken gelegt werden.

Beide Teilansichten besitzen getrennte Tags trotz gemeinsamer Tagtabelle.
Textänderungen aktualisieren die betroffenen logischen Absätze; Geometriewechsel
werden in Portionen von höchstens 256 Absätzen beziehungsweise drei Millisekunden
zwischen Absätzen verarbeitet. Alte Tags werden auch beim Ablösen eines Buffers
entfernt. Profil-v1 wird unverändert gelesen und erst bei einer tatsächlichen
Änderung als v2 gespeichert. Das feldweise Zusammenführen erhält andere
Fensteränderungen und bisherige Sprachwahlen.

Die isolierten nativen Gates prüfen alle drei Ziele, alle drei Einzüge und zwei
Breiten in beiden Teilansichten, tatsächliche Controlbedienung, 17 führende Tabs,
Unicode/ZWJ, gerichtete Auswahl, Dirty, Revision und Undo/Redo. Der Gegenlauf
ohne Capability behält den bisherigen Umbruch. Ein 100.000-Absatzfall benötigt
zwei eigene Tags je Ansicht, statt eines Tags je Absatz. Diese Belege ersetzen
die gemeinsame Paket- und physische Desktopabnahme nicht.

Pango darf führenden Leerraum als eigenes Fragment behandeln. Ein einzelnes
überbreites erstes Graphem bleibt erlaubt, damit das Layout vorankommt.
Vollständige Mac-Zeilenbruch-, Font-, Hardware- oder Waylandparität wird daraus
nicht abgeleitet. Die ursprünglichen Ausschlussgründe und ihre begrenzten
Gegenbelege bleiben unter [F01](F01-NATIVE-BOUNDARIES.md) nachvollziehbar.

## Desktop-Schrift und tatsächliche Spalten ab 1.188.0

GTK `set_monospace(true)` setzt nur eine CSS-Klasse. Ein Desktoptheme ohne
passende Regel konnte deshalb eine proportionale Quellschrift hinterlassen;
unter dem geprüften dunklen Theme war ein Leerzeichen etwa 3,05 Pixel breit,
während `W` 13 Pixel belegte. Ein rechnerisch korrektes 24-Spaltenprofil war
sichtbar zu schmal. Eine eigene Quellklasse setzt deshalb die generische
Monospace-Familie mit Application-Priorität. Schriftgröße und Farben folgen
weiter dem Theme; fremde App-Widgets erhalten diese Regel nicht.

Die Regression vergleicht echte `TextIter`-Positionen mehrerer ASCII-Zeichen
mit den Pango-Metriken in beiden Ansichten. Der alte Produktcode scheitert
unter den tatsächlichen Theme-/DPI-Einstellungen, der korrigierte besteht.
Die kombinierte Umbruchprobe besteht dort bei Skalierung 2 und zwei
Fensterbreiten über alle drei Ziele und Folgezeilenprofile. Abstände über
mehrere Leerzeichen werden als ganze Zeichenfolge gemessen, damit Rundung
pro Einzelzelle keine scheinbaren Geometriefehler erzeugt. Synthetische
XTest-Koordinaten berücksichtigen den Flächenskalierungsfaktor.
