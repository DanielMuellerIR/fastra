# Folder-Suche: ripgrep-Benchmark

Stand: 2026-07-13, Apple Silicon, macOS 14. Der Vergleich misst ausschließlich
die Dateiermittlung. Dekodierung, Binärschutz, Ausschlüsse und die
`NSRegularExpression`-Suche sind in beiden Wegen identisch und würden den
Vergleich verfälschen.

## Ausführen

```sh
cd app
swift Benchmarks/folder-search-benchmark.swift
```

Das Skript erzeugt je einen temporären Korpus und löscht ihn anschließend:

| Korpus | Dateien | Nutzdaten |
| --- | ---: | ---: |
| klein | 200 | 0,8 MiB |
| mittel | 2.000 | 7,8 MiB |
| groß | 10.000 | 39,1 MiB |

Je Pfad läuft ein Aufwärmdurchgang plus sieben Messungen; dokumentiert ist der
Median. Der alte Weg ist die frühere `FileManager`-Rekursion mit denselben
Optionen (`skipsHiddenFiles`, `skipsPackageDescendants`). Der neue Weg ist das
mit Fastra gebündelte `rg --files --null --no-ignore --glob !.git/**`.

## Rohwerte

| Korpus | FileManager Median | ripgrep Median | Faktor FileManager/ripgrep |
| --- | ---: | ---: | ---: |
| klein | 0,89 ms | 76,31 ms | 0,01× |
| mittel | 10,79 ms | 89,31 ms | 0,12× |
| groß | 51,68 ms | 130,94 ms | 0,39× |

## Ergebnis und Grenzen

Bei diesem lokalen, warmen Korpus ist die FileManager-Rekursion schneller. Der
Prozessstart und das Übertragen aller Null-getrennten Pfade dominieren die reine
Enumeration. Das ist kein Grund, Treffersemantik an ripgreps eigene Regex- und
Encoding-Regeln abzugeben: Fastra nutzt weiter seinen getesteten Suchkern, damit
Platzhalter, Capture Groups, BOMs, Latin-1/Win-1252, Binärschutz und
projektbezogene Ausschlüsse unverändert bleiben.

Der gebündelte ripgrep-Pfad ist dennoch Standard: Er arbeitet ohne externe
Installation, enumeriert robust in großen realen Verzeichnisbäumen und besitzt
einen vollständigen FileManager-Fallback, wenn die Ressource nicht startet.
Sichere komponentenbezogene Ausschlüsse werden seit v1.51.0 bereits als
Negativ-Globs an `rg --files` gereicht. Fastras einmal pro Lauf kompilierter
Matcher prüft danach trotzdem jeden Kandidaten verbindlich; Paketzugehörigkeit
wird erst anschließend und pro Verzeichnis gecacht. Für kleine/lokale Ordner
ist kein Geschwindigkeitsvorteil zu erwarten; die Anzeige bleibt deshalb
ehrlich und macht keine allgemeine Leistungszusage.

## Reale Projektmessung v1.51.0

Stand: 2026-07-25, M5, etwa 575 MiB großer 4D-Projektkorpus, read-only.
Ausgeschlossen wurden `.json`, `userPreferences.*` und der verbindliche
`DerivedData`-Baum. Ein Aufwärmlauf ging den drei dokumentierten Läufen voraus;
gesucht wurde `util_*` im Modus „Alle Dateien“ über Fastras vollständigen
Wildcard-/Encoding-/Binärschutz-Pfad.

| Wert | Ergebnis |
| --- | ---: |
| Dateien vor Ausschlüssen | 47.030 |
| Kandidaten nach Pfadausschlüssen | 2.275 |
| Treffer | 1.552 |
| Warme Laufzeiten | 0,342 / 0,347 / 0,347 s |
| Median | 0,347 s |
| CPU je Lauf | ca. 0,27 s User + 0,06 s System |
| Prozess-Max-RSS nach lokalem Autorelease-Pool | ca. 333 MiB, stabil |

Der frühere sichtbare Lauf dauerte auf demselben Rechner etwa 6,4 Sekunden.
Die reale Pfadinventur bestätigte 66 `.json`-Dateien, 43.012 Dateien unter
`userPreferences.*`-Ordnern und 1.733 Dateien unter `DerivedData`; keine davon
blieb Kandidat.

Die getrennte Öffnungsdiagnose für eine 21.958 Byte große, 916-zeilige
`folders.json` meldete den asynchronen Load-Callback nach 0,087 Sekunden und
den tatsächlich montierten Editor nach 0,259 Sekunden. Damit war der
Datei-/Editor-Ladepfad kein unabhängiger Mehrsekunden-Flaschenhals; die
beobachtete Wartezeit gehörte zum noch gültigen Projektscan beziehungsweise
zu dessen veralteter Trefferbasis.
