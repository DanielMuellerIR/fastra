# F11 · Git Fetch unter Linux

Der native Git-Dialog bietet „Abrufen …“. Der separate Fetch-Dialog zeigt die
ermittelte Repository-Wurzel, eine Auswahl der konfigurierten Remotes einschließlich
„Alle Remotes“ und die ausdrückliche Prune-Option. Die Namen werden asynchron
ermittelt; freie URL-Eingaben gibt es nicht. Deutsch und Englisch sind vollständig.

## Verhalten

„Abrufen“ startet das installierte Git-CLI auf einem Worker. „Alle“ führt für jeden
sichtbaren Remote einen eigenen `git fetch -- <Name>` aus. Dadurch werden Namen
nicht als Remote-Gruppen interpretiert; auch `skipFetchAll` lässt keinen ausdrücklich
gewählten Remote aus. Namen und Pfade bleiben Argumentdaten, auch bei führendem
Bindestrich und nicht als UTF-8 darstellbaren Bytes.

Prune ist zunächst aktiviert. Die Auswahl übergibt ausdrücklich `--prune` oder
`--no-prune`, sodass die sichtbare Entscheidung auch bei einer abweichenden
Repository-Konfiguration gilt. Die übrigen Fetch-Refspecs stammen aus Git.
Submodule werden nicht rekursiv abgerufen, automatische Wartung wird nicht gestartet.
Es gibt weder einen Auto-Fetch-Scheduler noch Pull, Push oder Commit.

Der Dialog zeigt laufende, begrenzte stderr-Ausgabe; fragmentierte UTF-8-Zeichen
werden erst aus dem gesammelten Bytepuffer dargestellt. Nach Abschluss bleiben pro
Remote Exitstatus, echte Git-Ausgabe und etwaige Abbruch-, Zeit- oder Ausgabefehler
sichtbar. Ein Git-Fehler bei einem Remote verhindert die übrigen Einzelabrufe nicht.
Abbruch, Zeitüberschreitung oder überschrittene Ausgabegrenzen beenden dagegen die
Serie; noch nicht bearbeitete Remotes werden ausdrücklich genannt. Bereits
abgerufene Refs werden bei einem Teilfehler nicht zurückgesetzt.

Der Host begrenzt einen Fetch auf 120 Sekunden sowie je 512 KiB stdout und stderr
über die gesamte Serie. Der Prozessrunner besitzt und beendet die Prozessgruppe
mit ihren Kindprozessen. Authentifizierung erfolgt ohne interaktive Git-/SSH-
Passwortdialoge; vorhandene Zugangsmittel werden weiterhin von Git verwendet.
SSH verwendet ausdrücklich `GIT_SSH_COMMAND="ssh -oBatchMode=yes -oStrictHostKeyChecking=yes"`.
Das überschreibt ein konfiguriertes `core.sshCommand`; interaktive Passwort- und
Hostschlüsselfragen werden nicht angeboten. Nur bereits bekannte SSH-Hostschlüssel
werden akzeptiert. Die explizite Fetch-API erlaubt ausschließlich `file`, `ssh`,
`https`, `http` und `git`; externe Git-Transporthelfer gehören nicht zu diesem Port.

## Bindung und Koordination

Der Auftrag bleibt an das Fenster, den aktiven Dokumentbesitzer, Dokumentrevision,
Dokumentpfad, den laufenden Speicherzustand und die Projektgeneration gebunden.
Tab-, Dokument-, Speicher- und Projektwechsel brechen alte Aufträge synchron ab.
Vor Start wird zusätzlich die Projektwurzel auf dem Worker validiert. Die
ermittelte Repository-/Gitdir-Identität wird vor jedem Einzelabruf erneut geprüft.
Eine inzwischen geänderte Liste bei „Alle“ verlangt ein erneutes Öffnen des Dialogs.
Ein ausgetauschtes Repository darf keinen Fetch des zuvor ermittelten Plans starten.

Eine prozessweite Lease verhindert gleichzeitige Fetch-/Index-Apply-Aufträge auf
demselben Repository, einschließlich verlinkter Worktrees mit gemeinsamem Gitdir.
Auch die Remote-Ermittlung und der vorbereitete Plan sind an diese gemeinsame
Identität gebunden; eine geänderte `commondir`-Datei darf den Auftrag nicht umlenken.
Die Datei wird über gehaltene Verzeichnis-/Dateideskriptoren ohne Symlink-Folgen
und ohne blockierendes FIFO-Öffnen gelesen. Nur reguläre Dateien bis 4096 Bytes
werden akzeptiert. Die gemeinsame Identität wird vor jedem Einzelabruf erneut
verglichen, auch nach bereits erfolgreichen Abrufen.

Diese Prüfung sperrt die Konfiguration nicht gegen fremde Prozesse. Ein externer
Austausch nach der letzten Prüfung oder während eines laufenden Git-Aufrufs ist
nicht atomar ausgeschlossen. Fastra prüft vor dem nächsten Einzelstart erneut;
ein bereits laufendes Git behält die Verantwortung für seine Laufzeitpfade und
Dateisperren.
Git selbst verwaltet seine Dateisperren; fremde Sperren werden nicht entfernt.
Die lesenden Git-APIs behalten `GIT_ALLOW_PROTOCOL=""` und `GIT_NO_LAZY_FETCH=1`.
Nur die ausdrückliche Fetch-API öffnet die begrenzte Transportfreigabe.

Nach vollständigem oder teilweisem Abruf werden Status und Branches erneut gelesen.
Offene Git-Lese-, Index- und Historienansichten desselben Repositorys laden über
die gemeinsame Gitdir-Identität neu, auch bei Alias-Pfaden oder verlinkten Worktrees;
eine Indexfreigabe muss danach neu vorbereitet werden. Ein inzwischen gewechselter
Dialogbesitzer erhält keine verspätete Ergebnisübernahme. Die übrigen offenen
Gitansichten werden trotzdem über den geänderten Remote-Stand benachrichtigt.

## Referenz und Prüfung

Die Auswahl und Einzelabrufe entsprechen der manuellen macOS-Funktion in
[`GitActions.swift`](../../app/Sources/Fastra/GitActions.swift),
[`GitSync.swift`](../../app/Sources/Fastra/GitSync.swift) und
[`GitRemoteActionDialog.swift`](../../app/Sources/Fastra/GitRemoteActionDialog.swift).
Linux legt Prune explizit pro Dialogauftrag fest; der macOS-Hintergrundscheduler
und dessen gespeicherte Auswahlpräferenzen werden nicht übernommen.

`cargo test -p fastra-git` prüft ausschließlich neue temporäre lokale Repositories
und Bare-Remotes. Die Fetch-Regressionen decken einen/alle Remotes, Remote-Gruppen,
`skipFetchAll`, Prune an/aus, fehlende und entfernte Remotes, führende Bindestriche,
Teilfehler, Liveausgabe, Abbruch, Zeit-/Ausgabegrenzen, Repository-Austausch und
Worktree-übergreifende Koordination sowie eine ausgetauschte gemeinsame Gitdir-
Zuordnung ab. HEAD, Index und Arbeitsdateien bleiben bei
den Testabrufen bytegleich.

`FASTRA_GIT_FETCH_SELFTEST=1` aktiviert im Debug-Build den nativen Fenstertest. Er
verlangt `FASTRA_ISOLATED_DISPLAY=1` und eine private GUI-Sitzung. Echte Maus- und
Tastaturereignisse wählen einen/alle Remotes, starten den Abruf und brechen einen
laufenden lokalen Fetch ab. Die Prüfung beobachtet Ausgabe vor Abschluss,
Teilfehler, Refresh-Benachrichtigung, eine tatsächlich aktualisierte offene
Branches-Ansicht und ungültige Dokumentbesitzer. Aufnahmen
werden mit `FASTRA_TOOL_SCREENSHOTS` und `FASTRA_TOOL_WIDTH` erzeugt; Mindestbreite
und breite Darstellung sind in beiden Sprachen sowie hell/dunkel zu prüfen.
Reale Netzwerk- und Authentifizierungsdienste sind nicht Bestandteil dieser
isolierten Offline-Prüfung.

Eine zusätzliche Integrationsprobe verwendet ein eigenes temporäres Bare-
Repository auf einem separaten SSH-Server und die tatsächliche neue Fetch-API.
Schlüsselauthentifizierung mit bekannter Hostidentität, Remote-Tracking-Ref und
laufende Ausgabe bestehen; HEAD, Index und Arbeitsdatei bleiben bytegleich.
Das eigene Remote-Repository wird anschließend entfernt. Das belegt den
SSH-Schlüsselpfad, keine allgemeine HTTPS-/Credential-Helper-Abnahme.
