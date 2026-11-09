# F11: lesender Git-CLI-Adapter begonnen

Stand: 2026-11-04. `crates/fastra-git` ist ein eigenständiger synchroner
Unix-Adapter über das konfigurierte installierte Git-CLI. Der Host muss ihn auf
einer Worker-Queue ausführen. Keine eigene Git-Engine, Shell oder
Produktpfad-Umschaltung. Die tatsächliche Abnahme dieses Teilpakets erfolgte auf
Linux; native Mac-Integration und UI-Anbindung sind offen.

## API und Ausgaben

`Git::new` verlangt einen absoluten CLI-Pfad. Ein fehlendes Programm liefert
`Unavailable`, ein Startfehler `Launch`; echte Git-Fehler liefern `GitFailed`
mit unverändertem Exit-Code, Signal, stdout- und stderr-Bytes. Der Host kann bei
`Unavailable` Git-Funktionen verbergen. Keine verlustbehaftete Dekodierung an der
Sprachgrenze und keine Umformulierung der echten Git-Fehlerausgabe.

`discover` ermittelt Worktree-Root und eigenes Git-Verzeichnis mit `rev-parse`.
Es entfernt ausschließlich den abschließenden Antwort-LF: Zeilenumbrüche und
Nicht-UTF-8 im tatsächlichen Pfad bleiben erhalten. Ein `Repository` hält
Verzeichnisidentitäten und prüft vor jedem lesenden Befehl Root, Git-Verzeichnis
und die aktuelle `rev-parse`-Zuordnung. Ein anderer Checkout unter demselben
Namen wird abgewiesen. Das ist keine Dateisperre gegen konkurrierende Änderungen;
alle Antworten bleiben lesende Momentaufnahmen.

Umgesetzt sind:

- Status: `--no-optional-locks status --porcelain=v2 --branch --untracked-files=all -z`.
  Branch, HEAD-OID, Upstream und Ahead/Behind sowie getrennte rohe XY-Spalten;
  Ordinary-, Rename/Copy-, Unmerged-, Untracked- und Ignored-Datensätze.
  Rename-Quellen sind eigene NUL-Datensätze. Namen sind rohe `RepoPath`-Bytes,
  nicht Anzeige-Strings; jeder Datensatz bleibt zusätzlich vollständig erhalten.
- Gestagter/ungestagter Diff, optional für einen genauen rohen Pfad nach `--`.
  Literal-Pathspecs verhindern, dass ein Dateiname als Glob oder Git-Magie wirkt.
  Externe Diff-Programme, Textconv und Farbe sind für diesen Anzeigepfad deaktiviert.
- Begrenztes rohes `log --graph --oneline --decorate --all` für den Text-Tab.
- Lokale und Remote-Tracking-Branches aus `for-each-ref`: volle Ref-Namen, OID,
  HEAD-Markierung und Worktree-Pfad. Alle Felder sind NUL-terminiert, sodass ein
  Zeilenumbruch im Worktree-Namen keinen zusätzlichen Branch erzeugt.

`status` und `branches` liefern `ReadResult<T>` mit geparstem Wert **und** roher
`GitOutput`, damit auch Warnungen erfolgreicher Aufrufe beim Host erhalten bleiben.
Parser weisen unvollständige Datensätze zurück; gekürzte Ausgabe wird niemals
als vollständiger Status oder vollständige Branch-Liste freigegeben.

Geerbte `GIT_*`-Variablen werden vor dem Start entfernt, damit Repository, Index,
Objektdaten oder Trace-Ausgabe nicht umgelenkt werden. Der gestartete Prozess
erhält ausschließlich kontrollierte Git-Schalter für Literal-Pathspecs,
deaktivierte optionale Locks und abgewiesene Editoren/Askpass-Dialoge. Reguläre
Git-Konfiguration bleibt lesbar; `core.fsmonitor=false` verhindert den Start
eines externen Statusmonitors. Es gibt keine Netzwerk-API.

## Prozessbesitz, Abbruch und Grenzen

Jeder direkte Kindprozess erhält vor `exec` eine eigene Prozessgruppe.
Beide Pipes sind nichtblockierend und werden abwechselnd in begrenzten Chunks
gelesen. Der Adapter begrenzt die gespeicherten Bytes und die Laufzeit pro
Kindprozess. Die Standardgrenzen sind 16 MiB stdout, 4 MiB stderr, 120 Sekunden
und 100 ms TERM-Frist. Höchstens 64/16 MiB Capture und fünf Sekunden TERM-Frist
sind konfigurierbar. Bei Ausgabeüberschreitung folgt `OutputLimit` mit genau dem
behaltenen Präfix und sichtbaren Truncation-Flags, kein erfolgreicher Teilwert.
Abbruch und Timeout erhalten ebenfalls ihre begrenzten bisherigen Rohbytes.

`waitid(WNOWAIT)` beobachtet das Elternende, ohne den Gruppenleiter aufzuräumen.
Seine noch reservierte PID verhindert die Wiedervergabe der Gruppen-ID bis zum
letzten Gruppensignal. Abbruch/Timeout senden TERM, danach KILL ausschließlich
an diese eigene Gruppe. Nach Elternende werden verbliebene Kinder bereinigt,
auch wenn sie ihre Ausgabepipes bereits geschlossen haben. Offene Pipes erhalten
zunächst 250 ms Drain-Frist; danach folgt kontrolliertes Cleanup. Erst nach dem
letzten Signal wird der direkte Kindprozess mit `wait` aufgeräumt. Es gibt keine
nachlaufenden Timer, die später eine wiederverwendete Gruppen-ID treffen könnten.

Dies ist Prozessgruppenbesitz, keine Betriebssystem-Sandbox. Ein fremdes
Unterprogramm, das absichtlich eine neue Sitzung/Prozessgruppe erstellt, liegt
außerhalb dieses Besitzes und wird nicht anhand bloß gemerkter PIDs verfolgt.
Seine geerbten offenen Pipes können den Rückweg nach KILL plus Drain-Frist
nicht unbegrenzt halten. Kernelprozesse in nicht unterbrechbarem I/O können
auch durch SIGKILL nicht mit einer absoluten Echtzeitgarantie beendet werden.

## Ausgeführte Prüfung

**17 Tests bestanden**: neun mit echten temporären Git-Repositories und acht
für Prozessbesitz im gemeinsam genutzten `fastra-process`-Modul. Reproduktion:

```sh
cargo test --locked -p fastra-git -p fastra-process
cargo clippy --locked -p fastra-git -p fastra-process --all-targets -- -D warnings
```

Belegt sind Nicht-UTF-8-/Tab-/LF-Namen, Rename plus zusätzliche Working-Tree-
Änderung, rohe Pfadargumente, verknüpfte Worktrees mit LF/Tab, Branches/Log,
unvollständiger Status, Konfliktdatensatz, echte Fehlermeldung, fehlendes Git,
ausgetauschtes Git-Verzeichnis und unterdrücktes externes Diff-Programm.
Ein temporäres **lokales Dateisystem-Remote** belegt Ahead/Behind; der Test
legt es selbst an, pusht ausschließlich dorthin und prüft danach die
abweichenden lokalen/entfernten OIDs. Das Arbeitsrepo ist nie ein Fixture.

Prozessprüfungen bestätigen bytegleiche Argumente und stderr, leeres stdin,
beide gleichzeitig gefüllten Pipes, begrenzte Dauerausgabe, Timeout und Abbruch
mit TERM-resistentem Eltern-/Kindprozess, zurückbleibende Kinder bei Elternende,
Kinder mit geschlossenen Pipes und den Fortbestand eines unbeteiligten
separaten Prozesses. Kein Signal wird aus einem nachträglich gespeicherten
Cancellation-Handle gesendet. Testhelfer benötigen `/usr/bin/python3`;
Repo-Fixtures nutzen `/usr/bin/git` und isolierte Git-Konfiguration.

## Noch offen

F11 ist begonnen, nicht abgeschlossen. Stage/Unstage/Commit, Branchwechsel,
Fetch/Pull/Push und deren vollständig gebundene Vorschau/Freigabe sind nicht
exponiert. Insbesondere darf ein späteres `git add` nicht aus einer bloßen
Status-vorher-Prüfung als racefrei gelten: Arbeitsdateien und Index können sich
zwischen Prüfung und Mutation ändern. Ein entsprechender Mutationsvertrag muss
zuerst belegt werden. Auch Konfliktaktionen, Diff-Rendering, native Mac-Prüfung,
UniFFI und Host-Queue/UI-Zustände bleiben offen. Der Adapter schaltet keinerlei
schreibende Produktfunktion frei.

## Nativer Linux-Host

Das sichtbare Menü „Werkzeuge / Tools“ öffnet ein eigenes GTK-Fenster für Status,
Branches, Verlauf sowie Index- und Arbeits-Diff. Die Git-Erkennung läuft auf einem
Worker; ohne installiertes Git bleibt der Menüpunkt verborgen. Jede Abfrage läuft
im Hintergrund mit begrenzter Ausgabe und explizitem Abbruch. Pfadwechsel
verwerfen laufende Ergebnisse; Fehler erhalten die echte CLI-Ausgabe. Dateien,
Index und Remotes werden durch dieses Fenster nicht geändert.

Die GTK-Prüfung verwendet ausschließlich synthetische temporäre Repositories.
Status → Branches → Verlauf → Arbeits-Diff → Status wurde auf Deutsch und Englisch
bei 640 und 1080 Pixel Breite ausgeführt und visuell geprüft. Das echte Tools-Menü
wurde zusätzlich mit vorhandenem und fehlendem Git geöffnet.
