# F07: Suche in der aktiven Auswahl

Stand: 2026-11-05. Der Hauptfenster-Suchbereich ergänzt „Aktuelle Auswahl“ als
Index 4. Aktive Datei (0), alle Tabs (1), Ordner (2) und Projekt (3) behalten ihre
bestehenden Kennungen und Suchwege. Eine nichtleere zusammenhängende Auswahl ist
verbindlich. Ohne sie oder bei einer Rechteckauswahl verweigert die Oberfläche die
Suche ausdrücklich; es gibt keinen Ganzdatei-Rückfall.

Die nativen GTK-Zeichenpositionen werden als unveränderliche Grenzen zusammen mit
dem vollständigen Text erfasst. Eine lineare UTF-16-Umrechnung läuft auf dem
Such-Worker. Die vorhandene `SearchRequest.range` steuert danach dieselbe begrenzte
Core-Suche; es gibt keine neue Such- oder Transformationsengine. UTF-16-Grenzen und
Ausgabe beziehen sich weiterhin auf den vollständigen Dokumenttext. Vorher/Nachher
zeigt deshalb auch unveränderte Textbereiche außerhalb der Auswahl.

Nur Insert-/Selection-Bound-Marken des aktiven Dokuments entwerten eine laufende
oder fertige Vorschau dieses Bereichs. In anderen Bereichen lösen bloße
Cursor-/Auswahlbewegungen keine neue Suchgeneration aus. Ein Tabwechsel oder
Textänderungen folgen den bisherigen Invalidierungsregeln. Späte Ergebnisse
prüfen Generation und Auswahlgrenzen erneut. Auch unmittelbar vor Apply wird die
gebundene Auswahl geprüft; nach jeder Auswahlverschiebung ist neu zu rechnen.

Der Primary-Apply-Pfad enthält außerdem unmittelbar vor `begin_user_action` dieselbe
zentrale `text_limits::validate`-Prüfung wie die übrigen Hostpfade. NUL, mehr als
32 MiB Text und logische Zeilen über 64 KiB werden vor jeder GTK-Mutation mit einer
sichtbaren DE/EN-Meldung verweigert. Ein solcher Fehler ändert weder Text noch Undo.
Die vorhandene gemeinsame ApprovalPane bleibt Renderer und Freigabegrenze.

## Prüfung

Der native `FASTRA_SELECTION_SELFTEST` verwendet ein eigenes Xvfb, privaten D-Bus
und frische XDG-Verzeichnisse. Echte Scope-Menü-, Such-, Apply- und Undo-Ereignisse
prüfen Emoji vor der Auswahl, kombinierende Zeichen, CRLF, zwei ausgewählte von
vier Dokumenttreffern, vollständige Ausgabe, genau einen Undo, verschobene und
leere Auswahl, verworfene späte Ergebnisse und erhaltene Scope-0-Vorschauen.

Für die zusätzliche letzte Apply-Schutzschicht ersetzt der Test ausdrücklich nur
das private Pending-Preview durch ein Core-Ergebnis mit NUL beziehungsweise einer
überlangen Zeile, während die normale Freigabe bereits steht. Dadurch erreicht
er den sonst schon durch die gemeinsame Darstellung gesperrten letzten Guard und
prüft eine unveränderte Quelle sowie Undo-Historie. Ein regulärer GUI-Suchlauf
verdoppelt zusätzlich eine zulässige 40-KiB-Zeile per Regex-Ersetzung; die überlange
Zielzeile bleibt bereits in der Vorschau gesperrt. Die künstliche Pending-Änderung
ist ausschließlich Testcode und kein produktiver Übernahmepfad.

Deutsch/Englisch sowie die betroffene Hauptansicht bei Mindestbreite und breit
werden nativ geprüft. Screenshots im privaten Ubuntu-Testcontainer können bei
Emoji einen fehlenden Fontglyphen zeigen; die tatsächlichen Codepunkte und
UTF-16-Bereiche werden unabhängig davon exakt geprüft. Native Mint-/Wayland-Abnahme
bleibt eine eigene Prüfung. Core, IO, Folder, Project und Session wurden in diesem
Teilpaket nicht verändert.

## Rechteckbefehle ab 1.178.0

`Text → Rechteckauswahl` enthält Klartext-Copy/Cut, Spaltenpaste und vertikale
Erweiterung; Ctrl+Shift+↑/↓ arbeitet über logische statt sichtbare Umbruchzeilen.
Kopien behalten ursprüngliche Zeilenenden und interne Leerzeilen. Mehrzeilige
Kopien enden mit einem Zeilentrenner, einzeilige nicht. Alte HTML-/RTF-Formate
werden ersetzt. Ausschneiden besitzt einen gemeinsamen Undo und entfernt keine
unmarkierten Zeichen kurzer Zeilen.

Ctrl+V füllt kurze Zeilen nicht auf. Die ausdrücklich gewählte Spaltenpaste nutzt
Tabs beziehungsweise Leerzeichen des aktiven Editorprofils und funktioniert auch
ab einem einzelnen Caret. Eine Clipboardzeile gilt für alle Cursor; fehlende
Zeilen leeren nur markierte Bereiche, zusätzliche werden in folgenden Zeilen
bis hinter das Dateiende eingefügt. Die vollständige Ausgabe wird vor der ersten
Änderung auf 4 MiB, 2001 Cursorzeilen und 64 KiB je logischer Zeile geprüft.

Zwischenablagedaten werden auf UTF-8-Klartext, NUL, Größe und Zeit begrenzt.
Jede neue Anfrage entwertet die vorherige. Clipboardwechsel, Pane-/Tabwechsel,
Fensterdeaktivierung, neue Quelle und neue Auswahl verwerfen ausstehende Antworten.
Zwei unabhängige Reviewfunde zu Anfrage-Reihenfolge und Zeilenlimit sind nach
gezielten Gegenfällen und Nachreview geschlossen. Die native Regression prüft
Tastatur und echtes Textmenü, Unicode, LF/CRLF/CR, leere/kurze Zeilen, gemeinsames
Undo sowie Grenzen ohne Änderung von Text, Revision oder Undo.


## Normale Quelltextpaste

Ctrl+V, Shift+Insert und das sichtbare Kontextmenü verwenden einen gemeinsamen
begrenzten Klartextread. Normale Paste bleibt bei 32 MiB; Rechteckpaste behält ihr
eigenes 4-MiB-/Zeilenbudget. UTF-8 und NUL werden geprüft. Entscheidend sind die
vollständigen Ergebniszeilen einschließlich Präfix und Suffix, nicht allein die
Clipboardgröße. Erst nach Prüfung aller Daten und des unveränderten Besitzers
folgt ein einziger nativer Undo-Schritt.

Verspätete Antworten dürfen weder eine neuere Auswahl noch ein anderes Dokument,
eine andere Pane oder eine neue Clipboardanforderung überschreiben. Revision,
gerichtete Auswahl, Buffer-/Window-/Tabbesitz, Schreibschutz und Close-Tickets
bleiben bis zur ersten Mutation gebunden. Beide ursprünglichen Produktfehler
(Zeilenüberschreitung und NUL-Teilübernahme) sind mit echten nativen Rot-/Grünläufen
und unabhängiger Prüfung geschlossen. Andere Insert-Einstiege sind damit nicht
pauschal als geprüft bezeichnet.


Normale PRIMARY-Mittelklickpaste verwendet ebenfalls den begrenzten Read und den
vollständigen Ergebnisplan am nativen Klickoffset. Sie ersetzt keine Auswahl und
versetzt den Caret nicht künstlich. Providerwechsel können bereits vor dem Klick
die PRIMARY-Auswahl verändern; gebunden wird der tatsächliche Zustand beim
Auftrag. Der eingebaute Zeilennummern-Renderer gehört nach eigenem Nativebeleg
zum selben GTK-Pastepfad und wird gezielt mit geprüft. Der dazu unabhängig
reproduzierte Gutter-Bypass ist am exakten Fix nachgeprüft und geschlossen.
Andere Renderer und aktive Rectangle-PRIMARY sind nicht als neu geschützt
bezeichnet. Unicode-, Combining-, ZWJ-, EOL- und EOF-Klickgrenzen wurden gegen
unveränderte native Baselines verglichen.


Nach gültiger normaler Clipboardpaste hält ab 1.182.0 ein einzelner nativer Idle
den Caret sichtbar. Auftragsgeneration, Quelle, gerichtete Auswahl und tatsächlicher
Fenster-/Tab-/Pane-Owner werden danach erneut geprüft. Eine neuere Auswahl oder
ein Tab-/Fokuswechsel verhindert den veralteten Scroll. Der Ablauf ändert weder
Text noch Undo und übernimmt keinen Fokus. PRIMARY bleibt vom Scrollzusatz unberührt.


## Unabhängige Split-Quellansichten

Jede Ansicht besitzt einen stabilen nativen GtkSourceBuffer mit eigener gerichteter
Auswahl. Der kanonische Dokumentpuffer bleibt Quelle für Revision, Dirty, IO und
Snapshots. Insert-/Delete-Deltas und native Useraktionsgrenzen werden synchron
übertragen; kein SetText pro Taste und keine eigene Undo-Engine. Sprache und
Faltung bleiben gemeinsam, Rechteckmarkierungen lokal. Die letzte Quellansicht
bleibt auch nach Toolbar-/Dialogfokus das Befehlsziel; Split AUS setzt Primary.

Auswahlabhängige Aufträge binden Dokument, Revision, Pane/View/Buffer,
Auswahlgeneration und ursprüngliche Fenstergruppe. Der Ganzdatei-Suchbereich
verlangt dieselbe Dokument-/Ansichtsbindung ohne zufällige Caretgleichheit;
der Auswahlbereich bleibt streng auswahlgebunden. Paste-Caret-Scroll prüft
zusätzlich das tatsächliche Paneziel und darf keine andere Ansicht verschieben.

Die SourceView-Unterklasse verwaltet die eigene native PRIMARY-Registrierung
an den unterstützten Realize-/Unrealize-/Dispose- und Bufferbindungsgrenzen.
Ein begrenztes lazy GDK-Angebot besitzt schwache Eigentümer und native Marken.
Reiner Fokuswechsel ersetzt kein Angebot. Tatsächliches Auswahl-Collapse räumt
nur das noch aktuelle eigene Angebot derselben Pane ab; fremde und andere
Pane-Angebote bleiben erhalten. Freie rohe GTK-Bufferwechsel außerhalb dieser
Komponente sind kein Produktvertrag.

Beide nativen Historien behalten 200 Levels, auch bei Split AUS. Eine isolierte
Messung mit 4 MiB Text und acht vollständigen Ersetzungen zeigte rund 69 MiB
Mehrverbrauch durch die zweite History (Gesamtzuwachs etwa 1,91-mal die reine
Kontrolle). Das ist eine Messung des ersten Kandidaten, keine feste Speicherobergrenze.
Allgemeine native Tastatur-/IME-Eingaben können die bestehende Textgrenze im
Puffer überschreiten; die bestätigte alte Größenüberschreitung erhält Undo und
wird beim Speichern abgewiesen. Clipboard- und programmatische Schutzpfade
bleiben vor der ersten Änderung begrenzt. Diese getrennte Grenze ist nicht als
gelöste allgemeine Eingabevorprüfung ausgewiesen.


Native GTK-Auswahlersetzung beim Tippen ist von Fastra-Paste zu trennen:
GTK 4.14.5 beendet bei einer mehrstelligen Auswahl die Lösch-Useraktion vor
der Einfügung ausdrücklich und erzeugt dadurch zwei Undo-Gruppen.
Gepaarte optimierte Paketproben bestätigen denselben Verlauf vor und nach
der Splitumstellung: erstes Undo entfernt die Eingabe, zweites stellt den
zuvor ausgewählten Text bytegleich wieder her. Save löscht weder History
noch Sourcefokus. Fastra-Paste und programmatische Textoperationen behalten
ihre geprüfte einzelne Useraktion. Ein ursprünglich zu strenger Ein-Undo-
Test für natives Tippen ist keine nachgewiesene Splitregression.
