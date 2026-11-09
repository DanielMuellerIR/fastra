# F12: Markdown-Inlinebefehle im Quellmodus

Ab 1.188.0 bietet die sichtbare Zeile „Markdown-Quelltext“ die vier Befehle
Fett, Kursiv, Markierung und Inlinecode. Sie gilt nur bei gewähltem Markdownformat
im Quellmodus; Rich behält seine eigene Werkzeugleiste. Die Befehle folgen dem
bestehenden Mac-Verhalten: enthaltene oder direkt umgebende Marker entfernen,
sonst ein Markerpaar ergänzen; ohne Auswahl bleibt die Einfügemarke in der Mitte.

Ein Auftrag bindet Dokument, aktive Teilansicht, Buffer, Auswahl, Revision,
Sprache und Modus. Ein später veränderter Zustand, Rechteckauswahl, Readonly
oder laufender Schließdialog verhindert die Änderung. Das vollständige Ergebnis
wird vor der Mutation auf 32 MiB, 64 KiB pro logischer Zeile und NUL geprüft.
Die Prüfung liest den bereits begrenzten Buffer synchron; sie verspricht keine
Millisekundengrenze. Eingefügt oder entfernt werden nur die Marker, nicht der
unveränderte Inhalt. Eine unabhängige Auswahl im Inneren der anderen Teilansicht
bleibt erhalten.

Jeder angenommene Befehl bildet eine Rücknahmeaktion. Eine unmittelbar davor
liegende leere Useraktion trennt den bekannten System-GTK-Gruppenfehler nach
Redo für diesen konkreten Befehlsweg. Sie wird erst nach allen Ablehnungsprüfungen
ausgeführt; eine Ablehnung erhält vorhandenes Redo. Die private Laufzeit behandelt
die allgemeine Historygrenze getrennt.

Drei reine Prüfungen vergleichen Markerfälle, Unicode, Kombinationszeichen,
CRLF und unveränderte Nachbarbytes. Echte GTK-/XTest-Läufe bedienen alle vier
Buttons auf beiden Quellansichten, Deutsch/Englisch, Mindestbreite und breit,
im System- und optionalen Laufzeitpfad. Geprüft sind Wrap/Unwrap, leeres Paar,
ein Undo/Redo, unabhängige Peer-Auswahl und die Ablehnungszustände. Neue Shortcuts,
Block-/Listen-/Linkbefehle und vollständige Markdown-Assistenzparität sind nicht
Teil dieses begrenzten Vertrags.
