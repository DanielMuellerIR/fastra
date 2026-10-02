# Soft-Wrap-Folgefragmentkern

Der Layoutkern unterstützt `flushLeft`, `firstLine` und `reverse`.
`firstLine` richtet Fortsetzungen an der führenden Einrückung aus; `reverse`
addiert genau eine Einrückungsstufe. Die Messung verwendet dieselben CoreText-
Attribute wie der Text, einschließlich Tabstopps und Zeichenabstand.

Das optionale Formatprofilfeld `softWrapIndentation` speichert stabile Rohwerte.
Fehlende oder unbekannte Werte verwenden `firstLine`; bestehende Wrap-Ziele,
Einrückungswerte und Nutzerabweichungen bleiben erhalten. Ein Moduswechsel
aktiviert Soft Wrap nicht. Zurücksetzen gilt weiterhin pro Format.

## Gemeinsame Geometrie

`LineFragment.xOffset` beschreibt den Ursprung relativ zum allgemeinen Text-
Inset. `TextLayoutManager.fragmentOriginX(for:)` übersetzt ihn in View-
Koordinaten. Zeichenpositionen und der Fragmentrenderer bleiben fragmentlokal.
Das erste Fragment behält Ursprung null und die volle Breite. Fortsetzungen
ziehen ihren Einzug von derselben Umbruchbreite ab; mindestens ein vollständiges
Graphem macht auch bei zu schmalem Platz Fortschritt. Überbreite einzelne
Grapheme und Attachments dürfen über den Rand reichen.

Der reproduzierbare Checkout-Patch liegt in
`app/Patches/CodeEditTextView/soft-wrap-indentation.py`; `app/build.sh` wendet ihn
nach den vorhandenen Typesetter-Patches an. Jede Ersetzung prüft unmittelbar
ihren vollständigen Zielzustand. Der Zeilencache vergleicht neben der Breite
auch Modus und Stufenbreite, ohne alle Dokumentzeilen vorab auszulegen.

| Verbraucher | Quelle relativ zu CodeEditTextView/Sources/CodeEditTextView |
| --- | --- |
| Fragmentzeichnung, Wiederverwendung und Gesamtausdehnung | `TextLayoutManager/TextLayoutManager+Layout.swift` |
| Klickpositionen und Caret-/Zeichenrechtecke | `TextLayoutManager/TextLayoutManager+Public.swift` |
| Auswahl-/Suchrechtecke | `TextLayoutManager/TextLayoutManager+Public.swift`, `TextSelectionManager/TextSelectionManager+FillRects.swift` |
| Cursor und vertikale Navigation | `TextSelectionManager/TextSelectionManager.swift`, `SelectionManipulation/SelectionManipulation+Vertical.swift` |
| IME-Kandidatenposition und IME-Hit-Test | `TextView/TextView+NSTextInput.swift` |
| Mausauswahl und Auto-Scroll | `TextView/TextView+Mouse.swift`, `TextView/TextView+ScrollToVisible.swift` |
| Drag-Vorschau und Maskierung | `TextView/DraggingTextRenderer.swift` |
| Drop-Caret und externer Drop | `TextView/TextView+Drag.swift`, versionierter `TextView+FastraExternalDrop.swift` |
| Rechteckauswahl | versionierter `app/Patches/CodeEditTextView/TextView+ColumnSelection.swift` |

Fastra verwendet diese APIs außerdem in `EditorView`, `GoToTarget` und
`FourDSignatureHelpPanel`. Vollzeilige Hintergründe und Gutter-Clamping behalten
das allgemeine Text-Inset; Klicks in den Einzug landen am Fragmentanfang.

## Bedienintegration

Das Fußzeilenmenü bietet die drei Modi unter „Folgezeilen einrücken“.
`Workspace` liest den gespeicherten Formatwert; `EditorView` reicht ihn durch
das Controller-Reconcile an den vorhandenen Layoutmanager weiter. Bei
Leerzeicheneinrückung gilt die Profilstufe, bei Tab-Einrückung die Tabbreite.
Ein Moduswechsel erzeugt weder einen neuen Editor noch eine Textänderung.

Der reproduzierbare Patch in `app/Patches/CodeEditSourceEditor/` verbindet
das Reconcile und die Minimap. Ihre eigenen `DisplayData` verwenden dieselben
Umbruchgrenzen und Attachmentbreiten vor der Miniaturskalierung. Modus,
Stufe und Umbruchbreite gehören auch dort zur Cache-Signatur. Wertgleiches
Reconcile behält den Cache; eine verborgene Minimap bleibt beim Scrollabgleich
unausgelegt. Sichtbereich und Drag-Abbildung verwenden dieselbe logische Zeile
und dasselbe Fragment in beiden Layoutmanagern. Der Höhenanteil wird innerhalb
dieses Fragments umgerechnet; unterschiedliche Editorfragmenthöhen verändern
dadurch weder den Zielindex noch die inverse Abbildung. Minimap-Laufbreiten
werden genau einmal skaliert: Am exklusiven Fragmentende stammt die bereits
skalierte Breite aus dem Fragment, innere Zeichenpositionen aus CoreText.
Dieselbe Endposition gilt für Auswahlrechtecke im Minimap-Layoutmanager.

Der Vergleich verwendet einen eigenen AppKit-Renderer und bietet die
Formatprofiloptionen weiterhin nur im normalen Texteditor an.

Die vollständige Abnahme umfasst alle Wrap-Ziele, Zoom, Tabs, schmale Fenster,
Caret, Auswahl, IME, Drag, Auto-Scroll und Rechteckauswahl im realen Bedienweg.
`softwrapindentcore` prüft nur den hier vorbereiteten Kern im echten Fenster;
`softwrapindent` bleibt der vollständigen Bedienintegration vorbehalten.
