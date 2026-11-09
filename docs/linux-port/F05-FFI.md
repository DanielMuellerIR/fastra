# F05: gemeinsame Swift/Rust-Sprachgrenze

Stand: 2026-11-04. `crates/fastra-ffi` kapselt den vorhandenen `fastra-core`
mit UniFFI **0.31.2**; Cargo.lock bindet auch die Generator-Abhängigkeiten.
Die Mac-Produktpfade bleiben unverändert. Dies ist eine unabhängig geprüfte
Sprachgrenze, keine Integration in den Mac-Produktpfad. Die zusätzliche native
Bundle-Probe ist in [F05-MAC](F05-MAC.md) beschrieben.

## Vertrag

Alle exportierten Funktionen, Methoden und der Cancellation-Konstruktor werfen
strukturierte `SearchError`-Werte. Regex-Fehler erhalten ICU-Code und Offset;
Engine-Fehler behalten den Code. Abbruch, Limit, ungültiger UTF-16-Bereich,
veraltete Vorschau und ungültige Freigabe sind eigene Varianten. Lokalisierte
Nutzertexte gehören zum Host. Rust-Panics innerhalb der exportierten
Implementierungen werden mit `catch_unwind` als `Internal` zurückgegeben.
Das gilt für unwind-fähige Builds; Speichererschöpfung oder `panic=abort` sind
kein abfangbarer Fehlervertrag.

`createPreview` übernimmt Text, Revision, Suchgeneration, Suchanfrage, Grenzen
und ein threadübergreifend nutzbares Cancellation-Objekt. Die Grenzen dürfen
gegenüber dem Core-Standard nur reduziert werden; insbesondere sind null
Millisekunden Regex-Zeit (ICU: unbegrenzt) nicht erlaubt. Der Host führt den
synchronen Aufruf auf einer Hintergrund-Queue aus. Es gibt keine UI-Callbacks.

Der resultierende `Preview`-Handle hat keine Mutation. `snapshot` gibt eine
Kopie von Quelltext, Revision, Generation und den vollständigen Treffern zurück;
Captures verwenden UTF-16-Codeeinheiten und bewahren fehlende Gruppen als `nil`.
`apply` verwendet ausschließlich die im Handle gespeicherten Treffer und
Ersetzungen. Aktueller Text, Revision und Generation müssen übereinstimmen.
Freigaben sind streng aufsteigend geordnete Trefferindizes des Handles, ohne
Duplikate. Auch eine leere Freigabe prüft die Vorschau-Basis. Das Ergebnis ist
ein neuer String; diese API schreibt keine Dateien.

Cancellation ist monoton und wird nicht zurückgesetzt. Für eine neue Suche
legt der Host ein neues Objekt an. `cancel` kann parallel zum synchronen
Suchaufruf laufen und erreicht den ICU-Abbruchpfad. Rust hält den Handle während
des Aufrufs; Strings und Records werden über die generierten UniFFI-Converter
übergeben, ohne geborgte Zeiger über die Sprachgrenze zu reichen.

## Reproduktion und Beleg

Auf einem Host mit ICU 78.3, Rust und Swift:

```sh
cargo test --locked --workspace --all-features
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
tools/ffi/check-swift.sh
```

`check-swift.sh` baut die echte Bibliothek, generiert Swift, Header und Modulemap
mit dem mitgebauten `fastra-bindgen`, kompiliert den Client und führt ihn aus.
Generierte Quellen bleiben temporär; der Generator ist ein optionales
`bindgen`-Feature und wird nicht für die produktive Bibliothek benötigt.
`CARGO_TARGET_DIR` wird respektiert. Für nicht im System installierte ICU-Dylibs
muss der Testhost seinen passenden Runtime-Suchpfad bereitstellen.

Ausgeführt: **24 Rust-Tests bestanden** (21 Core, 3 FFI), Clippy mit
`-D warnings` grün. Der Guard-Test injiziert einen Rust-Panic und erhält
`Internal`; ein produktiver Panic-Injektionsschalter existiert nicht.

Die tatsächlich generierten Swift-Bindings wurden mit **Swift 6.2.1** in einem
isolierten Linux-Container gegen die echte Rust-cdylib und die separat gebaute
ICU-78.3-Laufzeit kompiliert und erfolgreich ausgeführt. Der Client prüft Unicode,
UTF-16-Captures, Regex-Templates, vollständige Vorschau, alle drei Stale-Achsen,
ungültige Freigaben, strukturierten Regex-Fehler, vorab gesetzten und parallel
aus Swift ausgelösten Abbruch einer aufwendigen Regex sowie 1 MiB String-Inhalt.
Der Container lief ohne Netzwerk und mit schreibgeschützt eingehängten Quellen.
Dies ersetzt ausdrücklich keine Prüfung im nativen Mac-Prozess.

## Offene Gates

Die Einbindung in die Mac-App, native Swift-/Foundation-Gleichheit,
portables signiertes Mac-Bundle einschließlich ICU und UniFFI-Bibliothek,
Laufzeitpfade nach Verschieben sowie bestehende Selbsttests bleiben offen.
Bis zu ihrer Abnahme darf kein bisheriger Swift-Produktpfad entfernt werden.
Ebenso fehlen Host-Generationsverwaltung, UI-Freigabe und Mehrdateitransaktion;
eine bestandene reine Sprachgrenze schaltet keine Dateischreibfunktion frei.

Die erneute native Probe des aktuellen Kernstands vom 2026-11-05 einschließlich
Encoding, PreparedSearch und Textoperationen ist in
[F05-MAC](F05-MAC.md#aktuelle-arm64-coreffi-probe) mit ihren Quellidentitäten festgehalten.
