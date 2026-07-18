#!/usr/bin/env python3
"""Erzeugt Sources/Fastra/FourDSymbols.swift aus der lokalen 4D-Dokumentation.

Abgeleitet werden NAMEN (Befehle, Konstanten) sowie — seit Etappe 6 des
Wunschpakets 2026-07c — die maschinenlesbaren SYNTAX-Signaturen und
Befehlsnummern der Befehlsseiten (`<!--REF …Syntax-->`-Blöcke und die
„Command number“-Eigenschaft). Keine Beschreibungstexte, keine Beispiele.
Die 4D-Dokumentation steht unter CC BY 4.0 (LICENSE-docs im Doku-Repo);
die Attribution liegt in THIRD-PARTY-NOTICES.md und in der App-Hilfe.

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


# Syntax-Block einer Befehlsseite: <!--REF #_command_.NAME.Syntax-->…<!-- END REF-->
SYNTAX_PATTERN = re.compile(
    r"<!--REF #_command_\.[^.]+\.Syntax-->(.+?)<!--\s*END REF\s*-->", re.DOTALL
)
# Befehlsnummer aus der Properties-Tabelle: | Command number | 41 |
NUMBER_PATTERN = re.compile(r"^\|\s*Command number\s*\|\s*(\d+)", re.MULTILINE)


def clean_signature(raw: str) -> str:
    """Markdown/HTML aus der Syntax-Zeile entfernen → reiner Signatur-Text."""
    text = raw
    text = re.sub(r"<br\s*/?>", " | ", text)           # Syntax-Varianten
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # [Text](Link) → Text
    text = text.replace("**", "").replace("*", "")
    text = re.sub(r"<[^>]+>", "", text)                 # restliche Tags
    text = text.replace("&#8594;", "->").replace("&nbsp;", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def collect_command_details(base: Path) -> list[tuple[str, str, str]]:
    """(Name, Nummer, Signatur) je Befehl — Nummer/Signatur ggf. leer."""
    details: dict[str, tuple[str, str]] = {}
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
            try:
                content = md_path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            signature = ""
            if match := SYNTAX_PATTERN.search(content):
                signature = clean_signature(match.group(1))
            number = ""
            if match := NUMBER_PATTERN.search(content):
                number = match.group(1)
            # Bei Dubletten (commands/ und commands-legacy/) gewinnt der
            # Eintrag mit mehr Information.
            existing = details.get(title, ("", ""))
            details[title] = (number or existing[0], signature or existing[1])
    return sorted((name, num, sig) for name, (num, sig) in details.items())


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
    details = collect_command_details(base)
    signatures = sum(1 for _, _, sig in details if sig)
    numbers = sum(1 for _, num, _ in details if num)
    if len(commands) < 500 or len(constants) < 1000:
        print(f"FEHLER: unplausibel wenige Namen (Befehle={len(commands)}, "
              f"Konstanten={len(constants)}) — Quelle geändert?", file=sys.stderr)
        return 1
    if signatures < 800 or numbers < 800:
        print(f"FEHLER: unplausibel wenige Details (Signaturen={signatures}, "
              f"Nummern={numbers}) — Seitenformat geändert?", file=sys.stderr)
        return 1

    # Detailzeilen „Name\tNummer\tSignatur" als schlichte String-Liste —
    # riesige Dictionary-Literale würden den Swift-Typecheck ausbremsen;
    # das Parsen übernimmt FourDSymbols zur Laufzeit (lazy). Der Tab steht
    # als \\t-ESCAPE im Swift-Quelltext (literale Tabs in String-Literalen
    # lehnt der Compiler als „unprintable ASCII" ab).
    def escape(field: str) -> str:
        return field.replace("\\", "\\\\").replace('"', '\\"')

    detail_lines = [
        f'        "{escape(name)}\\t{num}\\t{escape(sig)}",'
        for name, num, sig in details
    ]
    detail_array = "\n".join(detail_lines)

    out = Path(__file__).resolve().parent.parent / "Sources" / "Fastra" / "FourDSymbols.swift"
    out.write_text(f"""// FourDSymbols.swift
//
// GENERIERT — NICHT von Hand bearbeiten.
// Quelle: lokale 4D-Dokumentation (Befehls-/Konstantennamen, Syntax-
// Signaturen und Befehlsnummern als Fakten abgeleitet; keine
// Beschreibungstexte). Die 4D-Doku steht unter CC BY 4.0 — Attribution in
// THIRD-PARTY-NOTICES.md und in der App-Hilfe. Neu erzeugen mit:
//     python3 tools/generate-4d-symbols.py
//
// Stand: {len(commands)} Befehle ({signatures} Signaturen, {numbers} Nummern),
// {len(constants)} Konstanten.

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

    /// Befehls-Details als Tab-getrennte Zeilen „Name\\tNummer\\tSignatur"
    /// (Nummer/Signatur können leer sein). Bewusst KEIN Dictionary-Literal:
    /// Tausende Einträge würden den Swift-Typecheck minutenlang beschäftigen.
    static let commandDetailLines: [String] = [
{detail_array}
    ]

    /// Ein Befehls-Detail: Signatur und `:Cnnn`-Nummer (beides optional).
    struct CommandDetail {{
        let name: String
        let number: Int?
        let signature: String?
    }}

    /// Details je Befehl, Schlüssel kleingeschrieben (case-tolerant).
    /// Einmalig lazy geparst.
    static let commandDetails: [String: CommandDetail] = {{
        var result: [String: CommandDetail] = [:]
        result.reserveCapacity(commandDetailLines.count)
        for line in commandDetailLines {{
            let parts = line.components(separatedBy: "\\t")
            guard parts.count == 3, !parts[0].isEmpty else {{ continue }}
            result[parts[0].lowercased()] = CommandDetail(
                name: parts[0],
                number: Int(parts[1]),
                signature: parts[2].isEmpty ? nil : parts[2]
            )
        }}
        return result
    }}()
}}
""", encoding="utf-8")
    print(f"OK: {out} — {len(commands)} Befehle, {len(constants)} Konstanten, "
          f"{signatures} Signaturen, {numbers} Nummern")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
