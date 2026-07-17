# 4D-Code prüfen mit tool4d (extern)

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

## Hinweis zur Integration in Fastra

Eine direkte tool4d-Anbindung in Fastra (Menüpunkt „4D-Methode prüfen“) ist
bewusst zurückgestellt: tool4d arbeitet projektbasiert, Einzeldatei-
Diagnosen erfordern den LSP-Modus (dauerhafter Serverprozess, JSON-RPC),
und die Nutzungsbedingungen für den Aufruf durch Dritt-Tools sind nicht
abschließend geklärt. Details siehe `ROADMAP.md`.
