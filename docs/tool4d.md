# Checking 4D code with tool4d (external)

> Since v1.35.0 a condensed version of this guide ships in the in-app
> help (section “4D and tool4d”), and **Help → Find tool4d…** searches
> the known locations for an installed tool4d.

Fastra highlights 4D methods (`.4dm`) but does not check them for syntax or
compiler errors. **tool4d**, 4D's lightweight headless runtime, is the right
tool for that. Fastra deliberately does **not** bundle tool4d (size,
licensing); this guide shows how to obtain and use it yourself.

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

For live per-file diagnostics tool4d offers a language-server mode
(`--lsp=<port>`, JSON-RPC) — exactly how the 4D-Analyzer extension works in
VS Code. If you want per-file diagnostics, that extension is currently the
best option.

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

## Note on Fastra integration

A direct tool4d integration (syntax checking via the LSP mode,
`--lsp=<port>`) is specified as a stage of feature package 3
(`docs/wunschpaket-2026-07c/goal-vorschlag.md`). The earlier uncertainty
about the terms of use is resolved by the sources quoted above; final
confirmation rests with the maintainer. See `ROADMAP.md` for details.
