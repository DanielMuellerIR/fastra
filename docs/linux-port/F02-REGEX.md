# F02: Regex, Unicode und Laufzeit

Die Mac-Referenz verwendet die originalen `WildcardPattern`,
`ReplacementReferences`, `CaseTemplate` und `NSRegularExpression`. Der isolierte
Rust-Verbraucher ruft öffentliche ICU-C-APIs durch einen kleinen Shim auf. Keine
privaten Apple-ICU-Symbole und kein Ersatz durch Rust `regex`.

Die 37 Fälle erfassen gierige Sterne, `**` und längere Sternläufe, Literale,
mehrere/optionale/namentliche Captures, Rückreferenzen/Lookbehind, leere Treffer,
Templates/Escapes, NFC/NFD, Unicode-Wortgrenzen, Surrogatpaare, kombinierende
Zeichen, LF/CR/CRLF/NEL/LS/PS, Case-Operatoren samt leerer Gruppe und Graphem sowie
Auswahlgrenzen mit Ankern/Lookbehind. Verglichen werden alle Capture-Ranges in
UTF-16 und vollständige Ausgabebytes; ein ungültiges Muster wird auf beiden
Seiten kontrolliert abgewiesen. Die Wildcard-Übersetzung wird für diesen Vergleich
noch von der originalen Mac-Implementierung geliefert: Das ist kein bereits
portierter Rust-Parser.

ICU 78.3 liefert auf macOS und beiden Linux-Zielen dieselben Referenzresultate.
Die Mac-Probe enthält ICU und Daten im verschobenen App-Bundle; alle externen
Abhängigkeiten sind auf dessen Framework-Verzeichnis umgebogen. Der Linux-Build
verwendet die offizielle ICU-Quelle, SHA-256
`3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0`,
und Ubuntu 24.04 mit `-march=x86-64`. Dasselbe Paket lief auf beiden Zielrechnern.
Der erste Versuch mit den lokalen x86-64-v4-Distributionsbibliotheken scheiterte
auf dem älteren Ziel mit SIGILL. Er zählt ausdrücklich nicht als bestandener
Laufzeitnachweis und wird nicht ausgeliefert.

Das pathologische Muster `(a+)+$` wird mit ICU-Limit 25 und 1 MiB Regex-Stack als
`U_REGEX_TIME_OUT` beendet. Der Match-Callback beendet denselben Auftrag als
`U_REGEX_STOPPED_BY_CALLER`. Der äußere Prüfprozess war zusätzlich auf fünf
Sekunden begrenzt. Daraus folgt kein harter Echtzeitvertrag für jede Eingabe.
Die vollständige Produktpaketierung samt Lizenzen und Sicherheitsupdates bleibt
F16; diese Probe ersetzt sie nicht.
