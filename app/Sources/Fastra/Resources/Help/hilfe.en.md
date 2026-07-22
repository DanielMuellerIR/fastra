# Fastra Help

Fastra is a native macOS text editor for safe, visually verifiable search
and replace across files and folders. The core idea: **before any bulk
change you see a complete preview** — Fastra never writes to files
without you having seen the effect first.

## Search and Replace

⌘F opens the search panel (⇧⌘F opens it directly in folder scope; ⌘E
uses the current selection as the search term). The search runs **live
while you type** and shows every match both in the results list and as a
highlight in the document.

**Scopes** (top of the panel):

- **File** — the active tab.
- **Open** — all open tabs (including unsaved ones).
- **Folder** — the enabled folders on disk. Live search starts at
  3 characters; “Search” or Return forces it at any time.
- **Project** — the project folder, narrowed down by file sets and
  exclude patterns.

**Wildcards:** With regex mode off, `*` matches any text **within a
line**, `**` also matches **across line breaks**. Every wildcard
automatically becomes a capture group: the pills (`$1`, `$2` …) below
the replace field can be **clicked or dragged** into the replace field.
Example: search `*, the`, replace `The *` turns “ring, The” into
“The ring”. The always-visible “∗ literal” switch treats `*` as a normal
character. It is enabled only while regex is off and the search expression
contains at least one `*`.

**Regex:** The regex switch enables regular expressions (ICU syntax, as
in `NSRegularExpression`). Capture groups appear as pills as well.
“From example…” derives a pattern from a before/after example.

**Options:** case sensitivity, “Whole word”, “Wrap-around”, and
“Selection only” (searches exclusively within the frozen selection).

**Replacing:**

- “Replace” replaces only the active match and moves on.
- “Replace All · N” (⌘Return) replaces every match in the scope.
- “Preview changes” shows every affected line as a before/after diff
  prior to replacing. What gets applied is **exactly** the match set you
  saw — that is a safety guarantee.
- In folder/project scope Fastra rechecks every file against the visible
  preview before the first write. Changed files and affected tabs with unsaved
  edits block the whole operation. Planning, backup and writing run in the
  background with progress feedback; cancelling before the short write phase
  leaves every target file unchanged.
- Fastra writes atomically per file and creates an automatic backup. “Undo”
  restores only files that were actually changed and stops if any of them was
  edited again after the replace.

**Navigation:** Return or ⌘G jumps to the next match, ⇧⌘G to the
previous one; the arrow keys walk the results list, which scrolls to the
active match. Escape hides the panel.

## Comparing Files

**Search → Compare Files…** (⌃⌘D) shows two files side by side — no Git
required. Fill the left and right side via the file chooser, drag and
drop, or from open tabs and recently opened files; the active tab
pre-fills the left side.

- **Preselect two open tabs:** First choose the current document tab, then
  Shift-click a second normal text tab. The current tab stays unmistakably
  active with the stronger gray fill; its comparison companion uses a
  softer gray. “Compare Files…” in either selected tab's context menu opens
  the dialog with both documents already selected on the left and right.
  Another Shift-click replaces or removes the companion; a normal tab click
  clears the pair.
- **Options:** trailing whitespace, all whitespace differences, blank
  lines, and letter case can be ignored while comparing. Active options
  are shown in the header of the view.
- **Differences list:** Below the diff, Fastra lists every difference
  (“Lines 12–14 changed”, “Line 30 only on the left”). Clicking jumps
  there; ⌥↑/⌥↓ move to the previous/next difference.
- **Long identical sections** are folded and can be expanded per section.
- **Compare Against Saved Version** compares the unsaved editor content
  of the active tab directly with the state on disk — handy before
  saving.
- Identical files are reported explicitly; binary, missing, or extremely
  large files explain themselves with a clear message instead of a
  misleading diff.

The comparison only displays — it never changes files.

## Text Transformations

All transformations act on the selection — without a selection, on the
whole document. Available from the **Text** menu and the editor’s
right-click menu.

- **Letters:** UPPERCASE, lowercase, Title Case.
- **Whitespace:** remove trailing spaces, tabs → spaces,
  spaces → tabs, indent, outdent, hard-wrap lines…
- **Lines:** sort alphabetically in ascending/descending order, reverse
  lines, remove blank lines, join lines (with/without separator), add
  prefix/suffix to lines…, add/remove line numbers, keep only matching
  lines…, delete matching lines…, keep only duplicate lines, remove
  duplicated lines.
- **Characters:** zap control characters, straighten quotes, educate
  quotes (English), resolve escape sequences, exchange characters,
  exchange words.
- **Unicode:** normalize spaces, strip diacritics, compose Unicode
  (NFC), decompose Unicode (NFD).

Also in the **Text** menu and the right-click menu: **Format Document**
(pretty-print JSON/XML), **Validate Document** (syntax check with error
position), and **Minify Document**. The three entries are only active when
the tab's file extension matches — `json`, `xml`, `xsd`, `xsl`, `xslt` and
`plist` can be formatted and minified, validation also covers `svg` and the
4D container files. A new, unsaved tab has no extension; name it something
like `data.json` when saving and the entries become available.

## Go to Target

**Option-double-click** a name to jump to its definition — modeled on
the 4D method editor:

- **4D (`.4dm`):** A method name opens the project method
  (`Project/Sources/Methods/…`), a class name opens the class file;
  `Function` definitions in the current class file jump locally. If
  none of that can be found, Fastra opens the project search with the
  name — never a silent failure.
- **Markdown:** Relative file paths in links/images open in the editor,
  `http(s)`/`mailto` addresses open in the browser, `#anchors` jump to
  the heading in the file.

Option-drag column selection is unaffected (it starts with a single
click). Unresolvable targets respond with a brief flash and a note in
the sidebar.

## Views: Text, Preview, Hex

The switcher on the right side of the footer appears whenever a file
offers more than one view:

- **Text** — the regular editor.
- **Preview** — rendered Markdown, images, PDFs, and SVGs.
- **Hex** — the saved on-disk state of the file as a hex dump; unsaved
  changes of the text tab are not included there. Binary files open
  directly in the hex view, very large text files in a chunked view.

## Markdown

For Markdown files the split view renders a live preview on the right:
tables, code blocks with syntax colors, formulas (KaTeX), and Mermaid
diagrams — fully local, no network access. **Clicking in the preview**
jumps the editor to the matching source line. Copying from the preview
yields real rich text (headings, lists, and bold survive).

### Special Preview Syntax

Fastra uses GitHub-Flavoured Markdown and adds the following local renderings
to its preview.

**Visible blank lines:** A source line containing only two or more ordinary
ASCII spaces (`U+0020 U+0020`) appears as exactly one completely empty text
line. In the example below, `␠` represents an ordinary space for clarity; do
not type the `␠` characters themselves:

```text
First paragraph
␠␠
Second paragraph
```

An empty line or exactly one space still follows CommonMark. Two spaces at the
end of a **non-empty** line and a trailing backslash remain ordinary hard
breaks. The extension does not apply inside indented code blocks or code
fences made from backticks or tildes. Copying carries the visible blank line
over as a normal newline.

**Text marker:** Text between pairs of two equals signs is highlighted with a
fixed background that adapts to the light or dark appearance, for example
`==important==`. Other Markdown formatting may be nested inside it; the equals
signs remain literal in inline code and code blocks. This syntax is a Fastra
extension and is not part of standard GFM.

**Formulas (KaTeX):** Put an inline formula between single dollar signs, for
example `$E = mc^2$`. A formula block starts and ends with two dollar signs:

```text
$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$
```

**Mermaid diagrams:** A code fence whose language is `mermaid` renders as a
diagram. Other code fences remain ordinary syntax-highlighted code:

````markdown
```mermaid
flowchart LR
  Start --> Check
  Check --> Result
```
````

KaTeX and Mermaid are loaded from the app and run entirely locally; the
preview does not need network access for either feature.

## Writing Markdown

For Markdown tabs, a **format toolbar** appears above the editor; the
same commands live in the “Markdown” menu and the right-click menu. They
act as normal, ⌘Z-undoable text edits on the selection or the cursor
line: bold (⌘B), italic (⌘I), highlight (⇧⌘H), code (⇧⌘K), heading 1–3
(⌘⌥1–3), back to
plain text (⌘⌥0), bulleted list (⇧⌘8), numbered list (⇧⌘7), quote
(⇧⌘9), link (⌘K), and “Insert table…” (a small dialog: columns, header
yes/no).

The toolbar's **Hard Line Break** command inserts two ordinary spaces at the
end of the selection followed by an ordinary line break. If the cursor is
already directly before a line break, it only adds or normalizes the two
spaces. The underlying Markdown stays visible and the edit remains undoable
with ⌘Z.

**Paste Formatted as Markdown** (⇧⌘V) converts HTML or RTF content from
browsers and office apps through the separately installed `md-clip` tool.
Fastra binds the window, tab, editor and selection when conversion starts. If
you switch targets or edit the content while it runs, Fastra stops safely and
does not insert into another document.

**Inserting images:** Pasting an image from the clipboard (⌘V) stores it
as a file **next to the document** (`documentname-YYYY-MM-DD-hhmmss.png`;
PNG/JPEG/GIF keep their format, everything else becomes PNG) and links
it relatively at the cursor position. **Dragging an image file** into
the Markdown editor copies it unchanged into the document folder (name
collision → suffix; a byte-identical file is not duplicated) and links
it relatively as well — other files open in a tab as usual. After
inserting, the preview scrolls to the insertion point. Unsaved documents
have no folder yet — save first (⌘S).

## Languages and Syntax Colors

Fastra detects the language from the file extension, and for files
without one, from the content. The language chip in the footer opens the
language menu: a manual choice always beats the automatics;
“Automatic” returns to them.

## Soft Wrap

The compact **Soft Wrap control** sits in the footer next to the language
chip. It visibly shows **On** or **Off**; clicking the main control toggles
it immediately. The separate arrow and a right-click open the same options.
**View → Soft Wrap** (⇧⌘L) toggles the same value.

Soft Wrap is stored **per effective document format** and applies
application-wide to every open and later-opened document of that format.
A manual language choice therefore also selects the format profile. In the
options menu, “Reset … to Factory Default” removes only the custom override
for the current format.

The available **wrap targets** are the window width, the page guide, and a
fixed column. Fixed-width presets are 72, 80, 100, and 120; a custom value
can be entered from column 20 through 500. Choosing a target also turns
Soft Wrap on. If the window is narrower than the chosen target, wrapping
falls back to the window edge.

The **page guide** can be shown independently through the Soft Wrap options,
**View → Show Page Guide**, or **Settings → Editor**. Its app-wide column
is configured there as well and defaults to 80. Fastra prefers word
boundaries when wrapping. A single long word falls back to character
boundaries without splitting a Unicode character.

The factory default is on for **Plain Text, Markdown, HTML, and XML**. It is
off for **4D, JSON, CSV, and other code/configuration formats**. With Soft
Wrap off, long lines remain reachable through the horizontal scroll bar.
Toggling it changes neither text nor selection, undo history, or the saved
file. The topmost displayed text line remains steadily anchored in place.

## Column Selection

**Option-drag** selects the same column range across multiple **logical text
lines**. This also works with Soft Wrap: a long line remains exactly one
rectangle row even when it is displayed as several wrapped fragments. Short
and empty lines, tabs, CRLF, and composed Unicode characters are not split
artificially.

**Copy, cut, delete, typing, and normal paste** operate on every part. One
clipboard line fills every rectangle row; multiple clipboard lines are
distributed in order. If the clipboard has fewer lines, the remaining
rectangle parts are cleared. Extra lines continue below the rectangle. Each
multi-part edit is fully undone with one ⌘Z.

**Edit → Paste Column** (`⌃⌘V`) is also available in the right-click menu.
It pastes clipboard lines vertically at the rectangle's left edge or, without
a rectangle, at the cursor. Short target lines are padded to the target
column; whole tab stops use tabs when the active indentation profile uses
tabs, with any remainder kept as spaces.

**Select Column Up/Down** (`⌃⇧↑/↓`) grows or shrinks a rectangle by one
logical line. Character operations such as case, quote, and Unicode
transformations process every rectangle part independently. Commands that
operate on whole lines or may create line breaks are disabled during a
column selection and explain why, so nothing outside the visible rectangle
is changed.

## 4D Support

`.4dm` methods are rendered with a dedicated 4D color scheme (commands,
keywords, variables, comments like in the 4D editor). In an open project,
Fastra also recognizes methods in `Project/Sources/Methods` case-insensitively
and highlights them distinctly from process variables; `[Table:1]` remains a
table. Via the language menu, 4D can also be enabled manually for other files.
`.4DProject`/`.4DForm` are real JSON files, `.4DCatalog`/`.4DSettings`
real XML — they open with JSON or XML rendering.

**Completion:** In `.4dm` methods, Fastra suggests commands (with their
syntax signature) and constants after two typed characters — Esc or ⌃Space also opens
the list manually, ↑/↓ select, Return/Tab accepts, Esc closes. The
names, signatures, and command numbers come from the official 4D
documentation (CC BY 4.0, © 4D SAS — see the third-party notices).

**Checking `.4DForm`:** “Text → Check Document” additionally validates
form files against the bundled form schema (MIT-licensed, by Mathieu
Ferry) and jumps to the offending spot including its JSON path.

**Export transformation:** The **Text** menu strips token suffixes of
canonical 4D exports (`ALERT:C41` → `ALERT`, also `:Knn:mm`) or re-adds
command tokens. No public source lists constant numbers — “Add command
tokens” therefore honestly leaves constants unchanged.

**Structure hints:** “Text → Check Document” inspects `.4dm` methods
heuristically for block balance (`If/End if`, `For each/End for each`,
`Case of/End case`, `Repeat/Until`, `While/End while`, `Function`
blocks) plus bracket, string, and comment balance, and jumps to the
spot. Honestly put: a heuristic, not a compiler replacement — tool4d
checks authoritatively (next section).

## 4D and tool4d

Fastra can check 4D code for syntax diagnostics with **tool4d**, 4D’s
lightweight headless runtime. According to 4D it is free and requires no
license. Fastra deliberately does not bundle it, downloads nothing, and
starts no installation.

**Getting tool4d** — one source is enough:

- **4D download page:** <https://product-download.4d.com> — download and
  unpack the “tool4d” package matching your 4D version.
- **VS Code extension “4D-Analyzer”** (publisher “4D”): downloads tool4d
  automatically; on the Mac it lives under
  `~/Library/Application Support/Code/User/globalStorage/4D.4d-analyzer/tool4d/…/tool4d.app`.

**Help → Find tool4d…** checks these known locations (plus PATH and the
Applications folders), shows the location and version, and remembers the
path.

**Check Document:** When a saved `.4dm` method belongs to an open 4D project
and tool4d is available, **Text → Check Document** starts a short local LSP
check. Fastra listens only on `127.0.0.1`, tool4d connects to it, and both
connection and process are closed after the result. When tool4d supplies a
non-`null` diagnostic report, errors include line and column and you can jump
to the first one. A `null` report is an explicit "no usable result", never a
clean check. A safe-project probe with tool4d 21.1 verified a full diagnostic
report and shutdown; an earlier `null` was the macOS `/tmp` alias, so Fastra
canonicalizes document and workspace URIs. Without tool4d or a matching
project, the explicitly heuristic structure hints remain available; they are
not a compiler replacement.

**Manual headless check:** tool4d works per project (always the
`.4DProject` file, never a single method). The most reliable full check
runs in compiled mode:

```
…/tool4d.app/Contents/MacOS/tool4d \
  --project "Path/to/Project/Project/MyProject.4DProject" \
  --opening-mode=compiled --dataless --skip-onstartup
```

Errors appear on the console; a non-zero exit code means problems.

## XPath Bar

For XML-like documents, ⇧⌘X shows the XPath bar: type an XPath query,
Fastra counts the matches and jumps to them in the document as you
navigate.

## Project and Sidebar

When you open a single file, the sidebar automatically shows the
matching folder — if the file lives in a Git repository, its root
folder. The sidebar header shows the project name (tooltip: full path);
**⌘-click the name** for a menu of neighboring folders to switch
projects quickly, and the right-click menu offers “Show in Finder” and
more. **⌘-click a document tab** shows the file’s macOS path menu. The
file tree can create, rename, and trash files and folders.

**Filtering files:** The filter field above the file tree filters live
by file name (substring, case-insensitive — deliberately no fuzzy
matching). Matches appear with their parent folders expanded; everything
else is hidden, and the counter shows “N of M files”. Escape or the X
clears the filter and restores the previous expansion state. The filter
only searches NAMES — for contents, use “Find in Folders…” (⇧⌘F, also
offered as a link when the filter finds nothing).

## Git

If the project is a Git repository (and `git` is installed), the sidebar
additionally shows the **Changes** and **Graph** tabs:

- Branch row with branch switching, ahead/behind, and fetch.
- **Changes:** stage/unstage files, discard, commit right from the
  sidebar; push and pull run asynchronously.
- **Graph:** the commit graph with branches and merges.
- History (`git log`) and diffs open as read-only tabs; clicking a
  commit hash shows its details.
- Git diffs use the same two-column view as **Compare Files** —
  including the differences list at the bottom and ⌥↑/⌥↓ navigation
  (⌥⌘[/⌥⌘] still work).
- Merge conflicts get a dedicated bar with safe resolution steps.

Fastra remains a thin frontend over the installed `git` — destructive
operations require a visible confirmation.

## Encoding and Line Endings

The footer shows the encoding and line ending of the active tab:

- **Encoding chip:** “Reopen with encoding” reloads the file from disk
  with a different encoding.
- **Line-ending chip:** choose LF, CRLF, or CR — the change takes
  effect on the next save.

UTF-32 files with a BOM are recognized in both byte orders. For older text
files without a BOM, Fastra distinguishes Windows-1252 characters such as
typographic quotes and the euro sign from Latin-1. If the format cannot be
handled safely, the file stays unchanged.

If an open file was changed outside Fastra, saving asks for explicit
confirmation. A further change immediately before the write always cancels
the save instead of silently overwriting the on-disk version.

## Windows and Tabs

⌘T opens a new tab, ⌘N a second, fully independent window (its own
tabs, its own search). ⌘S saves, ⌘W closes the tab — Fastra asks first
if there are unsaved changes. ⌘J jumps to a line number.

The Home button at the top left returns the current window to the welcome
screen. Clean tabs are closed. If unsaved content exists, an initial prompt
first confirms only the overall transition; cancelling leaves the workspace
completely untouched. Only after confirmation does Fastra ask to save each
affected file. Cancelling there keeps the project and tabs open.

The welcome screen may coexist with new, still-untitled tabs, but never with a
saved file or an open folder. Opening a folder, opening a file, or saving a file
for the first time automatically closes the Welcome tab.

When you open a file from the Finder, it lands in the window whose project
or repository contains it, and that window comes to the front. If no window
fits, Fastra uses an empty window (such as the welcome screen); if there is
none, it opens the file in a new one.

By default, Fastra restores the last project windows, saved documents, active
tabs, and window positions on the next launch. Windows without open files are
not restored: once you have closed every tab, the next launch greets you with
the welcome screen again. You can turn this off under
**Settings → Startup**. Contents of unsaved or untitled documents are never
stored or restored.

Shift-clicking a second normal text tab marks both for file comparison
without switching the current tab. The current tab keeps the stronger
highlight and the companion uses a softer one; a normal click clears the
pair.
