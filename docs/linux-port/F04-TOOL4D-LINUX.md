# tool4d unter Linux: isolierter ABI- und LSP-Beleg

Stand: 2026-11-05. Dies ist ein getrenntes Ergebnis zur
[statischen 4D-Navigation](F04-FOUR-D.md), keine Produktadapter-Freigabe.
Proprietäre Runtime-Dateien werden weder ins Repository noch ins App-Paket
übernommen. Die Runtime bleibt separat bereitzustellen.

## Herkunft und Lizenzbefund

Der [offizielle Analyzer-Downloader](https://github.com/4d/4D-Analyzer-VSCode/blob/main/editor/src/tool4D/apiManager.ts)
bildet für Linux öffentlich erreichbare Debian-URLs. Verwendet wurde
`https://resources-download.4d.com/release/21.x/latest/latest/linux/tool4d.deb`:
25.880.340 Bytes, Paketversion `21.0.2.100611`, Architektur `amd64`, SHA-256
`680ef3640c138462df9ec647f8d557fac8a95f8db0bc9b10bf8793ff854e7b02`.
Die ausführbare Datei meldet abweichend davon die Produktversion
`21.2 build 21.100611`. Der [offizielle 4D-Beitrag](https://blog.4d.com/a-tool-for-4d-code-execution-in-cli/)
beschreibt den CI-Betrieb ohne Lizenzschlüssel/Registrierung und den
unauthentifizierten Download. Dies ist keine Aussage über eine Erlaubnis,
proprietäre Bytes mit Fastra weiterzuverteilen.

Das Paket wurde ausschließlich mit `dpkg-deb -x` in eine private Testumgebung
extrahiert. Keine Maintainer-Skripte, Host-Paketinstallation, Host-Runtime- oder
Lizenzverzeichnisse wurden benutzt. Fehlende deklarierte Shared Libraries
(`libc++1`, `libfreeimage3` und deren Abhängigkeiten) wurden in einem eigenen
wegwerfbaren Ubuntu-Containerimage ergänzt. `--version` und `--help` enden
mit Exit 0; die Hilfe führt `--lsp=VALUE` auf.

## Konkrete Startbedingung

Der erste LSP-Start endete mit Exit 0 ohne Ausgabe und ohne Rückverbindung.
Der erwartete `/opt/tool4d`-Pfad allein änderte das nicht. Eine begrenzte
Datei-/Prozess-/Netz-Syscallspur zeigte den Grund: tool4d verwendet für sein
Profil das Home-Verzeichnis aus `getpwuid`, nicht die gesetzten HOME-/XDG-Pfade.
Im Container wurde `/home/ubuntu/.local/share` gesucht; dessen Anlage scheiterte
an der schreibgeschützten Containerwurzel. Erst ein ausschließlich privates,
leeres Testprofil an diesem Containerpfad ermöglichte den LSP-Start.

Die Runtime blieb schreibgeschützt. Es gab keine X11-/Display-Abhängigkeit und
keinen Anlass für einen Desktop-/Xvfb-Test. Beim ersten erfolgreichen Start
wurden nur `.local/share/tool4d`-Profilordner angelegt; keine Quelldateien oder
zusätzlichen Workspace-Dateien. Eine spätere Produktanbindung darf deshalb
nicht bloß HOME/XDG setzen und ungeprüft das echte Benutzerprofil freigeben.

## Protokoll und Ergebnis

Ein Listener innerhalb des vom Hostnetz getrennten Containers bindet
`127.0.0.1:0`. tool4d erhält ausschließlich `--lsp=<zugewiesener Port>` und
verbindet sich als TCP-Client zurück; Fastra ist logisch der LSP-Client.
JSON-RPC benutzt `Content-Length` und UTF-8. Es gibt keine `--project`-,
`--startup-method`- oder Codeausführungsaktion.

`initialize` erhält den kanonischen Workspace-URI oberhalb `Project/`, den
Workspaceordner, Diagnosecapabilities und aktivierte Dokumentdiagnosen;
Abhängigkeitsabruf bleibt deaktiviert. Der Server meldet `4D LSP Server`,
Version `2102`, inkrementelle Textsynchronisation, Diagnose- und
Signaturhilfeanbieter. Anschließend wurden ausgeführt:

1. `initialized`, `didOpen` und `textDocument/diagnostic`: gültige synthetische
   Methode liefert `{kind:"full", items:[]}`.
2. `didChange`, Version 2, ohne Dateischreiben: unvollständiges `$result:=`
   liefert Severity 1, „Syntax error“, bei nullbasierter Zeile 2.
3. Rückkehr zu gültigem ungespeichertem Text, eigener Caller mit `🚀` im
   Stringargument, `signatureHelp` nach dem Semikolon mit UTF-16-Cursorposition:
   `Probe( name : Text; count : Integer ) -> result : Boolean`, aktiver
   Parameter 1, zwei Parameterbereiche und Kommentardokumentation.
4. Der Caller liefert ebenfalls eine vollständige leere Diagnoseliste.
5. Beide `didClose`, `shutdown` mit `result:null`, `exit`: Prozess Exit 0,
   2543 empfangene LSP-Bytes, keine stdout-/stderr-Ausgabe.

Der Fehlerbereich verwendet `end.character = 2147483647`. Ein künftiger Host
muss solche Bereiche gegen die gebundene originale Zeile und UTF-16-Grenzen
prüfen beziehungsweise sicher begrenzen; rohe Werte sind keine gültigen
GTK-Offsets. `result:null` für Diagnosen wäre kein fehlerfreier Befund.

Die Runtime und der gesamte synthetische Workspace waren im abschließenden
Lauf read-only eingebunden. Alle drei Projektdateien wurden vorher/nachher
vollständig gehasht; Inhalt und Dateimenge blieben identisch. Die Netzspur
zeigte nur den eigenen Loopback-LSP-Port und erfolglose lokale `nscd`-Sockets.
Der Container hatte `--network none`, schreibgeschützte Wurzel, UID 1000,
keine Capabilities, `no-new-privileges`, begrenzte PIDs/CPU/RAM und ausschließlich
private Profile/Arbeitsdaten. Eine Aussage über den Netzwerkbetrieb außerhalb
dieser Isolation wird daraus nicht abgeleitet.

## Grenzen des Belegs

Der Prüfclient begrenzt Header auf 8 KiB, einzelne Nachrichten auf 1 MiB,
Gesamteingang auf 4 MiB, 200 Nachrichten und stdout/stderr auf 256 KiB.
Verbindung und Antworten haben 12-Sekunden-Fristen; ein äußerer 50-Sekunden-
Timeout begrenzt den Gesamtlauf. Der eigene Prozess erhält eine eigene Gruppe;
`finally` beendet verbliebene Gruppenmitglieder und wartet den Prozess ab.
Zusätzlich endet die gesamte private PID-Namespace mit dem Container.

Dieser unabhängige Protokollbeleg allein implementiert keinen Hostadapter.
Der anschließend umgesetzte isolierte Pipe-Worker und native Dialog sind separat
in [F04-TOOL4D-ADAPTER.md](F04-TOOL4D-ADAPTER.md) beschrieben und geprüft.
Source-Edits, Formatter-/Workspace-Änderungen, Methoden-/Makroausführung,
Downloads und Socketfreigaben zu externen Hosts bleiben ausgeschlossen.
