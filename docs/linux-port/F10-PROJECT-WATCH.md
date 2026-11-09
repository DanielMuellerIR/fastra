# Projektbaum und externe Änderungen im Linux-Host

## Umgesetzter erster Meilenstein

Das sichtbare Tools-Menü öffnet ein eigenes natives GTK-Projektfenster. Ein
lokaler Ordner ist ein Projekt; Git ist keine Voraussetzung. Verzeichnisse lassen
sich per Klick ein-/ausklappen, versteckte Einträge sind ausdrücklich zuschaltbar,
ein sichtbarer Textfilter begrenzt die angezeigten relativen Pfade. Die Reihenfolge
ist Verzeichnisse zuerst, dann rohe Unix-Bytes; eine Gleichheit mit der lokalen
Mac-Sortierung wird nicht behauptet. Die angezeigten Labels sind keine Pfadquelle:
PathBuf behält auch ungültige UTF-8-Bytes, Steuerzeichen werden sichtbar maskiert.

Der Scan läuft auf einem Worker mit gehaltenen Verzeichnisdeskriptoren und
O_NOFOLLOW/openat für Unterverzeichnisse. Symlinks und Spezialdateien sind sichtbar,
aber nicht anklickbar. Grenzen: 4.000 Einträge, 32 Ebenen, 1 MiB Dateinamen und
zwei Sekunden kooperatives Rechenbudget. Ein Grenzfehler zeigt keinen scheinbar
vollständigen Teilbaum. Bis zu 32 unlesbare Unterverzeichnisse erscheinen mit ihren
Fehlern; weitere Fehler brechen den Scan ab. Die automatische Aktualisierung läuft
alle drei Sekunden; ein zweiter Scan wird nicht parallel gestartet. Abbruch,
Wurzel- oder Filterwechsel invalidieren ausstehende Ergebnisse. „Abbrechen“
pausiert weitere Scans bis „Aktualisieren“ oder einer neuen Wurzel-/Filterwahl.

Ein Dateiklick benutzt den bestehenden asynchronen Dokumentlader mit einem
optionalen Worker-Validator. Nach dem stabilen Laden müssen Projektwurzel,
gescannte Dateimetadaten und geladene Dateiidentität noch passen. Unmittelbar vor
der Tab-Erzeugung prüft der vorhandene Besitzer-Guard die Projektgeneration und
ob das Projektfenster noch offen ist. Es gibt keine Dateisystemprüfung im GTK-Guard.
Abschnitts-/Hex-Entscheidung, Kodierung, BOM und Snapshot stammen weiter aus dem
Dokumentbackend. Dateien werden durch den Projektbaum nicht verändert.

## Externe Änderungen

Gespeicherte editierbare Textdokumente erhalten beim Laden oder ersten
erfolgreichen Speichern einen Watcher. Nur das aktive
Dokument wird alle zwei Sekunden im Hintergrund geprüft. Device, Inode, Größe,
mtime und ctime einschließlich Nanosekunden vermeiden wiederholte Voll-Lektüren.
Bei Änderung liest das bestehende Dokumentbackend einen stabilen Snapshot mit der
gewählten Kodierung; maximal ein solcher Worker läuft je Dokument.

Ein dauerhafter Hinweis erhält sowohl saubere als auch schmutzige Editorinhalte.
Es gibt keinen automatischen Reload. Die Schaltfläche zur Prüfung zeigt den
vollständigen alten und neuen Text, Quellpfad, Kodierung/BOM und einen gesonderten
Freigabehaken. Die vollständige Vorschau ist auf je 4 MiB begrenzt. Vor dem Reload
werden Quelle, aktives Dokument, Originalsnapshot, Revision und Vorschaugeneration
erneut geprüft. Ein geschlossenes Vorschaufenster hebt eine laufende Freigabe auf.
Die Übernahme ist eine Undo-Aktion; neuer Originaltext, Codec und Snapshot werden
gemeinsam übernommen. Ein späteres Save bleibt an diesen Snapshot gebunden.

„Editor behalten“ ersetzt weder Text noch Originalsnapshot. Ein Save gegen eine
extern geänderte Basis scheitert weiter sicher. Fehlende/umbenannte Quellen
werden sichtbar gemeldet; der Watcher folgt keiner erratenen Rename-Zieladresse.
Eine namensgleiche fremde Datei wird niemals still als neue Basis übernommen.
Sie kann nur nach vollständiger sichtbarer Vorschau ausdrücklich neu geladen
werden. Abschnitts-/Hex-Ansichten werden durch diesen Watcher nicht verändert.

## Ausgeführte Prüfungen

Sieben Host-Unitprüfungen, Clippy mit allen Targets und `-D warnings`, Build und
Formatprüfung bestanden. Drei neue Projektprüfungen belegen rohe Pfade, versteckte
Einträge, verweigerte Symlinks, Abbruch, Baumgrenze sowie den Austausch einer Datei
oder der gesamten Projektwurzel vor der Tab-Validierung.

Acht echte GTK-Läufe auf Deutsch/Englisch bei 640/1080 Pixeln bestanden in privaten
Xvfb-/DBus-Sitzungen. Der Projektlauf klickt tatsächliche Baumzeilen, filtert,
klappt Verzeichnisse, schaltet versteckte Dateien ein und verwirft einen
asynchronen Öffnungsauftrag nach Generationswechsel. Der Watcher-Lauf prüft:

- Sauberes Dokument bleibt bis zur Freigabe unverändert.
- Geschlossene Freigabe verhindert einen noch laufenden Reload.
- Tatsächlicher Reload erhält CRLF/Unicode und lässt sich einmal rückgängig machen.
- Dirty-Text bleibt nach „Behalten“, neuer Editorrevision und weiterer externer
  Änderung unverändert; veraltete Vorschauen werden verweigert.
- Rename und namensgleiche fremde Ersatzdatei binden keinen Snapshot still um.

Alle acht Aufnahmen wurden bei beiden Breiten visuell geprüft. Zusätzliche gezielte Läufe prüfen Scan-Abbruch/Fortsetzen sowie denselben
Watcher-Ablauf mit UTF-16LE und BOM. Die Testdaten sind
synthetisch; das echte Arbeitsrepository wurde nicht als Fixture benutzt.

## Grenzen und nächste Schritte

Dies ist kein FSEvents-/Inotify-Paritätsnachweis. Die Erkennung nutzt begrenztes
Polling, keine Ereigniszählung. Automatischer Reload, Rename-Verfolgung über
Dateideskriptoren, Abschnitts-/Hex-Watcher und
Dateibaum-Schreibaktionen sind nicht enthalten. Langsame Kernel-Dateisystemaufrufe
lassen sich durch das kooperative Scanbudget nicht hart unterbrechen.
Sitzungssicherung und Wiederherstellung sind getrennt in [F10-SESSION.md](F10-SESSION.md) beschrieben.

## Wiederverwendbares Projektfenster und Projektsuche

Je Hauptfenster bleibt derselbe Projektbaum verfügbar. Schließen blendet ihn aus;
Wurzel, Filter und eingeklappte Verzeichnisse bleiben im laufenden Fenster
erhalten. Ausblenden stoppt Scans und verwirft ausstehende Dateiöffnungen.
Erneutes Öffnen startet das begrenzte Polling wieder. Dies speichert keine
Projektliste oder Baumansicht über einen App-Neustart.

„Projekt durchsuchen“ sowie der sichtbare Hauptbereich „Projekt“ öffnen die
bestehende vollständige FolderPreview mit ausdrücklich gebundener Projektwurzel.
Die Wurzelanzeige ist dort schreibgeschützt; ein anderes Projekt wird im Baum
gewählt. Ohne vollständig eingelesene Auswahl wird stattdessen die Projektwahl
geöffnet. Baumfilter betreffen nur die Darstellung, nicht den Suchumfang.
Ausschlüsse, bekannte Textformate und der sichtbare Ausschluss versteckter Dateien
folgen der vorhandenen Ordnersuche.

Die unveränderliche Projektbindung enthält den kanonischen rohen Rootpfad,
Device/Inode und eine eigene Projektgeneration. Filter, Tabwechsel und
Baumaufklappen ändern diese Generation nicht. Wurzelwechsel und ersetzte oder
unlesbare Wurzeln invalidieren alte Bindungen und brechen aktive Projektworker
über deren tatsächlichen Cancellation-Token ab. Vor/nach der Vorschau und vor
Apply prüft ein Worker die Wurzelidentität. UI-Callbacks prüfen nur den Besitzer
und die Generation; sie führen keine Dateisystemabfragen aus. Alte Apply-Aktionen
werden verweigert. Eine bereits begonnene Transaktion behält ihre ursprünglichen
Ziele und ihre Recovery-/Undo-Daten. Die bestehende vollständige Snapshotprüfung
bleibt auch für wirkungslose Eingaben erhalten.

Der gewöhnliche Ordnerwähler behält ebenfalls den rohen PathBuf. Maskierte
Anzeigepfade werden weder dort noch im Projektbereich als Dateipfade geparst.
Rohe Dateinamen und aktive Unicode-Ausschlussregeln behandelt das Suchbackend;
dieses UI-Paket verändert dessen Semantik nicht.

Vier private echte GTK-Läufe DE/EN bei 760/1080 Pixeln prüften denselben Baum nach
Hide/Reopen, Filter/Expansion, gestopptes/neugestartetes Polling, verweigertes
asynchrones Öffnen aus einem ausgeblendeten Baum, den sichtbaren Projektbutton,
Nicht-UTF8-Wurzeln, stabile Vorschauen nach Tabwechsel, Projektwechsel mit
gebundenem Abbruch und verweigertem altem Apply. Neues Projekt-Apply/Undo erhielt
BOM, CRLF und Unicode; der Austausch der Wurzel erzeugte keine verwendbare
Vorschau und veränderte keine fremde Ersatzdatei. Baum und vollständige
Projektvorschau wurden in beiden Sprachen und Breiten visuell geprüft. Alle
Dateien waren synthetisch und alle XDG-Zustände privat.

Der konkrete Merge mit dem zweiphasigen Ordner-Apply hält die Projekt-Cancellation
über Planung und Schreibphase. Ein Projektwechsel nach Planungsdispatch und vor
der Completion verweigerte jeden Schreibstart. Eine wirkungslose freigegebene
Ersetzung durchlief die volle Snapshotprüfung und meldete „Keine wirksame
Ersetzung; keine Datei geschrieben“. Der Hauptfensterbereich „Projekt“ wurde
zusätzlich über den tatsächlichen Vorschauknopf in DE/EN und beiden Breiten
geöffnet; seine Geometrie wurde ebenfalls visuell geprüft.
