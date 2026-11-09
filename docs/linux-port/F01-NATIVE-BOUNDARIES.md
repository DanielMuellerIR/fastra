# F01: native Umbruch- und Eingabegrenzen

Stand 2026-11-06. Die folgenden ursprünglichen Prototypen dokumentieren die
GTK-/Pango-Grenzen und ihre kleinsten Gegenbelege. Der daraus entstandene
optionale Paketpfad ist inzwischen separat integriert; aktuelle Verträge sind
[Umbruchprofile](F07-WRAP-PROFILES.md), [native Editpläne](F01-NATIVE-EDIT-PLANS.md)
und der [private Toolkitpfad](F01-NATIVE-RUNTIME.md). Die unveränderten
Systembibliotheken und die allgemeine IME-Transaktionsgrenze bleiben davon
getrennt.

## Umbruch

Die getrennten Sourcebuffer erlauben eigene Absatz-Tags und paneweise
geklemmten Folgezeileneinzug. Die ursprüngliche gemeinsame Tag-Kollision ist
somit nicht mehr der verbleibende Ausschlussgrund. Dagegen nimmt Pango 1.52.1
17 führende echte Tabs trotz einer Breite von 320 Pixel als 1280 Pixel breites
Fragment an. Eine neue native Gegenprobe unter Pango 1.58.2 bestätigt dasselbe
Ergebnis; zusätzliche Umbruchattribute schließen diese Grenze nicht.
Der [aktuelle Pango-Quellweg](https://github.com/GNOME/pango/blob/1.58.2/pango/pango-layout.c)
nimmt Tab-Runs ausdrücklich vollständig an.

Ein isolierter Patch für Pango 1.52.1 lässt linksbündige Tabs bei CHAR/WORD_CHAR
vor dem nächsten überbreiten Tab umbrechen. Das erste überbreite Graphem darf
weiter ein eigenes Fragment bilden. Ein unabhängiger Review fand zunächst
einen verlorenen früheren Wortumbruch; der korrigierte Kandidat nutzt bei
WORD_CHAR das bestehende Backtracking. Der konkrete Fall `aaa bbbbbb<TAB>TAIL`
besteht damit. Bei Right-/Center-/Decimal-Tabs bleibt die bisherige Behandlung
unverändert; 18 tatsächliche Layoutkombinationen sind zur Systemkontrolle gleich.

Der korrigierte Kandidat besteht den ursprünglichen Tab-Gegenfall sowie zwei
native GtkSourceView-Resizeflüsse mit unterschiedlichen Pane-Breiten,
unveränderten Quellbytes, Dirty, Undo und gerichteten Auswahlmarken. Die
Geometrieproben erfassen je 768 Fragmente, nicht 768 unabhängige Nutzeraktionen.
Sieben Emoji-/Whitespace-Fragmente im schmalen Zustand bleiben eine gesonderte
Überbreitengrenze; vollständige Graphemparität ist damit nicht erklärt.
48 relevante Upstream-Subtests bestehen. Der Upstream-Layouttest bleibt wegen
einer fehlenden Fixture-Schrift übersprungen.

## Eingabe

GTK 4.14.5 beginnt den Commit hinter seiner bisherigen öffentlichen
Einfügegrenze bereits mit einer Useraktion und löscht gegebenenfalls Auswahl
oder Overwrite-Zeichen. Ein `insert-text`-Veto kommt zu spät. Der neue native
Gegenbeleg zeigt sowohl verlorenes Redo nach einer abgewiesenen leeren Aktion
als auch gelöschten Auswahltext vor der abgewiesenen Einfügung. Undo stellt den
Auswahltext wieder her, wenn der Test seinen eigenen Veto vorher entfernt.
Das ist keine geeignete Produkt-Vorprüfung.

Ein isolierter GTK-Prototyp ergänzt einen Query-Rückgabepunkt vor
`begin_user_action`: vollständiger Ersatztext und native Anfangs-/Endpositionen
werden geprüft, bevor die Mutation startet. Sechs echte native Commitfälle
bestehen: Ablehnungen an 64 KiB Zeilen- und 32 MiB Gesamtgrenze, Auswahl und
Overwrite erhalten Text, gerichtete Auswahl, Dirty und vorhandene Historie;
sie erzeugen weder `changed` noch eine Useraktion. Gültige Commitfälle behalten
die bisherige native Rücknahme.

Dies schützt nur den finalen Commit. Preedit-Start kann vorher Auswahl löschen;
Surrounding-Delete, Autoindent/Tab und AT-SPI besitzen weitere Mutationseingänge.
Auch ein reines Delete kann durch Zeilenjoin die Grenze überschreiten. Eine
vollständige Garantie verlangt eine native Transaktionsgrenze für diese Wege,
einen ausdrücklich definierten Kompositions-/Abbruchvertrag und eine begrenzte
Prüfrechnung statt einer 32-MiB-Vollkopie je Taste. Der Prototyp wird deshalb
nicht als allgemeine IME-Lösung angeboten.

Quellen: [GTK-Commit und Preedit](https://github.com/GNOME/gtk/blob/4.14.5/gtk/gtktextview.c),
[GTK-Textgeschichte](https://github.com/GNOME/gtk/blob/4.14.5/gtk/gtktexthistory.c)
und [IM-Commitvertrag](https://docs.gtk.org/gtk4/signal.IMContext.commit.html).

## Produktgrenze

Ein dauerhafter eigener Toolkitstand verändert den bisherigen Vertrag mit
Systembibliotheken. Die ältere Pango-Prototypbibliothek kann nicht einfach vor
aktuelle Systembibliotheken gelegt werden: GTK 4.24.1 importiert sechs erst
später hinzugekommene Pango-Symbole, die ihr fehlen. Ein Produktionspfad braucht
somit passende Versions-/Distributionsgrenzen, reproduzierbare Paketierung und
eigene Wartung. Die ursprünglichen Prototypen bleiben mit Quellen, Patches,
Hashes und kleinen Laufbelegen eingefroren. Ihre positive Weiterentwicklung
ist im ausdrücklich gewählten optionalen Toolkitpfad gebunden; Systempakete
bleiben Standard. Feste Profile und die einzelnen geprüften Eingänge besitzen
nun begrenzte Produktverträge. Vollständige IME-Transaktionen und die zusätzliche
physische Kandidatenfenster-Abnahme bleiben eigene offene Gates.
