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
“The ring”. The “∗ literal” switch treats `*` as a normal character.

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
- In folder/project scope Fastra writes atomically per file and creates
  an automatic backup; “Undo” restores the last folder replace
  bit-exactly.

**Navigation:** Return or ⌘G jumps to the next match, ⇧⌘G to the
previous one; the arrow keys walk the results list, which scrolls to the
active match. Escape hides the panel.

## Comparing Files

**Search → Compare Files…** (⌃⌘D) shows two files side by side — no Git
required. Fill the left and right side via the file chooser, drag and
drop, or from open tabs and recently opened files; the active tab
pre-fills the left side.

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
- **Lines:** reverse lines, remove blank lines, join lines
  (with/without separator), add prefix/suffix to lines…, add/remove
  line numbers, keep only matching lines…, delete matching lines…,
  keep only duplicate lines, remove duplicated lines.
- **Characters:** zap control characters, straighten quotes, educate
  quotes (English), resolve escape sequences, exchange characters,
  exchange words.
- **Unicode:** normalize spaces, strip diacritics, compose Unicode
  (NFC), decompose Unicode (NFD).

Also in the Text menu: **Format document** (pretty-print JSON/XML),
**Check document** (syntax check with error position), and **Minify
document** — for supported formats such as JSON and XML.

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

## Writing Markdown

For Markdown tabs, a **format toolbar** appears above the editor; the
same commands live in the “Markdown” menu and the right-click menu. They
act as normal, ⌘Z-undoable text edits on the selection or the cursor
line: bold (⌘B), italic (⌘I), code (⇧⌘K), heading 1–3 (⌘⌥1–3), back to
plain text (⌘⌥0), bulleted list (⇧⌘8), numbered list (⇧⌘7), quote
(⇧⌘9), link (⌘K), and “Insert table…” (a small dialog: columns, header
yes/no).

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

## 4D Support

`.4dm` methods are rendered with a dedicated 4D color scheme (commands,
keywords, variables, comments like in the 4D editor). Via the language
menu, 4D can also be enabled manually for other files.
`.4DProject`/`.4DForm` are real JSON files, `.4DCatalog`/`.4DSettings`
real XML — they open with JSON or XML rendering.

## 4D and tool4d

Fastra highlights 4D code but does not check it for syntax or compiler
errors. **tool4d**, 4D’s lightweight headless runtime, is the right tool
for that — according to 4D it is free and requires no license. Fastra
deliberately does not bundle tool4d, downloads nothing, and starts no
installation.

**Getting tool4d** — one source is enough:

- **4D download page:** <https://product-download.4d.com> — download and
  unpack the “tool4d” package matching your 4D version.
- **VS Code extension “4D-Analyzer”** (publisher “4D”): downloads tool4d
  automatically; on the Mac it lives under
  `~/Library/Application Support/Code/User/globalStorage/4D.4d-analyzer/tool4d/…/tool4d.app`.

**Help → Find tool4d…** checks these known locations (plus PATH and the
Applications folders), shows the location and version, and remembers the
path for a future check integration — nothing is executed.

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

## Windows and Tabs

⌘T opens a new tab, ⌘N a second, fully independent window (its own
tabs, its own search). ⌘S saves, ⌘W closes the tab — Fastra asks first
if there are unsaved changes. ⌘J jumps to a line number.
