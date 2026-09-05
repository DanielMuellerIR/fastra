# Messung der Suchperformance

Stand: 2026-09-05, Version 1.118.9 gegenüber 60cd0eb. Messgerät: Apple Silicon, Swift 6.3.3, Ziel arm64 macOS 26.0.

## Messaufbau

Je Fall ein eigener Aufwärmprozess und sieben frische Messprozesse; gleiche
Eingabebytes, warmer Dateisystemcache, keine gleichzeitig gestarteten Builds oder
Tests. Angegeben sind Median und Maximum, kein aus sieben Werten geschätztes P95.
RSS ist das vom Betriebssystem gemeldete Prozessmaximum. Prozessmaxima werden
nicht voneinander abgezogen; Eltern- und Kindprozess werden separat ausgewiesen.

Die Buffer-Messung kompiliert die originale Suchlogik mit `swiftc -O
-whole-module-optimization`: BufferSearch, SearchPlan und die unveränderten
Pattern-/Template-Funktionen. Sie misst `find(options:)` einschließlich Planaufbau,
ohne Einlesen und Prüfsummenbildung. Der Speicherpeak enthält das Einlesen.
Dies misst die Engine, nicht die Reaktionszeit eines vollständigen Editors.
Alle Matchfelder außer zufälligen UUIDs sowie Gesamtzahl, Limit und Fehlerstatus
haben in allen acht Fällen identische Prüfsummen.

Eingaben: 17.301.504 Bytes (16,5 MiB), mehrzeilig aus 524.288 Wiederholungen von
`abcdefghij klmnopqrst uvwxyz 123\n`; ein Treffer bei ungefähr 90 %, drei bei
90/95/99 %. Auswahlen umfassen die ersten beziehungsweise letzten 512
UTF-16-Einheiten. Die Einzelzeile besteht ausschließlich aus `a`. Das normale
Limit von 2.000 angezeigten Treffern bleibt aktiv; alle Treffer werden gezählt.

## Textsuche

Zeitangaben in Millisekunden; Peak RSS in MiB.

| Fall | Vorher Median / Max | Nachher Median / Max | RSS vorher / nachher |
|---|---:|---:|---:|
| Mehrzeilig, kein Treffer | 154.681 / 157.764 | 120.118 / 122.296 | 46.73 / 39.36 |
| Ein später Treffer | 154.212 / 156.278 | 148.178 / 149.748 | 46.70 / 39.33 |
| Drei späte Treffer | 154.091 / 155.980 | 152.770 / 154.500 | 46.70 / 39.33 |
| 524.288 Treffer | 179.271 / 184.543 | 148.334 / 155.810 | 47.20 / 39.83 |
| Auswahl am Anfang | 34.766 / 35.250 | 0.803 / 0.872 | 46.75 / 39.39 |
| Auswahl am Ende | 34.623 / 36.947 | 36.205 / 39.894 | 46.75 / 39.39 |
| Einzelzeile, kein Treffer | 140.603 / 142.611 | 118.516 / 124.200 | 39.41 / 39.36 |
| Einzelzeile, 17.301.504 Treffer | 39119.666 / 39275.229 | 883.811 / 922.013 | 40.80 / 40.73 |

Die fortlaufende Zeilenzählung allein senkt den Median ohne Treffer von 154,68 auf
121,27 ms und bei Auswahl am Anfang von 34,77 auf 0,728 ms. Der nachfolgend
separat gemessene Cache der letzten Kontextzeile senkt die Einzelzeile mit vielen
Treffern von 39,32 s auf 0,884 s. Seine anderen Messfälle belegen keinen
wesentlichen Zusatznutzen. Bei Auswahl am Ende ist keine Beschleunigung belegt;
der endgültige Median liegt sogar bei 36,20 statt 34,62 ms. Ohne Treffer wird der
Kontextcache nicht ausgeführt: Dortige Unterschiede zwischen den beiden neuen
Varianten belegen keinen Cachegewinn; ihre Ursache wurde nicht getrennt untersucht.

Ein revisionsgebundener Dokumentcache wurde nicht eingeführt: Die einfachere
fortlaufende Berechnung benötigt keine Invalidierung und spart bei mehrzeiligen
Eingaben ungefähr 7,35 MiB. Apply, Ersetzungen, Trefferreihenfolge, Dateifilter und
Prozessausführung wurden nicht geändert.

## Ordnersuche

Der fensterlose Modus `searchperf` läuft im gepackten Debug-Bundle. Die Messung
enthält die echte Enumeration durch das mitgelieferte ripgrep, Dateifilter,
Paketprüfung, Symlink-Auflösung, Laden und Suche. Zeiten schließen sich nicht
vollständig zur Gesamtdauer: Filter, Metadaten und Ergebnisaufbau liegen außerhalb
der reinen Enumeration und Dateisuche.

Je Baum 10.000 oder 100.000 Dateien zu 128 Bytes, 100 Dateien je Unterordner.
90 % liegen unter `excluded`, 10 % unter `included`; der Ausschlussfall verwendet
`excluded/**`. Keine-Treffer-Fälle suchen `ABSENT`, Limitfälle `MATCH` mit Limit 1.
Der reale Fall liest eine unveränderte Kopie des Quellbestands mit Muster `Fastra`.
Die Ordnerenumeration und ihre Filter bleiben produktiv unverändert.

Zeit in ms, RSS in MiB. „Erste Datei“ ist der Median seit Suchbeginn.

| Fall | Total vorher / nachher (Median) | Total vorher / nachher (Max) | Erste Datei vorher / nachher | Elternprozess Peak RSS vorher / nachher |
|---|---:|---:|---:|---:|
| 10000-none | 710.28 / 717.83 | 717.87 / 727.37 | 51.98 / 52.34 | 153.28 / 153.23 |
| 10000-excluded | 159.59 / 159.00 | 168.10 / 160.48 | 52.72 / 51.96 | 146.09 / 146.27 |
| 10000-limit | 53.28 / 54.28 | 55.24 / 58.24 | 52.19 / 53.23 | 138.27 / 138.19 |
| 100000-none | 6856.10 / 6928.49 | 6995.67 / 7186.62 | 357.24 / 365.64 | 273.52 / 274.52 |
| 100000-excluded | 1402.12 / 1423.14 | 1430.07 / 1521.72 | 365.28 / 373.76 | 224.42 / 224.19 |
| 100000-limit | 372.18 / 420.48 | 412.01 / 446.86 | 361.15 / 408.01 | 208.45 / 210.02 |
| real-sources | 240.03 / 255.27 | 242.41 / 298.45 | 17.61 / 18.35 | 163.45 / 164.94 |

Getrennte Phasen: jeweils Median / Maximum in ms.

| Fall | Enumeration vorher | Enumeration nachher | Dateisuche vorher | Dateisuche nachher |
|---|---:|---:|---:|---:|
| 10000-none | 51.72 / 54.00 | 52.08 / 52.59 | 503.74 / 508.27 | 509.79 / 515.21 |
| 10000-excluded | 52.38 / 53.38 | 51.59 / 52.66 | 52.07 / 57.48 | 52.56 / 53.57 |
| 10000-limit | 51.94 / 53.92 | 52.95 / 56.53 | 0.20 / 0.21 | 0.20 / 0.28 |
| 100000-none | 356.93 / 414.08 | 365.31 / 420.93 | 4933.21 / 4967.20 | 5000.15 / 5162.03 |
| 100000-excluded | 364.91 / 367.95 | 373.34 / 403.34 | 513.02 / 528.56 | 522.54 / 563.95 |
| 100000-limit | 360.86 / 399.54 | 407.53 / 434.99 | 0.21 / 0.22 | 0.22 / 0.23 |
| real-sources | 17.42 / 19.08 | 18.14 / 27.18 | 215.06 / 218.65 | 230.26 / 261.04 |

Der ripgrep-Kindprozess erreicht vorher höchstens 10,2 MiB, nachher 11,9 MiB Peak RSS.
Die Ordnerfälle belegen keine allgemeine Beschleunigung. Insbesondere steigt der
100.000-Dateien-Limitfall von 372 auf 420 ms; die unveränderte Enumeration bestimmt
hier fast die gesamte Zeit. Es wurde deshalb keine Ordnerbeschleunigung ausgeliefert.

Die ripgrep-Reihenfolge ist bereits zwischen frischen Ausgangsläufen nicht stabil.
Bei Limit 1 kann deshalb eine andere, inhaltlich identische Fixture-Datei zuerst
erscheinen. Für diese Fälle bestätigen die Messungen gleiche Trefferzahl und Limit,
nicht identische Dateipfade. Die Produktenumeration und ihre Reihenfolge wurden
nicht geändert. Ungekappte Ergebnisse werden zusätzlich unabhängig von ihrer
Reihenfolge verglichen.

## Erprobter Datenstrom, nicht übernommen

Ein privater Prototyp führte die Datei-Suche bereits während der ripgrep-Ausgabe
aus. Eine Queue war auf 256 KiB begrenzt; der vorhandene Runner behielt weiterhin
seinen Ausgabepräfix. Das war kein vollständig speicherbegrenzter Prozesspfad.
Erprobung nur an regulären synthetischen Dateien ohne Pakete: kein vollständiger
Ersatz für Filter, Symlinks, Fehlerdarstellung oder den FileManager-Rückfall.

| Fall | Total Median / Max (ms) | Erste Datei Median (ms) | Elternprozess Peak RSS (MiB) | Kindprozess Peak RSS (MiB) |
|---|---:|---:|---:|---:|
| 10000-none | 655.37 / 658.40 | 14.17 | 142.45 | 10.16 |
| 10000-limit | 20.90 / 22.01 | 14.30 | 121.45 | 10.16 |
| 100000-none | 6215.63 / 6353.87 | 14.34 | 155.91 | 29.70 |
| 100000-limit | 79.42 / 83.40 | 14.93 | 148.09 | 17.97 |

Der Prototyp verschiebt die erste Dateisuche auf ungefähr 14–15 ms. Seine
Enumeration läuft unter Rückstau gleichzeitig mit der Suche; ihre Dauer ist daher
keine mit dem seriellen Produktpfad direkt vergleichbare Einzelphase.
Ein gezielt um 1 ms je Datei verlangsamter Verbraucher auf dem 10.000-Dateien-Baum
lieferte nach 9.102 Dateien einen echten Fehler wegen unvollständiger Ausgabe.
Der Runner begrenzt das Nachlesen nach Prozessende; eine blockierte Ausgabe-Queue
passt nicht zu diesem Vertrag. Auch die bisher reine Prozessfrist würde unter
Rückstau Suchzeit enthalten. Diese Änderungen brauchen einen eigenen Prozesspfad
mit vollständigen Fehler-, Abbruch-, Filter- und Reihenfolgetests. Der Prototyp
wurde vollständig entfernt; die gemessene frühe Ausgabe ist kein ausgelieferter
Produktgewinn.

## Messmodus verwenden

Nach `app/build.sh` beschreibt eine lokale JSON-Datei den bewusst gewählten
Eingabebaum:

```json
{"root":"/tmp/search-fixture","pattern":"ABSENT","exclusions":[],"limit":10000}
```

```sh
FASTRA_SEARCH_PERF_INPUT=/tmp/search-input.json \
FASTRA_SEARCH_PERF_OUTPUT=/tmp/search-result.json \
./app/selftest.sh searchperf
```

Der Modus liest den Baum und schreibt ausschließlich den angegebenen Bericht
sowie die normalen lokalen Testprotokolle. Er ist nicht Bestandteil der
Standard-Selbsttests. Der Bericht nennt Gesamtzeit, Enumeration, Dateisuche,
Beginn der ersten Datei, Anzahl und Prüfsummen sowie getrennte Prozesspeaks.
Fehler liefern einen fehlgeschlagenen Test, auch wenn bereits Teilzeiten vorliegen.

`app/performance-baseline.sh` bleibt der bestehende vollständige App-Testpfad mit
sauberem Git-Stand, Build und gesamter Suite. Er misst zusätzlich Start und
Aufräumen; die hier gezielten Engine- und Ordnerreihen ersetzen ihn nicht und
tragen sich nicht als vollständige Baseline ein.

## Regressionen

Der Build vor dem Testlauf bestand einschließlich Portabilitätsprüfung ohne
lokalen Ressourcenrückfall. `app/test.sh` bestand mit 2.213 Tests der schnellen
Phase und 115 seriellen Integrationstests, beide Phasen Exit 0. Die fensterlosen
Selbsttests `search`, `selsearch`, `wildcard`, `git`, `gitactions` und `localization`
bestanden ebenfalls ohne Skips. Die neuen Positions- und Kontexttests decken
Unicode-Umbrüche, CRLF, EOF, Nullbreite, Auswahl und lange Grapheme ab. Die vorhandene
Suite prüft außerdem Filter, Symlinks, Fehler und gültige Apply-Snapshots.
