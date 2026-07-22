<p align="center">
  <img src="screenshots/app-icon.png" width="128" alt="Fastra app icon">
</p>

# Fastra: Native macOS text editor

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Fastra is a native text editor for macOS with search & replace abilities
no other editor offers: As simple as typing, as powerful as regular
expressions, and you always see exactly what will change before a single
character is touched.

*The name says it: **f**acillime **ad astra**, "by the easiest way to the
stars". The star (`*`) is the program.*

![Fastra in light mode with the visible Home button](screenshots/editor-light.png)

## Download / Releases

Ready-made builds are available as DMGs on the
[releases page](https://github.com/DanielMuellerIR/fastra/releases):
download the DMG, open it, and drag Fastra into your Applications folder.
The DMG is signed with a Developer ID and notarized by Apple, so Gatekeeper
opens it without warnings. Fastra must first be installed from a DMG; signed
in-app updates are available from version 1.19.1 onward under **Fastra → Check
for Updates…**. Requires macOS 14+ (Apple Silicon).

## The `*` wildcard: Power without the syntax

Everyday restructuring tasks are impossible in a plain text editor and
overkill in regex. Fastra's answer is the asterisk: **one `*` captures any
text**, and in the replace field you simply reuse it.

> Turn `ring, The` into `The ring` across a whole list:
> Search `*, The`, replace `The *`. Done. No regex, no manual, no risk:
> The live preview shows every change before you apply it.

<p align="center">
  <img src="screenshots/search-wildcards.png" width="84.2%" alt="Search dialog with wildcards">
</p>

- Each `*` becomes a numbered, draggable capture pill. Reorder text by
  dragging pills into the replace field.
- `**` captures across line breaks (grab whole blocks between two markers).
- This is something an ordinary text editor **cannot do at all**, and doing
  it with regular expressions requires syntax most people have to look up
  every time. With Fastra it is a single keystroke.

And when a task really needs the full power, switch on RegEx mode and get
token highlighting, curated patterns, and guided capture groups.

<p align="center">
  <img src="screenshots/search-regex.png" width="84.2%" alt="Search dialog in RegEx mode">
</p>

## Features

- **Preview before apply**: Side-by-side before/after for every operation;
  nothing is written until you confirm.
- **`*` wildcard search** with capture semantics, no regex knowledge needed.
- **Full RegEx mode** with colored token highlighting and a curated pattern library.
- **Drag & drop capture groups** from the find field into the replace field.
- **Scopes**: Current file, all open tabs, folders, or a configured file set in
  the current project.
- **Projects, Git and Markdown** live alongside ordinary text editing; each is
  explained below.
- **Compare files side by side**: Choose any two saved files or open tabs, or
  compare an edited tab with its version on disk. Shift-clicking a companion
  tab preselects both documents for the quick path.
- **Column selection under Soft Wrap** stays on logical text lines; column
  copy/paste, typing, deletion, transformations, and Paste Column are each
  undoable as one action.
- **A visible Home button** safely returns the current window to the welcome
  screen. Unsaved work is confirmed first and then gets its normal save dialogs.
- **Light & dark mode**, native SwiftUI/AppKit, no Electron.
- **Local & private**: No accounts, telemetry, document uploads, or subscription.
  The update check contacts only Fastra's signed GitHub Pages feed and sends no
  hardware or system profile.

## Projects and Git, in the editor

Open a folder and Fastra gives it a live, hierarchical file sidebar with an
always-visible file-name filter. Git repositories are recognised automatically,
remembered on the welcome screen, and remain ordinary local folders: Fastra is
a text editor first, not a replacement for a full Git client.

- The **Changes** view separates staged and unstaged files. Stage, unstage or
  discard individual files, inspect their diff, write a commit message and
  commit from the sidebar. During merge, rebase, cherry-pick and revert
  conflicts, a compact bar in the normal editor navigates conflict blocks,
  accepts either or both sides with native Undo, and marks only the verified,
  saved file version as resolved. Binary files, including text-decodable files
  that Git classifies as binary through attributes, and partially loaded files
  get an honest limitation instead of a text-only resolver.
- The **Graph** view renders branches and merges as a native multi-lane history,
  with branch and tag labels. Expand a commit to see its files; double-click a
  commit or file to open its diff in an editor tab. Text patches can use a
  read-only side-by-side view with aligned lines, intraline emphasis, folds,
  an overview ruler and keyboard navigation between hunks; binary and combined
  patches remain available through explicit metadata or the selectable unified
  fallback.
- The current branch, ahead/behind state and file status are visible in the
  project sidebar. Fetch can be manual or scheduled while Fastra is active;
  its age and errors stay visible. Pull always uses a selected strategy
  (rebase, merge or fast-forward-only), checks the repository again immediately
  before running, and never hides an automatic stash or push.
- Curated actions cover creating a branch, stash/pop, cherry-pick, revert and
  continuing or aborting an active Git operation. Destructive or history-
  changing paths use a fresh preflight and confirmation. Force push is exposed
  only as an exact **force-with-lease** operation. Git identity can be configured
  locally for the repository or, after a separate confirmation, globally.
- **Open in Terminal** hands the project directory to Terminal.app without
  constructing or running a shell command inside Fastra.

Git support is a thin, asynchronous front end to the installed `git` command.
If Git is unavailable, these controls stay out of the way; when Git reports an
error, Fastra shows its actual message rather than hiding it. Repository
operations are coordinated across Fastra windows so conflicting commands do
not run over one another.

## Markdown that stays local

Markdown files can show an optional live preview on the right, separated from
the editor by a persistent splitter. The renderer supports GitHub-flavoured
Markdown including tables, task lists, strikethrough, syntax-highlighted code
blocks and links. It also displays local images, TeX formulas written as `$…$`
or `$$…$$`, and diagrams from fenced `mermaid` blocks. Selecting and copying
from the preview preserves plain text, HTML and rich text where the receiving
app supports it.

A source-formatting toolbar plus menu and context-menu commands cover emphasis,
headings, lists, quotes, links and tables as normal undoable Markdown edits.
Pasting or dropping an image saves or copies it beside the saved document and
inserts a relative link, so text and images remain portable together.

Fastra's preview adds one deliberately narrow extension to GFM for visible
blank lines: a source line containing only two or more ordinary ASCII spaces
renders as exactly one completely empty text line. An empty line or exactly
one space keeps its CommonMark meaning. Two spaces at the end of a non-empty
line and a trailing backslash remain ordinary hard breaks; the extension does
not apply inside code blocks.

Text between pairs of two equals signs, such as `==important==`, is rendered
with a fixed, appearance-aware marker background. This is a Fastra extension,
not standard GFM; it composes with nested Markdown while code stays literal.
The Markdown toolbar, menu and context menu can add the marker. A separate
**Hard Line Break** helper inserts exactly two trailing spaces plus an ordinary
line break, keeping this otherwise easy-to-forget Markdown notation visible.

Clicking a passage in the preview scrolls the editor to the matching source
line and places the cursor there — including inside a long paragraph, where the
line is resolved from the line breaks before the click. The column is an
approximation, because the rendered text no longer contains the Markdown
syntax. Links still open in your browser, and dragging out a selection does not
jump.

The preview and all of its rendering libraries stay local. Image paths are
resolved relative to the Markdown file; remote images are deliberately not
loaded, so opening a file does not quietly contact the network. A link opens
only when you choose it.

**Smart Paste** converts formatted clipboard content from browsers or office
apps into clean Markdown at the cursor. It uses the separately installed
[md-clip](https://github.com/DanielMuellerIR/md-clip) command-line tool, and
explains how to install it when it is not available.

## More than search & replace

The Text menu bundles transformations that otherwise require heavyweight
editors. The more advanced ones:

- **Case transformations inside the replacement pattern** (`\U \L \u \l \E`):
  Reshape capitalization while replacing.
- **Process lines containing…**: Apply a search & replace only to lines
  matching a filter.
- **Process duplicate lines**: Detect duplicates and transform or collect them.
- **Extract matches**: Pull every hit into a new document.
- **Zap gremlins**: Hunt down invisible and invalid characters.
- **Unicode normalization** (NFC/NFD), strip diacriticals, straight ⇄ typographic
  quotes, escape sequences.
- Sort lines explicitly in ascending or descending alphabetical order, join
  and deduplicate them, hard wrap, add/remove line numbers, exchange words,
  and format JSON or XML.
- **Transform from an example** derives a wildcard pattern from before/after
  text; save, import and export reusable search patterns.
- Large and binary files have guarded views, including a read-only hex view
  with an explicit edit mode.

Fastra deliberately stays approachable: There are editors with even more
machinery, and a matching learning curve to go with it. Fastra covers the
everyday cases without a manual.

By default, Fastra reopens the last project windows and saved documents on
the next launch. You can turn this off under **Settings → Startup**. Contents
of unsaved or untitled documents are deliberately never stored or restored.

### XPath navigation for XML

`⇧⌘X` opens a floating XPath bar for XML-like documents (`.xml`, `.xsd`,
`.xsl`, `.xslt`, `.plist`, `.svg` source, `.4DCatalog`, `.4DSettings`):
typing jumps live to the first match, Enter/arrows step through further
matches, and child elements and attributes are suggested from the document.
A deliberately compact subset is supported:

- absolute (`/root/child`) and relative paths (treated like `//…`),
- `//` (any depth) and `*` (any element name),
- predicates `[n]`, `[@attr]`, `[@attr='value']`,
- targets `@attr` and `text()`.

Anything else (axes, functions, `..`) is reported clearly as unsupported.
With broken XML the last valid index stays active; the error appears
unobtrusively in the bar.

### Views, previews and language detection

- The view switcher in the footer (also in the View menu, `⌃⌘1–3`)
  toggles each file between Text, Preview and Hex — making the hex view
  reachable for every saved file.
- Images (PNG, JPEG, GIF, HEIC, TIFF, WebP) and PDFs open in a read-only
  preview (large images are downsampled to stay memory-safe); SVG renders
  by default and can be edited as XML source.
- Unsaved tabs without a file extension detect their language conservatively
  from content (JSON, XML, HTML, Markdown, CSS, JavaScript, shebang
  scripts); the format chip in the footer doubles as a manual language
  switcher whose choice always wins.
- The visible Soft Wrap control next to it stores its on/off state per effective
  format and synchronizes every open document of that format. Plain text,
  Markdown, HTML, and XML start wrapped; code and configuration formats start
  unwrapped with horizontal scrolling. Wrap targets can be the window width,
  an app-wide page guide, or a fixed column; the guide can be shown
  independently.
- Option-drag selects a rectangle across logical text lines even while they
  wrap visually. **Edit → Paste Column** (`⌃⌘V`) pastes clipboard lines
  vertically and pads short target lines to the chosen column.

### Syntax highlighting

Tree-sitter-based highlighting for 26 languages and file formats: Bash, C, C++,
C#, CSS, Dart, Dockerfile, Go (incl. go.mod), HTML, Java, JavaScript/JSX, JSON,
Kotlin, Lua, Markdown, Objective-C, Perl, PHP, Python, Ruby, Rust, SQL, Swift,
TOML, TypeScript/TSX and YAML. Everything else opens as plain text.

In addition, Fastra highlights 4D methods (`.4dm`) through its own
lightweight tokenizer using the familiar 4D colors (light and dark) —
including multi-word commands and constants, `$local`/`<>interprocess`
variables, `[tables]` and fields. `.4DProject`/`.4DForm` open as JSON,
`.4DCatalog`/`.4DSettings` as XML.

For 4D projects, Fastra also offers command and constant completion with
signatures, local structure checks, and Option-double-click navigation to
methods and classes. **Validate Document** can optionally use an already
installed tool4d for diagnostics; Fastra neither bundles nor downloads it.

## Requirements & installation

- macOS 14+ (Apple Silicon)
- Download the DMG from [Releases](../../releases), drag Fastra into
  `/Applications`, done.
- Starting with 1.19.1, future signed releases are available through
  **Fastra → Check for Updates…** and are installed only after confirmation.

### Build from source

```bash
cd app
./build.sh release   # bundle lands in the project root as Fastra.app
./selftest.sh        # unit tests + in-app self-tests
```

Details: [Build and test](docs/BUILD-AND-TEST.md) ·
[dependency lessons](app/LESSONS-LEARNED.md) ·
[AGENTS.md](AGENTS.md) (architecture & product principles) ·
[ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

## License

[MIT](LICENSE), © 2026 Daniel Müller

Fastra bundles and links third-party software (Sparkle, ripgrep, PCRE2, the CodeEdit and
tree-sitter components, cmark-gfm, and the Markdown-preview assets). Their
licenses and copyright notices are collected in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
