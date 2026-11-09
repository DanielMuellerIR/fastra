# Lokale Git-Historie und historische Dateipaare

„Git … → Historie erkunden …“ ergänzt die vorhandene Status-/Indexansicht um
einen vollständig lesenden Verlauf. Die Graphseite zeigt die echte Ausgabe von
`git log --graph`, keine eigene Graphlayout-Engine. Der Commitselektor enthält
bis zu200 Commits mit OID, Datum und Betreff. Nach Commitwahl wird ein
Vergleichselternteil ausdrücklich gewählt; bei Merge-Commits sind alle erfassten
Eltern getrennt verfügbar. Ein Root-Commit hat eine leere Vorgängerseite.

Die vollständige Änderungsliste kommt aus `git diff-tree --raw -z -M`.
Umbenennungen behalten beide Pfade; Linux-Pfadbytes bleiben Identität und werden
nur für die Anzeige eindeutig escaped. Kein Anzeigename wird zurück in einen
Pfad konvertiert. Der gewählte Eintrag wird mit „Gewähltes Dateipaar lesen“
geöffnet: Vorher/Nachher stehen nebeneinander; die dritte Seite enthält den
vollständigen begrenzten Fastra-Differenzbericht mit Commit-/Parent-/Autor-/
Datumsbasis. Dies ist kein Patch-Export und keine Editorübernahme.

## Bindung und Nebenwirkungen

Historie, Commiteltern und Dateiliste binden auf vollständige validierte OIDs.
Die Graphabfrage verwendet die erfassten OIDs; Refdekorationen sind ein separater
aktueller Lesestand. Repo-/Gitverzeichnisidentitäten werden bei jedem CLI-Aufruf
und abschließend erneut geprüft. Ein ersetztes Repository wird nicht still neu
gebunden. Dateipaare werden ausschließlich mit `git cat-file` aus den erfassten
Blob-OIDs gelesen. Ein inzwischen geänderter Arbeitsbaum oder Branch verändert
diese Paare nicht. Gelöschte Git-Objekte/GC erzeugen echte Git-Fehler und keinen
Arbeitsbaum-Fallback. Git-Replacements werden für sämtliche historischen
Objektlesevorgänge ausdrücklich deaktiviert.

Keine Datei-, Index-, Ref-, Checkout-, Fetch- oder Netzwerkaktion wird angeboten.
Ungespeicherte Editorinhalte werden weder gelesen noch in die Historie aufgenommen.
Git-Pager, externe Diffprogramme, Textconv und Signaturanzeige werden nicht
aufgerufen. Der vorhandene Prozessowner begrenzt Laufzeit/Ausgabe und räumt bei
Abbruch nur eigene Prozesse auf. Alle CLI-/Blob-/Diffarbeit läuft auf Workern;
GTK verarbeitet nur begrenzte fertige Modelle. Abfragegeneration und Auswahl
binden Completion; eine neue Dateiauswahl leert das alte Paar. Parent-Hide bricht
ab und schließt das Kindfenster; alte Completions übernehmen nichts.

## Ehrliche Grenzen

- Bis200 Commits je Reload,2000 Änderungen je Commit-/Parentpaar.
- CLI-stdout2 MiB, stderr64 KiB,15 Sekunden je CLI-Aufruf.
- Blob1 MiB, Paar insgesamt höchstens2 MiB; vor dem Bloblesen Größenprüfung.
- Textvergleich höchstens50.000 Zeilen,5 Millionen Arbeitseinheiten,64 MiB
  Vergleichsspeicher, vollständiger Bericht höchstens2 MiB.
- Nur reguläre UTF-8-Textblobs ohne U+0000 werden als Text verglichen. Binärdaten,
  ungültiges UTF-8, Symlinks und Submodule werden als nichttextuelle Objekte mit
  OID/Modus/Byteumfang ausgewiesen; kein Textdiff wird vorgetäuscht.
- Größen-/Work-/Ausgabeüberschreitungen verwerfen den gesamten Befund statt
  still gekürzte Daten als vollständige Vorschau zu zeigen. Fehler und echte
  stderr-Ausgabe bleiben im scrollbaren Berichtsreiter sichtbar.
- Die Historie ist ein begrenzter Lesestand. Weitere Commits erfordern derzeit
  das Git-CLI; es gibt keine Pagination über200, keinen graphischen Eigenbau,
  Pickaxe-/Dateihistorienfilter oder Commit-/Refmutation. Commit bleibt gesperrt.

## Ausgeführte Prüfung

Synthetische temporäre Repositories prüfen Root-Commits, beide Merge-Eltern,
Umbenennungen mit nicht-UTF-8-/Newline-Pfaden, Unicode/CRLF-Blobbytes, nachträglich
geänderte Arbeitsdateien, Binary/Löschung, Blobgrenze, Cancel sowie Repoaustausch
und Git-Replacement-Blobs. Symlinks/Gitlinks werden nicht als fremde Dateien
geöffnet. Ein echter Promisor-/ext-Helper-Sentinel prüft die Netzsperre auch für
bestehende Log-/Diff-Aufrufe; eine ausdrücklich ungeschützte lokale
Positivkontrolle führt denselben synthetischen Sentinel aus. Keine Nutzerrepos
dienen als Fixture. Alle31 Git-Tests (5 Historie,17 Indexmutation,9 bestehende
Repositorytests) bestanden seriell; Clippy und Release-Check ebenfalls.

Native DE/EN-Läufe bei640/1080 prüfen den tatsächlichen Historie-Knopf im
Gitfenster und den Dateipaar-Knopf, Merge-Elternwahl, exakte Textbytes der
Vorher-/Nachher-Puffer, Graph und Differenzblöcke, rohen Binärpfad, Root-Commit,
Abbruch und Parent-Hide. Vorher/nachher werden Arbeitsdatei, echter Index und HEAD
bytegleich geprüft; der vorhandene Editorpuffer und seine Undo-Historie bleiben
unverändert. Alle XDG-Verzeichnisse einschließlich STATE und DBus/Xvfb sind
privat; Container laufen ohne Netzwerk. Die App läuft aus einem staged relativen
Paket mit ICU, ohne Quell-/Buildbaum-Mount.


Die Netzsperre liegt zentral im bestehenden lokalen Git-Prozessadapter:
GIT_NO_LAZY_FETCH=1 und eine leere GIT_ALLOW_PROTOCOL-Liste gelten auch für
Status-/Log-/Diff- und Indexpfade. Konfigurierte Protokollfreigaben können dadurch
keinen versteckten Lazy-Fetch aktivieren. Fehlende Promisor-Objekte bleiben
sichtbare Fehler. Zukünftige ausdrücklich angebotene Netzwerkaktionen benötigen
einen eigenen Vertrag; aktuell existiert keine freigegebene Ausnahme.
