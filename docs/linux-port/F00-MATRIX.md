# F00: Bestand und Linux-Abnahme

Stand: 2026-11-06. Ausgang: `55ca70579861954a21cfbd22d96e12059fec68db`,
Produkt 1.157.1. Importkorrektur: 1.157.2 / Build 365. Laufbelege und die
Zuordnung der geprüften Programme stehen im [Entscheidungsbericht](../LINUX-DECISION.md).

Die Quellen unten liegen unter `app/Sources/Fastra`, die genannten Tests unter
`app/Tests/FastraTests`. README, beide Hilfefassungen und die CodeEdit-Patches in
`app/Patches` sind ergänzende Verhaltensreferenzen. Vorhandene Mac-Tests sind
Referenzen, keine schon bestandenen Linux-Tests. Keine private Nutzervorlage wurde
als Testdatum übernommen.

| Funktionsgruppe und Bestand | Quelle / vorhandener Beleg | Linux-Ziel und Paket | Abnahme / offene Grenze |
| --- | --- | --- | --- |
| Dateien, Encoding/BOM, Zeilenenden, Dirty, Fenster/Tabs, Auswahl, Undo, Split, Wrap, Faltung, Syntax, Rechteckauswahl | `Workspace.swift`, `FileLoader.swift`, `EditorContextMenu.swift`, `app/Patches`; `WorkspaceLoadTests`, `EncodingLineEndingTabTests`, `SplitEditorTests`, `CodeFoldingTests`, `FileLoaderTests`; Selbsttests `sourcesplit`, `colselwrap`, `colpaste`, `saveexisting` | F07; native Maus/Tastatur und eigener Linux-Editor, gemeinsame Dokumentidentität | Originalbytes, ein Undo je Aktion, Unicode, Wiederöffnung; F01 muss logische Rechtecke und gemeinsame Ansichten belegen. |
| Buffer/Ordner/Projekt/alle Tabs; Wildcards/Regex/Captures; Filter, Trefferfreigabe, Vorschau, Apply/Undo | `WildcardPattern.swift`, `BufferSearch.swift`, `SearchRunner.swift`, `SearchApproval.swift`, `ApplyEngine.swift`, `AtomicFileCommit.swift`; `WildcardPatternTests`, `BufferSearchPositionTests`, `SearchApprovalApplyTests`, `ApplySafetyTests`, `FileSystemSafetyTests` | F06/F08; Trefferbasis, Generation, Revision und Freigaben gemeinsam binden | Exakte UTF-16-Ranges und Ausgabebytes; stale/no-op/Dirty/Quellwechsel bis zum finalen Preflight schützen; Linux-Transaktionsadapter offen. |
| Textoperationen, Transformationen, Sortieren/Duplikate, Filter/Extraktion, Nummerierung, Umbruch, JSON/XML, Beispieltransformation | `TextOperations.swift`, `TextOperationTransform.swift`, `CaseTemplate.swift`; `TextOperationsTests`, `UnicodeTransformTests`, `CaseTemplateTests`; `textop` | F09; reine Rechnung gemeinsam, Host-Undo lokal | Jeden Menüweg und unveränderte Bereiche außerhalb der Auswahl prüfen. Case-Templates bleiben eigenes Paritätskriterium. |
| Vorlagen, Bausteine und Textabläufe | `SearchHistory.swift`, `TextSnippet*`, `TextWorkflow*`; `SearchHistoryTests`, `TextSnippetTests`, `TextWorkflowTests`, `TextWorkflowFilePlanTests`; `snippets`, `snippetfiles`, `textworkflowmulti` | F09; bestehende JSONs und Konfliktregeln erhalten | Import/Export, revisionsgebundene Bestätigung, gemeinsames Mehrdatei-Undo; keine ungefragte Speicherung ungesicherter Texte. |
| Projekte, Filter, Dateibeobachtung, Spracheinstellungen | `Workspace.swift`, `FolderSearch.swift`, `LanguageChoiceStore.swift`; `ProjectStoreTests`, `ExternalChangeTests`, `FileLocationTests`; `sidebarheader`, `sidebarfilter` | F10; lokale Linux-Beobachter, Ereignisse idempotent | Rename, wiederverwendeter Pfad, atomarer Austausch und Dirty-Dokumente; nicht aus Ereigniszahlen folgern. |
| Datei-/Ordnervergleich, Blockübernahme, Berichte, externer Helfer | `FileDiff*`, `FolderComparison*`, `DiffExport.swift`, `ExternalDiff*`; `FileDiffCancellationTests`, `FileDiffTransferTests`, `FolderComparisonTests`, `ExternalDiffProtocolTests`; `filedifftransfer`, `foldercompare` | F10; gemeinsamer Diff mit Budgets, Linux-Host für Ansichten | Relative Pfade, große/repetitive Texte, Bindung an Zielrevision; Ordnervergleich schreibgeschützt. |
| Git: Status/Staging/Commit/Graph, Branches, Remotes, Konflikte, Fetch/Pull, Push/Lease | `GitRunner.swift`, `Git*`, `Workspace.swift`; `GitConflictAndAdvancedTests`, `GitPush*Tests`, `GitMarkdownConversionTests`; `gitactions`, `gitpushbutton` | F11; dünnes asynchrones Frontend zum Git-CLI | Ausschließlich temporäre Repos/Remotes, echte Fehlerausgabe, Prozessbaum und stale Vorschau. Fehlendes Git verbirgt Funktionen. |
| Markdown: Quelle, Assistenz, Bilder/Paste/Drop, Gliederung, Links, Vorschau, KaTeX/Mermaid | `MarkdownEditing.swift`, `MarkdownRendering.swift`, `MarkdownPreviewAssets.swift`, `MarkdownReferences.swift`, `Resources/MarkdownVendor`; `MarkdownRichTextTests`, `MarkdownPreviewSchemeHandlerTests`, `MarkdownReferencesTests`; `mdimagewatch`, `mdreferences` | F12; vorhandene Ressourcen, lokale Allowlist und getrennte Linux-Bridge | Netzwerkfreiheit, Bildidentität, Umzug und echte gerenderte Inhalte. F04 liefert nur begrenzte Runtimeproben. |
| Markdown-WYSIWYG, Tabellen, Clipboard, Formatierung, Save/Close/Undo | `MarkdownVisualDocument.swift`, `MarkdownVisualEditor.swift`, `MarkdownTable.swift`, `visual-editor.js`, `visual-tables.js`; `MarkdownVisualTests`, `NativeMarkdownReviewTests`; `mdvisual`, `mdtable`, `mdtableinput` | F15; Blockerhalt und Synchronisation vor Hostaktionen | Gespeicherte UTF-8-Bytes nach frischem Prozess öffnen; unveränderte Blöcke erhalten. Vollständige Parität bleibt separat offen. |
| Bilder/PDF/SVG, Hex, große Dateien, Druck | `HexEditing.swift`, `FileLoader.swift`, `FilePreview.swift`, `MarkdownPreview.swift`; `HexEditingTests`, `HexEditLifecycleTests`, `ViewModeRoutingTests`; `filemodes`, `print` | F07/F14; vorhandene Grenzen, explizite Linux-Backends | Große/binäre Dateien abschnittsweise; PMT-PDF/OCR-Befunde sind kein Editor-/Drucknachweis. |
| 4D, XPath, Navigation | `FourDTokenizer.swift`, `FourDProjectMethodIndex.swift`, `FourDCompletion.swift`, `FourDMacroEngine.swift`, `Tool4DLSP.swift`, `XPathSupport.swift`; `FourD*Tests`, `Tool4DLSPTests`, `XPathSupportTests`; `macro4dengine`, `tool4dlsp`, `gototarget` | F14; native statische Analyse von externer Runtime trennen | Linux-tool4d/LSP/Makro-Ausführung nicht durch Syntaxfarben als portiert zählen. XPath ist die vorhandene Teilmenge. |
| Code-Erklärungen, Snapshot-Steuerung, CLI-Helfer | `CodeExplanationPackage.swift`, `CodeExplanationPlayer.swift`, `ControlSourceSnapshot.swift`, `ControlScripting.swift`; `CodeExplanationTests`, `LocalControlTests`, `ControlSourceSnapshotTests` | F14/F16; Herkunftsbindung und lokales Befehlsmodell erhalten | Keine neue Fernsteuerung oder stiller Schreibweg; Preview-/Apply-Grenze gilt auch für CLI. |
| Sitzung/Einstellungen/Hilfe/DE/EN/Start/Updates | `SessionRestoration.swift`, `SettingsView.swift`, `WelcomeView.swift`, `L10n.swift`, `Resources/Help`; `SessionRestorationTests`, `WelcomeLogicTests`, `Localization*Tests`; `sessionrestore`, `localization`, `help` | F07/F16; XDG/Linux-Konventionen, Paketmanager statt Sparkle | Nur gespeicherte Dokumente restaurieren; Ressourcen im Paket, beide Sprachen und reale Installations-/Upgradepfade. |
| PMT-Import und Desktop-Einstiege | `MarkdownImport*`, `Workspace.swift`; `MarkdownImportTests`, `MarkdownImportProgressTests`, `GitMarkdownConversionTests`; `markdownimport`, `markdowncollections`, `markdownimportui` | F13; lokale externe CLI, Formatkatalog und vollständiger Ergebnisbaum | Kollision, Assets, Prozessende, stale Tab/Projekt, maliziöse Antwort; Mac-Sammlungsfix erweitert den Vertrag nicht. |

## Fortschritt der Linux-Anbindung

Die Tabelle oben hält den ursprünglichen Funktionsbestand und seine
Abnahmekriterien fest. Der aktuelle implementierte Umfang ist über folgende
Folgebelege nachprüfbar; keiner erklärt die gesamte Portierung für abgeschlossen:

- [Speichern unter](F07-SAVE-AS.md), [appweites Beenden](F07-QUIT.md), [Git-Push und bestätigter Force-Push](F11-GIT-PUSH.md).
- [Native Dokumente und Editor](F07-LINUX.md), [Datei-/Ordner-Drops und Desktop-Einstiege](F07-DESKTOP-OPEN.md), [Sprachwahl und Einrückung](F07-EDITOR-OPTIONS.md), [Auswahlbereich](F07-SELECTION.md), [Zeilen-/Spaltennavigation](F07-EDITOR-NAVIGATION.md) und [Mehrtab-Freigaben](F06-TABS.md).
- [Dateitransaktionen und Wiederaufnahme](F03-TRANSACTIONS.md), [Ordnersuche](F06-FOLDER-SEARCH.md), [Projektbaum und externe Änderungen](F10-PROJECT-WATCH.md), [zuletzt benutzte Projekte](F10-RECENT-PROJECTS.md) sowie [optionale Textsitzungssicherung](F10-SESSION.md).
- [Suchpaarverlauf](F08-SEARCH-HISTORY.md), [Textabläufe und Bausteine](F09-WORKFLOWS.md), [weitere Textoperationen](F09-EXTENDED-TEXT.md), [4D-Tokenoperationen](F09-4D-TOKENS.md), [localegebundene Wortanfänge](F09-TITLECASE.md), [Abläufe über mehrere Tabs](F09-WORKFLOW-TABS.md), [Datei-/Ordner-/Projektabläufe](F09-WORKFLOW-DISK.md), [Suchvorlagen](F09-PATTERNS.md), [Dateivergleich](F10-DIFF.md), [Ordnervergleich](F10-FOLDER-COMPARE.md) und [Git-Indexvorschau](F11-GIT-INDEX.md) und [lesende Git-Historie](F11-HISTORY.md).
- [Sichtbare Markdown-Leerzeilen und Kopieren](F12-BLANK-LINES.md).
- [Markdown-Gliederung](F12-NAVIGATION.md), [formatierte Markdown-Bearbeitung](F15-RICH-EDITOR.md), [Rasterbilder und Clipboard-/Datei-Drops](rich-assets.md), [Dokumentvorschauen](F14-VIEWER.md), [Hexentwurf](F14-HEX-EDIT.md), [statische 4D-Navigation](F04-FOUR-D.md), [isolierte tool4d-Diagnosen](F04-TOOL4D-ADAPTER.md), [Druck](F14-PRINTING.md), [begrenzte XPath-Navigation](F14-XPATH.md) und [Paketierung](F16-PACKAGING.md).

Die optierte Sitzungssicherung darf nach sichtbarer Zustimmung auch ungesicherte
Textinhalte aufnehmen; standardmäßig ist sie ausgeschaltet. Das präzisiert das
anfängliche Ziel „nur gespeicherte Dokumente restaurieren“ ohne eine heimliche
Speicherung einzuführen. Ein kurzer echter Wayland-Start mit Skalierungsfaktor 2
ist belegt; vollständige Desktop-/IME- und Mac-Abnahme bleiben offen.

## Grenzwerte und Referenzen

Maßgeblich ist der Code, nicht historische Testzählung: `FileSnapshot.maximumReadBytes`
ist 256 MiB, `BufferSearch.defaultMaxMatches` 2000 und
`MarkdownPreviewAssets.maximumImageBytes` 32 MiB. Die Dateiklassifikation prüft bis
1 MiB, ihre Binärprobe 8 KiB (`FileLoader`). Der 32-MiB-Editorfall aus F01 ist ein
Entscheidungskorpus, keine neue allgemeine Importgrenze. Diff- und Dateimodus-
Budgets bleiben bei ihren eigenen Quellen; eine globale Erhöhung ist unbeauftragt.

Die kleinen Referenzen sind `tools/linux-probes/regex/cases.json` mit generierter
Mac-Referenz für Bereiche/Bytes/Fehler und `make-collections.py` mit zwei unabhängigen
Dokumenten und bekannter PNG-Prüfsumme. Sicherheitszustände prüft `exchange.py`.
Vorhandene Bestands-Fixtures werden weiterverwendet; es entsteht keine Kopie der
vollständigen Mac-Testsuite in Rust.

Weitere native Verträge: [einzelne Tabs schließen](F08-TAB-CLOSE.md), [Suchpaarverlauf](F08-SEARCH-HISTORY.md), [Transformation per Beispiel](F08-EXAMPLE.md) und [PMT-Hostintegration](F13-HOST.md).

Weitere umgesetzte Oberflächen: [4D-Vervollständigung](F09-4D-COMPLETION.md),
[4D-Textmakros](../FOUR-D-MACROS.md) und
[gespeicherte Code-Erklärungen](F16-CODE-EXPLANATIONS.md).
[Externe Lokalsteuerung](F17-LOCAL-CONTROL.md) und
[ausführbare Laufzeitmakros](../LINUX-4D-MACRO-RUNTIME.md) ergänzen diese Ansichten.
Die echte Runtime ist mit einer synthetischen Startup-Engine geprüft; die
Verträglichkeit beliebiger externer Enginekomponenten ist nicht damit belegt.

[Manueller Git-Fetch](F11-GIT-FETCH.md) ergänzt die lesenden Git-Ansichten und
die vorhandene Indexübernahme. [Normale Pushs](F11-GIT-PUSH.md) und
[Branchliste/Erstellen](F11-GIT-BRANCHES.md) sowie der ausdrücklich bestätigte
[lokale Branchwechsel](F11-GIT-SWITCH.md) und der
[vollständig bestätigte Indexcommit](F11-GIT-COMMIT.md) sind ergänzt.
[Force-Push](F11-GIT-PUSH.md) besitzt seit 1.174.0 eine eigene vollständige
Vorschau mit ausdrücklicher Zustimmung und exakter Server-Lease.
[Pull](F11-GIT-PULL.md) ergänzt die explizite Quellvorschau und den tatsächlichen Nachscan.

Die gemeinsame native Anwendung verwaltet weitere Starts und alle normalen Fenster
innerhalb derselben Desktop-D-Bus-Sitzung; Dienst- und GUI-Startreihenfolge bleiben
kompatibel. Die lokale Readonly-Steuerung einschließlich `fastra-control` ist unter
[F17](F17-LOCAL-CONTROL.md) beschrieben. Linux-Build, Signierung, ZIP/DEB/TAR und
Benutzerinstallation verwenden die Einstiege aus [F16](F16-PACKAGING.md).

Die automatische Aktualisierung lokaler Rasterbilder ist mit unverändertem Text,
Auswahl und Rücknahme unter [1.172.0](F16-1.172.0-EVIDENCE.md) geprüft.

[Source-/Vorschau-Klicknavigation und Klartext-Codekopie](F12-SOURCE-CODE.md) sind
mit dem gemeinsamen Stand [1.176.0](F16-1.176.0-EVIDENCE.md) geprüft.


Die [ausdrückliche Zeilenendenwahl](F07-LINE-ENDINGS.md) und der
[Optionsfokus](F07-EDITOR-OPTIONS.md) sind mit [1.179.0](F16-1.179.0-EVIDENCE.md)
geprüft. Rechteck-Copy/Cut, profilgerechte Spaltenpaste und gemeinsame Entscheidungen
für andere Tabs sind im [1.178.0-Abnahmebericht](F16-1.178.0-EVIDENCE.md) belegt.
Die [Formelbeschreibung](F12-MATH.md) trennt statische Vorschau und Rich-Atome.
Erweiterte Umbruchprofile und die vollständige
Desktop-/IME-/Accessibility-Abnahme bleiben eigene offene Kriterien.

Der [externe Vergleichshelfer](../EXTERNAL-DIFF.md#linux) ergänzt den CLI-Vertrag
mit getrennten readonly Fenstern, nativer Annahme und lokalem Sitzungs-D-Bus.

Die statische Vorschau übernimmt die [HTML-Positivliste und expliziten externen
Links](F12-MARKDOWN.md). Die vollständige Dialektgleichheit und aktuelle
Mac-/physische Desktopabnahme bleiben davon getrennt.

Unabhängige Split-Auswahlen und gebundene Befehlsziele sind unter
[F07-SELECTION](F07-SELECTION.md) beschrieben. Text-/Undo-Synchronität und
PRIMARY-Lebensdauer sind eigenständige native Prüfkriterien.

[Stabile Sortierung nach Textlocale](F09-LOCALIZED-SORT.md) und
[Dateimanageraktionen](F07-FILE-MANAGER.md) ergänzen die Linux-Anbindung ab
1.186.0. Die Sortierreihenfolge ist eine ausdrückliche stabile ICU-Entscheidung,
kein Finder-Paritätsversprechen. Feste Umbruchspalten, Folgezeilenprofile und
allgemeine native Eingabevorprüfung bleiben bis zu einer verifizierten
Produktintegration offen.

Die [native Machbarkeitsprüfung](F01-NATIVE-BOUNDARIES.md) trennt geschlossene
Prototyp-Gegenfälle von den weiterhin offenen Produkt-/Paketierungs- und
IME-Kompositionsgrenzen.

Die [Abnahme von 1.186.0](F16-1.186.0-EVIDENCE.md) ergänzt aktuelle notarierte
Mac-Fenstertests und eine physische Cinnamon-/X11-Probe für Tastatur, Compose,
Save/Undo/Redo und AT-SPI-Textzugriff. Dabei bleibt ein heller Quelleditor im
dunklen Desktop als konkreter Fehler offen. Kandidatenfenster-IME und
vollständige Screenreader-/Wayland-Abnahme sind weiterhin eigene Kriterien.

Der bei dieser Probe gefundene Farbfehler ist mit
[1.186.1](F16-1.186.1-EVIDENCE.md) nativ und auf dem physischen dunklen Desktop
geschlossen; [Quellfarben](F07-SOURCE-APPEARANCE.md) folgen auch Themewechseln.

[1.186.2](F16-1.186.2-EVIDENCE.md) ergänzt eindeutige zugängliche Namen der
sechs zentralen Textfelder und Beschreibungen von Suchmodus/-bereich, physisch
in beiden Sprachen geprüft. Der aktuelle Mac-Paketstand ist notarisiert
installiert und gegen seine unveränderte Fenster-Testbasis abgegrenzt.

Ab 1.187.0 sind [GFM-Autolinks mit ursprünglichen Quellbereichen](F12-AUTOLINKS.md)
im gemeinsamen Linux-Parserpfad integriert. [Umbruch- und Folgezeilenprofile](F07-WRAP-PROFILES.md)
sind an eine exakt geprüfte native Capability gebunden. Die gemeinsame
Abnahme des optionalen Laufzeitpakets, allgemeine IME-Transaktionen und
vollständige Markdown-Dialektgleichheit bleiben davon getrennte Kriterien.

Der [gemeinsame Stand 1.187.0](F16-1.187.0-EVIDENCE.md) bindet 600 gebaute
Quelldateien, den verpackten optionalen Laufzeitpfad, zehn echte finale
Commitfälle auf beiden Quellansichten und die gemeinsame GFM-/Rich-CRLF-Probe.
Die echte 4D-Engine besteht Diagnosen, Unicode-Signaturhilfe und Makroausführung
mit dem endgültigen GTK-freien Helfer in beiden Laufzeitpfaden. Allgemeine
IME-Transaktionen und die physische Abnahme des optionalen Pakets bleiben offen.

Die [mehrsprachige Syntaxfaltung](F07-FOLDING-FOUNDATION.md) ist ab 1.217.0
angebunden: gepinnte Mac-Grammatiken, 4D-Regeln, gebundene Prozessanalyse und
unabhängige native Ausschnitte. Der dort beschriebene Platzhalterfluss bleibt
eine konkrete technische Darstellungsgrenze. Allgemeine IME-/Desktopabnahme und
die optische Gesamtabnahme sind weiterhin eigenständige offene Punkte.

Die [reine Lesegrundlage](F07-DOCUMENTS.md#reine-lesegrundlage-ab-12180) trennt
ab 1.218.0 Vergleiche, Referenzprüfung und visuelle Vorschauen von den
Metadatenanforderungen schreibender Transaktionen. Lesbare Hardlinks sind dort
zulässig. Ab 1.219.0 kommen vollständige schreibgeschützte Quelltext-Tabs mit
Kopieren, Suche und Navigation, externem Änderungshinweis und bearbeitbarer
Kopie ohne Schreibfreigabe für die Quelle hinzu. Ab 1.220.0 merkt die freiwillige
Sitzungssicherung solche Tabs als Dateiverweise; die Wiederherstellung liest
den aktuellen Stand ausdrücklich erneut schreibgeschützt. Fehlende Quellen
blockieren Entwürfe nicht; die ursprüngliche Sicherung bleibt erhalten.

Der begrenzte Stand 1.188.0 ergänzt [Tab-Dateigriffe](F07-TAB-FILE-DRAG.md),
[vier Markdown-Quellbefehle](F12-SOURCE-INLINE.md) und
[native Delete-/Join-Pläne](F01-NATIVE-EDIT-PLANS.md) im passenden optionalen
Laufzeitpfad. Die [Spaltenmessung unter Desktopthemes](F07-WRAP-PROFILES.md)
verwendet eine ausdrücklich gesetzte Monospace-Familie. Aktuelle Paket- und
Desktopbelege sind getrennt von diesen Funktionsverträgen zu bewerten.

Die [private GTK-Historykorrektur](F01-NATIVE-HISTORY.md) ist von den
Systembibliotheken getrennt. Der im unabhängigen Review gefundene
Trunkierungsabsturz des ersten Kandidaten ist im gebundenen V2-Patch geschlossen.

Der [gemeinsame Stand 1.188.0](F16-1.188.0-EVIDENCE.md) bindet 610 Gitblobs,
das endgültige optionale Paket und die aktuelle notarierte Mac-/physische
Cinnamon-Abnahme. Native Iterator-, Editplan- und Returnverträge werden vor
Dokumenten geprüft. Allgemeine IME-Transaktionen, automatische mehrsprachige
Faltung, vollständige Markdown-Assistenz und breitere Desktopabnahme bleiben offen.

Ab 1.189.0 ergänzen aktive Linux-Benutzerinstallationen automatische tägliche
GitHub-Updateprüfungen und einen ausdrücklich freigegebenen Paketwechsel.
[Updatevertrag und Prüfung](../BUILD-AND-TEST.md#linux-updates-aus-github)
trennen diesen Weg von Systempaketen und dem optionalen Toolkitkanal.
