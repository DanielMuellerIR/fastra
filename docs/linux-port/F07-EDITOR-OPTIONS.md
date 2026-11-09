# Native Syntaxwahl und Editoroptionen

Stand: 2026-11-05. Die Sprachwahl arbeitet über das installierte
GtkSourceView-Sprachpaket. Automatik anhand des Dateinamens, reiner Text und
manuelle Formate sind sichtbar im Dokumenttab erreichbar. Änderungen betreffen
die Syntaxfarben; Text, Kodierung, Zeilenenden und Undo bleiben erhalten.

Die manuelle Wahl wird für gespeicherte Dateien unter
`$XDG_CONFIG_HOME/fastra-editor/languages.json` beziehungsweise
`$HOME/.config/fastra-editor/languages.json` gemerkt. Gespeichert werden nur
Rohpfadbytes und Sprachbezeichner, keine Dokumentinhalte. Automatik entfernt den
Eintrag. Dateinamen ohne Endung und ungültige UTF-8-Namen bleiben unterscheidbar.
„Speichern unter“ übernimmt die aktuelle Wahl an den neuen Pfad. Nicht
installierte gemerkte Formate bleiben als solche sichtbar und werden durch
normales Speichern nicht still gelöscht.

Der Speicher hält höchstens 300 Zuordnungen und 1 MiB JSON. Verzeichnis und
Dateien besitzen private Rechte; Symlinks, Mehrfachlinks, fremde Sperren,
beschädigte Daten und unbekannte Schemafassungen werden abgewiesen. Lesen und
Ändern laufen auf Workern. Jede Änderung lädt unter einer nicht blockierenden
Dateisperre frisch, sodass andere Fensterzuordnungen erhalten bleiben. Die
Veröffentlichung erfolgt über eine neue Datei, `fsync` und atomaren Austausch
unter dem gehaltenen Verzeichnisdeskriptor. Aufeinanderfolgende Wahlen desselben
Tabs werden geordnet geschrieben; verspätete Leseantworten überschreiben keine
neue manuelle Wahl.

Tabulator-/Einrückungsbreite (1–16), Einrückung mit Leerzeichen, automatische
Einrückung, Zeilennummern, aktuelle Zeile und Spalte-80-Rand wirken auf beide
Ansichten desselben Tabs. Vorhandener Text wird nicht umgeschrieben. Diese
Darstellungsoptionen waren zunächst tabbezogen. Der folgende Abschnitt beschreibt die ab 1.178.0 gespeicherten Formatprofile.
Faltung blendet Nummern weiterhin aus; Entfalten respektiert die gewählte
Nummerndarstellung.

## Beleg und Grenzen

Zwei Speicherprüfungen belegen frische Änderungen verschiedener Instanzen,
Rohpfade, Automatik, beschädigte Daten, Symlinks und konkurrierende Sperren.
Die native Prüfung wechselt die Sprache über das GTK-Auswahlsignal und bedient
Nummern, Einrückungsbreite und Leerzeichen mit echten XTest-Eingaben. Beide
Ansichten und erneutes Öffnen werden geprüft, ebenso unveränderte Textbytes,
Modified-Flag und Undo. Ein fehlendes Sprachpaket bleibt über normales Speichern
erhalten und wird erst durch eine explizite Automatikwahl entfernt. Die vier
Läufe auf Deutsch/Englisch bei 640/1100 px bestehen; beide Breiten wurden
visuell geprüft. Die Prüfung der Sprachauswahl nutzt das echte GTK-Signal,
nicht den zuvor erfolglosen synthetischen Dropdown-Tastaturpfad.

Die GtkSourceView-Grammatiken ersetzen keine behauptete vollständige
CodeEdit-Syntaxparität. 4D-Syntax, Parameterhilfe, Projektindex und externe
LSP-/Makroanbindungen bleiben getrennte Portierungsschritte. Die Mac-Anwendung
verwendet weiter ihren bisherigen Sprachspeicher und Editor.

## Rechteckauswahl und Tabbreite

Ab 1.177.0 verwenden Mausposition, logische Rechteckgrenzen und Spaltenpaste
dieselbe eingestellte Tabbreite. Ein Tabbreitenwechsel stoppt eine alte Ziehgeste,
entfernt deren Markierungen und entwertet eine ausstehende Clipboardantwort.
Text und Undo bleiben erhalten. Echte DE-/EN-Läufe prüfen Breite 2 und 8,
kurze Zeilen, Spaltenpaste und ein gemeinsames Undo. [Rechteck-Copy/Cut und
Tastaturerweiterung](F07-SELECTION.md) sind ab 1.178.0 implementiert; Formatprofile sind im folgenden Abschnitt beschrieben.

## Persistente Formatprofile ab 1.178.0

Tabbreite und Einrückungsbreite 1–16, Tabs/Leerzeichen und Fensterumbruch besitzen
unabhängige, pro Syntax-ID gespeicherte Werte. Werkstandard sind vier Leerzeichen
und Breite vier. Plain Text, HTML, JSON, Markdown, XML und Diff umbrechen am
Fenster, Codeformate nicht. Nummern, Autoeinrückung und weitere Anzeigeoptionen
bleiben dokumentbezogen. Feste Umbruchspalte, Page Guide und Folgezeilenoptionen
bleiben offen. Beide Sourceansichten übernehmen dasselbe Formatprofil.

`profiles.json` ist vom unveränderten Sprachspeicher getrennt. Sichere begrenzte
Dateizugriffe, geprüfte Sperre, Feldmerge und atomare Veröffentlichung erhalten
Änderungen anderer Fenster. Asynchrone Reads sind an Formatgeneration und die
seitdem ausdrücklich gewählten Felder gebunden. Solange die Sprachwiederherstellung
den Schlüssel noch ändern kann, sind Profilcontrols sichtbar ladend gesperrt.

Jeder akzeptierte Write bleibt bis zu seinem abschließenden Main-Receipt in der
geordneten Queue. Fehler behalten die Absicht; ausdrückliches erneutes Schließen
oder eine neue Wahl versucht sie erneut. Pending und Fehler halten normales
Fenster-/Appschließen sichtbar an. Nach Erfolg muss erneut geschlossen werden;
es gibt kein verspätetes automatisches Quit. Nicht bestätigter Spintext wird vor
der Freigabe übernommen. Das unabhängige Review hat den ursprünglichen Verlust
beim schnellen Beenden reproduziert und nach Korrektur geschlossen.

Beim Schließen der Editoroptionen werden Quelltextfokus und Auswahl einschließlich
ihrer Richtung wiederhergestellt. Die Wiederherstellung ist an Dokument, Revision,
Dialog und zwischenzeitliche Benutzerinteraktion gebunden. Neue Auswahlen, Tabwechsel
und andere aktive Ansichten haben Vorrang. Native Maus-/Tastaturproben in beiden
Sprachen prüfen beide Panes und die Ausschlussfälle; das unabhängige Review hat den
ursprünglichen Fokusbefund nach Korrektur geschlossen.


## Appweite Seitenlinie

„Seitenlinie anzeigen“ und „Seitenlinie: Spalte“ steuern die native Seitenlinie
unabhängig vom Fensterumbruch und Syntaxformat. Die Spalte reicht von 20 bis 500;
ab Werk gilt 80 und die Linie ist ausgeschaltet. Änderungen gelten für alle
Fenster und beide Quellansichten und bleiben nach Neustart erhalten. Die native
Darstellung folgt der tatsächlichen Zeichenbreite, dem Scrollen und der Breite
der jeweiligen Pane. Feste Umbruchspalten und Folgezeileneinzug bleiben offen.

Der erste Guide-Read sperrt die betreffenden Controls sichtbar bis zum Erfolg.
Ein Fehler bleibt sichtbar und kann durch Wiederöffnen erneut geprüft werden.
Guidewerte sind ein optionales Feld im bestehenden Profilformat. Änderungen laden
unter dem bestehenden Lock neu und führen zusammen; alte Format- und Sprachdaten
bleiben erhalten. Guide und Formatwahl verwenden dieselbe geordnete Write-Queue
bis zum Main-Receipt. Noch nicht bestätigter Spintext wird vor Close/Quit übernommen.
Nach erfolgreichem Schreiben ist ein ausdrückliches erneutes Schließen erforderlich.
Unabhängige native Lock-/Receipt-/Mehrfensterprüfungen haben keinen offenen P1/P2.
