# F11: Lokaler Branchwechsel

Ein normaler lokaler Branchwechsel ist ausdrücklich als Git-CLI-Vertrag mit
zusätzlicher Vorschau, Bestätigung und anschließender Zustandsprüfung freigegeben.
Die separate lokale Brancherstellung bleibt ein Vorgang ohne Checkout. Löschen,
Force, Reset, Stash, Commit und Netzwerkaktionen gehören nicht zu diesem Paket.

## Mac-Verhalten und zusätzliche Vorschau

`GitActions.swift` (`gitSwitchBranch`, Zeilen 1434–1477 der gelesenen Basis)
verwendet normales `git switch <Name>` und überlässt Git die Dirty-Prüfung. Eine
pauschale Clean-Pflicht oder vollständige Diffbestätigung gibt es dort nicht.
`GitValidatedMutationRunner` in `GitAdvancedCore.swift` bindet Inspektion und
Fastra-internen Slot, stellt aber keine externe HEAD-/Indextransaktion bereit.
`GitActionContext` bindet Repository und Projektgeneration. Workspace-Reloads
schützen Dokument-ID, Pfad, Ladegeneration, Inhaltsrevision und Plattenbasis.

Die native Ansicht zeigt Repositorybasis, vollständige Quell-/Ziel-Commit-OIDs,
lokalen Zielref, vollständigen binären Commitpatch, Status sowie vollständige
Index- und Arbeitsdiffs. Zielauswahl, Dokument-/Fensterbesitzer, Revision, Pfad,
Speicherzustand oder Projektgeneration entwerten Vorschau und Zustimmung.
Die ausdrückliche Zustimmung wird vor Start verbraucht. Ein erneuter Versuch
benötigt eine neue Vorschau und Zustimmung.

Die Vorprüfung vergleicht erneut HEAD/Branch, Ziel-OID, Status, Indexbytes,
Datei-/Verzeichnisbindungen und Konfiguration. Dateibindungen verwenden die
vorhandenen gehaltenen Deskriptoren der Indexvorschau; Symlinks und Spezialdateien
werden nicht versehentlich als reguläre Dateien verfolgt. Die gemeinsame
commonDir-Lease koordiniert Fastra-Fetch, Index-, Branch- und Wechselvorgänge,
auch bei Linked Worktrees. Repository-/Gitdir-/commonDir-Austausch wird geprüft.
Die UI invalidiert Besitzer synchron und unwiderruflich, auch bei einem Wechsel
weg und zurück zwischen zwei Mainloop-Durchläufen.

Der gestartete Befehl ist:

```text
git -c color.ui=false -c core.fsmonitor=false switch \
    --no-guess --no-overwrite-ignore --no-recurse-submodules -- <lokaler Name>
```

Keine Shell verarbeitet Pfade oder Ref-Namen. Es gibt weder Force noch Merge,
Reset, Stash, automatisches Tracking oder Remote-Guessing. Native Git-Schutzregeln
für konkurrierende Worktrees, Konflikte und lokale Änderungen bleiben aktiv.
Zusätzlich schützt `--no-overwrite-ignore` vorhandene ignorierte Dateien.
Es erfolgt kein rekursives Submodule-Update und kein Lazy Fetch. Nicht unterstützte
CLI-Optionen ergeben einen echten sichtbaren Gitfehler, keinen schwächeren Ersatz.

## Bewusst freigegebene externe Racegrenze

Die Vorschau beschreibt die bestätigten Commitunterschiede und vorhandenen lokalen
Änderungen. Sie ist keine atomare Zusage des späteren gesamten Dateizustands.
Ein anderes Git kann nach der letzten Prüfung oder während des normalen Switches
HEAD, Zielref, Index, Dateien oder Konfiguration ändern. Git kann dann auf einen
anderen Zwischenstand reagieren. Die Fastra-Lease schützt ausschließlich gegen
andere koordinierte Fastra-Aufträge; fremde Locks werden niemals entfernt.

Git konvertiert Dateien nach seinen normalen Attributen und Filtern. Native
Checkout-/Referenzhooks werden weder deaktiviert noch ersetzt. Sie können zusätzliche
Dateien oder Refs ändern, eigene Prozesse starten und Fehler liefern. Die gebundene
Konfigurationsliste entdeckt vorherige Konfigurationsdrift; ausführbare Hook- oder
Filterdateien und spätere Drift sind keine atomar eingefrorene Basis. Die gesetzten
Git-Protokoll-/Promptgrenzen sind keine Sandbox für vom Nutzer installierte Hooks.
Es wird keine stärkere Hook-/Checkouttransaktion oder Hookparitätsgarantie behauptet.

Schon ein fehlgeschlagener Wechsel kann Arbeitsdateien und Index verändert haben,
während HEAD noch auf der Quelle steht. Insbesondere schützt eine fremde HEAD.lock
nicht vor früheren Dateischreibvorgängen. Abbruch oder Timeout bedeutet ebenfalls
kein Rollback. Die Vorschau darf deshalb nicht durch eine eigene vorgeschaltete
HEAD-Sperre, Force oder eine selbstgeschriebene Checkoutengine ergänzt werden.

## Nachprüfung und offene Dokumente

Nach jedem Ausführungsversuch, auch nach Fehler oder Abbruch, werden mit einem
frischen Abbruchtoken tatsächlicher HEAD/Branch, Status und vollständige Index-/
Arbeitsdiffs gelesen. Die Lease bleibt bis danach gehalten. Ergebnis und gelesener
Zustand stehen getrennt im Dialog. Eine erfolgreiche CLI-Rückkehr gilt erst mit
passendem tatsächlichem Zielref und vollständiger Ziel-OID als bestätigtes Ziel.
Eine scheiternde Zustandsprüfung wird als Fehler gezeigt; sie ersetzt keine Daten
durch Annahmen. Die Nachprüfung bleibt eine endliche Folge normaler Git-Leseaufrufe,
kein über externe Prozesse atomarer Gesamtsnapshot.

Alle passenden offenen Gitansichten werden zum Aktualisieren benachrichtigt.
Offene Textdokumente werden über den vorhandenen Watcher erneut geprüft, auch
inaktive Tabs. Ein schon laufender Watcher-Read wird verworfen und erneut gelesen.
Fastra ersetzt keinen sauberen oder ungespeicherten Textpuffer automatisch.
Der vorhandene Reload-Dialog zeigt Editor und Datei nebeneinander und verlangt
eine eigene ausdrückliche, revisions-/pfad-/snapshotgebundene Zustimmung.
Bei zwischenzeitlichem Tippen bleibt der Editor unverändert. Fehlende oder
unlesbare Quellen behalten den Editor; kein neuer Pfad wird automatisch eingesetzt.
Abschnitts-, Hex- und Bild-/PDFansichten behalten ihre gebundene bisherige Fassung;
laufende Reads werden entwertet und ein Hinweis verlangt das erneute Öffnen.
Bestehende Hexentwürfe bleiben erhalten.

Git läuft ausschließlich auf Workern über den vorhandenen Prozessrunner:
Prozessgruppenbesitz, Parent-Loss-Abbruch, Timeout und begrenzte Ausgabe.
Akzeptierte stderr-Bytes erscheinen live; der tatsächliche Abschluss enthält die
vollständig akzeptierte Ausgabe. Der Dialog fordert bei weiteren Versuchen ein
Neuladen und neue Zustimmung.

## Grenzen und Prüfung

Die Ansicht begrenzt einen Vorschau-/Prüfblock insgesamt auf 4 MiB stdout und
128 KiB stderr, 30 Sekunden, maximal 128 betroffene oder dirty/untracked Pfade,
32 MiB je regulärer Datei/Index und 64 MiB Arbeitsdateien. Der abschließende
Zustandsscan hat eine eigene endliche Frist; Abbruch kann deshalb noch kurz auf
diesen Scan warten. Bei Überschreitung gibt es keine gekürzte freigebbare Vorschau.
Ungeborener HEAD, betroffene Verzeichnis-/Submodule-/Spezialdateipfade oder
unsichere Vorfahren werden ausdrücklich abgewiesen. SHA-1, SHA-256 und ein
losgelöster vorhandener Quell-HEAD werden unterstützt.

Die gezielten Tests verwenden ausschließlich temporäre lokale Repositories.
Sie prüfen normalen Wechsel, erhaltenes nicht kollidierendes Staging/Dirty,
kollidierende Dirty- und ignorierte Dateien, Quell-/Ziel-/Index-/Datei-/Configdrift,
Repoaustausch/commonDir-Lease, Linked Worktrees, losgelösten HEAD, SHA-256,
Hookfehler, Liveabbruch, Timeout, Ausgabegrenze und fremde HEAD.lock mit bereits
veränderten Dateien/Index. Ein eigener Versuch verschiebt den Zielref erst nach
der Vorprüfung und belegt ausdrücklich die nicht atomare Grenze sowie die danach
abweichende tatsächliche OID. Native DE/EN-Fensterflüsse prüfen Auswahl, vollständige
Vorschau, verbrauchte Zustimmung, Owner-ABA, erhaltenen ungespeicherten Editor,
veraltete Reloadzustimmung, anschließenden ausdrücklichen Reload, Teilfehler und
Liveabbruch bei Mindestbreite und breitem Fenster. Konkrete Laufbelege liegen im
separaten Integrationshandoff.
