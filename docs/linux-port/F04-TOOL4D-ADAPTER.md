# Optionaler Linux-tool4d-LSP-Adapter

Der native Werkzeugdialog „4D-Diagnosen (tool4d) …“ ergänzt den statischen
4D-Index. Er fragt ausschließlich vollständige Dokumentdiagnosen oder
Parameterhilfe am gebundenen Cursor ab. Kein Compilerlauf, keine Methoden,
Makros, Formatter oder Workspace-Edits. Die Runtime wird separat bereitgestellt;
Fastra enthält weder proprietäre Runtime-Dateien noch einen Download/Installer.
Die öffentliche Distribution und der unabhängige Protokollversuch sind in
[F04-TOOL4D-LINUX.md](F04-TOOL4D-LINUX.md) dokumentiert.

## Bedienung und Bindung

Im Projektbaum das vollständige lokale 4D-Projekt wählen, eine gespeicherte
`.4dm`/`.4qs` unter `Project/Sources` oder `Sources` öffnen und tool4d auswählen.
PATH und `/opt/tool4d/tool4d` werden lediglich als Dateikandidaten gesucht;
erst „Dokument prüfen“ oder „Parameter am Cursor“ startet den Prozess.
Die neben der Runtime liegenden echten Verzeichnisse `Resources` und optional
`lib` bleiben erforderlich. Unsichere/unvollständige Installationen scheitern
sichtbar. Debian/Ubuntu benötigen zusätzlich die vom Runtime-Anbieter genannten
Systembibliotheken; Fastra installiert diese nicht.

Aktueller, auch ungespeicherter Quelltext gelangt ausschließlich über anonyme
Pipes und den internen Loopbackkanal zum Server. Er wird weder in argv/env noch
in regulären Zwischen-Dateien gespeichert. Die ursprüngliche gespeicherte
Snapshot-Basis wird vorher/nachher geprüft und niemals still aktualisiert.
Projektwurzel und Quelldatei werden im isolierten Worker nochmals über die
gebundenen Identitäten und ursprüngliche Dateibytes geprüft. Tabwechsel,
Textrevision, Rich-Sperre, Projektwechsel und Fensterschluss entwerten Ergebnisse
und brechen laufende Abfragen ab. Ein Diagnosenklick selektiert ausschließlich
im ursprünglichen aktuellen Quelltab; aufgefaltete Originalquelle und gültige
Unicode-Grenzen sind Voraussetzung. Es gibt keine Dateischreiboperation.

LSP-Positionen sind UTF-16, GTK-Positionen Unicode-Skalare. Ein linear aufgebauter
Index erhält CR/LF/CRLF und Surrogatgrenzen. Übergroße Server-Endspalten werden
an das echte Zeilenende begrenzt; ungültige Startpositionen bleiben sichtbar,
aber ohne Navigation. Meldungen werden als reiner Text mit sichtbaren
Steuerzeichen dargestellt. SignatureHelp ist ebenfalls reine Textanzeige.
`result:null` bei Diagnosen gilt ausdrücklich nicht als fehlerfreier Befund.

## Isolation und Lebensdauer

Der Host startet `/usr/bin/prlimit` und `/usr/bin/bwrap`, ohne Shell. Der gleiche
App-Executable läuft vor GTK-Initialisierung als privater Pipe-Worker. Bridge
und tool4d teilen eine neue Netzwerk-Namespace; sie sehen nur Loopback.
Der Worker prüft abweichende Namespace-Identität und ausschließlich `lo`, bevor
er tool4d startet. Es gibt keine direkte Host-Socketverbindung und keinen
ungeschützten Fallback, falls User-Namespaces/Bubblewrap nicht funktionieren.

`--unshare-all --die-with-parent --new-session --cap-drop ALL --clearenv` trennt
zusätzlich PID, IPC, UTS und Umgebung. Nur nötige Systembibliotheken, Zeitzonen,
die Runtime-Teilstruktur, App-Executable mit relativer `../lib`-ICU und der
gewählte Workspace werden read-only eingebunden. Private passwd/group-Daten
weisen auf ein bereits vorbereitetes, ebenfalls read-only Home. `/tmp` ist
read-only. Keine Host-Homes, Passwörter oder Benutzerprofile werden eingebunden.
Ein PID-Namespace beendet auch einen mittels `setsid` aus der ursprünglichen
Prozessgruppe gelösten Nachfahren. Der bestehende Prozessowner begrenzt Pipes,
TERM/KILL und Reaping; der neue `run_with_input`-Zusatz schreibt nichtblockierend
im selben Owner-Loop, ohne separaten unbeschränkt wartenden Writer-Thread.

Der Server erhält nur `--lsp=<privater Port>`. Initialisierung deaktiviert
Abhängigkeitsdiagnosen. `workspace/applyEdit` wird ausdrücklich abgelehnt;
unbekannte Serveranfragen erhalten einen Fehler. Vollständige Dokumentdiagnosen
benötigen Pull-Diagnostics-Unterstützung. Ältere Publish-only-Server sind nicht
als unterstützt ausgegeben. Nach didClose/shutdown/exit folgt begrenztes Warten,
danach kontrolliertes TERM/KILL. Ein bereits vollständiges Ergebnis bleibt wie
im Swift-Vorbild erhalten; nötiges erzwungenes Cleanup wird sichtbar angezeigt.
Unvollständige Antworten werden niemals dadurch erfolgreich.

## Feste Grenzen

- Aktueller Quelltext: 1 MiB UTF-8; ursprüngliche gespeicherte Datei: 32 MiB.
- Maximal zwei gleichzeitige Abfragen pro App; eine pro Werkzeugfenster.
- Pipe-Eingabe 8 MiB JSON; Ergebnis 1 MiB, Runtime-stdout/stderr je16 KiB.
- LSP-Header8 KiB, einzelne Nachricht1 MiB, Gesamteingang4 MiB,128 Nachrichten.
- Höchstens200 vollständige Diagnosen;8 Signaturen, jeweils begrenzte Texte.
- Runtime-LSP-Phase15 s, Kindprozess18 s, äußerer Prozessowner25 s;
  Cleanup erhält eigene kurze Fristen. Prlimit:2 GiB Adressraum,15 CPU-Sekunden,
 1 MiB Dateigröße,128 Dateideskriptoren.
- Projektmarker-Suche: höchstens256 Einträge je Root-/Project-Verzeichnis.
- Der relative Methodenpfad muss UTF-8 sein; rohe Projektwurzelpfade bleiben
  bytegenau. Keine rekursive Projektindexierung pro Tastendruck.

Die Isolation ist ein enges read-only Profil, keine allgemeine Plugin-Plattform.
Runtime/OS-Unterstützung und User-Namespace-Verfügbarkeit bleiben Voraussetzungen.
Volle Compiler-/Projektparität, Completion, Definition-LSP, Refactoring,
Ausführung und andere Runtime-Versionen sind damit nicht abgenommen.

## Ausgeführte Prüfung am 2026-11-05

Getestet mit tool4d21.2 build21.100611 (LSP2102), privat entpackt, nicht gebündelt.
Host-Rust:57 bestanden, ein unabhängiger nativer Viewer-Test bewusst ignoriert;
`fastra-process`:11 bestanden. Darunter8 Adaptertests für Framing, Grenzen,
Edit-Ablehnung, Pfadbindung und Unicode/CRLF;3 neue stdin-Prozessprüfungen mit
vollständiger Duplex-Eingabe, EPIPE, nicht lesendem Kind, Cancel/Timeout/Cleanup.
Clippy für beide betroffenen Crates mit `-D warnings` und Release-Check bestanden.

Vier echte GTK-Läufe (DE/EN,640/1080) in privaten DBus/Xvfb-Containern mit
`--network none` bestanden. Die App sah nur das staged relative App-Paket,
externe Runtime und synthetische Projekte, keinen Build-/Quellbaum. Geprüft:
ungespeicherter Syntaxfehler, vollständiger leerer Befund nach Korrektur,
UTF-16-/CRLF-Navigation ohne Textänderung, fremder Tab, Projektwechsel,
Parameterhilfe mit Unicode-Argument, Rich-Sperre, Parent-Hide und unveränderte
Quellbytes. Synthetische onStartup/onExit-Methoden mit LOG-EVENT-Sentinel
wurden nicht ausgeführt. Die beigefügte C-Fixture ignoriert TERM und erzeugt
einen setsid-Nachfahren; aktiver Cancel wartete beide ab und ließ keinen
Runtime-Prozess zurück. Diagnose-/Signaturansichten wurden visuell geprüft.

Reproduktion: normale Linux-Buildumgebung mit Bubblewrap/prlimit und vollständiger
externer Runtime; `FASTRA_4D_RUNTIME_SELFTEST=1`,
`FASTRA_4D_RUNTIME_PATH=<tool4d>`, `FASTRA_4D_FAKE_PATH=<kompilierte C-Fixture>`,
`FASTRA_TOOL_WIDTH=640|1080`, `FASTRA_TOOL_SCREENSHOTS=<privater Ordner>`.
Alle XDG-Verzeichnisse einschließlich STATE auf eigene Testpfade setzen;
private DBus-/Xvfb-Sitzung benutzen. Die C-Fixture als `tool4d` neben einem echten
leeren `Resources`-Verzeichnis kompilieren. Release enthält den privaten
Protokollworker, aber keinen GUI-Selbsttest-Einstieg.


## Runtime-Bindung vor dem ersten Fremdcode-Laden

Programm, Resources und optionales lib werden relativ zu einem gehaltenen
Elternverzeichnis mit O_NOFOLLOW/O_NONBLOCK geöffnet; Verzeichnisse zusätzlich
mit O_DIRECTORY. Die Files bleiben für die gesamte Abfrage offen. Der Request
bindet Gerät, Inode, Typ/Modus, Größe und ctime einschließlich Nanosekunden.
Ein fehlendes lib bleibt ausdrücklich None; dangling Symlinks gelten als Fehler.
Der vertrauenswürdige Worker öffnet alle tatsächlich unter /runtime gemounteten
Objekte erneut ohne Symlinkfolge und vergleicht sämtliche Proofs vor tool4d-Fork.
Auch diese Worker-Deskriptoren bleiben bis zum Abfrageende offen. Unerwartetes lib,
Pfadtausch, Typwechsel und veränderte Metadaten führen zu Stale ohne Runtime-Start.

Die App-/Worker-Ladeumgebung enthält ausschließlich /app/lib, niemals /runtime/lib.
Erst das nach erfolgreicher Prüfung gestartete tool4d-Kind erhält /runtime/lib.
Dadurch kann ein dort bereitgestellter Bibliothekskonstruktor nicht schon vor
Worker-Entry die Bindungsprüfung umgehen. Die Bind-Mounts werden weiterhin aus
Pfaden aufgebaut; eine ausgetauschte Quelle wird spätestens im vertrauenswürdigen
Worker vor Fremdcodeausführung verworfen. Dies ist keine unveränderliche Kopie
der gesamten Runtime-Dateibaum-Inhalte; Änderungen an tieferen Dateien werden
nicht vollständig gehasht oder eingefroren. Host-Homes bleiben ungemountet,
Projekt und Runtime read-only und das Netzwerk privat.

Gezielte Nachprüfung am 2026-11-05: elf Adapter-Rusttests bestanden, darunter drei
neue Tests mit sechs tatsächlichen Dateisystemwechseln, gehaltenen Inodes,
fehlendem/dangling lib, Inhaltsänderung und FIFO. Sechs zusätzliche echte
Bubblewrap-Mount-Austauschfälle (Symlink und Ersatzobjekt für Programm,
Resources und lib) endeten jeweils im Worker mit Stale, vor jeglichem tool4d-Start.
Die synthetischen Fremdverzeichnisse wurden nicht gelesen. Testscript:
crates/fastra-linux/tests/tool4d/mount_swaps.py; es erwartet das staged App-Paket
unter /app und einen privaten beschreibbaren /test-Ordner im isolierten Container.
Clippy mit -D warnings und Release-Check bestanden. Ein erneuter echter
DE640-Tool4D-/GTK-Lauf bestand Diagnosen, Parameterhilfe, aktive Cancel-/setsid-
Prozessbereinigung, Owner-/Projektprüfung und unveränderte Quellen.

## ELF-Laderprüfung

`crates/fastra-linux/tests/tool4d/loader/run-ctor-check.sh` vergleicht den
Bibliothekssuchpfad mit einem synthetischen ELF-Constructor, ohne echte Runtime,
Quelldateien, GUI oder Installation. Benötigt werden ein vorhandenes SDK-Bild mit
`cc` und `libz.a`, ein vorhandenes Laufzeitbild und die gepackte App-Struktur:

```sh
bash crates/fastra-linux/tests/tool4d/loader/run-ctor-check.sh \
  /path/to/staged-app local-builder-image local-runtime-image
```

Die Prüfung vom 2026-11-05 bestätigt: Mit `/app/lib:/runtime/lib` läuft der
Constructor vor der Requestprüfung, mit `/app/lib` bleibt er aus. Beide Aufrufe
verwerfen denselben ungültigen Request kontrolliert. Die Prüfung vergleicht echte
ELF-Ladervorgänge; die Auswahl des produktiven Suchpfades wird zusätzlich am
Argumentgenerator und durch den tatsächlichen Adapterlauf geprüft.
