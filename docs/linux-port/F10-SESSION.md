# Lokale Textsitzungen im Linux-Host

## Zweck und sichtbarer Ablauf

Die native Hauptansicht bietet eine lokale Sitzungssicherung für editierbare
Texttabs und vollständige schreibgeschützte Quelltext-Tabs, „Jetzt sichern“ und „Wiederherstellung“. Die Textsicherung ist standardmäßig
ausgeschaltet. Erst das ausdrückliche Aktivieren für dieses Fenster sichert auch
ungesicherte Inhalte lokal und unverschlüsselt; der Hinweis bleibt sichtbar.
Vorhandene Kopien können unabhängig davon ausdrücklich geöffnet oder gelöscht werden. Abschnitts-/Hex-Tabs sind
sichtbar ausgenommen. Die Funktion ersetzt weder Speichern noch die gesonderte
Dateitransaktions-Recovery. Quelldateien werden durch die Sicherung und
Wiederherstellung nicht beschrieben.

Eine Wiederherstellung zeigt sämtliche gesicherten bearbeitbaren Editorinhalte in eigenen
Notebook-Seiten mit Quellpfad, Dirty-Zustand, Kodierung und BOM. Erst ein
Freigabehaken aktiviert „Wiederherstellen“. Die Dokumente werden als neue Tabs
hinzugefügt. Tabwechsel, neue Suchgeneration oder ein geschlossenes
Freigabefenster verwerfen ausstehende Ergebnisse; vorhandene Tabs bleiben erhalten.
Der erste frühere aktive Tab wird gewählt und die Fenstergröße auf den aktuellen
Monitor begrenzt. Mehrere frühere Fenster werden in einem Fenster angeboten.

Beim Schließen mit Dirty-Text gibt es getrennte Entscheidungen: Abbrechen,
mit Wiederherstellung schließen oder verwerfen und schließen. Der letzte
Editorstand wird für die erste Variante dauerhaft gesichert, bevor das Fenster
schließt. Verwerfen schreibt die Originaltexte statt der Dirty-Texte; ungebundene
Dokumente werden aus dieser Schließkopie entfernt. Doppelte Schließdialoge und
nachträgliche Autosaves während des endgültigen Schließens sind gesperrt.

## Daten und Sicherheitsgrenze

Jedes Fenster besitzt eine eigene Datei unter `$XDG_STATE_HOME/fastra`, mit
Rückfall auf `$HOME/.local/state/fastra`. Das verwaltete Verzeichnis muss dem
aktuellen Benutzer gehören und Modus 0700 besitzen; Die Inhalte liegen lokal und unverschlüsselt vor.
Dateien müssen regulär,
einfach verlinkt, im eigenen Besitz und Modus 0600 sein. O_NOFOLLOW/O_NONBLOCK,
gehaltene Verzeichnisdeskriptoren, fd-relative Namen und ein Wurzelvergleich
verhindern das Folgen ausgetauschter Links und Spezialdateien.

Ein exklusives flock pro Datei trennt laufende von beendeten Sitzungen. Lebende
Fenster werden nicht als Crashsitzung übernommen. JSON wird in einer exklusiv
angelegten temporären Datei vollständig geschrieben und fsync-bestätigt, atomar
umbenannt und mit Verzeichnis-fsync abgeschlossen. Ein Fehler erhält die vorige
Kopie. Alte Wiederherstellungsdateien werden erst nach dauerhafter Übernahme in
die neue Sitzung entfernt. Ihre ausdrückliche Löschung besitzt eine eigene
Bestätigung und betrifft keine Quelldateien oder bereits offenen Tabs.

Gespeichert werden rohe Pfadbytes, aktuelle Editorinhalte, unveränderte
Originalbytes und deren Codec/BOM sowie eine Bindung an den Originalsnapshot.
Eine frische Datei wird nur dann als Speicherbasis übernommen, wenn die
vollständige gespeicherte Snapshotbindung noch übereinstimmt. Geänderte, fehlende
oder nicht mehr eindeutig gebundene Quellen erzeugen ungebundene Dirty-Tabs.
Deren Originalbytes und frühere Quellbindung bleiben auch in einer weiteren
Sitzungssicherung erhalten. Speichern öffnet dann den bestehenden sicheren
Neudatei-Dialog; die fremde Quelldatei wird nicht zum stillen Überschreibziel.

## Grenzen und Fehler

Pro angebotener Wiederherstellung gelten insgesamt 32 bearbeitbare und schreibgeschützte Textdokumente. Für bearbeitbare Inhalte gelten je 4 MiB Editortext
und Originalbytes sowie 8 MiB gemeinsame Nutzdaten. JSON ist auf 64 MiB begrenzt,
der private Ordner auf 256 Einträge und die Sammlung auf 16 inaktive Dateien.
Unbekannte Schemafelder, ungültige Codecs, NUL, ungültige Pfade, harte Links,
fehlende Rechte oder überschrittene Grenzen sind sichtbare Fehler. Es wird keine
unvollständige Sicherung als vollständig angeboten.

Bei aktivierter Textsicherung löst eine Änderung nach spätestens dem nächsten Ein-Sekunden-Takt eine neue
Hintergrundsicherung aus. Bei abruptem Prozessende oder Stromausfall können
noch nicht dauerhaft bestätigte letzte Eingaben fehlen. Bewusstes Schließen
mit Wiederherstellung wartet auf die bestätigte letzte Kopie. Fehler lassen das
Fenster offen; „Jetzt sichern“ erlaubt einen neuen Versuch. Der Schalter gilt für das aktuelle Fenster. Deaktivieren stoppt
neue automatische Sicherungen; vorhandene und bereits begonnene Kopien bleiben
bis zur ausdrücklichen Löschung erhalten.

Unsichtbare, weiterhin registrierte Hauptfenster starten keine neue Sicherung
und erzeugen keine Restore-Tabs. Dokumentinhalt, Codec und gespeicherte
Originalbasis werden nicht allein durch einen aktuellen Plattenstand ersetzt.

## Rich-Editor-Abgleich

Vor jedem Capture gleicht der Host sämtliche Rich-Editoren über ihre eigene
Dokumentbindung ab. Erst nach erfolgreichem `flush_all_owned` wird synchron auf
GtkMain der unveränderliche Text-/Codec-/Originalsnapshot erfasst. Die JS-Fence
bleibt bis zum Ende des Capture bestehen. Beim Schließen sperrt das Fenster
Eingaben bis zum bestätigten atomaren Schreiben. Ein fehlgeschlagener Abgleich
oder eine inzwischen geänderte Editorzusammensetzung verhindert Capture und
Schließen; der sichtbare Rich-Entwurf bleibt erhalten. Ein alter Quellpuffer wird
nicht als aktueller Rich-Stand gesichert.

## Noch nicht enthalten

Projektbaumzustand, Abschnitts-/Hex-Tabs, Auswahl-/Scrollpositionen und die
ursprüngliche Aufteilung mehrerer Fenster werden nicht rekonstruiert.
Systemweite Recovery-Verwaltung und Produktparität zum Mac sind nicht behauptet.

## Ausgeführte Source-Prüfungen

Clippy mit allen Targets und `-D warnings`, 13 Hosttests, Debug-Build,
Release-Compilecheck und Formatprüfung bestanden. Sechs neue Sessiontests prüfen
Originalbytes/BOM/rohe Pfade, Inodewechsel und fehlende Quellen, Rechte, mtime,
Xattrs, Elternidentität, private Dateimodi, Symlinks/Hardlinks/FIFOs, Grenzen und
Erhalt der vorherigen Kopie. Ein fehlender älterer Bindungstoken fällt konservativ
auf eine ungebundene Wiederherstellung zurück.

Vier echte Prozessfolgen DE/EN bei 640/1080 Pixeln prüften eigenen SIGKILL nach
bestätigtem fsync und danach einen frischen GTK-Prozess mit geänderter Quelle.
Alle vollständigen Texte, Originaltoken und BOM blieben erhalten; veraltete und
geschlossene Freigaben erzeugten keine Tabs. Der beim Schließen zuletzt
eingegebene Text wurde erst im Close-Flush gesichert. Ein explizites Discard
schloss ihn aus der dauerhaften Kopie aus. Weitere frische Prozesse prüften
unveränderte Quellen mit korrekter Snapshotbindung, Discard mit erhaltener
Originaldatei sowie die ausdrücklich bestätigte Löschung ausschließlich inaktiver
Backups. Ein tatsächlicher Rechtefehler und der sichtbare Retry-Knopf sowie eine
Basisbestätigung ohne Texteingabe während eines laufenden Backups bestanden.

Die Fenster und Fehlermeldungen wurden in privaten Xvfb-/DBus-Sitzungen visuell
geprüft. Alle Runner setzten CONFIG/DATA/CACHE/STATE auf eigene Testverzeichnisse;
nur die beabsichtigte Producer-/Reopen-Folge teilte ihren privaten STATE-Pfad.
Sämtliche Quellen waren synthetisch. Diese Source-Prüfungen enthalten Rich-Flush
und Journalindex nicht; die Folgeprüfungen sind separat beschrieben.

## Folgeprüfung: Opt-in und Rich-Fence

Nach dem Source-Handoff bestanden Clippy aller Targets, 24 Hosttests (ein
umgebungsgebundener Viewer-Test bleibt ausdrücklich ausgenommen) und der
echte GTK-/WebKit-Lauf: Standardmäßig ausgeschaltete Sicherung erzeugt auch
mit Dirty-Text keine Sitzungs-JSON. Eine stille DOM-Änderung ohne input-Ereignis
erscheint erst nach dem Rich-Abgleich in der bestätigten Kopie; auch die letzte
weitere DOM-Änderung vor Close bleibt enthalten. Bei absichtlich fehlerhaftem
prepareAction bleibt das Fenster mit sichtbarem Entwurf offen, die vorige
JSON ist bytegleich und die Quelldatei unverändert. DE-Fehlerzustand sowie
DE/EN-Opt-in-Hinweis wurden visuell in privaten Displays geprüft.

## Dateitransaktionsindex

Optional enthält derselbe private Record bis zu 64 eindeutige absolute rohe
Journalpfade, je höchstens 4096 Byte ohne NUL. Alte Records ohne Feld bleiben
lesbar. „Dateitransaktionen“ bietet eine ausdrückliche Auswahl; sie öffnet
ausschließlich `recovery::open_path` mit dem gehaltenen PathBuf. Escape-Anzeigen
werden niemals zurück in Pfade konvertiert. Fehlende oder fremd geänderte
Journale durchlaufen die vorhandene vollständige Recovery-Prüfung. Es gibt
keine automatische Rücknahme, Bereinigung oder Quelländerung.

`session::remember_journal(ui, path)` registriert den Index,
`session::forget_journal(ui, path)` entfernt ihn nach verifizierter Bereinigung.
Auch bei ausgeschalteter Textsicherung wird ausschließlich Metadaten-JSON
geschrieben: Bereits bestätigte Dokumentrecords bleiben erhalten; aktuelle
Puffer werden nicht erfasst. Indexänderungen werden atomar im Hintergrund
bestätigt. Close wartet bei ausstehendem Index und setzt anschließend den
normalen Source-/Rich-Closepfad fort. Fehler bleiben sichtbar und erlauben
Retry. Die Einzeldateien sind atomar, die Änderung mehrerer inaktiver Records
ist keine gemeinsame Transaktion; eine Unterbrechung kann einen alten
Indexeintrag erneut anbieten, aber keine Dateirücknahme auslösen.

Der gezielte neue Store-Test prüft rohe Nicht-UTF8-Pfade, metadatenleere
Textlisten, Grenzen und Rückwärtskompatibilität. DE/EN folgten jeweils drei
frische GTK-Prozesse: realer synthetischer Transaktionsordner unter Nicht-UTF8-
Projektpfad bei Text-Opt-out, explizites Öffnen der vollständigen Recovery ohne
Autowrite, danach verifiziertes Undo/Discard und Indexentfernung. Der dritte
Start fand keinen bereinigten Altindex mehr. Aktuelle Dirty-Texte waren in
keinem Indexrecord enthalten.

Fehlende oder veraltete Einträge lassen sich mit „Eintrag vergessen …“ nach
eigener Bestätigung ausschließlich aus dem Index entfernen. Quelldateien und
Sicherungsordner bleiben erhalten. Der Auswahlbereich zeigt den asynchronen
Persistenzstatus und Fehler; „Jetzt sichern“ erlaubt einen neuen Versuch. Ein
echter Missing-Entry-/Fresh-Reopen-Lauf bestätigte den dauerhaft leeren Index.

Neue Fensterleases werden mit zufälligem UUID-Namen und O_EXCL angelegt, mit
höchstens acht Kollisionsversuchen. Bestehende JSON-Dateien werden nie als neue
Fensterrecords übernommen. Nach flock und vor Leasezugriffen muss der benannte
Lock noch dieselbe Geräte-/Inodebindung besitzen. Der begrenzte Hintergrundscan
entfernt leere verwaiste Locks nur bei exklusiv erworbenem flock; lebende Locks
bleiben erhalten. Gezielt geprüft wurden das Open-vor-flock-Cleanup-Fenster,
Lockersatz, Namenskollisionen mit/ohne Lock und 300 aufeinanderfolgende leere
Leases ohne Ansammlung. Andere lebende Fenster behalten ihre eigenen Records;
deren alter Index kann einen inzwischen fehlenden Pfad später erneut anbieten.
Dieser löst weiterhin ausschließlich eine explizite vollständige Prüfung aus.


## Schreibgeschützte Quelltextverweise ab 1.220.0

Vollständige schreibgeschützte Quelltexte werden getrennt als Dateipfad,
Kodierung und Tabposition gespeichert, ohne zwischengespeicherten Text oder
Schreibsnapshot. Solche Archive tragen Schema V2; bestehende V1-Archive bleiben
lesbar. Ohne Lese-Tabs bleibt das Format V1. Pfad- und Kodierungsgrenzen sowie
eindeutige Positionen gelten zusätzlich zum gemeinsamen Tablimit. Eine Sitzung
mit ausschließlich solchen Quellen darf nicht als leeres Archiv verschwinden.

Der Freigabedialog erklärt für jede Lesequelle, dass bei Zustimmung der aktuelle
Dateiinhalt erneut gelesen wird. Der Loader öffnet ausschließlich eine
`ReadOnlyTextDocument`-Grundlage und erwirbt auch bei inzwischen sicher
bearbeitbaren Dateien keine Schreibbasis. Kodierung und aktuelle BOM kommen
aus dem erneuten verlustfreien Lesen; gespeicherte Reihenfolge und aktiver Tab
bleiben erhalten. Es gelten die vollständigen Lesegrenzen aus dem
[Dokumentvertrag](F07-DOCUMENTS.md#sitzungsreferenzen-ab-12200).

Fehlende oder nicht mehr vollständig als Text lesbare Quellen werden einzeln
übersprungen und sichtbar gemeldet. Verfügbare Tabs und ungesicherte Entwürfe
werden trotzdem wiederhergestellt; die ursprünglichen Sicherungen bleiben für
eine neue ausdrückliche Prüfung erhalten. Ein erneuter vollständiger Versuch
kann weitere Kopien bereits wiederhergestellter Tabs öffnen. Nur eine
vollständig erfolgreiche Wiederherstellung darf das bisherige atomare
Verbrauchsverfahren starten. Abbruch stoppt den Lese-Worker; vor der Übernahme
bleiben Fenster- und Generationsprüfungen verbindlich.
