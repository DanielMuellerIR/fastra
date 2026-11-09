# Umsetzungsplan für Fastra auf Linux

Stand: 2026-11-06. Planungsbasis: Fastra 1.157.1, Commit `6f59816`.
Historisch gebundener Paket-/Desktopstand: **1.188.0 / Build 400**, mit
[gebundenem Paket- und Desktopbeleg](linux-port/F16-1.188.0-EVIDENCE.md).
Gemeinsamer Suchkern, GTK-Anwendung, Dateitransaktionen und Hostwerkzeuge sind
angebunden. Ein separater optionaler Toolkitpfad integriert feste Umbruchprofile
und die jeweils nachgewiesenen nativen Eingabevorprüfungen; Systempakete bleiben
Standard. Die aktuelle Mac-/Cinnamon-Abnahme ersetzt keine vollständige IME-,
Screenreader-, Wayland- oder distributionsübergreifende Freigabe. Die aktuelle
Weiterentwicklung ergänzt die [mehrsprachige Syntaxfaltung](linux-port/F07-FOLDING-FOUNDATION.md)
und die [getrennten reinen Lesewege](linux-port/F07-DOCUMENTS.md#reine-lesegrundlage-ab-12180).
Weitere Markdown-Parität und die optische Gesamtabnahme bleiben offen.
Die [GTK/Pango-Grenzbelege](linux-port/F01-NATIVE-BOUNDARIES.md) bleiben als
historische Gegenproben erhalten; die positive Integration ist separat gebunden.
GTK4/GtkSourceView ist inzwischen die reversible Entwicklungsbasis; die
[aktuelle Toolkitentscheidung](LINUX-DECISION.md#aktuelle-entwicklungswahl-vom-2026-11-05)
blockiert Poor Man's Text nicht bis zu Fastras endgültiger Desktopabnahme.

Die ursprünglichen Paketbeschreibungen bleiben Planungsreferenzen. Die
[fortgeschriebene Abnahmematrix](linux-port/F00-MATRIX.md#fortschritt-der-linux-anbindung)
verlinkt den tatsächlich implementierten und geprüften Umfang; sie erklärt
weder die historische Entscheidungsprobe noch einzelne Paketläufe zur
vollständigen Portierung.

Fastra erhält im bestehenden Repository eine Linux-Anwendung in Rust. Ein
schrittweise eingeführter Rust-Kern soll die fachlich gleichen Operationen auf
macOS und Linux tragen. Die Mac-Oberfläche bleibt SwiftUI/AppKit mit CodeEdit.
Ziel sind CachyOS mit KDE/Wayland und Linux Mint 22.2 mit Cinnamon/X11 auf x86_64.
Markdown-WYSIWYG darf einer ersten alltagstauglichen Linux-Version folgen;
vollständige funktionale Gleichwertigkeit bleibt ein eigenes Abschlussziel.

## Verbindliche Grenzen

- Vorschau, freigegebene Treffer, Dokumentrevisionen und Apply bilden einen
  gebundenen Vorgang. Keine neue Suche hinter dem Apply-Button, keine still
  geänderte Trefferbasis und keine schreibende Abkürzung für CLI oder Tests.
- Dateiquellen, bestehende Sicherheitsgrenzen, Encoding/BOM und die ausdrücklich
  definierte Wildcard-/Capture-Semantik bleiben erhalten.
- Kein vollständiger Mac-Neubau und kein dauerhafter Linux-Fork. Kein gemeinsamer
  plattformübergreifender Fenster-/Editorrahmen für beide Betriebssysteme.
- Dokumente werden lokal verarbeitet. Die Verbindung zu Poor Man's Text bleibt
  zunächst ein lokaler Prozessaufruf. Keine Konvertierung über einen entfernten Mac.
- Keine neue Cloud-, Konto-, Telemetrie- oder Modellabhängigkeit im Produkt.
- macOS-Funktionen erhalten unter Linux sinnvolle Entsprechungen; AppleEvents,
  Finder und Sparkle selbst sind keine Linux-Abnahmekriterien.
- Eine Teilversion bezeichnet ihre Lücken ausdrücklich. Ein als nicht verfügbar
  gemeldetes Merkmal ist damit noch nicht vollständig portiert.

Die geltenden Projektregeln und [Build-Anleitung](BUILD-AND-TEST.md) bleiben
maßgeblich. Ein erfolgreicher Rust-Test ersetzt keine Mac- oder Linux-GUI-Abnahme.

## Zusammenarbeit mit Poor Man's Text

Poor Man's Text bleibt ein eigenständiges Produkt und Repository mit eigener CLI
und Oberfläche. Fastra besitzt Editor, Such-/Ersetzungslogik, Vorschau und die
Entscheidung zum Import. Poor Man's Text besitzt Erkennung, Konverter, OCR,
Ausgabepakete und Verlustdiagnosen. Fastra implementiert keine zweite Formatliste
und keine eigenen Office-/Mail-Konverter.

Das Gegenstück zu diesem Plan liegt im Repository `poormans_text` unter
`docs/LINUX-PORT.md`. Die gemeinsame Schnittstelle ist dort unter
`docs/FASTRA-CONTRACT.md` definiert. Deren erster Stand dokumentiert den heutigen
CLI-Vertrag; geplante Erweiterungen sind getrennt gekennzeichnet. Der PMT-Writer
pflegt Vertrag und Produzenten-Fixtures, der Fastra-Writer pflegt den Verbraucher.
Jede abgestimmte Integrationsabnahme nennt beide Commits und den Vertragsstand.

Ein gemeinsames Rust-Konverterpaket ist keine Startvoraussetzung. Poor Man's Text
prüft zuerst die Wiederverwendung seines vorhandenen Swift-Kerns auf Linux.
Diese Entscheidung darf Fastras Editorentwicklung nicht blockieren.

## Zielarchitektur und Migrationsgrenzen

Die bestehende Mac-App bleibt unter `app/`. Der Cargo-Workspace entsteht daneben;
die folgenden Namen sind vorgeschlagene Zuständigkeiten, keine fertigen Targets:

| Bereich | Inhalt | Bewusst außerhalb |
| --- | --- | --- |
| `fastra-core` | Wildcards, Ersetzungsvorlagen, Treffer-/Vorschaumodell, Freigaben, Textoperationen, Diff-/Filterberechnung | GUI, direkte Dateischreibvorgänge, globale Einstellungen |
| `fastra-io` | Begrenztes Lesen, Dateisnapshots, sichere Transaktionssteuerung | Keine Behauptung gleicher Systemaufrufe auf allen Plattformen |
| Plattformadapter | Darwin-/Linux-Dateioperationen, Prozessverwaltung, Beobachter | Keine eigene Definition der Vorschau-/Apply-Regeln |
| `fastra-ffi` | Kleine, typisierte Swift-Anbindung, zunächst UniFFI prüfen | Fensterobjekte, UI-Callbacks pro Zeichen, riesige ungebremste Textkopien |
| Linux-App | Editoranbindung, Fenster, Linux-Systemintegration | Eigene Regex-/Ersetzungssemantik |
| Gemeinsame Prüfdaten | Eingaben und erwartetes fachliches Verhalten | Persönliche Dokumente und plattformspezifische Pixelgleichheit |

Nur tatsächlich benötigte Pakete anlegen. Git-Auswertung darf später ein eigenes
Paket erhalten; kein vorab aufgebautes Framework aus leeren Modulen.

Sucharbeit läuft außerhalb des UI-Threads. Ergebnisse besitzen eine Generation
und eine Dokumentrevision; verspätete Antworten dürfen weder neue Eingaben noch
einen wiederverwendeten Tab überschreiben. Cancellation gehört zur API.
UTF-8-Byteposition, UTF-16-Position, logische Zeile und sichtbare Spalte sind
unterschiedliche Typen. Die Umrechnung liegt zentral und wird über Unicode-Fälle
geprüft. Dateipfade sind keine normalisierten Dokumentstrings: unter Linux
ungültiges UTF-8 in Namen bewusst behandeln, niemals verlustbehaftet umdeuten.

### Schrittweise Übernahme auf dem Mac

1. Vorhandenes Swift-Verhalten als überprüfbare Eingabe-/Ausgabefälle sichern.
2. Ein begrenztes Modul in Rust implementieren und beide Ergebnisse vergleichen.
3. Die native Mac-Anbindung dieses Moduls samt Paketierung prüfen.
4. Erst dann den alten produktiven Pfad entfernen; Prüffälle bleiben bestehen.

Reine Textmodule kommen vor Schreibtransaktionen. Kein dauerhafter doppelter
Produktpfad und kein ungeprüfter Rückfall von Rust auf Swift bei Fehlern. Der
letzte grüne Commit bleibt die Rückkehrmöglichkeit. Ein Scheitern der FFI-Prüfung
führt zu einer angepassten Modulgrenze, nicht zum Ersatz der Mac-Oberfläche.

## Frühe Entscheidungstests

Die folgenden Versuche gehören in isolierte Entwicklungsstände. Zunächst ein
Arbeitsblock von höchstens vier Stunden je Versuch; danach Ergebnis und Rest
bewerten. Die Begrenzung ist ein Diagnosepunkt, keine Zusage, dass das Problem
in vier Stunden gelöst ist. Zwei erfolglose gleiche Prüfwege ohne neue Erkenntnis
führen zu einem anderen Versuch oder einer begründeten Entscheidungsvorlage.

### F01 Editor und Linux-Oberfläche

Erster Kandidat: GPUI mit GPUI Kit. Vergleich: GTK4 mit GtkSourceView. egui bleibt
nur dann Kandidat, wenn eine konkrete geeignete Editor-Komponente nachgewiesen
wird. Keine Eigenentwicklung eines Textlayouts als Nebenprodukt der Portierung.

Beide Proben müssen dieselben Fälle zeigen: Datei mit 4 MiB Text, 32-MiB-Grenzfall,
sehr lange Einzelzeile, Emoji/kombinierende Zeichen, CRLF, Tabulatoren, zwei
Ansichten desselben Dokuments, ein Undo pro Mehrfachoperation, Syntaxfarben,
Faltung, IME-Komposition, deutsche Tastatur und Zwischenablage. Rechteckauswahl
unter Soft Wrap muss auf logischen Zeilen bleiben und kurze Zeilen beim
Spalteneinfügen richtig auffüllen. Capture-Pillen lassen sich mit der Maus in
Ersetzungstext ziehen. Auf Wayland und X11 sind Fokus, Drag-and-drop, Menüs,
Skalierung und Zugänglichkeit zu prüfen.

GPUI Kits dokumentierte Auswahl pro Bildschirmzeile ist eine bekannte Abweichung,
kein bestandener Nachweis. Die Probe muss zeigen, ob sich die benötigte Semantik
über eine wartbare öffentliche Schnittstelle ergänzen lässt. Bei GTK sind
Mehrfachauswahl/Faltung und notwendige Erweiterungen ebenso nachzuweisen.

**Ausgang:** Entscheidung mit Versionspins, benötigten Patches, Aufwand und
Messwerten für Öffnen, Tippen, Speicher und Scrollen. Kein Kandidat gewinnt allein
wegen eines schönen Demo-Fensters. Benötigt jeder Kandidat einen großen Fork,
stoppt die GUI-Festlegung; Alternativen und Kosten zur Entscheidung vorlegen.

### F02 Regex und Unicode

ICU über eine gekapselte Rust-Anbindung gegen den bestehenden
`NSRegularExpression`-Pfad vergleichen. Eine festgelegte ICU-Version und ihre
Paketierung auf beiden Plattformen prüfen; keine privaten Apple-ICU-Symbole nutzen.
Rusts `regex` ist kein kompatibler Ersatz für Lookarounds und Rückreferenzen.

Korpus: gieriges `*`, mehrzeiliges `**`, Sternläufe, Literalschalter, leere Treffer,
Capture-Nummerierung, benannte Gruppen, Escapes, Case-Templates, Auswahlbereiche,
Unicode-Wortgrenzen, NFC/NFD, Surrogatpaare und alle unterstützten Zeilenenden.
Echte gespeicherte Vorlagen ergänzen nur nach Freigabe und ohne private Inhalte.
Pathologische Muster benötigen begrenzte Laufzeit/Speichernutzung und Abbruch.

**Ausgang:** keine unerklärte fachliche Differenz im verpflichtenden Korpus;
genaue Trefferpositionen und Ausgabebytes. Abweichungen benötigen Korrektur oder
eine ausdrückliche Produktentscheidung samt Migration. Keine stillen Fallbacks.

### F03 Dateioperationen und FFI

Zwei kleine Proben, getrennt auswerten: Swift ruft ein reines Rust-Modul aus dem
gepackten Mac-Bundle auf; Linux führt eine sichere Ersetzung mit den realen
Dateisystemprimitiven aus. Fehler, Abbruch, Speicherbesitz und Panics an der
Sprachgrenze testen. Keine UI-Arbeit in Rust-Callbacks.

Linux-Fälle: Btrfs und ext4, Quelle geändert, Pfad ausgetauscht, Symlink/FIFO,
volle Platte, verweigerte Rechte, Metadaten, Abbruch vor/nach Tausch und
Prozessabbruch. Austausch-/Rollback-Semantik an `renameat2` und tatsächlich
unterstütztem Dateisystem prüfen; Netz-/Wechseldatenträger separat. Fehlende
Garantie verständlich ablehnen, niemals mit unsicherem Überschreiben ersetzen.
Ein einzelnes Rename macht eine Mehrdateiänderung nicht zu einer systemweiten
atomaren Transaktion; Wiederherstellung und beobachtbare Grenzen dokumentieren.

**Ausgang:** keine verlorene Ausgangsdatei; jeder Fehler hat einen nachprüfbaren
Endzustand. Paketierte FFI funktioniert ohne Build-Verzeichnisse.

### F04 Markdown und Hilfsprogramme

Bestehende HTML-/JS-Ressourcen in einer Linux-Webansicht lokal rendern. Zuerst
Vorschau mit Bild, KaTeX und Mermaid; dann ein WYSIWYG-Absatz mit Speichern,
frischem Öffnen und Undo. Netzwerkfreiheit, Dateischema, Bildidentität und
Message-Bridge prüfen. Ein Minimalprototyp genügt hier, kein vollständiger Umbau.
Der gewählte UI-Weg muss eine tragfähige Integration erlauben.

Parallel Verfügbarkeit der bestehenden externen 4D-/LSP-/Makro-Werkzeuge auf
Linux prüfen. Native 4D-Syntax/Indexierung von einer externen Runtime trennen.
Fehlt ein lokales Backend, die betroffenen Funktionen ausdrücklich offen halten.

**Ausgang:** Vorschaupfad, WYSIWYG-Pfad und externe Funktionsgrenzen bekannt.
WYSIWYG darf später folgen, blockiert aber vollständige Gleichwertigkeit.

## Arbeitspakete

F00–F04 sind die Entscheidungsphase. Die weiteren Pakete gelten erst nach den
jeweils genannten Toren. Jedes Paket endet mit grünem relevanten Prüfumfang,
kurzem Beleg und eigenem fachlich zusammenhängenden Commit. Große Pakete dürfen
an den genannten Funktionsgruppen geteilt werden; keine halbfertige öffentliche
Funktion freischalten. Die Einzelstände der Entscheidungsphase stehen im [Entscheidungsbericht](LINUX-DECISION.md);
Der aktuelle Stand von F05–F17 samt verbleibenden Grenzen steht in der
[fortgeschriebenen Abnahmematrix](linux-port/F00-MATRIX.md); die folgenden
Paketbeschreibungen bleiben Zielverträge, keine aktuelle Erledigtenliste.

### F00 Bestand und Referenzen sichern

**Abhängigkeit:** keine. **Umfang:** README, Hilfe, Tests, Ressourcen und
Editor-Patches in eine Funktionsmatrix überführen. Jede Zeile erhält vorhandene
Quelle, Linux-Zielverhalten, Paket und Test. Kleine unabhängige Referenzdateien
mit erwarteten Treffern, Bytes und Fehlern sichern. Grenzwerte aus Code übernehmen,
nicht aus alten Testzahlen. Einen gültigen Mac-Baseline-Lauf herstellen.
**Abnahme:** sämtliche unten aufgeführten Funktionsgruppen zugeordnet; Baseline
mit Commit und App-Version. **Grenze:** kein Funktionsumbau.

### F01 bis F04 Entscheidungstests ausführen

**Abhängigkeit:** F00, innerhalb der Phase unabhängig ausführbar.
**Lieferung:** je ein kurzer Entscheidungsbeleg gemäß vorherigem Abschnitt,
reproduzierbare Probe und gegebenenfalls kleine weiterverwendbare Prüfdaten.
**Abnahme:** bestanden, begründet verworfen oder externe Entscheidung erforderlich;
kein pauschales „funktioniert wahrscheinlich“. Keine Produktfreigabe durch diese
Versuche. Eine verworfene Probe wird nicht zur zweiten Produktimplementierung.

### F05 Rust-Grundlage und erste Mac-Anbindung

**Abhängigkeit:** F02, F03-FFI. Cargo-Workspace, festgelegte Toolchain,
Versions-/Ressourcenpfad und minimale Swift-Anbindung anlegen. Mit Wildcard- und
Ersetzungsvorlagen beginnen; die Mac-UI bleibt identisch. Fehlertypen tragen
strukturierte Daten, lokalisierte Darstellung bleibt beim Host.
**Abnahme:** gemeinsame Prüfdaten in Rust und Mac-Integration grün; echtes Bundle
portabel; bisheriger Swift-Produktpfad erst nach Gleichheitsnachweis entfernt.

### F06 Suche und Vorschau als gemeinsame Fachlogik

Der erste gemeinsame Ordnerpfad samt Dateifreigaben ist in
[F06-FOLDER-SEARCH](linux-port/F06-FOLDER-SEARCH.md) beschrieben.

**Abhängigkeit:** F05. Buffer-/Ordner-/Projekt-/Alle-Tabs-Suche, Filter,
Cancellation, Trefferlimits, Captures, Case-Templates, Auswahlbereiche und
Trefferfreigabe übertragen. Suchgeneration und Dokumentrevisionen explizit
modellieren. Ergebnisse beim Öffnen eines Ordnersuchtreffers nicht neu starten.
**Abnahme:** gleiche Treffer, Reihenfolge, Warnungen und Vorschau; stale Ergebnisse
werden abgewiesen. Alle materialisierten Grenzen sind sichtbar. Keine Writes.

### F07 Linux-Dokumente und Editor

**Abhängigkeit:** F01, F03-Linux. Öffnen/Speichern, mehrere Fenster/Tabs,
Dirty-Zustand, sichere Auswahl, Encoding, Zeilenenden, Syntaxfarben, Split,
Wrap, Rechteckauswahl, Undo/Redo und Sitzungswiederherstellung anlegen.
Nur gespeicherte Dokumente wiederherstellen; ungesicherte Inhalte nicht plötzlich
persistieren. Große/binäre Dateien in die vorhandenen Abschnitts-/Hex-Regeln
überführen. **Abnahme:** echte Maus-/Tastaturbedienung, Neustart, externe
Dateiänderung und Speichern mit unabhängiger Byteprüfung auf beiden Desktops.

### F08 Vollständiger Vorschau- und Apply-Durchstich

**Abhängigkeit:** F06, F07. Suchmaske mit allen Bereichen, ziehbaren Captures,
selektiver Freigabe und vollständiger Vorher-/Nachher-Ansicht bauen. Gemeinsamen
Plan mit einem Linux-Dateiadapter ausführen. No-op-Eingaben bis zum letzten
Preflight mitprüfen. Undo/Recovery und Änderungen an offenen Dirty-Buffern
explizit behandeln. **Abnahme:** manipulierte Quellen/Freigaben verhindern Apply;
Abbruch und Fehler erhalten Originale; reale erfolgreiche Mehrdateiänderung samt
Rückgängig. Mindestbreite und breite Ansicht je Bereich in DE/EN prüfen.

### F09 Textwerkzeuge und gespeicherte Abläufe

**Abhängigkeit:** F06–F08. Sortieren, Duplikate, Zeilenfilter, Extraktion,
Unicode-Transformationen, Gremlins, Nummerierung, Umbruch, JSON/XML-Formatierung,
Transformation per Beispiel, Suchvorlagen, Textbausteine und Textabläufe portieren.
Gemeinsame Rechnung von Editor-Undo trennen. **Abnahme:** jeder vorhandene Befehl
in der Matrix über echten Menüweg; ein Undo pro fachlicher Aktion und unveränderte
Bereiche außerhalb der Auswahl. Import/Export bestehender Vorlagen kompatibel.

### F10 Projekte und Vergleiche

**Abhängigkeit:** F07, F08. Dateibaum und Filter, idempotente Dateibeobachtung,
Umbenennungserkennung, Spracheinstellungen, Datei-/Ordner-Diff, Blockübernahme,
Berichte und externen Diff-Helfer portieren. Rechenbudgets des Diff-Kerns erhalten.
**Abnahme:** große/repetitive Diffs, relative Pfade und geänderte Quellen ehrlich
behandelt; Blockübernahme an Zielrevision gebunden; externe Ereignisse erhalten
Dirty-Texte. Ordnervergleich bleibt schreibgeschützt.

### F11 Git-Funktionen

**Abhängigkeit:** F10. Status, Staging, Commit, Graph, Branches, Remotes,
Konfliktauflösung und vorhandene Advanced-Aktionen in Gruppen umsetzen. Danach
Fetch/Pull und exakt gebundene Push-/Force-with-Lease-Vorschau. Asynchrone
Prozessgruppen, Git-Fehler und Linux-Credential-/SSH-Integration erhalten.
**Abnahme:** temporäre lokale Repos/Remotes, Rebase-/Merge-Konflikte, stale
Push-Vorschau, fehlendes Git, Abbruch und Kindprozess-Cleanup. Kein echtes
Arbeitsrepository als Fixture. Keine neue Git-Engine.

### F12 Markdown-Quellmodus und Vorschau

**Abhängigkeit:** F04, F07. Assistiertes Schreiben, Bilder/Paste/Drop,
Gliederung, Links/Anker, Verweisprüfung, KaTeX/Mermaid und Syntaxanzeige portieren.
Vorhandene Ressourcen teilen; getrennte Plattform-Bridge. Ungefragte
Netzwerkladevorgänge verhindern. **Abnahme:** wirkliche gerenderte Inhalte,
Bildwechsel ohne Cache-Verwechslung, Ordnerumzug und unabhängiges Speichern/Öffnen.

### F13 Poor-Man's-Text-Integration

**Abhängigkeit:** F07, F12 und PMT P01/P03/P06. Katalog, Verfügbarkeit,
Datei-/Paket-Erkennung, Vorschaufrage, Fortschritt, Abbruch, Diagnoseanzeige und
sichere Übernahme des vollständigen Ergebnisbaums nach Vertrag implementieren.
Tab-/Projektgenerationen vor dem Abschluss erneut prüfen. Sammlungen mit
Übersicht, Einzeldokumenten und Assets erhalten. Spätere PMT-Formatpakete
ergänzen dieselbe Abnahmematrix ohne neue Endungsliste in Fastra.
**Abnahme:** reales DOCX/RTF mit Bild, Tabelle, Sammlung, Abbruch, fehlendes Tool,
maliziöse CLI-Ausgabe, Projektwechsel, wiederverwendeter Diff-Tab, persistente
Bildlinks nach Beenden beider Apps. Alte/neue Producer nach Vertragsmatrix.

### F14 Weitere Ansichten und Fachfunktionen

**Abhängigkeit:** F09/F10; PDF-/Bildbackend mit PMT P04/P09 abstimmen.
Hex-Edit, Bild/PDF/SVG-Vorschau, Druck, Gliederung/Navigation, XPath-Teilmenge,
4D-Farben, Index/Completion/Signaturen und lokal verfügbare LSP-/Makro-Anbindung
portieren. Code-Erklärungsplayer, Snapshot-Steuerung und Herkunftsprüfung erhalten.
**Abnahme:** Funktionsmatrix ohne unbegründete Lücken; sichere Ausgabe und
Ressourcenlimits; fehlende externe 4D-Fähigkeit nicht als implementiert zählen.
Plattformbefehle dürfen Linux-Konventionen folgen, müssen aber sichtbar sein.

### F15 Markdown-WYSIWYG

**Abhängigkeit:** F12 und bestandener F04-Pfad. Bestehenden JS-/HTML-Bestand und
Blockerhalt weiterverwenden. Synchronisation vor Save/Close/Moduswechsel,
Clipboard/Images, Tabellen, Formatierung und Undo an Linux anbinden.
**Abnahme:** jeder Formatierungsbefehl über Speichern, Schließen und frisches
Öffnen; geschützte Bereiche, NBSP, Listen, Tabellen, Unicode und externe
Dateiumzüge. Unveränderte Markdown-Blöcke bleiben erhalten. Keine alleinige
DOM- oder Screenshot-Prüfung. Darf nach der ersten Alltagsversion folgen.

### F16 Paketierung und Desktopintegration

**Abhängigkeit:** F07/F08; Auslieferung erst mit gewähltem Meilensteinumfang.
Zunächst Debian-Paket für Mint/Ubuntu-24.04-Basis und Arch-Paket für CachyOS.
CLI-Helfer, Icons, MIME-/Desktop-Einträge, Ressourcenzugriff, DE/EN-Hilfe,
XDG-Einstellungen und Paketmanager-Updates definieren. Vorhandene Standards nicht
ungefragt übernehmen. Keine Build-Pfade als Laufzeitabhängigkeit.
**Abnahme:** frische Installation ohne Entwicklerwerkzeuge, Datei-Doppelklick,
Upgrade, Entfernung ohne Nutzerdatenverlust; Linux-App und optionale PMT-CLI
unabhängig installierbar. Flatpak/AppImage erst nach gesonderter Bewertung.

### F17 Mac-Konsolidierung und gemeinsame Freigabe

**Abhängigkeit:** alle Pakete des jeweiligen Freigabeumfangs. Bereits übertragene
Module konsolidieren und weitere gemeinsame Teile nur bei messbarem Nutzen
übernehmen. Linux-Eigenheiten bleiben in Adaptern. Vollständige Mac-Suite nach
Build, Ressourcen-/Lokalisierungs-/Portabilitätsprüfungen sowie notarierte native
Abnahme der betroffenen Funktionen. Linux-Langlauf mit mehreren großen Dokumenten,
Fenstern, wiederholtem Import und Prozessneustart.
**Abnahme:** keine offene Datenverlust-/Vorschauverletzung, alle Pflichtfälle
bestanden, Umweltfehler getrennt, bewusste Produktabnahme. Veröffentlichung und
öffentliche Remotes benötigen weiterhin einen gesonderten Auftrag.

## Meilensteine und kritischer Pfad

| Meilenstein | Benötigt | Aussage |
| --- | --- | --- |
| M0 Technische Entscheidung | F00–F04, PMT P01 und P02/P04 | UI, Regex, Dateisicherheit, Markdown- und Konverterweg entschieden |
| M1 Sicherer Linux-Alltag | F05–F08, F12, F16 im Teilumfang | Öffnen, Bearbeiten, Vorschau, Apply/Undo und Markdown lokal nutzbar; Lücken benannt |
| M2 Beide Apps zusammen | F13 und PMT P06/P07/P08/P12/P13/P15 | Reale Konvertierung samt Bildern/Sammlungen und gegenseitigem Öffnen |
| M3 Funktionsgleichwertigkeit | F09–F11, F14–F17; alle PMT-Formatgruppen | Vollständige Matrix einschließlich WYSIWYG oder ausdrücklich geänderter Produktumfang |

F05/F06 können nach ihren Toren parallel zu F07 vorbereitet werden, benötigen
aber getrennte Arbeitskopien und explizite Writer-Zuordnung. Der normale Start
verwendet einen Writer pro Repository. Die beiden Produkt-Repositories können
gleichzeitig arbeiten. PMT-Formate und Fastra-Git sind weitgehend unabhängig.

F01 ist Eigentümer der Linux-Toolkitentscheidung; PMT P12 wartet nur auf diesen
Entscheidungsbeleg, nicht auf die fertige Fastra-App. PMT P01 besitzt den
Konvertervertrag; Fastra darf bis dahin gegen den dokumentierten Altvertrag
arbeiten. Keine gegenseitigen Kreisabhängigkeiten.

## Verifikation und Gleichwertigkeitsmatrix

F00 legt für jede Funktion eine Zeile mit `vorhandener Beleg`, `Linux-Paket`,
`Test`, `Status` und `offene Grenze` an. Pflichtgruppen: Editor/Dateien;
Suche/Wildcards/Regex/Freigabe/Apply; Textoperationen/Vorlagen/Abläufe;
Projekte/Dateibeobachtung; Datei-/Ordner-Diff; Git; Markdown-Quelle/Vorschau/
WYSIWYG; Bilder/PDF/Hex/Druck; 4D/XPath/Navigation; Code-Erklärungen/CLI-Helfer;
Sitzung/Einstellungen/Hilfe/DE/EN; Import und externe Desktop-Einstiege.

Tests vergleichen Fachresultate und Dateibytes, nicht Mac-/Linux-Pixelgleichheit.
Für UI gelten beide Sprachen, hell/dunkel, Mindestbreite und breite Ansicht,
Maus/Tastatur, Wayland/X11 sowie 100 % und fraktionale Skalierung. Der konkrete
Alt-/Strg-Shortcut muss mit den Desktop-Shortcuts verträglich sein.

Sicherheitsprüfungen umfassen Quellenwechsel zwischen Vorschau und Apply,
No-op-Eingaben, ungültige Pfade, Symlinks, volle Platte, fehlende Rechte,
Prozessabbrüche, Kindprozesse und nicht UTF-8-codierte Dateinamen. Große Dateien
prüfen die vorhandenen Grenzen, nicht einen neuen unbegrenzten Vollimport.

Performance wird in F00/F01 gemessen; daraus vor weiterer Optimierung feste
Budgets für Start, Laden, Eingabe, Suche, Abbruch und Speicher ableiten. Auf
demselben Host und mit demselben Korpus vergleichen. Ein grüner isolierter Test
ersetzt weder Langlauf noch nativen Installationspfad.

## Arbeitsauftrag je Entwicklungsblock

Der Entwicklungsagent erhält genau ein Paket oder einen zusammenhängenden
kleinen Block: Ziel, Basis-Commit, erlaubte Pfade, Abhängigkeiten, Akzeptanzfälle
und Stoppgrenze. Zuerst bestehende Tests und Regeln lesen; bei einem Verhaltenstest
den Fehler beziehungsweise die erwartete Referenz unabhängig von der neuen
Implementierung festhalten. Pro Block die kleinste vollständige Funktion liefern.

Abschluss: geändertes Verhalten, relevante Tests, offene Grenze, Commit,
Schnittstellen-/Dependency-Änderung und nächstes freies Paket. Bei Plattformblockern
unabhängige Arbeit fortsetzen, keine grünen Tests erfinden. Nach F00–F04 zunächst
Entscheidungsbericht; keine stillschweigende Freigabe eines großen UI-Forks.

Reine Plan-/Test-/Strukturarbeit ohne Verhaltensänderung braucht keinen
Produktversions-Bump. Nutzerwirksame Implementierungen folgen der bestehenden
Versionsregel im selben Commit. Hilfe und beide Screenshot-Sprachen prüfen;
Hilfe-Marker nach den Projektregeln aktualisieren.

## Technische Referenzen

- [PhotoCraft-Schichten und Befehlsmodell](https://github.com/storytold/photocraft/blob/main/AGENTS.md)
- [GPUI-Kit-Editor und Auswahlverhalten](https://gpui-kit.com/component/editor/)
- [GtkSourceView](https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/overview.html)
- [ICU-Regular-Expressions](https://unicode-org.github.io/icu/userguide/strings/regexp.html)
- [Grenzen von Rust regex](https://docs.rs/regex/latest/regex/)
- [UniFFI mit Swift](https://mozilla.github.io/uniffi-rs/latest/)
- [WebKitGTK und GTK4](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/gtk/migrating-to-webkitgtk-6.0.md)

Referenzstand 2026-11-04. Versionen werden bei F01–F04 erneut ermittelt und bewusst
gepinnt. Die Webseiten belegen Fähigkeiten und APIs, keine bestandene
Fastra-Portierung.
