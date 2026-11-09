# F16 – Paned-A/B-Beleg

2026-11-05 UTC. A: unveränderter Commit `7aea37ab9c6422e711675fa5ae34447ed96c8390`, Version 1.163.0. B: exakt dasselbe Archiv mit ausschließlich `main.rs`: `i32::MAX` durch `max_position()` ersetzt und bei eingeklappter Suche nach geänderter Maximalposition nachgeführt. Alle Archivdateien wurden verglichen; nur diese eine Datei unterscheidet sich. Binär- und Image-SHA256 stehen in der JSON-Datei.

Je 16 frische Prozesse, acht SVG und acht PDF, jeweils privates Xvfb und D-Bus im netzlosen Wegwerfcontainer. Identische Ressourcen/ICU aus dem ursprünglichen Tar, nach Entpacken verschoben; für B wurde nur die freigegebene Binary ersetzt. Fenster 1400×1000, Aufnahme nach sechs Sekunden und danach Resize 1390×990 → 1400×1000. Ctrl+S unverändert wie im ursprünglichen Smoke. Die fünf Eingabehashes blieben in beiden Reihen erhalten.

A hatte **1/16 weiße Starts** (PDF 1/8, SVG 0/8), Versuch 14. Der Dokumentbereich blieb auch nach Resize weiß. B hatte **0/16 weiße Starts**, auch nach Resize. Alle 32 anfänglichen Aufnahmen wurden visuell als Kontaktblätter geprüft. Die ergänzende Inhaltszählung betrachtet ausschließlich den Viewer-Innenbereich (400,310)–(1000,800): der Fehlerframe besitzt dort null Inhaltsfarben/ dunkle Textpixel, SVG rund 131881, PDF rund 32862. Die vollständigen Einzelzählungen sind beigefügt; dies ersetzt keine Sichtprüfung.

Die Reproduktion stützt den Paned-Fix, ist allein kein deterministischer Kausalitäts- oder vollständiger Releasebeweis. Der ursprüngliche 1.163-P2 und seine früheren Aufnahmen werden nicht umgedeutet oder überschrieben. Der gezielte native Collapse-/Vergrößerungstest prüft den Allokations-/Überlaufmechanismus separat.


Die spätere Sichtprüfung des vollständigen Fensters zeigte beim isolierten
Zwischenstand außerdem einen unsichtbaren Expanderkopf: `shrink-end-child=true`
erlaubte dessen Höhe null. Der integrierte Stand erhält deshalb zusätzlich die
Mindesthöhe des Suchbereichs. Die 16 B-Läufe belegen den Viewer-Inhalt des
isolierten Zwischenstands, keine Abnahme dieser späteren vollständigen UI-Korrektur.
