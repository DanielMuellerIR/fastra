# F07: gespeicherte Dateien aus Tabs ziehen

Ab 1.188.0 besitzt jeder gespeicherte Tab einen eigenen Dateigriff neben dem
Namen. Der native GTK-Drag bietet eine `GdkFileList` mit COPY an. Übertragen
wird die vorhandene Datei mit ihrem letzten gespeicherten Stand; ein geänderter
Editorpuffer wird weder exportiert noch als temporäre Datei ausgegeben. Der
zweisprachige Hinweis nennt diesen Unterschied. Neue ungespeicherte Tabs haben
keinen Griff.

Die Zielidentität wird bei Beginn des Drags frisch geprüft. Gelöschte Quellen,
Ordner, defekte Verweise und die überlagerten privaten Laufzeitpfade werden
abgewiesen; reguläre Dateien und gültige Dateiverweise bleiben nutzbar. Native
Datei-URIs erhalten auch Leerzeichen, Prozent-/Rautezeichen, Unicode und unter
Linux ungültige UTF-8-Pfadbytes. Speichern unter und die erste Speicherung
aktualisieren den Griff auch bei gleichem Dateinamen. Bild-, PDF-, Hex- und
Abschnittsansichten übergeben ebenfalls die ganze gespeicherte Datei.

Die Prüfung zieht mit echten XTest-Mausereignissen in einen unabhängigen
GTK-Empfängerprozess. Der Empfänger prüft URI und gespeicherte Bytes, während
Quelle, Revision und Rücknahme des schmutzigen Editorpuffers unverändert
bleiben. Weitere Gegenfälle betreffen entfernte/umgebogene Quellen, beide
Sprachen und schmale/breite Fenster. Ein Review fand die zunächst fehlende
Aktualisierung nach später Bild-/Abschnittsbindung. Drei echte `load_path`-Fälle
mit PNG, Hex und 34,4-MiB-Abschnittsdatei reproduzieren den Fehler und bestehen
mit der Aktualisierung. Das ist noch keine Abnahme aller fremden Zielprogramme.
