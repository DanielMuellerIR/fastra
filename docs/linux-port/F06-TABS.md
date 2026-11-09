# F06/F08: gemeinsame Vorschau für offene Texttabs

Der Linux-Suchbereich „Alle editierbaren Tabs“ erstellt eine einzige gebundene
Vorschau aller vollständig geladenen, aktuell im Quelltext bearbeitbaren Tabs.
Schreibgeschützte und aktive Rich-Ansichten werden sichtbar gezählt und
übersprungen. Dateien werden durch diesen Bereich nicht gespeichert.

`fastra-core::batch` bindet Dokumentidentität, Reihenfolge, Revision, Quelltext
und Suchgeneration einschließlich Dokumenten ohne Treffer. Der Suchplan wird
vollständig berechnet und nochmals gegen den gesamten Dokumentbestand geprüft,
bevor die erste GTK-Änderung erfolgt. Es gelten höchstens 128 Dokumente,
4 MiB je Eingabe, 64 MiB gemeinsame Quellen und 10.000 Treffer. Überschreitungen
liefern keine teilweise anwendbare Vorschau.

Die native Oberfläche verwendet dieselbe Vorher-/Nachher- und Trefferfreigabe
wie die Ordnersuche. Jede geänderte Datei erhält eine native Undo-Aktion im
Editor. Eine zusätzliche gemeinsame Rücknahme prüft sämtliche Ergebnisstände,
einschließlich unveränderter Dokumente, bevor sie Originaltexte wieder einsetzt.
Ein Tabwechsel allein verändert die Dokumentidentität nicht; veränderte Texte,
neue oder geschlossene Tabs und native Undo-Aktionen können die gemeinsame
Rücknahme dagegen ungültig machen. Deren ausdrücklich beschriftetes Verwerfen
ändert keine Texte und erhält die normale Editorhistorie.

Acht reine Kernprüfungen bestehen für selektive Freigaben, Dokumentzugehörigkeit,
wirkungslose Eingaben, Revisionen, Grenzen, Abbruch und gemeinsame Rücknahme.
Der echte GTK-Ablauf prüft selektive Treffer über mehrere Tabs, ein natives Undo,
veraltete gemeinsame Rücknahme samt bewusstem Verwerfen, erfolgreiche gemeinsame
Rücknahme, geänderte Nichttreffer und veränderte Mitgliedschaft. Alle vier
DE-/EN-Fensterläufe bei 640/1100 Pixeln bestanden und wurden visuell geprüft.
Die aktuellen Befunde stammen aus privaten Xvfb-Sitzungen; die native
Desktop-/IME-Abnahme bleibt separat offen.

Die gemeinsame Freigabeansicht berechnet den vollständigen Nachher-Text im
Hintergrund. Bis beide Seiten fertig angezeigt werden, gibt sie keine Freigaben
zum Anwenden zurück. Ein Darstellungswechsel besitzt eine eigene Generation
und Cancellation. Ein optionaler verlustfreier Escape-Modus stellt sämtliche
Nicht-ASCII-Zeichen, Steuerzeichen, Backslashes und Zeilenenden eindeutig dar;
NFC und NFD bleiben dadurch unterscheidbar. 16 MiB je Darstellungsseite sind eine
harte Grenze, keine Kürzung. Der GUI-Test prüft zusätzlich Unicode-Ausgabe,
Abweisung während des Renderns und schnelle wechselnde Darstellungsanforderungen.

Beim Ausblenden des Hauptfensters wird die Mehrtab-Ansicht geschlossen und
ihre aktive Arbeit abgebrochen. Der letzte gemeinsame Apply-/Undo-Preflight
verlangt zusätzlich die sichtbare Elternansicht. Gemeinsame Rücknahme gleicht
den Dirty-Zustand gegen die gespeicherte Dokumentbasis ab. Die native Regression
prüft sowohl erhaltene vorher ungespeicherte Inhalte als auch eine wieder
saubere Basis sowie Parent-Hide unmittelbar nach dem Apply-Klick.
