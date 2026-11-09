# F03/F08: Linux-Snapshots und Dateitransaktionen

Stand: 2026-11-04. `crates/fastra-io` implementiert den Linux-Schreibpfad für
reguläre Einzeldateien sowie mehrere Dateien auf demselben ext4-/Btrfs-Dateisystem.
Die ursprüngliche Primitive-Probe bleibt unter F03-SAFETY dokumentiert.

Ein Snapshot hält Originalbytes, Verzeichnis- und Dateiidentität, Größe,
Änderungszeit, Modus, Eigentümer/Gruppe, xattrs und SHA-256 zusammen. Öffnungen
sind verzeichnisrelativ und folgen keinen Symlinks; FIFOs blockieren nicht.
Hardlinks, besondere Modusbits, nicht erhaltbare Metadaten und andere
Dateisysteme werden abgewiesen. Der Host darf vor dem Laden einen bewusst
gewählten Symlink auflösen. Lesen und Schreiben gehören auf eine Hintergrundqueue.

## Vorschau und Apply

`Change::from_preview` dekodiert die gespeicherten Bytes streng und bindet die
Ersetzung an genau den vorhandenen Core-Preview mit Quelltext, Revision,
Suchgeneration und freigegebenen Trefferindizes. Re-Encoding erhält BOM,
Kodierung und bestehende Zeilenenden. Nicht darstellbare Ersetzungen scheitern
vor jedem Dateischreiben. Es gibt keine neue Suche beim Apply.

Für jedes geänderte Ziel werden in einem privaten Journalverzeichnis ein
Ersatz und eine unabhängige Kopie der Originalbytes angelegt und synchronisiert.
Ein versionierter, atomar publizierter Intent hält alle beteiligten Verzeichnisse
und Inodes fest. Erst danach folgt der letzte Preflight sämtlicher Eingaben,
einschließlich wirkungsloser Treffer. Dateien werden einzeln mit
`RENAME_EXCHANGE` getauscht; verdrängte Inodes bleiben erreichbar. Vor dem
Erfolgsmarker werden alle Ergebnisse und wirkungslosen Eingaben erneut geprüft.
Ein Mehrdatei-Vorgang ist **nicht global atomar**.

Abbruch nach begonnenem Tausch versucht ein überprüftes Undo. Bei fremden
Änderungen, Schreib-/Synchronisationsfehlern oder einem unklaren Zustand bleibt
das Journal erhalten und `RecoveryRequired` trägt seinen Ort. Es gibt keinen
ungeprüften Rücktausch. Nach einem Prozessabbruch unterscheidet `reopen`/`inspect`
Original, ersetzt und Konflikt anhand beider Namen und der Originalkopie.
Ein teilweise ausgeführtes Undo lässt sich erneut aufnehmen. Erst ein
verifiziertes Undo erlaubt `discard`; unbekannte Journaldateien werden erhalten.

## Dokument-Save

Ein ausdrückliches Einzeldatei-Speichern hat einen eigenen Intent-Zweck.
`saved_document_snapshot` liefert ausschließlich den exakt verifizierten
Ersatz-Inode als neue Editorbasis. Ein nachträglich untergeschobener Inode mit
identischen Bytes wird nicht still übernommen. Nur dieser Save-Zweck darf nach
Erfolg seine Sicherung über `finish_document_save` freigeben; eine
Suchtransaktion behält ihr Undo.

`save_new_document` publiziert ein neues Dokument atomar mit
`RENAME_NOREPLACE`. Ein belegter Name, Symlink oder FIFO wird niemals überschrieben.
Nach dem Publizieren wird eine Datei bei spätem Fehler nicht blind zurückgelöscht.

## Prüfbeleg und Grenzen

Die Suite prüft Byte-/Identitätserhalt, BOM/Kodierungen, Unicode, nicht-UTF-8-
Dateinamen, Modus und user-xattr, stale/no-op, Fremdänderungen, Kollisionsziele,
private Journale, Pfadescape und echte SIGKILL-Grenzen während Apply, Undo und
Manifestupdates. Die aktuelle Fassung mit 34 Unitfällen und sechs zusätzlichen
Snapshot-/Recovery-Belegtests bestand auf Btrfs und einem eigenen Kernel-ext4-Image.
Die Belege verweigern identische Bytes eines fremden Inodes und falsche
Transaktionsphasen. Beide ext4-Läufe bestätigten Unmount, Detach des eigenen
Loop-Geräts und Entfernung des eigenen Images.

Grenzen bleiben Stromausfalltests, ACL-/Security-xattr-Abnahme, Netz-/Wechselmedien,
Dateisystemgrenzen innerhalb einer Transaktion und gegen denselben Benutzer
gerichtete Namespace-Angriffe. Journale sind keine authentifizierten Fremddaten.
Die Adapterabnahme allein ersetzt weder sichtbare Vorschau noch Host-Dirty-
Prüfung oder vollständige native Desktop-Abnahme.

## Sichtbare Wiederaufnahme

Der Linux-Dialog „Dateisicherungen …“ öffnet einen eigenen Transaktionsordner.
`recovery_preview` bindet den unveränderten Intent, die Journalidentität und alle
angezeigten aktuellen/originalen Bytes an eine Freigabe. `undo_approved` prüft
sie unmittelbar vor Undo erneut. Auch wirkungslose und bereits zurückgestellte
Eingaben werden vor dem abschließenden Undone-Marker nochmals geprüft.
Manipulierte Größenangaben im Journal scheitern vor dem Lesen großer Quellen.

Die native Ansicht zeigt vollständige Texte oder begrenzte, vollständig
navigierbare Hex-Seiten. Explizite Zustimmung ist erst nach fertiger Darstellung
möglich. Dirty-, speichernde oder aktiv formatierte betroffene Editoren blockieren
die Wiederherstellung. Nach Erfolg erhalten saubere offene Texttabs ausschließlich
die exakt bestätigten Originalsnapshots. Das Entfernen der Sicherung benötigt
eine weitere Freigabe nach verifiziertem Undo; bei Fehlern bleibt sie erhalten.

Der echte private GTK-Lauf prüfte stale Freigabe, Dirty-Editor-Abweisung,
UTF-16LE/BOM, exakte Editoraktualisierung und ausdrücklich bestätigtes Aufräumen.
Die 34 Unit- und sechs Belegtests bestanden am 2026-11-05 erneut auf Btrfs und
ext4; beide eigenen ext4-Images wurden nach bestätigtem Aushängen und Loop-Detach
entfernt. Keine Stromausfall- oder echte Desktopabnahme wird daraus abgeleitet.

Der ausdrückliche Hex-Schalter macht auch bei kurzen lesbaren Textdateien
konkrete BOM-, Unicode- und Zeilenendbytes sichtbar. Ein Moduswechsel hebt die
Zustimmung auf und sperrt Wiederherstellung bis zur fertigen neuen Darstellung.
Die echte GUI-Prüfung enthält Hin- und Rückwechsel zwischen Text und Hex.
