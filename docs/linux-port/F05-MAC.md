# F05: Native Swift-FFI im verschobenen macOS-Bundle

`tools/ffi/check-mac-bundle.sh` prüft die echte UniFFI-Swift-Grenze auf einem
arm64-Mac. Es handelt sich um einen headless Prüfaufbau; der bestehende native
Mac-Produktcode, installierte Anwendungen und globale Toolchains bleiben
unverändert.

## Wiederholen

```bash
tools/ffi/check-mac-bundle.sh /path/to/source-snapshot \
  /path/to/verified/icu78.3 /tmp/new-fastra-ffi-check
```

Der ICU-Präfix muss arm64-Header und die drei ICU-78.3-Dylibs enthalten. Die
Header-Version wird geprüft. Cargo/Rustup, Swift und `pkg-config` müssen vorhanden
sein; vorhandene Cargo- und Homebrew-Werkzeugpfade werden berücksichtigt. Das
Zielverzeichnis darf noch nicht existieren.

Der Lauf installiert Rust 1.99.1 ausschließlich in ein privates `RUSTUP_HOME`
und `CARGO_HOME` unter dem neuen Zielverzeichnis. `--no-self-update` verhindert
Rustups Selbstaktualisierung; Compiler und Cargo werden anschließend direkt aus
diesem Toolchain-Verzeichnis verwendet. Die globale Standardtoolchain wird nicht
umgestellt. Cargo baut mit `--locked`; Rust und Swift verwenden macOS 14 als
Deployment-Ziel.

Der Ablauf:

1. Einen lokalen Quell-Snapshot und einen eigenen ICU-Entwicklungspräfix anlegen.
2. Die Tests von `fastra-core` und `fastra-ffi` ausführen, die echte FFI-Dylib und
   den Bindingsgenerator bauen und daraus die Swift-Bindings erzeugen.
3. Den vorhandenen `tools/ffi/client.swift` gegen diese erzeugten Bindings und
   die echte Dylib als `Probe.app` kompilieren. FFI und ICU liegen in
   `Contents/Frameworks`; Abhängigkeiten verwenden `@rpath`, der Client
   `@executable_path/../Frameworks`.
4. Alle Dylibs und das Test-Bundle ad-hoc signieren, das Bundle verschieben und
   die eigenen ursprünglichen Build- und ICU-Verzeichnisse umbenennen.
5. Die strikte tiefe Code-Signatur, Bibliotheksreferenzen und Laufzeit-Suchpfade
   prüfen. Nur relative oder macOS-Systempfade sind erlaubt. Den Client ohne
   `DYLD_LIBRARY_PATH` starten und über Dylds tatsächliches Ladeprotokoll
   nachweisen, dass FFI und alle drei ICU-Bibliotheken aus dem verschobenen
   Bundle kommen.

Nach Erfolg entfernt das Skript standardmäßig nur seine eigenen Quell-, Build-,
ICU- und Toolchain-Arbeitsverzeichnisse. Die verschobene Probe, erzeugte Bindings
und kleine Versions-, Quellhash-, Linker- und Ergebnisbelege bleiben erhalten.
`FASTRA_KEEP_FFI_BUILD=1` erhält auch die eigenen Arbeitsverzeichnisse. Bei einem
Fehler bleiben sie zur Diagnose stehen. Ein fremder ICU-Präfix wird weder
umbenannt noch gelöscht. Ein Lauf von einer anderen Architektur oder Plattform
wird abgewiesen.

## Verifiziert am 2026-11-04

- Native arm64-Ausführung auf macOS 26.7.2 mit Rust 1.99.1
  (`58cf8f9c35b355199727627d07ae34a4e2846d67`, LLVM 23.1.1), Apple Swift 6.4.2
  (`swiftlang-6.4.2.1.9 clang-2100.4.1.1`) und ICU 78.3.
- Alle 36 Rust-Tests bestanden: 22 Suchtests einschließlich des gemeinsamen
  37-Fälle-Swift-Korpus, elf Textoperationstests einschließlich der 37
  Swift-Referenzvektoren und drei FFI-Tests.
- Der tatsächlich aus der Dylib generierte Swift-Client bestand UTF-16-/Unicode-
  und Capture-Prüfungen, Trefferfreigaben, veralteten Text/Revision/Generation,
  Regex-Fehler, vorzeitigen und laufenden Abbruch sowie die Besitzprüfung eines
  1-MiB-Textes.
- Das verschobene, ad-hoc signierte Bundle bestand `codesign --verify --deep
  --strict`. Seine nicht-systemeigenen Bibliotheksreferenzen waren relativ.
  Die einzigen ermittelten RPATHs waren `/usr/lib/swift` und
  `@executable_path/../Frameworks`.
- Nach vollständigem Entfernen der eigenen Build-, ICU-Präfix- und
  Toolchain-Verzeichnisse bestand derselbe Client erneut. Dyld lud
  `libfastra_ffi.dylib`, `libicui18n.78.dylib`, `libicuuc.78.dylib` und
  `libicudata.78.dylib` ausschließlich aus den Frameworks des verschobenen
  Bundles. Die vorher vorhandene globale Rust-Version blieb 1.95.0.

Der geprüfte Quell-Snapshot hat Archiv-SHA256
`4cc0af864da34eaabb8c01e2b4c5a1d9352e0070dbf66ff24b9aae527622e896`.
Die sortierte Liste seiner Datei-SHA256-Werte hat selbst SHA256
`f9aa492142c344d1607f72a9f546458a7df4035b76bcf56bf22f000670979fd6`.
Diese Identität beschreibt den geprüften Stand; spätere Änderungen erfordern
einen neuen Lauf.

Der Nachweis betrifft die native Sprachgrenze und deren Bundle-Portabilität.
Er ersetzt weder die Einbindung in die bestehende Mac-App noch deren GUI-,
Signatur-/Notarisierungs- und Installationsabnahme. Die Probe wird nicht als
Produktpaket ausgeliefert. Keine Benutzeroberfläche wurde gestartet und nichts
nach `/Applications` installiert.
## Aktuelle arm64-Core/FFI-Probe

Der eingefrorene aktuelle Rust-Core wurde am 2026-11-05 unabhängig auf arm64 macOS
mit privater Rust-1.99.1-Toolchain und ICU 78.3 geprüft: sechs Encoding-, 25 Such-,
elf Textoperations- und drei UniFFI-Tests bestanden (45 insgesamt). Der Stand
enthält PreparedSearch, Whole-word, Encoding und Textoperationen. Ausgangscommit
ist befb948f4dbb2b3c90bb2834819a70a2670396a9; der genaue uncommittete Stand ist
über das SHA-256-Dateimanifest festgehalten.

Die neu generierten Swift-Bindings wurden übersetzt und mit dem aktuellen
Rust-Kern ausgeführt. Der Prüfkunde prüft Unicode/Captures, Freigaben,
Text-/Revisions-/Generationsbindung, Syntaxfehler, kontrollierten Abbruch und
1 MiB übertragene Quelldaten. Ein gleichzeitiger ICU-Zeitbudgetablauf darf vor
einem eingeplanten Cancel gewinnen; danach muss der tatsächlich abgebrochene
Token weitere Aufrufe ausdrücklich als Cancelled beenden. Die aktive
Regex-Callback-Cancellation wird zusätzlich vom strikten Core-Test geprüft.

Das ad-hoc-signierte eigene Prüf-Bundle enthält Rust und ICU, wurde verschoben,
seine privaten Build-/Header-/ICU-Verzeichnisse wurden unzugänglich gemacht und
anschließend entfernt. Signaturprüfung und erneuter Start nach Cleanup sind
separat belegt. Alle vier Fremdbibliotheken wurden aus Contents/Frameworks
geladen. Die globale Rust-1.95.0-Toolchain und die installierte Mac-App blieben
unverändert. Dies ist keine Produktintegration, Notarisierung oder Freigabe,
bisherige Swift-Produktpfade zu entfernen.

Identität des zusätzlich geprüften aktuellen Kernstands:

- `fastra-core/src/lib.rs`: SHA-256 `292f50f97391b1c3dc903ebef1c6234fc233e156f2297def6acf328912dea9f2`.
- `fastra-core/src/encoding.rs`: SHA-256 `150d0e2cf5276eb2c7261fc9a25cc5cf4cb79d8fa2c2e5615ee715c947d306a7`.
- Swift-Prüfkunde: SHA-256 `6e7dccf92cdc885bd1d440b3e5ee3b4e876916390a9caf5a45ad2fcea51f105b`.
