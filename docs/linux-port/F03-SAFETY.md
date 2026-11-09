# F03: Sprachgrenze und Dateisicherheit

UniFFI 0.31.2 erzeugt die real kompilierten Swift-Bindings. Leere Daten, Unicode
und 1 MiB werden bytegleich zurückgegeben; ungültiges UTF-8, Abbruch und Panic
werden kontrolliert gemeldet. Ein Swift-Hintergrundaufruf wartet in Rust, ein
zweiter Aufruf bricht ihn tatsächlich ab. Das verschobene Bundle läuft ohne sein
ursprüngliches Buildverzeichnis. Die vorgeschaltete kleine C-Schnittstelle
bestätigt zusätzlich expliziten Rust-Speicherbesitz und Freigabe.

Empfehlung: eine kleine **werfende** UniFFI-API mit eigenen Fehlertypen und
explizitem Cancellation-Objekt weiterführen. Bei nicht werfenden Funktionen kann
UniFFI unerwartete Fehler zu einem nicht abfangbaren Swift-Fehler machen; das ist
in der [offiziellen Swift-Binding-Dokumentation](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html)
beschrieben. Die Probe enthält keine UI-Callbacks und keinen produktiven Core.

Der Linux-Dateiversuch ergänzt PMT um **RENAME_EXCHANGE**, statt seine bereits
bestandenen No-Replace-Versuche zu wiederholen. Auf Btrfs und ext4 bleiben nach
Tausch und Rücktausch beide Byteversionen und die verdrängte Inode erhalten.
Ein inzwischen fremdes Ziel ist nach dem Tausch erkennbar und wird zurückgestellt.
Ein FIFO wird ohne Blockieren per `fstat` erkannt. Der Kernel tauscht sogar einen
Symlink als Namen aus: Er ersetzt also die vor-/nachgelagerte Typ- und
Identitätsprüfung nicht. Der geprüfte Modus 0640 bleibt erhalten; das ist kein
vollständiger ACL-/xattr-Nachweis.

Nach SIGKILL unmittelbar nach dem Tausch liegen neue Bytes am Ziel und alte am
Vorbereitungsnamen. Beide sind erreichbar; **es gibt keinen automatischen
Rollback**. Ein expliziter Rücktausch ist belegt. Vor Produktion fehlen dauerhaft
gebundenes Journal, sichere Wiederaufnahme bei erneut verändertem Namensraum,
fsync-/Crash-Durability und die vollständige Mehrdatei-/Undo-Transaktion samt allen
Fehler- und Abbruchpunkten. Bereits bestandene PMT-Rechte-/ENOSPC-/FD-Proben sind
Primitive, kein Ersatz dafür. Netz-/Wechseldatenträger bleiben unfreigegeben.
Das eigene ext4-Image wurde nach bestätigtem Unmount und Detach entfernt.

## Fortsetzung: persistenter Intent und lesender Wiederanlauf

Am 2026-11-04 ergänzt `tools/linux-probes/recovery.py` den Dateiversuch um
einen isolierten Wiederanlaufvertrag. Diese Probe ist kein Produktadapter und
schaltet keine Schreibfunktion frei. Der ursprüngliche Exchange-Versuch bleibt
unverändert; dessen ext4-Ergebnis gilt nicht automatisch für diese Erweiterung.

Vor dem Tausch werden Original und Ersatz jeweils synchronisiert. Ein
versionierter Intent bindet beide an Geräte-/Inode-Identität, Größe, Modus und
SHA-256 sowie an die Identität des gemeinsamen Verzeichnisses. Der Intent wird
zunächst unter einem temporären Namen geschrieben und synchronisiert, dann
umbenannt; anschließend wird das Verzeichnis synchronisiert. Die Probe verwendet
feste lokale Dateinamen, keine vom Journal vorgegebenen Pfade.

Ein frischer Prozess unterscheidet ausschließlich folgende Zustände:

| Zustand | Erforderlicher Befund | Verhalten der Probe |
| --- | --- | --- |
| Nicht getauscht | Original am Ziel, Ersatz am Vorbereitungsnamen; beide Identitäten und Inhalte stimmen | Zustand melden, nichts schreiben |
| Getauscht | Ersatz am Ziel, Original am Vorbereitungsnamen; beide Identitäten und Inhalte stimmen | Zustand melden, nichts schreiben |
| Gesperrt | Jede andere oder unlesbare Konstellation | Keine automatische Reparatur und keine Löschung |

Dateiöffnungen folgen keinen Symlinks und blockieren nicht an FIFOs. Reguläre
Dateien mit mehreren Hardlinks werden abgewiesen. Der Fingerprint prüft während
des Lesens zusätzlich Größe, Zeitstempel und Modus auf Änderungen. `ctime` wird
nicht als dauerhafte Identität gespeichert, weil der Exchange sie selbst ändert.
Ein verschobenes, identisches Verzeichnis bleibt zuordenbar; eine Kopie oder ein
Symlink am Verzeichnisnamen wird abgewiesen.

**Beleg:** Auf lokalem Btrfs und Kernel-ext4 bestehen jeweils 17 Prüfpunkte, darunter SIGKILL nach
gesichertem Intent, unmittelbar nach Exchange und nach Verzeichnis-`fsync`.
Jeweils liest ein neuer Prozess den Zustand; eine separate Byteprüfung bestätigt
beide erwarteten Versionen. Weitere Fälle sperren fremde Inhalte, identische
Bytes unter neuer Inode, fehlende Originale, geänderten Modus, Hardlinks,
Symlinks/FIFOs am Ziel und Journal sowie ein abgeschnittenes Journal.

**Grenze:** SIGKILL simuliert keinen Stromausfall. Der Intent ist kein
authentifizierter Nachweis gegen einen Angreifer mit Schreibrecht auf den
gesamten Testordner. Die lesende Momentaufnahme garantiert keinen unveränderten
Namensraum bei einer späteren Aktion. Das eigene ext4-Image wurde nach bestätigtem Unmount und Detach entfernt.
Es fehlen insbesondere sichere verzeichnisrelative Handles über die gesamte Transaktion,
ACL/xattr/Eigentümer, Fehler bei `fsync`, vollständige Journal-Zustandswechsel,
Mehrdatei-Abbruch/Undo und Wiederherstellung ohne Überschreiben fremder Änderungen.
Ein späterer Adapter darf deshalb aus „getauscht“ allein keinen automatischen
Rücktausch ableiten. Das vollständige F03-Linux-Tor bleibt offen.

Der anschließend implementierte Adapter mit mehreren Dateien und Wiederaufnahme
ist unter [F03/F08-Transaktionen](F03-TRANSACTIONS.md) beschrieben. Die obigen
Aussagen bleiben der Beleg der isolierten Proben.
