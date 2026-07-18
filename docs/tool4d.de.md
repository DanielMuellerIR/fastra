# 4D-Code prüfen mit tool4d (extern)

> Seit v1.35.0 steckt diese Anleitung gestrafft auch in der App-Hilfe
> (Abschnitt „4D und tool4d“), und **Hilfe → tool4d finden…** sucht ein
> installiertes tool4d an den bekannten Orten.

Fastra hebt 4D-Methoden (`.4dm`) farblich hervor, prüft sie aber nicht auf
Syntax- oder Compilerfehler. Dafür eignet sich **tool4d**, die schlanke
headless-Runtime von 4D. Fastra bündelt tool4d bewusst **nicht** (Größe,
Lizenz); diese Anleitung zeigt, wie man es selbst bezieht und nutzt.

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

Für Live-Diagnosen je Datei bietet tool4d einen Language-Server-Modus
(`--lsp=<port>`, JSON-RPC) — genau so arbeitet die 4D-Analyzer-Extension in
VS Code. Wer Einzeldatei-Diagnosen möchte, ist mit dieser Extension derzeit
am besten bedient.

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

## Hinweis zur Integration in Fastra

Eine direkte tool4d-Anbindung (Syntax-Check über den LSP-Modus,
`--lsp=<port>`) ist als Etappe des Wunschpakets 3 spezifiziert
(`docs/wunschpaket-2026-07c/goal-vorschlag.md`). Die frühere Unklarheit
über die Nutzungsbedingungen ist durch die oben zitierten Quellen
ausgeräumt; die abschließende Bestätigung liegt beim Maintainer.
Details siehe `ROADMAP.md`.
