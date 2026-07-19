# 4D-Code prüfen mit tool4d

> Seit v1.35.0 steckt diese Anleitung gestrafft auch in der App-Hilfe
> (Abschnitt „4D und tool4d“), und **Hilfe → tool4d finden…** sucht ein
> installiertes tool4d an den bekannten Orten.

Fastra hebt 4D-Methoden (`.4dm`) farblich hervor und kann sie mit **tool4d**
auf Syntaxdiagnosen prüfen. tool4d ist die schlanke headless-Runtime von 4D.
Fastra bündelt tool4d bewusst **nicht**, lädt es nicht herunter und startet
keine Installation.

## tool4d beziehen

Eine der beiden Quellen genügt:

- **4D-Downloadseite:** <https://product-download.4d.com> — dort das Paket
  „tool4d“ passend zur eigenen 4D-Version laden und entpacken.
- **VS-Code-Extension „4D-Analyzer“:** Die Extension (Herausgeber „4D“)
  lädt tool4d automatisch nach. Der Pfad auf dem Mac lautet dann:

  ```text
  ~/Library/Application Support/Code/User/globalStorage/4D.4d-analyzer/tool4d/<version>/<build>/tool4d.app
  ```

Das ausführbare Binary liegt jeweils unter
`tool4d.app/Contents/MacOS/tool4d`.

## Wichtig: tool4d arbeitet projektbasiert

tool4d prüft keine einzelne `.4dm`-Datei, sondern immer ein komplettes
4D-Projekt (die `.4DProject`-Datei mit ihren `Project/Sources`-Ordnern).
Die Methode, die geprüft werden soll, muss also Teil eines Projekts sein.

## Syntax-/Compilerprüfung (headless)

Der zuverlässigste Gesamtcheck ist ein Start im kompilierten Modus — er
deckt Syntax- und Compilerfehler des ganzen Projekts auf:

```bash
TOOL4D="…/tool4d.app/Contents/MacOS/tool4d"
"$TOOL4D" --project "Pfad/zum/Projekt/Project/MeinProjekt.4DProject" \
          --opening-mode=compiled --dataless --skip-onstartup
```

- `--dataless` startet ohne Datendatei,
- `--skip-onstartup` überspringt die `On Startup`-Datenbankmethode,
- Fehler erscheinen auf der Konsole; Exit-Code ≠ 0 bedeutet Probleme.

## Diagnose aus Fastra

Ist eine gespeicherte `.4dm`-Methode Teil eines geöffneten Fastra-Projekts mit
`.4DProject`-Datei und tool4d an einem bekannten Ort vorhanden, führt
**Text → Dokument prüfen** eine kurze LSP-Prüfung aus. Fehlermeldungen nennen
Zeile und Spalte, sofern der Server einen nicht-`null`-Diagnosebericht liefert;
der erste Fund lässt sich direkt anspringen. Einen `null`-Bericht zeigt Fastra
ausdrücklich als fehlendes verwertbares Ergebnis, nie als fehlerfreie Prüfung.

Der Transport folgt dem offiziellen 4D-Analyzer: Fastra öffnet einen nur an
`127.0.0.1` gebundenen Zufallsport und startet tool4d ausschließlich mit
`--lsp=<port>`. tool4d verbindet sich zurück; Fastra übergibt beim
`initialize` den geöffneten Workspace (Ordner oberhalb von `Project/`) und
die Dokument-URI. Fastra fragt Diagnosen über den LSP-Pull-Abruf
`textDocument/diagnostic` ab; `publishDiagnostics` bleibt für Server mit
diesem Verfahren ein Fallback. Eine lokale Probe mit tool4d 21.1 Build
21.100543 gegen eine sichere vollständige Projektkopie bestätigte initialize,
Capabilities, Shutdown und echte vollständige Diagnoseberichte (darunter eine
bereits vorhandene Severity-2-Diagnose in einer unveränderten Methode). Ein
anfängliches `null` ließ sich auf den macOS-Alias `/tmp` ↔ `/private/tmp`
zurückführen: tool4d vergleicht Dokument- und Workspace-URI strikt. Fastra
kanonisiert daher beide URIs vor dem Handshake und meldet ein späteres `null`
weiterhin als „kein verwertbares Diagnoseergebnis“, niemals als fehlerfrei.
Nach Ergebnis, Abbruch, Timeout oder Projektwechsel sendet Fastra
`didClose`/`shutdown`/`exit` und beendet den Kindprozess notfalls nach kurzer
Gnadenfrist.

Fastra speichert und verändert dabei keine 4D-Projektdatei. Fehlt tool4d oder
die Projektzuordnung, bleiben die ausdrücklich heuristischen Struktur-Hinweise
verfügbar; sie sind kein Compiler-Ersatz.

## Lizenz und Nutzungsbedingungen (Stand 2026-07-18)

tool4d ist laut offiziellen 4D-Quellen frei und benötigt keine Lizenz:

- 4D-Dokumentation: „tool4d is a free, lightweight, stand-alone
  application“ — <https://developer.4d.com/docs/Admin/cli>
- 4D-Blog: „tool4d does not need any license to run“; der Download ist
  bewusst ohne Authentifizierung möglich und für CI/CD-Nutzung gedacht —
  <https://blog.4d.com/a-tool-for-4d-code-execution-in-cli/>

Die dokumentierten Einschränkungen sind rein technisch (Application-,
Web- und SQL-Server, Backup-Scheduler u. a. sind deaktiviert); eine
Beschränkung, wer tool4d aufrufen darf, nennt keine der Quellen.

Die direkte LSP-Anbindung ist Etappe 8 des Wunschpakets 3
(`docs/wunschpaket-2026-07c/goal-vorschlag.md`) und mit v1.39.0 umgesetzt.
