# Linux: Git-Pull mit vollständiger Vorschau

Pull ist ein dünnes asynchrones Frontend über das installierte Git-CLI. Die
Quellwahl besteht aus einem konfigurierten Remote, einem wörtlichen Branch und
FF-only, Merge oder Rebase. Es gibt kein Autostash, Force, Reset, automatischen
Konfliktabbruch oder anschließenden Push.

## Zwei ausdrückliche Schritte

„Quelle abrufen und Vorschau erstellen“ startet den sichtbaren Fetch; dabei
können Refs und FETCH_HEAD geändert werden. Die komplette Vorschau zeigt
ankommende und lokale Commit-Patchfolgen, HEAD→Quelle, vollständige IDs, Status,
Index- und Arbeitsdiffs. Binäränderungen erscheinen als Git-Binärpatch.
Merge-/Rebase-Patches sind keine Vorhersage des endgültigen Dateistands.

Erst die eigene Checkbox und ein weiterer Ausführen-Klick erlauben Pull. Jede
Quell-, Strategie- oder Basisänderung verbraucht diese Freigabe. Repository,
HEAD/Branch, Refs, FETCH_HEAD, Config, Hooks, Index und die gesamte gehaltene
Pfadunion werden direkt vor dem Dispatch erneut geprüft. Auch unveränderte
assume-unchanged-Dateien bleiben gebunden.

## Native Grenzen und tatsächlicher Bericht

Der native Pull fetcht erneut. Ein vorab geprüfter Remote kann danach vorgerückt
sein; fremdes Git, Filter und Hooks können zusätzliche Dateien ändern, auch vor
einem Fehler. Die Ansicht nennt diese nicht atomare Grenze ausdrücklich.
Es erfolgt keine automatische Rücknahme. Konflikte und Teiländerungen bleiben
als native Git-Zustände erhalten.

Jeder begonnene Versuch erhält trotz Cancel/Fehler einen eigenen endlichen
Nachscan mit tatsächlichem HEAD/Branch, Status/Diffs, Vorgangsmarkern, FETCH_HEAD,
Graphprüfung und vollständigem ursprünglichem→tatsächlichem HEAD-Patch.
Prüfungsfehler verhindern eine Erfolgsmeldung. Bei verlorenem Kontext erscheint
nur ein lesender Bericht mit dem ursprünglichen Repositorybezug.

Alle lebenden Fenster einschließlich ausgeblendeter Fenster werden berücksichtigt.
Laufende Source-/SaveAs-/Hex-/Folder-/Asset-Publikationen blockieren den Start.
Während Pull und Nachscan werden entsprechende neue Dateipublikationen vor der
ersten Änderung abgewiesen; Entwürfe und Pläne bleiben erhalten. Normales
Close/Quit wartet sichtbar bis zum abschließenden Main-Receipt. Nach Erfolg ist
ein ausdrücklicher Retry nötig, kein späteres automatisches Quit. Puffer werden
nicht durch den Git-Bericht ersetzt.

## Grenzen und Prüfung

Pull hält höchstens 65.536 eindeutige Pfade, 1 MiB Pfadbytes, 64 MiB Arbeitsdaten
und 32 MiB je Datei/Index. Die bestehende Switchgrenze von 128 Pfaden bleibt
unverändert. Die UI begrenzt einen Auftrag auf 4 MiB stdout, 128 KiB stderr und
30 Sekunden; der Nachscan hat ein eigenes endliches Budget. Keine gekürzte
Vorschau kann bestätigt werden. Shallow-Historie, Legacy-Grafts, mehrere
Fetchadressen, nicht erlaubte Remotehelper und unvollständige Daten ergeben keine
Freigabe. Raw-Reftests ändern nicht die ausdrücklich UTF-8-basierte Branchtexteingabe.

Configfehler-stdout wird vollständig entfernt, weil Config auch undurchsichtige
Zugangsdaten außerhalb von URLs enthalten kann. Erfolgreiche Configbytes bleiben
intern an die Freigabe gebunden. URL-Zugangsdaten werden in den übrigen
Pull-Fehlerausgängen redigiert; erfolgreiche Patch- und Statusinhalte bleiben
vollständig. Unabhängige echte Gitproben haben den ursprünglichen Pull- und
Switch-Configbefund nach Korrektur geschlossen.

Prüfungen verwenden ausschließlich temporäre lokale Repositories und Remotes.
Sie umfassen echte 129-/1024-Datei-Pulls, Stale- und Budgetablehnung vor Dispatch,
Konflikte, Cancel/Ownerverlust, gehaltenen Main-Receipt und gegenseitige
Source-/Hex-/Folder-/PNG-Publikationsgates. Das ersetzt keine vollständige
physische Desktop-/IME-Abnahme oder plattformübergreifende Mac-Abnahme.
