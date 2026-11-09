# Gepinnte Syntaxfaltungs-Grammatiken

`catalog.json` bindet die 32 aktiven Sprachzuordnungen des gepatchten
Mac-Katalogs aus CodeEditLanguages an 31 Grammatiken aus 29 Quellprojekten.
JSX verwendet JavaScript. Die zehn im Mac-Katalog entfernten Provider bleiben
explizit ohne Grammatik; 4D verwendet seinen eigenen lexikalischen Provider.

Die unveränderten C-/C++-Quellen und benötigten Header liegen einzeln als Gzip
mit festem Zeitstempel vor. Der Build prüft komprimierte und entpackte SHA-256,
Größe sowie die originalen Lizenzdateien und entpackt ausschließlich in
`OUT_DIR`. Er lädt nichts aus dem Netz und führt keine Upstream-Buildskripte aus.
Die Komprimierung vermeidet mehr als 300 MiB generierte Parsertabellen im
Quellbaum; Parser und Scanner bleiben vollständig auditierbar.

Die Quellen entsprechen den Revisionen der frameworkeigenen
`CodeLanguages-Container/.../swiftpm/Package.resolved`, nicht der Auflösung
des App-Projekts. Swift verwendet ausdrücklich `parser_abi14.c`; PHP nur den
auf dem Mac aktiven PHP-Provider. YAML benötigt zusätzlich die unveränderten
Schema-Includes. Lizenzen: MIT, die vollständigen Texte liegen pro Projekt bei.

Der Build gibt Grammatik- und Scanner-Symbolen einen eigenen Namensraum;
die bestehende Regex-Hervorhebung behält ihre getrennte Grammatikrevision.
Tree-sitter 0.25.10 wird aus `../regex-syntax/runtime` wiederverwendet.

Das Cargo-Feature `syntax-folding` aktiviert den Build. Der reine Provider ist
kein GUI-Controller: Der Linux-Controller in `fastra-linux/src/folding` sichert Ressourcenisolation,
Quellrevision, Sprachwechsel und veraltete Ergebnisse ab.
