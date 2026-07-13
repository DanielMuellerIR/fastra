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
Pakete, versteckte Dateien, `.git` und Ausschlüsse werden nach der Enumeration
noch einmal nach Fastra-Semantik geprüft. Für kleine/lokale Ordner ist kein
Geschwindigkeitsvorteil zu erwarten; die Anzeige bleibt deshalb ehrlich und
macht keine Leistungszusage.
