# Reine Hex-Referenz und Linux-Modell

Die Referenz wurde am 2026-11-05 mit Swift 6.2.1 aus den unveränderten reinen
Typen in `app/Sources/Fastra/HexEditing.swift` erzeugt. Quellhash und tatsächliche
Containeridentität stehen in `reference.json`. Nur Foundation und ein identischer
L10n-Stringstub werden ergänzt; CryptoKit, Darwin-Dateispeicherung und GUI-Code
werden nicht eingebunden. Es gibt keine Fixtures aus Nutzerdateien.

`generate.py` erzeugt 117 Parserfälle, fünf vollständige Edit-/Undo-/Redo-Verläufe,
die Referenzwerte der Save-Lineage und einen Scan aller 1.112.064 gültigen
Unicode-Skalarwerte. `reference.rs` enthält die tatsächlich gemessenen Werte für
die Rust-Tests. Die JSON-Felder `saveLineage` sind durch native Swift-Preconditions
abgesichert; sie beschreiben den Hostvertrag, keine Save-Implementierung im Modell.

Swift akzeptiert bei zwei Zeichen auch `+1`, `+F`, `+a` und `-0`; `-1`, NUL und
Vollbreitenziffern bleiben ungültig. `Character.isWhitespace` bewertet ganze
Graphemcluster. Deshalb akzeptiert das Original beispielsweise ein Leerzeichen
mit anschließendem kombinierendem Akzent als Trenner. Der Linux-Parser verwendet
die gemessenen 25 Whitespace-Skalare und 328 Bereiche angehängter Skalare, statt
unbemerkt auf ASCII-Whitespace oder Rust `split_whitespace` umzudeuten.

`differential.py` prüft zusätzlich 27.849 deterministische Kombinationen gegen
die originale Swift-Funktion: Bereichsgrenzen, alle Trenner, kombinierende
Zeichen, ZWJ, Emoji, Indic-Kontexte und Zufallsfolgen mit festem Seed `0xFA57`.
Der Korpus bleibt temporär; `differential.json` hält den kleinen Ergebnisbeleg.
Dies ist keine Behauptung, sämtliche beliebig langen Unicodefolgen erschöpfend
verglichen zu haben. Der Referenzdecoder nutzt `String(decoding:as:)`, damit ein
führendes U+FEFF als Inhalt erhalten bleibt.

Ausführung vom Repo-Root mit bereits vorhandenen Testbildern:

```sh
python3 crates/fastra-linux/tests/hex-reference/generate.py
python3 crates/fastra-linux/tests/hex-reference/differential.py
```

Die Skripte verwenden `swift:6.2.1-noble` ohne Netz und ohne erneutes Pull sowie
für den Vergleich `fastra-linux-package-builder:local` mit Rust 1.99.1. Die
reinen Tests lassen sich ohne GTK mit `rustc --edition 2021 --test
crates/fastra-linux/src/hex_editor/model.rs` ausführen. Die acht Tests prüfen
zusätzlich Offset-/Seitengrenzen, atomare Limits, Frozen-Pläne und Rebase-Epochen.

Das Modell begrenzt Quellen auf 32 MiB, Änderungen auf 4096 Bytes, die
Undo-/Redo-Historie auf insgesamt 4096 wirksame Zeilenaktionen, Seitenausgaben auf
4096 Bytes und eine Eingabe auf 4096 UTF-8-Bytes. Ungültige oder wirkungslose
Eingaben verändern weder Revision noch Redo. Eine wirksame Zeilenänderung ist
eine Undo-Aktion; neue Änderungen nach Undo verwerfen den Redo-Zweig. Änderungen
beziehen sich immer auf die unveränderte Originalquelle.

`Session::frozen(revision)` kopiert auf dem Hauptthread nur ein `Arc<[u8]>` und
die sortierten kleinen Änderungen. `Frozen::output()` erzeugt die vollständige
Ausgabe auf dem Worker. `Session::output` existiert nur für Tests und delegiert
an denselben Rechenkern. Das Modell implementiert keine Dateioperationen.
Der Host muss Snapshot, Dokumentinstanz, State-Epoche und Worker-Abbruch binden,
vor Save sperren sowie Erfolg oder Fehler dem richtigen Auftrag zuordnen. Ein
Rebase erzeugt eine neue Session und darf dieselbe Revisionsnummer haben; die
Revision allein schützt deshalb keinen verspäteten Auftrag nach Save/Reopen.
