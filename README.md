<p align="center">
  <img src="screenshots/app-icon.png" width="128" alt="Fastra app icon">
</p>

# Fastra

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Fastra is a native macOS editor for search & replace: as simple as a text
editor, as powerful as regular expressions — and you always see exactly what
will change before a single character is touched.

*The name says it: **f**acillime **ad astra** — "by the easiest way to the
stars". The star (`*`) is the program.*

![Fastra in light mode](screenshots/editor-light.png)

## Download / Releases

Ready-made builds are available as DMGs on the
[releases page](https://github.com/DanielMuellerIR/fastra/releases):
download the DMG, open it, and drag Fastra into your Applications folder.
The DMG is signed with a Developer ID and notarized by Apple — Gatekeeper
opens it without warnings. Requires macOS 14+ (Apple Silicon).

## The `*` wildcard — power without the syntax

Everyday restructuring tasks are impossible in a plain text editor and
overkill in regex. Fastra's answer is the asterisk: **one `*` captures any
text**, and in the replace field you simply reuse it.

> Turn `ring, The` into `The ring` across a whole list:
> search `*, The` — replace `The *`. Done. No regex, no manual, no risk:
> the live preview shows every change before you apply it.

![Search dialog with wildcards](screenshots/search-wildcards.png)

- Each `*` becomes a numbered, draggable capture pill — reorder text by
  dragging pills into the replace field.
- `**` captures across line breaks (grab whole blocks between two markers).
- This is something an ordinary text editor **cannot do at all** — and doing
  it with regular expressions requires syntax most people have to look up
  every time. With Fastra it is a single keystroke.

And when a task really needs the full power: switch on RegEx mode and get
token highlighting, curated patterns, and guided capture groups.

![Search dialog in RegEx mode](screenshots/search-regex.png)

## Features

- **Preview before apply** — side-by-side before/after for every operation;
  nothing is written until you confirm.
- **`*` wildcard search** with capture semantics — no regex knowledge needed.
- **Full RegEx mode** with colored token highlighting and a curated pattern library.
- **Drag & drop capture groups** from the find field into the replace field.
- **Scopes:** current file, all open tabs, or whole folders.
- **A well-stocked Text menu** — see below.
- **Markdown preview** and Smart Paste (formatted clipboard → Markdown).
- **Light & dark mode**, native SwiftUI/AppKit — no Electron.
- **Local & private:** no cloud contact, no telemetry, no subscription.

![Fastra in dark mode](screenshots/editor-dark.png)

## More than search & replace

The Text menu bundles transformations that otherwise require heavyweight
editors. The more advanced ones:

- **Case transformations inside the replacement pattern** (`\U \L \u \l \E`) —
  reshape capitalization while replacing.
- **Process lines containing…** — apply a search & replace only to lines
  matching a filter.
- **Process duplicate lines** — detect duplicates and transform or collect them.
- **Extract matches** — pull every hit into a new document.
- **Zap gremlins** — hunt down invisible and invalid characters.
- **Unicode normalization** (NFC/NFD), strip diacriticals, straight ⇄ typographic
  quotes, escape sequences.
- Sort, join and deduplicate lines, hard wrap, add/remove line numbers,
  exchange words.

Fastra deliberately stays approachable: there are editors with even more
machinery — and a matching learning curve. Fastra covers the everyday cases
without a manual.

### Syntax highlighting

Tree-sitter-based highlighting for 26 languages and file formats: Bash, C, C++,
C#, CSS, Dart, Dockerfile, Go (incl. go.mod), HTML, Java, JavaScript/JSX, JSON,
Kotlin, Lua, Markdown, Objective-C, Perl, PHP, Python, Ruby, Rust, SQL, Swift,
TOML, TypeScript/TSX and YAML — everything else opens as plain text.

## Requirements & installation

- macOS 14+ (Apple Silicon)
- Download the DMG from [Releases](../../releases), drag Fastra into
  `/Applications`, done.

### Build from source

```bash
cd app
./build.sh release   # bundle lands in app/dist/
./selftest.sh        # unit tests + in-app self-tests
```

Details: [app/README.md](app/README.md) · [CLAUDE.md](CLAUDE.md) (build, tests, QA)
· [AGENTS.md](AGENTS.md) (architecture & product principles) ·
[ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

## License

[MIT](LICENSE) — © 2026 Daniel Müller
