# F01: konsistente GTK-Zeilenmetadaten

Der gemeinsame Auswahl-Return-Test mit dem neuen Bibliothekspaar fand eine
weitere Grenze der unveränderten GTK-4.14.5-Basis: Der Text war nach Undo exakt
wiederhergestellt, der ausschließlich aus Metadaten berechnete Bytezähler aber
ungültig. Ein zusätzlicher Diagnoseaufruf ließ den Fehler verschwinden.

`gtk_text_iter_get_bytes_in_line` las den zwischengespeicherten Segmentbyteoffset,
bevor `_gtk_text_iter_get_indexable_segment` den Iterator wieder gültig machte.
Nach einer erlaubten Segmentänderung konnte dieser Offset noch den internen
Ungültigkeitswert −10000 enthalten. Der erste Aufruf lieferte dadurch 10007
statt 5; erst der zweite Aufruf war richtig. Das verletzt den bestehenden
öffentlichen Gettervertrag, ohne eine fehlende Undoaktion zu bedeuten.

Der private GTK-Patch aktualisiert den Iterator vor dem Lesen des Offsets.
Die Anwendung kopiert weder das Dokument neu noch ruft sie den Getter zur
verdeckten Cacheheilung zweimal auf. Ein unabhängiger Gegenbeleg benutzt den
Getter nach einer Markeinfügung genau einmal. Eine gezählte Buffer-Subclass
prüft zusätzlich Auswahlersatz und Undo: auf der alten Bibliothek falsche
Löschlängen und ungültiger Cache, mit der Korrektur exakte Längen 8/1 und
wiederhergestellte 16 Textbytes bei gültigem Cache.

Die nur lesbare UInt-Property `fastra-iter-metadata-abi-v1` auf GtkTextBuffer
bestätigt diesen gekoppelten privaten Vertrag mit `0x49545231` (`ITR1`). Die
Anwendung prüft Owner, Typ, Flags und tatsächlichen Wert vor dem Laden von
Dokumenten. Eine alte Runtime mit Returnplan, aber ohne korrigierte Metadaten,
ist somit ebenfalls kein akzeptierter Laufzeitpartner.

Der zusätzliche Buildpfad bindet sowohl `gtktextiter.c` als auch die
Propertyergänzung in `gtktextbuffer.c` an ihre exakten Ausgangs-/Zielhashes.
GTK wird vollständig aus der authentifizierten Distributionsquelle neu gebaut;
Pango und GtkSourceView bleiben in diesem Schritt unverändert. Die vorherigen
Runtimefassungen bleiben als begrenzte historische Prototypen erhalten und
werden nicht als neue Abnahme ausgegeben.
