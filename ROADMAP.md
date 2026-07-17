# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Wunschpaket Juli 2026** (beschlossen 2026-07-17): Die sechs Etappen sind
  mit v1.20.0–v1.25.0 umgesetzt (Spezifikation samt 4D-Farbvorgaben liegt in
  `docs/wunschpaket-2026-07/`). Bewusst offen geblieben:
  - **tool4d-Anbindung (4D-Lint) zurückgestellt:** tool4d arbeitet
    projektbasiert; Einzeldatei-Diagnosen erfordern den LSP-Modus
    (dauerhafter Serverprozess, JSON-RPC) und die Nutzungsbedingungen für
    den Aufruf durch Dritt-Tools sind nicht abschließend geklärt. Statt der
    Integration liefert Fastra eine Anleitung in `docs/tool4d.de.md` und
    `docs/tool4d.md`. Wiedervorlage nur mit geklärten Bedingungen und
    tragfähigem Einzeldatei-Konzept.
  - **4D-Farbdetails:** Underline (Konstanten) kennt das CESE-Attributmodell
    nicht; `errors`/`plug_ins`/`member` aus den Farbvorgaben entfallen
    mangels Analyse bzw. Unterscheidbarkeit (siehe Slot-Mapping in
    `EditorView.swift`).
  - **Fenster-Selbsttest-Nachholung (Stand 2026-07-17):** Die neuen
    Selbsttests `highlight4d` und `xpath` sowie die fokusabhängigen Tests
    (`cmdw`, `newwindow`, `multisearch`, `navmatch`) konnten am Abend nicht
    mehr laufen (Bildschirm gesperrt bzw. aktiver Desktop entzog den
    Fokus — bekannte Umgebungs-Falle, siehe docs/BUILD-AND-TEST.md). Auf
    einer entsperrten, ruhigen UI-Sitzung `./selftest.sh` vollständig
    ausführen; die fensterlosen Tests und alle Unit-Tests (1072) liefen
    zum v1.25.0-Stand grün. Eintrag nach grünem Lauf entfernen.

## Offene Produktentscheidungen

- **Monetarisierung:** Ältere Anforderungen nennen eine kostenlose
  Testmöglichkeit als wichtig. Das aktuelle Modell beschreibt Fastra dagegen als
  Donationware ohne Lizenz- oder Trial-Wall. Vor einer Monetarisierungsfunktion
  muss dieser Widerspruch ausdrücklich entschieden werden.

## Später – nur auf ausdrückliche Anfrage

- **Cross-Platform-Portabilität (Windows/Linux):** Weder Machbarkeit noch
  Implementierung werden ohne ausdrücklichen Auftrag untersucht.
