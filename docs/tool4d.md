# Checking 4D code with tool4d

> Since v1.35.0 a condensed version of this guide ships in the in-app
> help (section “4D and tool4d”), and **Help → Find tool4d…** searches
> the known locations for an installed tool4d.

Fastra highlights 4D methods (`.4dm`) and can check them for syntax
diagnostics with **tool4d**, 4D's lightweight headless runtime. Fastra
deliberately does **not** bundle or download tool4d and never starts an
installation.

## Getting tool4d

Either source works:

- **4D download page:** <https://product-download.4d.com> — download the
  “tool4d” package matching your 4D version and unpack it.
- **VS Code extension “4D-Analyzer”:** the extension (publisher “4D”)
  downloads tool4d automatically. On the Mac it ends up at:

  ```text
  ~/Library/Application Support/Code/User/globalStorage/4D.4d-analyzer/tool4d/<version>/<build>/tool4d.app
  ```

The executable binary is at `tool4d.app/Contents/MacOS/tool4d`.

## Important: tool4d is project-based

tool4d does not check a single `.4dm` file — it always operates on a whole
4D project (the `.4DProject` file with its `Project/Sources` folders). The
method you want to check must therefore be part of a project.

## Syntax/compiler check (headless)

The most reliable overall check is a start in compiled mode — it surfaces
syntax and compiler errors for the whole project:

```bash
TOOL4D=".../tool4d.app/Contents/MacOS/tool4d"
"$TOOL4D" --project "path/to/project/Project/MyProject.4DProject" \
          --opening-mode=compiled --dataless --skip-onstartup
```

- `--dataless` starts without a data file,
- `--skip-onstartup` skips the `On Startup` database method,
- errors appear on the console; a non-zero exit code means problems.

## Diagnostics from Fastra

When a saved `.4dm` method belongs to an open Fastra project with a
`.4DProject` file and tool4d is available in a known location, **Text → Check
Document** runs a short LSP check. If the server supplies a non-`null`
diagnostic report, its entries include line and column and you can jump to the
first result. A `null` report is explicitly shown as no usable result, never
as a clean check.

The transport follows the official 4D-Analyzer: Fastra opens a random port
bound only to `127.0.0.1` and starts tool4d exclusively with `--lsp=<port>`.
tool4d connects back; on `initialize`, Fastra supplies the open workspace (the
folder above `Project/`) and the document URI. Fastra requests diagnostics via
the LSP pull request `textDocument/diagnostic`; `publishDiagnostics` remains a
fallback for servers that use it. A local probe with tool4d 21.1 build
21.100543 against a safe complete project copy verified initialize,
capabilities, shutdown, and real full diagnostic reports (including an
existing severity-2 diagnostic in an unchanged method). An initial `null`
report was traced to the macOS `/tmp` ↔ `/private/tmp` alias: tool4d compares
document and workspace URIs strictly. Fastra therefore canonicalizes both
URIs before the handshake and still treats any later `null` as no usable
result, not as error-free. After a result, cancellation, timeout, or project
change, Fastra sends `didClose`/`shutdown`/`exit` and stops the child process
after a short grace period if necessary.

Fastra does not save or modify 4D project files. If tool4d or the project
association is unavailable, the explicitly heuristic structure hints remain
available; they are not a compiler replacement.

## License and terms of use (as of 2026-07-18)

According to official 4D sources, tool4d is free and requires no license:

- 4D documentation: “tool4d is a free, lightweight, stand-alone
  application” — <https://developer.4d.com/docs/Admin/cli>
- 4D blog: “tool4d does not need any license to run”; the download is
  deliberately available without authentication and intended for CI/CD
  use — <https://blog.4d.com/a-tool-for-4d-code-execution-in-cli/>

The documented restrictions are purely technical (application, web and
SQL server, backup scheduler and others are disabled); none of the
sources restricts who may invoke tool4d.

The direct LSP integration has been available since v1.39.0.
