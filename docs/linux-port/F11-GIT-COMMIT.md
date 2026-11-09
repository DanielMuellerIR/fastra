# F11: Bestätigter vollständiger Indexcommit

Die native Commitansicht committet ausschließlich den vollständig gezeigten
Index-Snapshot. Sie zeigt Repository, aktuellen Ref, vollständige Tree-OID,
geordnete Parentliste, Autor und Committer samt fixierter Git-Vorschauzeit,
Signierungskonfiguration, vollständige Nachricht, binären Gesamtdiff und alle
Treeeinträge mit Modus, Typ, Objekt-ID und Rohpfad. Eingabe-, Dokument-, Fenster-
oder Projektwechsel entwerten Vorschau und Zustimmung synchron. Die ausdrückliche
Zustimmung wird vor dem Auftrag verbraucht.

## Native Vorbereitung und Veröffentlichung

Die Vorbereitung verwendet einen eigenen nativen Bare-Scratch mit eigener
Objektablage; Originalobjekte sind nur Alternates. Der Originalindex wird als
gebundene und begrenzte opake Datei gelesen. Native Git-Befehle erzeugen daraus
den vollständigen Tree und einen unabhängigen Vollindex, einschließlich Split-/
Sparse-Index und Linked Worktrees. Nur diese eigene Scratchvorbereitung besitzt
ausdrücklich ein leeres Hookverzeichnis. Sie startet keine Originalhooks und
schreibt weder Originalindex noch Originalobjekte. Scratchbereinigung erfolgt
auch bei Fensterinvalidierung auf einem Worker.

Der echte Auftrag ist normaler `git commit --cleanup=verbatim --file <message>`
mit privatem GIT_INDEX_FILE. Es gibt kein commit-tree, --no-verify, --no-gpg-sign,
Force, Reset, Amend, automatisches Stagen oder Zurückschreiben des Arbeitsindex.
Git erzeugt die zuvor bestätigten Treeobjekte identisch in der Original-ODB.
Späteres unabhängiges Staging bleibt erhalten. Ungespeicherte Editorpuffer werden
weder gespeichert noch automatisch ersetzt.

Ein temporäres eigenes Hookverzeichnis leitet alle vorhandenen ausführbaren
Originalhookdateien an ihren Originalpfad weiter. Der interne Helpermodus des
vorhandenen Appbinarys läuft vor GTK. Originalhooks behalten Arbeitsverzeichnis,
native Argumente ab argv[1] und stdin; sie werden über ihren aufgelösten absoluten
Originalpfad gestartet. Skripte, die die exakte relative Schreibweise von argv[0]
prüfen, können diesen Unterschied sehen. Die ursprüngliche
GIT_CONFIG_PARAMETERS-/COUNT-/KEY-/VALUE-Umgebung wird vor Original-Exec
wiederhergestellt; der äußere Gitprozess behält seine Wrapperkonfiguration.
Dadurch sehen Originalhooks wieder ihren ursprünglichen hooksPath und dessen
lokalen Scope/Origin. Interne Helpervariablen werden nicht weitergegeben.

Der native reference-transaction-Hook gibt jede tatsächliche Phase und Roh-stdin
zunächst unverändert an das Original weiter. In prepared hält Git seine eigenen
HEAD-/Branchlocks. Vor Veröffentlichung prüft der Helper tatsächliche alte OID,
Raw-Tree, vollständige geordnete Parentliste, vollständige Nachrichtenbytes sowie
Autor-/Committerheader des neuen unveränderlichen Commitobjekts. Native Hooks
können die Nachricht ändern; bei Abweichung wird nichts still zurückgesetzt oder
überschrieben, sondern der äußere Commit vor Ref-Veröffentlichung verweigert.

Seit Vorschau gehaltene Root-/Gitdir-/Common-/HEAD-/Ref-/Packedref-Deskriptoren,
Identitäten, Zeitstempel und Inhaltsfingerprints erkennen native Branch-/Ref-ABA
auch bei gleicher endgültiger OID. Dazu kommen Config-/Hookfingerprints und die
commonDir-Lease für koordinierte Fastra-Vorgänge. Keine zweite Guardtransaktion
und keine eigenen Ref-/Reflog-/Lockdateien ersetzen Gits native Transaktion.
Fehlender, geänderter oder nicht ausführbarer eigener Referenzvalidator wird
vor dem Commit abgewiesen. Eine Markierungsdatei überspringt die Hauptprüfung nie.

## Signierung, Abbruch und tatsächlicher Zustand

Native Signierung bleibt durch Git konfiguriert. Autor und Committer einschließlich
Datum sind die gezeigten gebundenen Werte. Konfigurierte persönliche Signierschlüssel
werden weder von Fastra gelesen noch angezeigt; die native Git-/Signerwahl bleibt
wirksam. Der Signerfehler ist ein echter Fehler. Erfolgreiche native SSH-Signierung
mit anschließendem git verify-commit ist separat an privatem Testschlüssel belegt.

Git läuft mit begrenzter Ausgabe und Frist auf einem Worker. Akzeptiertes stderr
erscheint live; der Abschluss enthält die akzeptierte stdout-/stderr-Ausgabe.
Originalhook und normale Kinder bleiben im besessenen Gitverband. Helper und
Originalhook besitzen Parent-Loss-Bindung mit Raceprüfung; bei tatsächlichem
Gitverlust beendet der Helper den durch seine Mitgliedschaft noch reservierten
Vorgangsverband. Regulärer Nutzerabbruch verwendet die Runner-Grace.
Diese Aussage ist kein allgemeines Orphanfreiheitsversprechen für absichtlich
daemonisierende oder sich entziehende Fremdprogramme.

Nach Erfolg, Fehler oder Abbruch werden tatsächlicher HEAD, Status sowie volle
Index-/Arbeitsdiffs mit frischem Abbruchtoken gelesen. Native Hook-Nebeneffekte
und bereits erfolgte Veröffentlichungen werden nicht zurückgerollt. Originalhooks
sind beliebiger Code mit Nutzerrechten; direkte zusätzliche Datei-/Index-/Ref-
Änderungen durch solche Programme sind keine durch Fastra isolierte Sandbox.
Die App selbst kopiert niemals den privaten Index zurück.

Offene Gitansichten werden aktualisiert. Passende Dokumente laufen durch den
vorhandenen geschützten Watcher-/Reloadpfad; Dirty-Puffer bleiben erhalten.
Source-Dateiänderungen durch einen verweigerten Hook bleiben sichtbar, ohne
Editorinhalt automatisch zu überschreiben. Vor weiterem Commit ist eine neue
Basis, Vorschau und Zustimmung nötig.

## Umfang und Grenzen

Git 2.43 oder neuer und das Files-Refbackend sind erforderlich. SHA-1, SHA-256,
Initial-, Detached- und normale Mergecommits sind geprüft. Indirekte symbolische
Branchaliases, Cherry-Pick-/Revert-/Rebase-Sequenzen und Reftable sind ausdrücklich
nicht freigegeben. Git kann redundante Mergeparents anders normalisieren; eine
abweichende tatsächliche Parentliste wird verweigert und nicht still angepasst.
Konflikte oder unlesbare/missing Objekte liefern native Fehler. Kein Lazy Fetch,
Pull, Push oder anderer automatischer Netzwerkvorgang entsteht.

Der Index ist auf 32 MiB begrenzt, kopierte Shared-Indizes auf 64 MiB/64 Dateien,
Hookverzeichnis auf 256 Einträge und 4 MiB ausführbaren Inhalt, einzelne Hooks
auf 1 MiB. Nachricht: gültiges UTF-8 ohne NUL bis 128 KiB; ein abschließender LF
wird in der Vorschau ausdrücklich gezeigt. Der serialisierte gebundene Kontext
besitzt zusätzlich 512 KiB Grenze. Zu große Kontexte werden vor Git abgewiesen.
Vorschauausgaben sind insgesamt begrenzt; es gibt keine gekürzte freigebbare
Vorschau. Git-/Hookfehler und weitergehende Native-Git-Grenzen bleiben sichtbar.

## Unterschied zum Mac

GitActions.swift gitCommitAll (184ff) führt add -A vor Commit aus; gitCommit
(383ff) tut dies, wenn nichts bereitgestellt ist. Dieser Port übernimmt diesen
Fallback bewusst nicht: Der bestätigte Vollindex und späteres paralleles Staging
bleiben unabhängig. Die Nachricht wird vollständig gezeigt; Originalhooks dürfen
sie nicht nachträglich unbemerkt in einem veröffentlichten Commit verändern.
Amend und weitere Commitvarianten sind nicht Teil dieses Pakets.
