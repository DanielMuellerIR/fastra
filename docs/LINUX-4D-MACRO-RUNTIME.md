# 4D-Makros unter Linux

Textmakros und die vier erkannten Varianten von `MAO_MethodeKomplettierenNeu`
verwenden den vorhandenen Makrokatalog. Textmakros benötigen keine Runtime.
Runtime-Makros benötigen eine vom Nutzer bereitgestellte Linux-Version von Tool4D
mit benachbartem `Resources`-Verzeichnis sowie ein Engine-Projekt mit
`Sources/Methods/MacroRun.4dm`. Fastra lädt keine Runtime herunter. Die Auswahl von
Runtime und Engine-Projekt führt keinen fremden Code aus. Erst der sichtbare Knopf
„Vorschau vorbereiten“ startet einen Makrolauf. Die Auswahl wird zusammen mit den
Makroquellen in der XDG-Konfiguration gespeichert. Alle vier Auswahlfelder und
Reset teilen eine serielle Schreibqueue. Jeder Auftrag liest den aktuellen
Diskstand, ändert ausschließlich sein beauftragtes Feld und speichert atomar.
Eine exklusive Linux-Dateisperre am gehaltenen Elternverzeichnis schützt den
Read–Merge–Rename-Ablauf zusätzlich zwischen unabhängigen Appprozessen.
Verspätete UI-Antworten bleiben an Fenster, Owner und Generation gebunden; ein
abgewiesener Write übernimmt keine neue Wahl in die Oberfläche.

## Vertrag mit MacroRun

Die Argumente entsprechen der bestehenden macOS-Engine; Optionen und Werte sind
getrennte argv-Einträge:

```text
--project <private-engine-project.4DProject>
--dataless --skip-onstartup --opening-mode interpreted
--startup-method MacroRun
--user-param <input>|<output>|<variant>|<method-name>
```

Unterstützte Varianten sind `komplettieren`, `komplettieren-ohne-nv`,
`komplettieren-ohne-var` und `komplettieren-ohne-nv-var`. `00_DM_Info` und
`Compiler_*` bleiben bewusst ausgenommen. Ein `|` in Eingabe-/Ausgabepfad oder
Methodenname wird abgewiesen; er darf keine zusätzliche Parametergrenze erzeugen.

Ausschließlich `<output>.status` entscheidet über das fachliche Ergebnis:
`OK` benötigt einen nicht leeren Ergebnistext, `UNVERAENDERT` bedeutet keine
Änderung, und `FEHLER …` liefert den erklärenden Fehlertext. Exit 0 allein ist
kein Erfolgsbeleg; ein anderer Exitcode entwertet einen vollständig geschriebenen
Status nicht. Fehlender, leerer oder unbekannter Status wird abgewiesen.
Ergebnis- und Statusdateien müssen reguläre, gültige UTF-8-Dateien sein; Symlinks,
FIFOs und abgeschnittene Ergebnisse werden nicht übernommen. Ein UTF-8-BOM wird
wie beim Foundation-Dateileser entfernt. Der Ergebnistext wird auf LF normalisiert.
Ein Timeout, Prozessabbruch oder überschrittenes Prozessausgabelimit liefert auch
bei einer vorher geschriebenen OK-Datei keine übernehmbare Vorschau.

Vor dem Lauf entfernt der vorhandene Tokenkern die 4D-Suffixe aus dem sichtbaren
Editorpuffer. Danach stellt derselbe Scanner gelernte Befehls-/Konstantensuffixe
wieder her, auch bei unbekannten und mehrwortigen Namen. Neue bekannte Befehle
bekommen ihre Katalognummer; Konstanten ohne gelerntes Suffix bleiben unverändert.
Strings, Kommentare, lokale/interprozessweite Variablen, Objektmember und
Deklarationstypen erhalten keine unpassenden Suffixe.

## Isolation und Originalschutz

Runtime-Makros haben einen getrennten Worker-Modus. Der vorhandene LSP-Worker für
reine Leseabfragen behält seine readonly-Projekt-/Home-/Temp-Mounts und seine
bisherigen Beschränkungen. Beide Modi teilen Runtime-Bindung und Proof-Prüfung:
Die Anwendung hält offene Deskriptoren für Runtime, Ressourcen und optionale
Bibliotheken. Der Worker lädt zuerst nur Fastras eigene Bibliotheken über
`LD_LIBRARY_PATH=/app/lib`; erst nach bestätigter Mountidentität darf er Tool4D
mit dessen Bibliotheken starten. Die Proof-Prüfung findet vor Fremdcodeausführung
statt. Eine ausgetauschte Runtime startet nicht.

Der Makro-Worker läuft in Bubblewrap mit neuen PID-, Netzwerk-, Mount- und weiteren
Namespaces, entfernten Capabilities und eigener Session. Er sieht Systembibliotheken,
die readonly Runtime, eine eigene Projektkopie, eigene Ein-/Ausgabedateien und
ein frisches Home/Temp. Für MacroRun-SystemWorker steht genau das vorhandene
System-Shellbinary readonly unter `/bin/sh` bereit. Weitere Systemwerkzeuge
werden dadurch nicht freigegeben. Weder das Benutzer-Home noch das Originalprojekt werden
eingebunden. Es gibt keinen Netzwerkzugang und keinen ungeschützten Ersatzstart.
Beim Ende des Namespace werden auch Nachfahren beendet, die `setsid()` aufgerufen
haben.

Ein readonly Engineprojekt mit einem einzelnen privaten Cache-Overlay ist nicht
allgemein verwendbar: Fehlt `Project/DerivedData`, kann Bubblewrap das Mountziel
unter dem readonly Projekt nicht anlegen. Deshalb kopiert Fastra die gewählte
Engine vor dem Start begrenzt in den privaten Arbeitsordner. Der Kopierweg öffnet
alle Komponenten relativ zu gehaltenen Verzeichnisdeskriptoren mit `O_NOFOLLOW`.
Er verweigert Symlinks, Spezialdateien, veränderte Quellen und überschrittene
Budgets, statt eine unvollständige Engine zu starten. Reguläre Komponenten-,
Ressourcen- und Einstellungsdateien werden mitkopiert. Im Projektroot entfallen
`.git` und `userPreferences.*`. Dadurch erreicht insbesondere die bekannte
Absturzquelle `debuggerWatches.json` den Lauf nicht. Original-Watchdateien werden
nie umbenannt oder verändert; eine Backup-/Restore-Transaktion ist in diesem
isolierten Modus überflüssig. Diese Regel ersetzt keine Wiederherstellung alter
Backups anderer Programme.

Die Grenze der Isolation ist die bewusst gewählte Ausführung fremden Enginecodes
innerhalb dieses privaten Dateibaums. Kompilierte Komponenten müssen selbst zur
Linux-Runtime passen. Eine erfolgreiche synthetische Startup-Probe belegt den
Protokoll- und Isolationsweg, nicht die Verträglichkeit jeder externen Engine.

## Bindung und Vorschau

Makroläufe teilen eine prozessweite FIFO. Abgebrochene wartende Aufträge verlassen
die Queue. Nach Erhalt des Slots und unmittelbar vor dem Prozessstart fordert der
Hintergrundlauf eine neue Prüfung auf dem GTK-Thread an: Fenster, Dokumentobjekt,
Pfad, Inhaltsrevision, Auswahl und Projektgeneration müssen noch zum Start passen.
Der Projektbezug unterscheidet auch A → B → A. Ein Ownerwechsel, verborgenes
Fenster oder „Abbrechen“ beendet den Auftrag und dessen Prozess. Späte Antworten
können keinen neueren Auftrag oder dessen Apply-Freigabe verändern.

Ein geändertes Ergebnis durchläuft denselben vollständigen Diff wie ein natives
Textmakro. Übernahme bleibt an die ursprüngliche sichtbare Grundlage gebunden;
eine alte Auswahl, Revision oder Projektwahl blockiert Apply. Erst „Übernehmen“
ändert den Editor als genau einen Undo-Schritt. Die Datei bleibt ungespeichert.
Die vollständige Vorschau wird niemals still gekürzt. Vor Diffberechnung und
Übergabe an GTK prüft die zentrale Texteditorvalidierung sowohl Quelle als auch
Changed-Ergebnis: U+0000 und logische Zeilen über 64 KiB werden abgewiesen.
Die bestehenden Makro-Bytebudgets bleiben zusätzlich bestehen. Auch ein gültiges
OK-Protokoll umgeht diese Texteditorgrenze nicht.

## Grenzen und gezielte Prüfung

- Editorquelle: 4 MiB UTF-8; der vorhandene Tokenscanner hat ebenfalls 4 MiB
  Quellgrenze. Ergebnisdatei: höchstens 8 MiB; größere Ergebnisse werden vor der
  Rücktokenisierung abgewiesen, oberhalb der Tokenquellgrenze ebenfalls erklärt.
- Status: 16 KiB; stdout/stderr von Tool4D: jeweils 32 KiB. Worker-JSON: 32 MiB.
- Enginekopie: 32 MiB je Datei, 256 MiB insgesamt, 16.384 Einträge und Tiefe 32.
- Tool4D: 60 Sekunden, äußere Workerreserve 5 Sekunden; 60 CPU-Sekunden,
  3 GiB virtueller Speicher, 8 MiB maximale geschriebene Datei, 128 Deskriptoren.
- Vollständige gerenderte Diffansicht: 4 MiB für beide Seiten zusammen.

Gezielte Tests sind `cargo test -p fastra-core --test four_d_macro_tokens
--test four_d_transform` und `cargo test -p fastra-linux four_d_macro_runtime::tests`.
Der native Debug-Selbsttest `FASTRA_4D_MACRO_RUNTIME_SELFTEST=1` verlangt eine
isolierte Anzeige (`FASTRA_ISOLATED_DISPLAY=1`), ein ausschließlich synthetisches
Fixtureverzeichnis (`FASTRA_MACRO_FIXTURE`) und das synthetische Prüftool
(`FASTRA_MACRO_TEST_TOOL`). Er prüft fehlende Konfiguration, echten isolierten
Runtime-Start, gelernte Rücktokenisierung, sichtbaren Diff, stale-Apply-Sperre,
ein Undo sowie den Abbruch bei Projekt A → B → A. `FASTRA_TOOL_SCREENSHOTS`
und `FASTRA_TOOL_WIDTH` liefern die vorhandenen nativen DE/EN-Aufnahmen.
Die LSP-Regressionssuite bleibt separat erforderlich, sobald ihr Ausführungspfad
geändert wird.

## Aufruferidentität

Die Makro-Sandbox bildet ausschließlich den tatsächlichen POSIX-Login des
Aufrufers ab. Er wird außerhalb der Sandbox über die UID und die System-
Benutzerdatenbank ermittelt; `USER` und `LOGNAME` stimmen damit überein. Das
private Home bleibt `/home/fastra`, andere Konten und echte Homeverzeichnisse
werden nicht eingebunden. Eine nicht verlässlich oder nicht als UTF-8 darstellbare
Identität verhindert den Lauf mit Fehler. Ein erfundener Sandboxbenutzer darf
nicht als Autor in Methodenköpfe geraten. Die synthetische Shell-Engine unter
`crates/fastra-linux/tests/tool4d/macro-shell` prüft den tatsächlichen
`Current system user` im vollständigen Tool4D-/Vorschau-/Apply-/Undo-Weg.
