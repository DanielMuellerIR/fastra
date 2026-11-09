# Markdown: Klicknavigation und Codekopie

Die zwei Mac-Klickpfade stehen unter Linux bereit: Quelltextklick scrollt den
passenden Vorschauabschnitt; Vorschauklick setzt den primären Source-Caret,
entfaltet das Ziel und fokussiert den Editor. Beide Source-Panes bedienen dieselbe
Vorschau. Original-UTF-8-Bereiche werden auch nach Textmarker-Rewrite, Unicode
und CRLF auf 1-basierte UTF-16-Spalten abgebildet. Tabellenzellen besitzen eigene
Quellzeilen. Entferntes Markup macht einzelne Spalten bewusst näherungsweise.
Es gibt keine kontinuierliche Scrollkopplung oder Rich-Auswahlübertragung.

Ein gemeinsamer WebKit-Manager registriert ausschließlich `markdownPosition`
und `markdownCodeCopy`. Nachrichten sind auf 512 JSON-Bytes und bekannte Felder
beschränkt. Render-Token, erneuerte Sichtbarkeitsepoche, Dokumentinstanz,
Revision, aktiver Tab und Source-Modus werden geprüft. Neue Benutzereingaben
entwerten ausstehende Positionsantworten; veraltete Antworten übernehmen weder
Fokus noch Auswahl. Links, Auswahl und Buttons lösen keinen Source-Sprung aus.

Codekopie übernimmt ausschließlich hostseitig registrierten dargestellten Code,
keinen Nachrichtentext. Der synchrone GDK-Klartextprovider ersetzt ältere HTML-
und RTF-Formate. Grenzen sind 2 MiB je Block, 4 MiB Registrytext insgesamt und
10.000 Blöcke. Die Darstellung normalisiert Codezeilenenden; eine rohe Fence-
Bytekopie wird nicht behauptet. Quelle, Revision, Caret und Undo bleiben erhalten.
Die Knöpfe sind per Maus und Space bedienbar und folgen Scrollen und Resize.
Print-CSS entfernt die Controls; allgemeines Copy entfernt zusätzlich interne
Positions- und Codeattribute ohne Inhalt zu verlieren.

`linux/test.sh source-sync` und `linux/test.sh code-copy` starten die vorhandenen
nativen Prüfungen. Die integrierten DE-/EN-Läufe verwenden echte X11-Eingaben,
GDK-Clipboard und eine aktive innere WebKit-Sandbox auf privaten Displays.
Die Editorprüfung umfasst 760 und 1280 Pixel Breite. Der Footer hält vier Controls
pro Zeile; damit erzeugt GTK 4.14 bei seiner ungebundenen Höhenmessung keine
zusätzlichen unsichtbaren Footerzeilen. Die tatsächlichen Ansichten bleiben bei
Mindestbreite bedienbar und sind visuell geprüft.

Reine CR-Codefences bleiben eine bestätigte Parsergrenze, keine erfolgreiche
Paritätsprüfung. CR-only-Absätze und Überschriften sowie LF-/CRLF-Fences sind
separat geprüft. Formelparität, aktuelle Mac-Fensterabnahme und vollständige
Wayland-/IME-/Accessibility-Abnahme bleiben offen. Paketnachweis:
[1.176.0](F16-1.176.0-EVIDENCE.md).
