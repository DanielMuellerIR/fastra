# Linux: Beenden über mehrere Fenster

„Fastra beenden“ und Ctrl+Shift+Q beenden die gesamte Anwendung. Ctrl+Q schließt
weiterhin das aktuelle Hauptfenster. Appweites Beenden sammelt zuerst für jedes
Fenster die ausdrückliche Entscheidung über ungesicherte Inhalte: speichern,
mit aktivierter Sitzungssicherung wiederherstellbar schließen, verwerfen oder
abbrechen. Abbrechen und Fehler erhalten alle Hauptfenster. Bereits ausdrücklich
gespeicherte Quelldateien bleiben gespeichert.

Jede Freigabe bindet die konkreten Dokumentinstanzen, ihren letzten Rich-Abgleich,
Revision, Kodierung und Speicherbasis. Ein neu geöffnetes Fenster, ein anderer
Rich-Editor, neuere Eingaben oder ein noch laufender Speichervorgang verwerfen
alte Freigaben. Der abschließende gemeinsame Check erfolgt unmittelbar vor dem
Schließen; ausstehende Dateiarbeiten und ihre letzten Zustandsprüfungen müssen
vollständig zurückgekehrt sein.

Bei aktivierter lokaler Textsicherung werden sämtliche neuen Schließkopien zuerst
dauerhaft publiziert. Bestehende Wiederherstellungsstände bleiben bis zum
vollständigen Abschluss erhalten. Scheitert ein anderes Fenster, werden die zuvor
übernommenen Sessionzustände zurückgesetzt. Erst nach dem wirklichen Entfernen
aller freigegebenen Fenster werden alte Sicherungsstände bereinigt. Ein neuer
Dateiaufruf während der anschließenden Bereinigung erhält sein neues Fenster.
Der lokale Steuerungsdienst endet erst nach diesem Abschluss.

Bild-Apply, Rücknahme und verschachtelte Wiederherstellung besitzen einen
anwendungsweiten Arbeitsbesitz bis einschließlich ihres letzten Main-Rückrufs.
Das gilt auch für einen inzwischen entfernten Rich-Editor und ein leeres
Hauptfensterinventar. Es wird weder auf dem Main-Thread gewartet noch eine fremde
Dateiauswahl abgebrochen. Nur die zum eigenen Schließversuch gehörende offene
Dateiauswahl wird bei dessen Abbruch beendet.

Native Proben prüfen Mehrfenster-Cancel, Save/Discard, neue Fenster und Eingaben
während der Vorbereitung, Rich-Abgleichfehler, späte Sitzungsschreibfehler sowie
Beenden während echter Bildpublikation und Rücknahme. Der versionsgebundene
Nachweis steht im [Paketprotokoll](F16-1.174.0-EVIDENCE.md).

Laufende Ordner-/Projekt-/Dateiworkflow-Vorgänge schützen ebenfalls ihr eigenes
Hauptfenster vor dem Schließen. Der gemeinsame Busy-Check bleibt bis zur
Ergebnisübernahme einschließlich Journalbestätigung aktiv; das Zerstören eines
Kindfensters darf ihn nicht umgehen. Apply und Undo werden nativ mit bereits
abgeschlossener echter Dateitransaktion und noch wartendem Main-Ergebnis geprüft.
