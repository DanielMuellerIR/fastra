# F11 · Manueller Git-Push unter Linux

Das native Git-Fenster bietet „Push …“. Der Dialog liest zunächst ausschließlich
lokale Remote-Konfiguration. Erst „Vorschau laden“ kontaktiert den ausgewählten
Remote. „Push ausführen“ ist eine getrennte ausdrückliche Freigabe. Es gibt keinen
Hintergrund-Push, Pull, Reset oder Rebase.

## Sichtbare Grundlage

Die vollständige Vorschau nennt Repository, konfigurierten Remote, bereinigte
effektive Push-Adresse, vollständigen Zielref, vollständige Quell-Commit-OID,
erwartete Remote-OID beziehungsweise das ausdrückliche Fehlen des Zielrefs,
Vorsprung/Rückstand und alle zu übertragenden Commits. Ausgabeüberschreitungen
liefern einen Fehler statt einer freigabefähigen Teilvorschau.

Die Quelle ist der Commit des aktiven lokalen Branches; das Ziel ist derselbe
vollständige Branchref im ausdrücklich gewählten Remote. Detached HEAD und ein
noch commitloser Branch werden abgewiesen. Es gibt keine freie URL- oder
Refspec-Eingabe und keinen stillen Wechsel zu einem anderen Remote. Mehrere
Push-Adressen eines Remotes werden verständlich abgewiesen; die anderen Ziele
bleiben benutzbar. HTTP-Zugangsdaten sowie Query-/Fragmentwerte erscheinen nicht
in der sichtbaren Adresse.

`ls-remote --refs` ermittelt den tatsächlichen Serverstand. Ein bestehender
Remote-Commit wird über genau diese Adresse und OID geholt, ohne FETCH_HEAD,
Tags, Prune, Wartung, Submodulabruf oder Änderung lokaler Branch-/Trackingrefs.
Die Anwendung liest danach die beiden OIDs und ihre Commitmengen. Ein normaler
Push bleibt bei divergenten Historien gesperrt. Der getrennte, standardmäßig
ausgeschaltete Modus „Force Push mit exakter Lease“ benötigt eine neue Vorschau
und eine zusätzliche native Bestätigung.

## Bindung und Ausführung

Der Ausführungsplan hält die vollständige Quell-OID und den vollständigen Zielref
fest. Repository-/Common-Gitdir-Identität, ausgewähltes Remote mit effektiver
Adresse und lokaler Branch/HEAD werden vor der Ausführung erneut geprüft.
Die prozessweite Operation-Lease wird mit Fetch und Indexänderungen geteilt,
auch über verknüpfte Worktrees hinweg. Git verwaltet weiterhin seine eigenen
Sperren; fremde Sperrdateien werden nicht entfernt.

Wie beim macOS-Vertrag sind konfigurierte `insteadOf`-/`pushInsteadOf`-Regeln vor
der Vorschau und Freigabe ein sichtbarer Abbruchgrund. Ein zufälliger temporärer
Remote trägt URL und Push-URL als einmaligen Sentinel. Eine exakte Zuordnung im
Command-Scope desselben Git-Prozesses bildet diesen einmal auf die geprüfte
Adresse ab. Adresse und mögliche Zugangsdaten stehen dabei in der kontrollierten
Prozessumgebung, nicht in argv. Auch nach der letzten Prüfung ergänzte breite
URL-Regeln oder Änderungen am ursprünglichen Remote lenken diesen Auftrag nicht
auf eine andere Adresse um. Es wird kein dauerhafter Remote angelegt.

Ein unabhängiges `merge-base --is-ancestor` bestätigt vor jedem normalen Push die
Abstammung der exakten alten und neuen OIDs. Git-Replacement-Objekte und Grafts
sind dabei deaktiviert. Zusätzlich erhält `git push` eine exakte
`--force-with-lease=<vollständiger Ref>:<erwartete OID>`; bei einem neuen Branch
ist die erwartete OID leer. Diese Lease bindet die atomare Serveränderung an den
angesehenen Stand. Eine Lease allein wäre kein Fast-Forward-Schutz, weshalb der
Abstammungsnachweis zwingend zusätzlich gilt. Die Quelle des Ref-Specs ist die
feste Commit-OID und niemals ein beim Senden erneut aufgelöster Branchname.

Nur der eine bestätigte Branchref wird gesendet. Automatisches Follow-Tags und
rekursive Submodul-Pushs sind ausdrücklich deaktiviert. Pre-Push-/Server-Hooks
und die normale Git-Signaturkonfiguration bleiben aktiv. Upstreamkonfiguration,
HEAD, Index und Arbeitsdateien werden nicht umgeschrieben. Fremde Hooks bleiben
gewöhnliche Git-Unterprogramme und können eigene Nebenwirkungen besitzen.

## Ausdrücklicher Force Push mit exakter Lease

Der Force-Modus ist eine eigene, privat im Vorschauplan gespeicherte Freigabe.
`prepare_push` bleibt der normale Fast-Forward-Pfad; nur `prepare_force_push`
bereitet einen Force-Auftrag vor. Weder angezeigte Zähler noch eine divergierende
Normalvorschau schalten diese Freigabe um. Es gibt kein unbedingtes `--force`,
keinen Ref-Löschpfad und keinen automatischen Force-Folgeauftrag.

Zusätzlich zu Quelle, exaktem altem Remote-Commit, Adresse und Zielref zeigt die
Force-Vorschau zwei vollständige Listen: neue über diesen Zielbranch erreichbare
Commits sowie bisher darüber erreichbare Commits, die nach dem Update darüber
nicht mehr erreichbar wären. Das bezeichnet keine globale Objektlöschung; andere
Refs können diese Commits weiter erreichen. Der Backendvergleich verwendet die
festen OIDs ohne Replacement-Objekte oder Grafts. Beide Listen müssen vollständig
innerhalb der Ausgabe-/Zeitgrenzen vorliegen. Flache Repositories werden vor und
nach dem Vorschauabruf sowie vor Ausführung abgewiesen: Die fehlende Historie muss
zuerst außerhalb dieses Dialogs vervollständigt werden. Ein fehlender Zielbranch
oder ein unveränderter Commit benötigt keinen Force-Auftrag. Ein ausdrückliches
Zurücksetzen des Zielbranches auf einen älteren Commit kann null ausgehende und
mehrere danach darüber unerreichbare Commits besitzen und wird vollständig gezeigt.

„Mit Lease erzwingen …“ verbraucht die geladene Vorschau und öffnet eine eigene
native Warnung mit konfiguriertem Remote, bereinigter Adresse, vollständigem
Zielref sowie vollständiger alter und neuer OID. Abbrechen ist voreingestellt.
Auch ein Abbruch verbraucht die Freigabe; ein neuer Versuch braucht eine frisch
geladene Vorschau. Mode-/Zieländerung verwirft Vorschau und Warnung. Besitzer-,
Projekt- und Revisionsinvalidierung cancelt die Warnung über ihren eigenen
GTK-Cancellable synchron; eine verspätete Antwort darf keinen Push starten.
Die Antwort prüft zusätzlich den gebundenen Eingabezeitpunkt und aktuellen Owner.

Der normale unabhängige Fast-Forward-Nachweis entfällt ausschließlich bei diesem
expliziten Force-Plan. Alle übrigen Bindungen, native Hooks und Signaturregeln,
Prozessbesitz, Liveausgabe, Abbruch und Refresh gelten identisch. Die native
Serveränderung bleibt exakt an `--force-with-lease=<Zielref>:<alte OID>` und
`<feste neue OID>:<Zielref>` gebunden. Remoteänderungen vor dem Start oder während
des pre-push-Hooks werden durch Git verweigert. Ein erfolgreiches Update oder
Abbruch danach lässt sich dadurch nicht rückgängig machen. Kein Pull wird aus
diesem separaten Force-Auftrag abgeleitet.

Das Mac-Vorbild ist `GitAdvancedActions.gitForcePushWithLease` mit eigener
Bestätigung und `GitForcePushRunner` mit erneuter Auflösung; der Push-Folgepfad
in `GitActions.prepareBoundForcePush` liest den Serverstand vor seiner Warnung
neu. Linux erweitert die bereits explizit auswählbaren konfigurierten Ziele um
diesen separaten Modus und zeigt beide vollständigen Commitmengen statt allein
der gekürzten OIDs im Mac-Warntext. Die exakte CLI-Lease und feste Quelle folgen
dem bestehenden nativen Vertrag.

## Laufzustände und Grenzen

Ermittlung, Netzwerkprüfung und Ausführung laufen auf Workern. Der Dialog zeigt
begrenzte Live-stderr-Ausgabe sowie anschließend die echte Git-Ausgabe mit
Exitstatus beziehungsweise Abbruch-/Zeit-/Ausgabefehler. Der Prozessrunner besitzt
die gestartete Prozessgruppe samt ihren Kindern. Eine Benutzerabsage kann eine
bereits vom Server übernommene Änderung nicht zurücknehmen; danach ist immer eine
neue Vorschau erforderlich. Andere offene Git-Ansichten erhalten auch nach einem
Teilfehler oder inzwischen gewechseltem Dialogbesitzer eine Refresh-Nachricht.

Fenster, aktiver Dokumentbesitzer, Dokumentrevision, Dokumentpfad, Speicherzustand
und Projektgeneration binden den Auftrag. Tab-/Dokument-/Speicher- und
Projektwechsel brechen alte Aufträge synchron ab. Ein Projektwechsel A → B → A
macht eine alte Freigabe nicht wieder gültig. Verspätete Worker-Ergebnisse werden
nicht in einen anderen Besitzer übernommen. Die Projektwurzel wird zusätzlich
unmittelbar vor den Workeraktionen validiert.

Je Aktion gelten 120 Sekunden sowie begrenzte stdout-/stderr-Capture. Die
Transport-/Authentifizierungsregeln entsprechen dem expliziten Fetch:
`file`, `ssh`, `https`, `http`, `git`; keine externen Git-Transporthelfer,
keine interaktiven Passwort-/Hostschlüsselfragen. SSH verwendet BatchMode und
StrictHostKeyChecking. Gewöhnliche Git-Zugangsmittel bleiben verfügbar. Die
lesenden APIs öffnen weiterhin keine Netzwerkfreigabe.

Die Lease koordiniert Aufträge innerhalb desselben Fastra-Prozesses, keine
beliebigen fremden Prozesse. Git bleibt für seine Laufzeitpfade, Objektdaten und
Sperren verantwortlich. Externe Änderungen nach der letzten lokalen Prüfung
ändern die feste übertragene OID nicht; konkurrierende Änderungen des Remote-Refs
werden durch die Server-CAS-Prüfung abgewiesen.

## Nachweis

`cargo test -p fastra-git` verwendet ausschließlich temporäre lokale Repositories
und File-Remotes. Push-Prüfungen erfassen normale/neue Branches, exakte Absenz,
Divergenz, unabhängigen Abstammungsnachweis trotz falscher Zusammenfassung,
HEAD-/Ziel-/Repositorywechsel, Remoteänderungen vor und während Pre-Push,
Startzeit-URL-Umleitung, echte Hookfehler, Liveausgabe und Abbruch,
Zeit-/Ausgabegrenzen, Common-Gitdir-Leases über Worktrees, Nicht-UTF-8-Branchrefs,
Follow-Tags- sowie Preview-Fetch-Refschutz und getrennt fehlerhafte Remote-Ziele.
Force-Prüfungen ergänzen SHA1/SHA256-Divergenz, vollständige beidseitige Listen,
Rewind, fehlenden/unveränderten Zielref, Shallow-/Source-/Targetdrift,
Replacement-/Graftabwehr, geschlossene Ausgabegrenzen sowie CAS vor/im Hook.
Bestehende normale Pushprüfungen bleiben erhalten.

Der Debug-Einstieg `FASTRA_GIT_PUSH_SELFTEST=1` verlangt
`FASTRA_ISOLATED_DISPLAY=1`. Die private native GUI-Prüfung klickt echte Controls,
prüft die Remoteänderung, Live-Hookausgabe, nativen Abbruch, Besitzerwechsel,
laufenden Revisionsabbruch und Projekt-ABA. `FASTRA_TOOL_WIDTH` und
`FASTRA_TOOL_SCREENSHOTS` steuern Layoutbelege; Deutsch/Englisch bei 640 und
1100 Pixeln werden jeweils tatsächlich ausgeführt und visuell geprüft.

Der zusätzliche Debugschalter `FASTRA_GIT_FORCE_PUSH_SELFTEST=1` zusammen mit
`FASTRA_GIT_PUSH_SELFTEST=1` wählt die Force-Fensterprüfung: normal verweigerte
Divergenz, sichtbarer Moduswechsel, komplette Vorschau, echte native Warnung mit
Cancel ohne Remoteänderung, frische Warnung mit exaktem Update, Remote-Drift,
Mode-ABA und Besitzerwechsel während offener Warnung. Auch dieser Pfad verlangt
das private isolierte Display. Die normale Push-Fensterprüfung bleibt verfügbar.
