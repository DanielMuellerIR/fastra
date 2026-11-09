# F05/F06: gemeinsamer Suchkern begonnen

Stand: 2026-11-04. `crates/fastra-core` ist das erste produktionsorientierte
Rust-Modul im Cargo-Workspace. Es ist noch nicht in die Mac-App eingebunden.
Die Swift-Produktpfade bleiben bis zur nativen Gleichheits- und Bundle-Abnahme
erhalten. F05 ist deshalb begonnen, noch nicht abgeschlossen.

Der Kern kapselt ICU 78.3 hinter einer C-Schnittstelle mit kontrolliertem
Speicherbesitz. Geprüfte Toolchain: Rust 1.99.1; Cargo.lock bindet Abhängigkeiten.
Andere ICU-Versionen lehnt der Build ab. Der Versionsvergleich ersetzt nicht
die noch nötige portable Runtime-Paketierung.

Implementiert sind Literal-/Wildcard-/Regex-Suche, UTF-16-Capture-Ranges,
Foundation-kompatible numerische Templates, Case-Operatoren und Auswahlbereiche.
Die Vorschau bindet Quelltext, Dokumentrevision und Suchgeneration. Apply benutzt
ausschließlich diese gespeicherten Treffer und Ersetzungen; abweichender
Quelltext, Revision, Generation oder ungültige Freigaben werden abgewiesen.
Auch wirkungslose Ersetzungen behalten diese Prüfung. Keine Dateischreibvorgänge.

Trefferzahl, Eingabe-/Ausgabegröße und Regex-Zeit/Stack sind begrenzt.
Überschreitungen liefern Fehler statt teilweise anwendbarer Vorschauen.
Ein Cancellation-Objekt unterbricht auch einen laufenden ICU-Match von einem
anderen Thread. Lokalisierte Fehlertexte gehören zum Host.

## Belege und gefundene Abweichung

`cargo test --offline --workspace`: 21 Tests bestanden, einschließlich der
37 F02-Fälle. `cargo clippy --offline --workspace --all-targets -- -D warnings`
ist grün. Die erwarteten Ausgaben in
`crates/fastra-core/tests/fixtures/swift-search-reference.json` stammen aus den
unveränderten Swift-Modulen mit Swift 6.2.1/Foundation im isolierten
Linux-Container. Verglichen werden alle Capture-Ranges und Ausgabebytes.
Dies ist eine unabhängige Quellreferenz, **keine neue native Mac-Abnahme**.

`opaque-lookbehind` deckte im lokalen ICU-78.3-Paket auf, dass `(?<=a)b` bei
Region `[1, 1]` in `ab` trotz opaker Grenzen ein Match liefert. Die direkte
C-API-Gegenprobe bestätigte das. Der Adapter reicht deshalb den ausgewählten
Text als eigenständige ICU-Eingabe ein und überträgt Capture-Offsets zurück.
Das entspricht der Swift-Referenz einschließlich Ankern und leeren Bereichen.
Die frühere F02-Probe garantiert nicht das Verhalten beliebiger Systempakete.

## Fortsetzung

`PreparedSearch` teilt den kompilierten ICU-Ausdruck über mehrere Dokumente.
Jeder geklonte Matcher erhält Zeit-/Stackgrenzen und Cancellation ausdrücklich
erneut. Ganze Wörter verwenden denselben Boundary-Vertrag wie Swift; Wildcard-
Modus ohne tatsächliche Stern-Gruppe hält Ersetzungssterne wörtlich. Ein eigenes
Gesamtbudget begrenzt gespeicherte Capture-Ranges. Native Bundle-/FFI-Belege:
[F05-MAC](F05-MAC.md), [F05-FFI](F05-FFI.md). Die Mac-Produktpfade bleiben erhalten.

## Noch offen

Native Swift-Anbindung und portables Mac-Bundle, vollständige Suchoptionen und
Umnummerierung, Mehrdatei-/Tab-Suche, Host-Generationen und sichtbare
Vorschau/Freigabe. Vor dem Entfernen eines Swift-Produktpfads müssen die
betroffenen Funktionsgruppen bestanden sein. Die isolierte GTK-Erweiterung
verwendet diesen Kern noch nicht.
