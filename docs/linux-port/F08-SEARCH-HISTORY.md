# Linux-Suchpaarverlauf

Der Linux-Verlauf überträgt den Vertrag aus `SearchHistory.swift`: höchstens
15 exakte Such-/Ersetz-Paare, zuletzt verwendet zuerst, identische Paare nach
oben verschieben, verschiedene Ersatztexte getrennt halten, leere Suche
ignorieren und die gemeinsame Liste ausdrücklich leeren. Die Auswahl füllt
beide Felder, erhält Modus, Flags und Bereich und entwertet über die normalen
Entry-Signale jede alte Vorschau. Sie führt keine Suche oder Ersetzung aus.

Der sichtbare native GTK-Menüknopf neben dem Suchbereich ist per Maus und
Tastatur erreichbar; Alt+H öffnet das Popover. Vorschauaktionen im Hauptfenster,
in der Alle-Tabs-Vorschau sowie im Ordner-/Projektfenster merken das Paar.
Tippen und Verlaufsauswahl speichern nichts. Gespeicherte Textabläufe tragen
keine unbeteiligten Suchformularwerte ein.

`fastra-workflow::search_history` nutzt die gemeinsame `PrivateStore`-Ablage
unter `$XDG_CONFIG_HOME/fastra-search-history` (sonst
`$HOME/.config/fastra-search-history`). Der Ordner ist privat (0700), Dateien
sind 0600. Datei-/Ordnersymlinks, Hardlinks, fremde oder zu offene Dateien,
ungültige Formate, übergroße Dateien und eine belegte Sperre werden abgewiesen.
Jede Änderung liest frisch und wiederholt eine kollidierende CAS-Änderung
höchstens sechsmal. Alte Fenster schreiben keinen veralteten Gesamtstand
zurück. Maximal 64 KiB je Feld begrenzen Speicher- und JSON-Aufwand; Fehler
werden sichtbar gemeldet, ohne die eigentliche Suche zu sperren oder auf
flüchtige Ersatzdaten auszuweichen.

Alle produktiven Dateizugriffe laufen außerhalb des GTK-Threads. Eine begrenzte
serielle Auftragsliste erhält die Reihenfolge diskreter Aktionen und eines
expliziten Leerens. Bereits angenommene Aufträge können nach dem Fensterschluss
fertig speichern. Rückgaben ändern ausschließlich das zugehörige noch sichtbare
Fenster; sie übernehmen keine Felder oder Dokumente. Öffnen liest die gemeinsame
Liste neu. Such-/Ersetztexte können persönliche Informationen enthalten und
werden ausdrücklich durch Suchaktionen lokal gespeichert.

Prüfung: fünf Storetests decken Wiederöffnung, exakte Paare, Reihenfolge,
15er-Grenze, Unicode/Mehrzeilen/Nullzeichen, Zweifenster-Merge, Clear ohne
Wiederbelebung, CAS-Rennen samt Retrygrenze, beschädigte Dateien, Größenlimits,
0600/0700, Symlinks, Hardlinks und belegte Sperren ab. Der native Selbsttest
`linux/test.sh search-history` prüft echten Mausaufruf und Clear, Tastaturwahl
und Alt+H, vollständige Feldfüllung, unveränderte Flags und Bereich,
Vorschauentwertung, Tippen ohne Speicherung, Zweifenster-/Neuladeverhalten,
15 sichtbare Paare und sichtbare Fehler ohne Überschreiben. Deutsch und
Englisch werden bei 760 und 1100 Pixeln geprüft; die gerenderten Popovers und
Hauptfenster werden visuell abgenommen. Dies ersetzt keine allgemeine
Desktop-/IME-Abnahme.
