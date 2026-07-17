#!/usr/bin/env python3
"""Erzeugt Sources/Fastra/FourDSymbols.swift aus der lokalen 4D-Dokumentation.

Abgeleitet werden ausschließlich NAMEN (Befehle, Konstanten) als eigene,
generierte Datenstruktur — keine Doku-Texte, keine Beschreibungen, keine
Beispiele (Fastra ist öffentlich; die Lizenz der 4D-Doku ist ungeklärt,
reine Bezeichner-Listen sind Fakten).

Aufruf (vom Repo-Root oder app/):
    python3 tools/generate-4d-symbols.py [PFAD-ZUR-4D-DOKU]

Standard-Quelle: ~/git/4d-docs-v21 (versioned_docs/version-21/commands*/).
"""

import re
import sys
from pathlib import Path

# Seiten in commands*/, die KEINE Befehle beschreiben (Index-/Themenseiten).
EXCLUDED_IDS = {
    "command-index",   # „Commands by name" — Index
    "constant-list",   # Konstantenliste (separat verarbeitet)
    "4d",              # Namespace-/Klassenbeschreibung, kein Befehl
}

# Ein gültiger 4D-Befehlsname: Wortzeichen und einzelne Leerzeichen/Punkte
# (z. B. „ABORT PROCESS BY ID", „Abs", „WEB SERVICE Get result").
NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*(?: [A-Za-z0-9_.&-]+)*$")


def extract_title(md_path: Path) -> str | None:
    """Liest den Frontmatter-Titel einer Doku-Seite."""
    try:
        head = md_path.read_text(encoding="utf-8", errors="ignore")[:600]
    except OSError:
        return None
    match = re.search(r"^title:\s*(.+)$", head, re.MULTILINE)
    return match.group(1).strip() if match else None


def collect_commands(base: Path) -> list[str]:
    commands: set[str] = set()
    for folder in ("commands", "commands-legacy"):
        directory = base / folder
        if not directory.is_dir():
            continue
        for md_path in directory.glob("*.md"):
            if md_path.stem.lower() in EXCLUDED_IDS:
                continue
            title = extract_title(md_path)
            if not title or not NAME_PATTERN.match(title):
                continue
            commands.add(title)
    return sorted(commands)


def collect_constants(base: Path) -> list[str]:
    """Englische Spalte der Konstantenliste (Markdown-Tabelle)."""
    path = base / "commands-legacy" / "constant-list.md"
    if not path.is_file():
        return []
    constants: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 2 or cells[0] in ("English", "---", ""):
            continue
        name = cells[0]
        # Konstanten dürfen mit Ziffern beginnen („4D Server") und
        # Bindestriche/Punkte enthalten; alles andere ist Tabellenrauschen.
        if re.match(r"^[A-Za-z0-9_][A-Za-z0-9_.&+-]*(?: [A-Za-z0-9_.&+-]+)*$", name):
            constants.add(name)
    return sorted(constants)


def swift_array(names: list[str], indent: str = "        ") -> str:
    lines = [f'{indent}"{name.replace(chr(92), chr(92) * 2).replace(chr(34), chr(92) + chr(34))}",'
             for name in names]
    return "\n".join(lines)


def main() -> int:
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "git" / "4d-docs-v21"
    base = source / "versioned_docs" / "version-21"
    if not base.is_dir():
        print(f"FEHLER: Quelle nicht gefunden: {base}", file=sys.stderr)
        return 1

    commands = collect_commands(base)
    constants = collect_constants(base)
    if len(commands) < 500 or len(constants) < 1000:
        print(f"FEHLER: unplausibel wenige Namen (Befehle={len(commands)}, "
              f"Konstanten={len(constants)}) — Quelle geändert?", file=sys.stderr)
        return 1

    out = Path(__file__).resolve().parent.parent / "Sources" / "Fastra" / "FourDSymbols.swift"
    out.write_text(f"""// FourDSymbols.swift
//
// GENERIERT — NICHT von Hand bearbeiten.
// Quelle: lokale 4D-Dokumentation (Befehls-/Konstantennamen als Fakten
// abgeleitet, keine Doku-Inhalte). Neu erzeugen mit:
//     python3 tools/generate-4d-symbols.py
//
// Stand: {len(commands)} Befehle, {len(constants)} Konstanten.

import Foundation

enum FourDSymbols {{
    /// Alle bekannten 4D-Befehlsnamen (englisch, teils mehrwortig).
    /// Kanonische Schreibweise; Matching erfolgt case-tolerant.
    static let commands: [String] = [
{swift_array(commands)}
    ]

    /// Alle bekannten 4D-Konstantennamen (englisch, teils mehrwortig).
    static let constants: [String] = [
{swift_array(constants)}
    ]
}}
""", encoding="utf-8")
    print(f"OK: {out} — {len(commands)} Befehle, {len(constants)} Konstanten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
