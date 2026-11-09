# F11 · Lokale Branchliste und Erstellen ohne Wechsel

„Lokale Branches …“ im nativen Git-Fenster zeigt lokale Branchnamen, vollständige
Commit-IDs, den aktuellen Branch und vorhandene Worktreepfade. Die Ansicht erstellt
einen neuen lokalen Branch an einer ausdrücklich bestätigten Commit-ID. Sie führt
keinen Checkout, Force, Reset, Commit, Netzwerkzugriff oder automatisches Speichern
aus. Branchwechsel und Löschen besitzen keinen ausführbaren Knopf in dieser Ansicht.

## Vertrag der Ref-Erstellung

Die Commitquelle lässt sich aus einem vorhandenen lokalen Branch übernehmen oder
als vollständige 40-/64-stellige hexadezimale Commit-ID eingeben. Die Auswahl wird
vor der Vorschau in eine tatsächliche Commit-OID aufgelöst; Abkürzungen, Rev-Ausdrücke
und Nicht-Commit-Objekte werden abgewiesen. Die Vorschau zeigt Repository, neuen
Branchnamen, vollständige OID und Commitbetreff. Namen bleiben bis zum Git-Argument
unveränderte Bytes; Steuerzeichen und ungültiges UTF-8 werden sichtbar maskiert.
`check-ref-format --branch` prüft den Namen. Rückverweise wie `@{-1}` werden nicht
als vermeintlich wörtlicher Name übernommen.

Eine frische ausdrückliche Bestätigung schaltet „Lokalen Branch erstellen“ frei.
Eingabe-, Dokument-, Pfad-, Revisions-, Speicher- und Projektwechsel verwerfen die
Freigabe. Verspätete Antworten können keine neue Freigabe erzeugen. Die vorhandene
Ownerbindung des Fetch-Dialogs wird wiederverwendet. Die Bestätigung wird beim
Start verbraucht; ein zweiter Auftrag verlangt eine neue Vorschau und Bestätigung.

`git branch --no-track -- <Name> <vollständige OID>` erstellt den Ref über Gits
eigene Ref-Transaktion. Ohne Force verweigert Git einen inzwischen vorhandenen
Namen; ein fremder Branch wird nicht überschrieben. Ein zwischenzeitlich bewegter
Quellbranch oder gewechselter HEAD ändert die bestätigte Ziel-OID nicht. Git führt
weder eine Arbeitsbaumübernahme noch einen Branchwechsel aus. Deshalb dürfen
Dirty-Arbeitsdateien, vorbereitete Indexänderungen und ungespeicherte Editorpuffer
bestehen bleiben; die Anwendung lädt solche Puffer nach der Ref-Erstellung nicht
neu. Die unveränderte OID wird vor der Erstellung erneut geprüft. Git-Replacements
sind für die zielgebundenen Metadatenlesungen und die Erstellung ausgeschaltet.

Die vorhandene prozessweite Repository-Lease koordiniert Fetch, Index-Apply und
Branch-Erstellung, auch bei verlinkten Worktrees. Repository-, Gitdir- und gemeinsame
Gitdir-Identität werden erneut geprüft. Ein umgebogener `commondir` darf den Auftrag
nicht in ein fremdes Repository umlenken. Ausführbare `reference-transaction`-Hooks
werden vor Vorschau und Erstellung ausdrücklich abgewiesen, einschließlich eines
konfigurierten `core.hooksPath`. Sie werden weder heimlich deaktiviert noch ausgeführt;
solche Repositories benötigen für diesen Auftrag das Git-CLI.

Alle Git-Prozesse laufen außerhalb von GtkMain und behalten begrenzte echte stdout/
stderr-Ausgabe, Zeitlimit und abbrechbare Prozessgruppen. Die Ansicht begrenzt die
Git-Ausgabe pro Aufruf auf 512 KiB stdout / 128 KiB stderr, die lokale Liste auf
2000 Branches. Überschreitungen erlauben keine Teilvorschau. Nach Erfolg oder Fehler
wird die Branchliste frisch gelesen, andere offene Gitansichten werden über die
geteilte Repository-Identität aktualisiert. Ein nach Gits Ref-Veröffentlichung
eingehender Abbruch kann einen bereits angelegten Branch nicht rückgängig machen;
die Ansicht fordert deshalb bei Fehlern zum Prüfen der tatsächlichen Liste auf.
Es gibt keine automatische Löschung als Rücknahme.

## Unterschied zum Mac und separater Branchwechsel

macOS verwendet in `GitActions.swift` für die normale Auswahl `git switch <Name>`;
Git entscheidet dabei über lokale Änderungen und belegte Worktrees. Eine zusätzliche
vollständige Datei-Diffvorschau oder Checkboxbestätigung gibt es dort nicht. Die
Neuanlage in `GitAdvancedActions.swift` verwendet `git switch -c <Name> [Commit]`
und wechselt damit sofort; dafür verlangt macOS einen sauberen Arbeitsbaum ohne
Konflikte oder laufenden Git-Vorgang. Der validierte Mac-Runner prüft vor/nach der
Entscheidung und koordiniert Fastra-interne Aufträge. Seine Garantie ist kein
externer HEAD-Lock während des normalen Git-Aufrufs.

Die stärkere atomare Linux-Bindung eines vollständigen Dateiwechselplans ließ sich
mit normalem `git switch` nicht halten: Ein vorab gehaltener HEAD.lock verhindert
zwar dessen abschließende HEAD-Änderung, Git hat Arbeitsdateien und Index dann aber
bereits auf das Ziel geschrieben. Sperren der Quell-/Ziel-Branchrefs verhindern
einen anderen normalen Switch nicht. Ein synthetischer Driftversuch bestätigt:
Eine Vorschau main → target nennt nur file.txt; ein fremder Switch nach other legt
extra.txt an, und der anschließend geplante Switch nach target entfernt extra.txt
außerhalb dieser Vorschau.

Diese Branchansicht erstellt weiterhin ausschließlich unabhängige Refs.
Der normale [Branchwechsel](F11-GIT-SWITCH.md) ist inzwischen mit zusätzlicher
Vorschau, Bestätigung und Nachprüfung ausdrücklich freigegeben. Seine dokumentierte
externe Git-Racegrenze bleibt bestehen; er besitzt einen eigenen Dialog.
Ein belegter Mac-Löschpfad mit eigener Bestätigung wurde nicht gefunden; Branchlöschen
bleibt separat offen. Siehe auch die bestehende HEAD-Sperrgrenze für normale Commits
in [F11-GIT-INDEX.md](F11-GIT-INDEX.md).

## Prüfung

Backendtests verwenden ausschließlich synthetische temporäre lokale Repositories.
Sie prüfen erhaltene Dirty-Dateien/Index/HEAD, unveränderte bestätigte OID trotz
bewegter Quellref, SHA-1-/SHA-256-Repositories, Rohbytes, ungültige Namen/Aliase,
Nicht-Commit-IDs, Namenskollision nach Vorschau, Repository-/commonDir-Austausch,
gemeinsame Lease, nachträglich konfigurierte Ref-Hooks, Ausgabegrenzen sowie echten
Abbruch und Timeout des besessenen Git-Aufrufs.

`FASTRA_GIT_BRANCHES_SELFTEST=1` aktiviert den nativen Debug-Fenstertest; er verlangt
`FASTRA_ISOLATED_DISPLAY=1`. Er bedient den sichtbaren Git-Einstieg, Namen, Quelle,
Vorschau, Bestätigung, Erstellung und Abbruch mit echten Maus-/Tastaturereignissen.
Zusätzlich prüft er verbrauchte Freigaben, Eingabe-/Ownerwechsel, verspätete Antworten,
echte Git-Namenskollision, Refresh und unveränderte ungespeicherte Editorinhalte.
`FASTRA_TOOL_WIDTH` und `FASTRA_TOOL_SCREENSHOTS` steuern die privaten Layoutbelege.
Deutsch/Englisch bei Mindestbreite und breit werden tatsächlich ausgeführt und
visuell geprüft. Der Hostdesktop und echte Arbeitsrepositories sind keine Fixtures.
