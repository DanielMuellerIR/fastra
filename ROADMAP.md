# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Wunschpaket Juli 2026** (beschlossen 2026-07-17): sechs Etappen in dieser
  Reihenfolge — 1. kleine UX-Verbesserungen (CMD+N im Willkommenszustand,
  Elternordner beim Einzeldatei-Öffnen, Standard-Speicherort, leere Ordner
  ohne Aufklapp-Chevron, sichtbarer statt stiller Ordnerwechsel),
  2. Ansichts-Umschalter mit Bild-/PDF-Vorschau und manuellem Hex-Zugang,
  3. inhaltsbasierte Spracherkennung für ungespeicherte Dokumente,
  4. 4D-Unterstützung (eigener Highlight-Provider, keine neue
  tree-sitter-Grammatik), 5. XPath-Navigation für XML, 6. natives
  JSON/XML-Lint und -Minify plus optionale tool4d-Anbindung. Der
  vollständige Goal-Prompt mit Kontextfakten und Leitplanken liegt lokal in
  `~/Desktop/fastra/goal-vorschlag.md` (samt 4D-Farbvorgaben `dark.json`/
  `light.json`; zu Beginn der Umsetzung ins Repo übernehmen).

## Offene Produktentscheidungen

- **Monetarisierung:** Ältere Anforderungen nennen eine kostenlose
  Testmöglichkeit als wichtig. Das aktuelle Modell beschreibt Fastra dagegen als
  Donationware ohne Lizenz- oder Trial-Wall. Vor einer Monetarisierungsfunktion
  muss dieser Widerspruch ausdrücklich entschieden werden.

## Später – nur auf ausdrückliche Anfrage

- **Cross-Platform-Portabilität (Windows/Linux):** Weder Machbarkeit noch
  Implementierung werden ohne ausdrücklichen Auftrag untersucht.
