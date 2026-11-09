# Entscheidungsproben F00–F04

Isolierte Proben; keine produktiven Rust-Targets. Die Ergebnisse und ihre Grenzen
stehen in `../../docs/LINUX-DECISION.md`. Der davon getrennte gemeinsame
Suchkern unter `../../crates/fastra-core` beginnt inzwischen F05/F06.

- `path-regression.sh <Fastra-Repo> <PMT-Repo>` belegt den Fehler gegen den
  ursprünglichen Service und den Erfolg gegen den Fix mit denselben Dateifällen.
  Es nutzt die vorhandenen PMT-Frameworkstubs, keine echte GUI.
- `make-collections.py <neuer Fixtureordner>` erzeugt zwei Mails und zwei Notizen
  mit einer bytegenau bekannten PNG-Anlage sowie belegten Zielnamen. Anschließend
  `FASTRA_COLLECTION_REVIEW_DIR=<ordner> FASTRA_POORMANS_TEXT=<geprüfte CLI>` mit
  dem nativen `markdowncollections`-Selbsttest ausführen. Vor einem **zweiten
  App-Prozess** die leere Markerdatei `reopen` im Fixtureordner anlegen.
- `regex/mac.swift`: mit den originalen `WildcardPattern.swift` und
  `ReplacementReferences.swift` und `CaseTemplate.swift` kompilieren. Argumente: `cases.json`, Ausgabe der
  normalisierten Fälle, Ausgabe der Mac-Referenzen. `icu.c` mit `icu-i18n` als
  `libfastra_icu_probe.so` übersetzen; Cargo baut die gekapselte Rust-Probe mit
  diesem Bibliothekspfad. Sie liest die normalisierten Fälle von stdin. Verglichen
  werden alle Capture-Ranges in UTF-16 und die vollständigen UTF-8-Ausgaben.
- `uniffi/run-mac.sh`: prüft UniFFI 0.31.2 mit generierten Swift-Bindings,
  Bytes, Fehlern, Panic und Abbruch eines bereits laufenden Rust-Auftrags.
  Das verschobene App-Bundle hat keine Abhängigkeit zum Buildordner.
- `ffi/run-mac.sh`: benötigt Swift und Rust im PATH. Prüft eine kleine eigene
  C-Schnittstelle; kein UniFFI-Nachweis. Verschiebt das Bundle und entfernt den
  ursprünglichen Buildordner vor dem Aufruf.
- `regex/build-icu-linux.sh` baut die offizielle ICU-78.3-Quelle im eigenen
  Ubuntu-24.04-Container mit `-march=x86-64`. Das lokale CachyOS-Paket ist
  x86-64-v4 und ausdrücklich keine Mint-Laufzeit. `regex/package-mac.sh` packt
  dieselbe ICU-Version mit relativen Loaderpfaden in ein verschiebbares Bundle.
- `exchange.py <Test-Dateisystem>` prüft ausschließlich RENAME_EXCHANGE und
  beobachtbare Recovery-Zustände in einem eigenen, anschließend entfernten
  Unterordner. Kein produktiver Apply-Adapter. Keine No-Replace-Probe aus PMT
  wiederholen oder daraus eine Mehrdatei-Atomizität ableiten.
- `recovery.py <Test-Dateisystem>` ergänzt F03 um einen vor dem Tausch per
  Datei-/Verzeichnis-`fsync` gesicherten Intent und eine **rein lesende**
  Wiederanlaufprüfung in einem neuen Prozess. Drei echte SIGKILL-Punkte und
  manipulierte Dateien/Journalnamen prüfen Identität, Bytes und Sperrzustände.
  Nur eigene temporäre Dateien werden verändert und anschließend entfernt.
  Kein automatischer Rollback, kein Stromausfallnachweis und keine Freigabe
  eines produktiven Journals; Vertrag und Grenzen stehen in
  `../../docs/linux-port/F03-SAFETY.md`.
- `gtk/Dockerfile`, `gtk/editor.py` und `gtk/markdown.py`: isolierte Ubuntu-24.04-
  Umgebung mit GTK4, GtkSourceView5 und WebKitGTK6. Quellen lesend mounten,
  Ergebnisse separat; Laufzeit, CPU und Speicher begrenzen. Xvfb ist ausdrücklich
  kein echter Wayland-/Cinnamon-Abnahmebeleg. WebKits eigene Sandbox bleibt aktiv;
  ihr Namespace-/Loopback-Aufbau muss in der äußeren Testumgebung erlaubt sein.

Generatoren und kleine normalisierte Ergebnisse bleiben Referenzmaterial. Große
Builds, kopierte Anwendungen und Laufzeiten bleiben außerhalb des Repositories;
entbehrliche Arbeitskopien spätestens 30 Tage nach Abnahme entfernen.
