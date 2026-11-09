# F01: Editorentscheidung bleibt angehalten

Aktuelle Einordnung vom 2026-11-05: GTK4/GtkSourceView ist die reversible
Entwicklungsbasis beider Linux-Apps. Die untenstehenden frühen Proben bleiben
historische Ausschluss- und Abnahmebelege. Offene native Desktop-/IME-Tore
blockieren PMTs GTK-Entwicklung nicht; siehe
[aktuelle Entscheidung](../LINUX-DECISION.md#aktuelle-entwicklungswahl-vom-2026-11-05).

GPUI Kit 0.9.0 wurde auf Commit
`7591a35eced761e3613c01e71ff04c10129dae1a` gelesen. Sein eigener
`InputBaseState.build_columnar_selection` bildet eine Auswahl pro **Anzeigezeile**
und begrenzt sie auf vorhandenen Zeilentext. Das ist auch die
[offiziell dokumentierte Semantik](https://gpui-kit.com/component/editor/).
Die Methode ist intern (`pub(super)`); öffentliche `add_selection`-Aufrufe allein
belegen weder eine ersetzte Mausgeste noch das Auffüllen kurzer logischer Zeilen.
Eine wartbare öffentliche Erweiterung wurde nicht nachgewiesen. Der unveränderte
Editor scheidet damit für die verbindliche Rechtecksemantik aus. Er wurde nicht
gebaut und erhielt keine erfundenen Leistungswerte oder Desktopabnahme.

GTK 4.14.5 / GtkSourceView 5.12.0 wurde im isolierten Ubuntu-24.04-Prozess mit
zwei echten Ansichten desselben Buffers ausgeführt. Mehrfachänderung und ein Undo,
Redo, CRLF/Tabulatoren, kombinierende Zeichen, Emoji und der reale
Python-Highlighter sind belegt; die Fensteraufnahme wurde visuell geprüft.
GtkTextBuffer bietet ein natives Auswahlpaar, keine vollständige
Mehrcursor-/Rechteckbedienung. Die erforderliche Erweiterung und Faltung sind
noch nicht als bedienbarer Prototyp nachgewiesen.

| Ladefall, zwei Ansichten | Gemessene Zeit | Bisheriger Spitzenspeicher des Prozesses |
| --- | --- | --- |
| 4 MiB mit kurzen Zeilen | 0,317 s | 178 MiB |
| 32 MiB mit kurzen Zeilen | 1,613 s | 529 MiB |
| 4 MiB in einer Zeile | 2,932 s | 606 MiB |
| 32 MiB in einer Zeile | 20,321 s | 3370 MiB |

Die Werte stammen aus demselben Prozess, höchstens vier CPU-Kernen und dem
Cairo-/Xvfb-Weg. `ru_maxrss` ist der bisherige Prozesshöchststand; die Zeilen sind
keine unabhängigen Speicherzuwächse. Software-Rendering und Containerlast sind
keine Prognose für den nativen GPU-Weg. Die lange Zeile ist dennoch ein konkreter
Ausschlussbefund für eine ungeprüfte Übernahme der Standardeinstellungen.
Tippen-/Scrollbudgets wurden nicht daraus erfunden.

Wayland, echter Cinnamon-X11-Desktop, physische deutsche Tastatur/IME,
Capture-Drag, Menüs, Accessibility und fraktionale Skalierung sind offen. Ein
Xvfb-Fenster besteht diese Fälle nicht stellvertretend. Deshalb erhält keiner der
beiden Kandidaten eine Freigabe. Vor einem größeren Fork braucht es eine bewusste
Entscheidung: eine begrenzte, gepflegte Editorerweiterung weiter untersuchen oder
weitere Alternativen gesondert beauftragen. Die Produktanforderungen werden in
keinem Fall still abgesenkt. Ein seriöser Gesamtaufwand ist aus diesen Teilproben
noch nicht ableitbar.

## Öffentliche Erweiterung weiter untersucht

Die Fortsetzung am 2026-11-04 ergänzt `tools/linux-probes/gtk/extended_editor.py`.
Sie verwendet ausschließlich öffentliche GTK-/GtkSourceView-APIs, ohne
Upstream-Patch. Auf isoliertem X11/Xvfb bestehen echte Alt-Mausgeste,
logische Rechtecke bei Soft Wrap, gemeinsames Tippen über drei Zeilen mit
Tabulator, kombinierendem Zeichen und Emoji, ein echtes Ctrl-Z für die gesamte
Aktion und Spalten-Paste mit Auffüllen kurzer Zeilen und einem Undo.
Normales Tippen füllt kurze Zeilen entsprechend dem Mac-Verhalten nicht auf.

Zwei Ansichten teilen denselben Buffer. Echte Knöpfe falten zwei Zeilen per
`GtkTextTag.invisible` und stellen sie wieder her; vollständige Bytes bleiben
erhalten. Ein echter Capture-Drag über `GtkDragSource`/`GtkDropTarget` fügt `$1`
ins Ersetzungsfeld ein. Syntaxfarben bleiben aktiv; die Fensteraufnahme wurde
visuell geprüft. Der Drop-Handler benötigt die Capture-Phase, weil das interne
Textfeld sonst den eigenen Drop-Pfad abfängt.

Damit ist eine begrenzte öffentliche Erweiterung technisch nachgewiesen; die
frühere Aussage „noch kein bedienbarer Prototyp“ gilt für diese Teilfälle nicht
mehr. Eine Toolkitfreigabe folgt daraus noch nicht: Faltung ist bufferweit,
IME, physische deutsche Tastatur, native Desktops/Skalierung, vollständiges
Clipboard und Langzeilenbudgets bleiben offen. Keine Produktoberfläche.
