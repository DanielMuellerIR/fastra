# F07: Lokale Datei- und Ordner-Einstiege

Das Hauptfenster nimmt native GTK-`GdkFileList`-Drops entgegen. Derselbe Adapter
verarbeitet `GApplication::open`, also Aufrufe mit lokalen Dateiparametern und
Dateiöffnungen durch den Desktop. Reguläre Dateien durchlaufen unverändert den
vorhandenen Text-/Abschnitts-/Hex-/Viewer-Loader; ein Ordner durchläuft die
bestehende Projektwahl und deren Identitätsprüfung.

Vor der Veröffentlichung prüft ein Hintergrundauftrag die vollständige Auswahl:
1–32 Einträge, nur lokale Ziele, höchstens ein Ordner, keine besonderen Dateien.
Symlinks werden aufgelöst, gleiche aufgelöste Pfade unter Erhalt der ersten
Position dedupliziert. Rohe Unix-Pfade bleiben erhalten; Tabnamen stellen
Steuerzeichen, Backslashes und ungültige UTF-8-Bytes eindeutig dar. Kein vorhandener
Tab wird ersetzt und kein Quelltext gespeichert. Die eigentlichen Ladevorgänge
bleiben unabhängig und können ihren jeweiligen vorhandenen Ladefehler zeigen.

Neue Drops sowie ein verborgenes oder geschlossenes Ursprungsfenster machen alte
Prüfergebnisse und noch ausstehende Ladevorgänge ungültig. Weder entfernte URIs
noch Drop-Text werden als lokale Dateien umgedeutet. Capture-Drag-and-drop in die
Ersetzung behält seinen eigenen Text-Datentyp.

`linux/test.sh desktop-open` prüft auf einem ausdrücklich isolierten Display mit
echten Mausbewegungen einen nativen DragSource/FileList-Transfer zwischen zwei
GTK-Fenstern: zwei Dateien einschließlich rohem Dateinamen, Dublette, Projektordner,
Ablehnung zweier Ordner, Remote-URI, veralteter Auftrag, unveränderte Plattenbytes
und bestehender Dirty-Tab. Der Hosttest prüft zusätzlich Symlinks, FIFO und Limits.
Die Xvfb-Abnahme ersetzt keine reale Desktop-/Wayland-/IME-Abnahme.
