# F09: gespeicherte Textabläufe und Textbausteine

Stand: 2026-11-08. Dieses Teilpaket ergänzt die nativen Werkzeugmenüs für das
aktive editierbare Dokument und seine einzelne Auswahl. Es schreibt beim
Übernehmen ausschließlich in den Editor. All-Tabs-/Ordnerabläufe sind in [F09-WORKFLOW-TABS](F09-WORKFLOW-TABS.md)
und [F09-WORKFLOW-DISK](F09-WORKFLOW-DISK.md) beschrieben. Suchvorlagen sind im getrennten
[F09-PATTERNS](F09-PATTERNS.md) umgesetzt; F09 ist nicht insgesamt abgenommen.

## Quellen und Datenformate

Referenzen sind `TextWorkflow.swift`, `TextWorkflowStore.swift`,
`TextWorkflowSheet.swift`, `TextSnippetTemplate.swift`, `TextSnippetStore.swift`
und deren bestehende Swift-Tests. Das neue reine Paket `fastra-workflow` liest
`schemaVersion: 1` mit `workflows` beziehungsweise `snippets`. IDs, Revisionen,
Reihenfolge, Aktivierung, Suchflags und sämtliche Parameter bleiben erhalten.
Zusatzfelder werden auch als präzise JSON-Zahlen erhalten; Formatierung und
Schlüsselreihenfolge werden beim Export neu erzeugt.

Import in eine Sammlung erstellt wie der Swift-Store Kopien mit neuen IDs und
Revisionen, neuen Schritt-IDs und gegebenenfalls einem Namenszusatz. Vor dem
Speichern zeigt die GTK-Anbindung bei Abläufen den vollständigen resultierenden
Sammlungsstand, bei Bausteinen die vorgeschlagenen neuen Namen.
Widersprüchliche Erweiterungsfelder, ungültige Definitionen und überschrittene
Grenzen verwerfen den ganzen Import. Es gibt keine stille Teilübernahme.

Unbekannte Felder bleiben gespeichert und exportierbar, werden aber nicht still
interpretiert: unbekannte semantische Felder und aktivierte unbekannte Schrittarten
sperren die Ausführung mit konkreten Feld-/Schrittnamen. U+0000 in bekannten
Textfeldern wird in diesem GTK-Teilstand ausdrücklich abgewiesen, bevor native
Textwidgets oder Dokumentänderungen erreicht werden. Die ursprüngliche
Importdatei wird nie verändert.

Die Namensprüfung verwendet Grapheme und die vorhandene ICU-78.3-Kategorisierung
für Foundations Steuer-/Formatzeichen. Der Namensvergleich für Kollisionen nutzt
Unicode-Kleinschreibung und ist keine belegte benutzerlokalisierte Mac-Kollation.
`unicode-segmentation` ist auf 1.13.3 gepinnt; siehe
[Upstream](https://github.com/unicode-rs/unicode-segmentation). Die Paketierung
sammelt dessen vollständige Lizenztexte wie die übrigen Cargo-Abhängigkeiten.

## Rechnung und Freigabe

Alle 39 Swift-Schrittarten verwenden direkt die vorhandenen
`fastra-core::text_operations` oder `PreparedSearch`. Keine zweite Such-,
Ersetzungs- oder Dateischreibengine wurde eingeführt. Verfügbar sind Suchen/
Ersetzen einschließlich Wildcards, Regex, Case-Operatoren und Whole Word,
Root-Sortierung, drei Duplikatmodi, Root-Casing, Trim/Gremlins, Zeilenfolge,
Leerzeilen, Verbinden, Präfix/Suffix, Nummern, Zeilenfilter, Spaces und NFC/NFD.

Weitere 13 reine Textoperationen samt Parametern sind in
[F09-EXTENDED-TEXT](F09-EXTENDED-TEXT.md) beschrieben. `titlecase` verwendet den
ausdrücklichen [Systemlocale-Vertrag](F09-TITLECASE.md). Die beiden 4D-Transformationen sind in
[F09-4D-TOKENS](F09-4D-TOKENS.md) beschrieben. Ihre Definitionen werden nicht gelöscht. Root-Sortierung
und Root-Casing werden ausdrücklich so beschriftet und nicht als lokale Mac-Parität
behauptet. Der Swift-Schutz gegen vollständig leerfilternde Operationen bleibt
bestehen. Bei gleicher Inhaltszeilenzahl stellt der Ablaufadapter individuelle
LF-/CRLF-/CR-Trenner nach der Einzeloperation wieder her.

Jeder aktivierte Schritt erhält vollständige Vorher-/Nachher-Texte; das Endergebnis
enthält das ganze Dokument einschließlich der unveränderten Bereiche außerhalb
der Auswahl. „Exakte Zeichen“ ist eine sichtbare Darstellungsoption. Der gemeinsame
reine `fastra_core::display::escaped_text` zeigt Backslash, Zeilenenden, Controls
und alle Nicht-ASCII-Codepunkte unterscheidbar. Der Worker berechnet beide Seiten
und sämtliche Stufen vollständig vor der Freigabe. Die normale Ansicht bleibt
lesbar. Ein Darstellungswechsel verlangt eine neue Vorschau; es wird nicht gekürzt
oder still auf eine andere Darstellung zurückgefallen.

Die Übernahme prüft Dokumentobjekt, vollständige Quelle, Revision, Generation,
Definition und Auswahl erneut. Berechnung und Darstellung laufen außerhalb des
UI-Threads; späte Ergebnisse auf geänderter Basis werden verworfen. Ein nativer
Undo-Schritt stellt die gesamte Übernahme zurück. Ein verschobener Cursor macht
auch eine Baustein-Einfügestelle ungültig. Rechteckauswahlen sind für dieses
Werkzeug gesperrt. Veraltete Sammlungsstände überschreiben keine fremden Änderungen.

## Native Bedienung und Speicherung

Die Oberfläche bietet gespeicherte Definitionen, Neu/Duplizieren/Löschen,
geordnete aktivierbare Schritte, Parameter, Vorschauauswahl und explizite Übernahme.
Irrelevante Parameter bleiben deaktiviert. Bausteine verwenden `{{Name}}`, teilen
wiederholte Namen und erlauben mehrzeilige native Feldwerte; eingesetzte Werte
werden nicht erneut als Vorlage ausgewertet.

Die private Sammlung liegt unter `$XDG_CONFIG_HOME/fastra-workflow` beziehungsweise
`$HOME/.config/fastra-workflow`. Verzeichnis und Dateien entstehen mit 0700/0600;
Eigentümer, private Rechte, Dateityp, Symlinks und Hardlinks werden geprüft.
Gehaltene Verzeichnisdeskriptoren, eine nicht blockierende exklusive Sperre,
Bytevergleich des zuletzt gelesenen Stands und atomarer Austausch mit fsync
verhindern verlorene Änderungen. Ein kaputter Store wird nicht geleert.
Ungesicherte Entwürfe werden sowohl am Werkzeug- als auch am Hauptfenster geschützt.
Der Hauptfenster-Guard muss vor einer Session-Abschlussarbeit laufen.

Export erstellt über die vorhandene sichere IO-API eine neue JSON-Datei und
verweigert belegte Ziele. Er exportiert die in diesem Fenster geladene gespeicherte
Sammlung; ungesicherte Entwürfe müssen vorher gespeichert werden. Dokument-Save,
Codecs, Root-Batch-Apply, Recovery und Sessionmodule wurden nicht ersetzt.

Grenzen: 50 Definitionen je Sammlung, 1 MiB je JSON-Archiv, 32 Schritte,
4 MiB Quell-/Ausgabetext, 32 MiB gehaltene Rechentexte und fünf Sekunden je
Berechnung. Die optionale exakte Darstellung ist zusätzlich insgesamt auf 64 MiB
begrenzt und teilt identische Darstellungen. Bausteine erlauben 16 KiB pro Vorlage/
Feldwert, 32 verschiedene Platzhalter und 256 KiB Ergebnis. Fehler liefern keine
Teilvorschau oder Teilübernahme. Die zweisprachige gebündelte Linux-Hilfe beschreibt
den aktuellen Umfang und die Grenzen.

## Textbausteine in Quelltext und Rich

Die eigene Bausteinansicht verwendet dieselben Ablage- und Konfliktprüfungen wie
Textabläufe, folgt aber der Mac-Maske: Bibliothek mit Filter und Auswahl links,
Vorlage, Felder und vollständige Einfügevorschau rechts. Sie beginnt bei
760 × 650 Pixeln; 960 × 740 ist die Idealgröße. Return erzeugt in Feldwerten
Zeilenumbrüche, Tab wechselt den Fokus. Wiederholte Platzhalter teilen ein Feld.
Speichern erhält ausgefüllte Werte. Neue oder duplizierte Vorlagen erhalten einen
freien Namen. Der sichtbare Filter und die Namensprüfung beim Bearbeiten nutzen
ICU; die ältere Archivzusammenführung verwendet weiterhin die oben beschriebene
Unicode-Kleinschreibung.

Das Ziel wird beim Öffnen festgehalten. Quellbausteine prüfen Dokumentmitgliedschaft,
Revision, Pfad, konkrete Teilansicht und deren Auswahl erneut. Die laufende
Zielprüfung verwendet die Revision und die nativen Auswahlpositionen, statt große
Dokumente ständig auszulesen. Die Grenze beträgt hier 32 MiB Quelltext und
64 KiB je logischer Zeile; die 4-MiB-Grenze der Textabläufe gilt nicht für Bausteine.
Die vollständige Prüfung des erzeugten Dokuments läuft vor dem nativen Einfügen
auf einem Worker. Veraltete Ziele werden nicht still an eine neue Auswahl gebunden.

Rich hält nach `prepareAction` ein echtes `fastraVisual.bookmark()` fest. Native
Bindung, Sitzung, Eingaberevision, Dokumentrevision, Pfad und Tabgeneration müssen
beim Einfügen noch passen. `insertBookmarked` verwendet denselben sicheren Renderer
und dieselbe native WebKit-Historie wie die übrigen Einfügungen. Lokale Bilder werden
relativ zum gespeicherten Ziel gelesen; bei ungespeichertem Ziel erklärt die Maske
die nötige Speicherung. Ein Einfügeschritt schreibt keine Dokument- oder Bilddatei.
Nach dem Schließen werden GTK- und DOM-Fokus wiederhergestellt, damit Strg+Z wirkt.

Speichern, Verwerfen und Zurück schützen ungespeicherte Vorlagen. Folgeaktionen
warten auf den Abschluss der GTK-Rückfrage, bevor sie deren Elternfenster verändern.
Export liest bei Bausteinen den aktuellen privaten Store; Import nennt vor der
CAS-gesicherten Übernahme die neuen Namen. Eine fehlgeschlagene Prüfung lässt den
bestehenden Stand erhalten.

## Reproduzierbare Prüfpfade

Die JSON-Fixtures unter `crates/fastra-workflow/tests/fixtures` stammen aus den
Swift-Definitionen und prüfen Datenformat, Transformationsfolgen, Platzhalter,
Grenzen und Ablehnung unbekannter Ausführungsfelder. Die Unit-Suite und
All-Targets-Clippy laufen im bestehenden `linux/test.sh`-Pfad.

`linux/test.sh workflow` bedient die wirklichen Werkzeugmenüs, Datei-Import und
Export, Schrittfolge, Zwischenstufen, Gesamtvorschau, Auswahl und native Rücknahme.
Textänderungen und Darstellungswechsel verwerfen die Freigabe. Ein noch offenes
Ablaufwerkzeug wird für den nativen Undo-Klick vorübergehend ausgeblendet, damit
sein Fenster den Quelleditor nicht verdeckt.

`linux/test.sh snippet-source` prüft festgehaltene Auswahl, direkte Vorschau,
mehrzeilige/wiederholte Werte, Werterhalt beim Speichern, Filter einschließlich
ß/SS, Speichern/Verwerfen/Zurück, tatsächliche Dateidialoge, neue Import-IDs und
Namenszusätze sowie verweigerte veraltete Ziele. `snippet-rich` prüft das wirkliche
WebKit-Lesezeichen, formatierten Inhalt, lokalen Bildverweis, Fokus, native
Rücknahme/Wiederholung und unveränderte Dateien. `snippet-big` verwendet mehr
als 4 MiB Quelltext und 600.000 zusätzliche kurze Zeilen.

Für die Sichtprüfung sind Deutsch/Englisch, hell/dunkel und Mindest-/Idealgröße
vorgesehen. `FASTRA_TOOL_SCREENSHOTS` sammelt die nativen X11-Aufnahmen;
`FASTRA_TOOL_WIDTH` stellt die Breite ein. Die Bausteinmaske verwendet ihren eigenen
Kopf ohne zusätzliche Fenstertitelzeile und zeigt leere Statusbereiche nicht an.
Temporäre XDG-Konfiguration, Daten, Cache, Runtime und State bleiben pro Lauf
isoliert. Native Wayland-/IME-Abnahmen stehen weiterhin gesondert aus.
