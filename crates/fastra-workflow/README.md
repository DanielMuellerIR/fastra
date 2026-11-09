# Textabläufe und Textbausteine

`fastra-workflow` enthält Definitionen, begrenzte Vorschauen und eine private
lokale Sammlung. Es schreibt keine Dokumentdateien. Die GTK-Anbindung steht
unter `crates/fastra-linux/src/workflow_view*`.

`preview` bindet die vollständige Quelle, UTF-16-Auswahl, Dokumentrevision,
Generation und unveränderte Definition. `Preview::apply` liefert nur den neuen
Text und verweigert eine abweichende Basis. Der Host prüft zusätzlich die
Dokumentidentität und aktuelle Auswahl und setzt den Text in einer Undo-Gruppe.
Jeder aktivierte Schritt hat eine vollständige Vorher-/Nachher-Vorschau; das
Endergebnis enthält auch die unveränderten Dokumentteile.

Die Ausführung verwendet ausschließlich `fastra-core::PreparedSearch` und
`text_operations`. ICU-Root-Sortierung und Root-Groß-/Kleinschreibung sind keine
Zusicherung macOS-lokalisierter Gleichheit. Ein Zeilenadapter erhält wie der
Swift-Ablauf die individuellen Trenner, wenn die Inhaltszeilenzahl gleich bleibt.
Filter behalten den bestehenden Schutz gegen vollständiges Leeren bei.

Die Swift-JSON-Hüllobjekte `schemaVersion: 1` mit `workflows` beziehungsweise
`snippets` werden getrennt gelesen und exportiert. Bekannte Pflichtfelder müssen
vorhanden sein. Zusatzfelder bleiben einschließlich präziser JSON-Zahlen erhalten.
Aktivierte unbekannte Schrittarten oder unbekannte semantische Felder sperren die
Ausführung. U+0000 in bekannten Textfeldern wird für die GTK-Anbindung konkret
abgewiesen; keine native Textdarstellung darf Daten still abschneiden. Import in eine Sammlung erstellt wie beim Mac Kopien mit neuen
Kennungen/Revisionen und gegebenenfalls einem Namenszusatz. Der Namensvergleich
verwendet Unicode-Kleinschreibung, keine benutzerlokalisierte macOS-Kollation.

Grenzen: 50 Definitionen je Sammlung, 1 MiB je Import-/Exportarchiv, 32 Schritte,
4 MiB Quell-/Ausgabetext, 32 MiB gehaltene Textvorschau und fünf Sekunden pro
Ablauf. Der Zeitwächter erreicht auch laufende Core-Operationen über deren
Abbruchtoken. Fehler geben keine Teilvorschau zurück. Vorlagen/Feldwerte sind auf
16 KiB begrenzt, auf 32 verschiedene Platzhalter und auf 256 KiB expandierten Text.
Wiederholte Namen teilen einen Wert; eingesetzte Werte werden nicht erneut geparst.

Graphemgrenzen verwenden das gepinnte `unicode-segmentation` 1.13.3. Namen werden in
Graphemen gezählt; der Ablauf weist angeschnittene Auswahl-Grapheme zurück. Die bereits für
Fastra vorgeschriebene ICU-78.3-ABI liefert Kategorien für Foundations
`controlCharacters` und horizontale Unicode-Leerzeichen; keine zweite
Kategorientabelle wird mitgeführt.

`store::Store` hält einen privaten Verzeichnisdeskriptor, legt Verzeichnis/Dateien mit 0700/0600 an, prüft Eigentümer,
verweigert Gruppen-/Fremdrechte, verweigert Symlinks, besondere Dateitypen und Hardlinks und
ersetzt die Sammlung atomar mit Datei- und Verzeichnis-fsync. Eine exklusive
nicht blockierende Sperre und ein Vergleich der zuletzt gelesenen Bytes verhindern
verlorene Änderungen zwischen Werkzeugfenstern. Eine beschädigte Sammlung wird
nicht als leere Sammlung behandelt und nicht überschrieben.

Die JSON-Fixtures unter `tests/fixtures` wurden mit Swift 6.2.1 und den vorhandenen
Codable-Typen aus `TextWorkflow.swift`, `TextSnippetStore.swift` und
`TextSnippetTemplate.swift` erzeugt. Nur nicht verwendete UI-/Such-Computed-
Properties wurden für diesen reinen Foundation-Lauf entfernt. Die erwartete
Dreischritt-Ausgabe stammt aus `TextWorkflowTests.sequence`, die Unicode-Vektoren
wurden durch den originalen Swift-Templateparser ausgewertet. Das ist keine
native macOS-Abnahme.

```sh
cargo test --locked -p fastra-workflow
cargo clippy --locked -p fastra-workflow --all-targets -- -D warnings
```
