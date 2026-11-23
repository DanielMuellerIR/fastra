#!/usr/bin/env python3
"""Schmales SwiftLint-Gate; schreibt weder Quellen noch Baseline."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

VERSION = "0.65.1"
RULES = ["force_cast", "force_try", "force_unwrapping"]
FIELDS = {"file", "line", "character", "rule", "reason", "line_sha256"}


def fail(message):
    raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path):
    mode = path.lstat().st_mode
    if not stat.S_ISREG(mode) or not mode & 0o444:
        fail(f"Keine lesbare reguläre Datei: {path}")
    return path.read_bytes()


def load_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail(f"Doppelter JSON-Schlüssel: {key}")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def inventory(root):
    sources = root / "app/Sources"
    for directory in (root / "app", sources):
        if not stat.S_ISDIR(directory.lstat().st_mode):
            fail(f"Kein reguläres Quellverzeichnis: {directory}")
    files = {}

    def walk(directory):
        mode = directory.lstat().st_mode
        if not mode & 0o444 or not mode & 0o111:
            fail(f"Nicht lesbares Quellverzeichnis: {directory}")
        for path in sorted(directory.iterdir()):
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                fail(f"Symlink im Quellbaum: {path}")
            if path.suffix == ".swift" and not stat.S_ISREG(mode):
                fail(f"Keine reguläre Swift-Datei: {path}")
            if stat.S_ISDIR(mode):
                walk(path)
            elif path.suffix == ".swift":
                files[path.relative_to(root).as_posix()] = regular_bytes(path)
    walk(sources)
    if not files:
        fail("Keine Swift-Quelldateien unter app/Sources")
    return files


def run(command, root):
    return subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=120)


def validate_entries(entries):
    if not isinstance(entries, list):
        fail("Diagnosen müssen eine JSON-Liste sein")
    for item in entries:
        if not isinstance(item, dict) or set(item) != FIELDS:
            fail("Ungültige Baseline-Diagnosefelder")
        path = item["file"]
        if (not isinstance(path, str) or not path.startswith("app/Sources/")
                or not path.endswith(".swift") or "\\" in path
                or any(part in ("", ".", "..") for part in path.split("/"))):
            fail("Ungültiger relativer Diagnosepfad")
        for field in ("line", "character"):
            if type(item[field]) is not int or item[field] <= 0:
                fail(f"Ungültige Diagnoseposition: {field}")
        if item["rule"] not in RULES or not isinstance(item["reason"], str) or not item["reason"]:
            fail("Ungültige Regel oder Diagnose")
        if not isinstance(item["line_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", item["line_sha256"]):
            fail("Ungültiger Quellzeilenhash")
    return Counter(json.dumps(item, sort_keys=True) for item in entries)


def scan(root, config, files, tool):
    version = run([tool, "version"], root)
    if version.returncode != 0 or version.stdout.strip() != VERSION or version.stderr:
        fail(f"SwiftLint {VERSION} erforderlich; Versionsprüfung fehlgeschlagen")
    result = run([tool, "lint", "--config", str(config), "--disable-sourcekit",
                  "--strict", "--no-cache", "--quiet", "--reporter", "json",
                  *[str(root / path) for path in files]], root)
    if result.returncode not in (0, 2) or result.stderr:
        fail(f"SwiftLint-Ausführung fehlgeschlagen (Exit {result.returncode}): {result.stderr.strip()}")
    raw = load_json(result.stdout)
    if not isinstance(raw, list):
        fail("SwiftLint lieferte keine Diagnoseliste")
    entries = []
    for item in raw:
        if (not isinstance(item, dict) or set(item) != {
                "file", "line", "character", "rule_id", "reason", "severity", "type"}
                or item["severity"] not in ("Warning", "Error")
                or not isinstance(item["type"], str) or not item["type"]
                or not isinstance(item["file"], str)):
            fail("Ungültiges SwiftLint-JSON-Schema")
        path = Path(item["file"])
        if not path.is_absolute():
            path = root / path
        # Normierung erlaubt relative Reporterpfade, aber keine fremden Dateien.
        relative = Path(os.path.abspath(path)).relative_to(root).as_posix()
        if relative not in files:
            fail("SwiftLint meldet eine Datei außerhalb der Inventur")
        line = item["line"]
        lines = files[relative].splitlines(keepends=True)
        if type(line) is not int or not 1 <= line <= len(lines):
            fail("SwiftLint meldet eine ungültige Zeile")
        entries.append({"file": relative, "line": line, "character": item["character"],
                        "rule": item["rule_id"], "reason": item["reason"],
                        "line_sha256": digest(lines[line - 1])})
    validate_entries(entries)
    if (result.returncode == 0) != (not entries):
        fail("SwiftLint-Exit und Diagnosen widersprechen sich")
    return sorted(entries, key=lambda item: json.dumps(item, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--export", action="store_true", help="Diagnosebestand nach stdout; keine Baseline schreiben")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    config = root / "app/swift-lint-configuration.json"
    files = inventory(root)
    config_bytes = regular_bytes(config)
    if load_json(config_bytes) != {"only_rules": RULES}:
        fail("Konfiguration muss ausschließlich die drei freigegebenen Regeln enthalten")
    tool = os.environ.get("SWIFTLINT_BIN") or shutil.which("swiftlint")
    if not tool:
        fail("SwiftLint fehlt: SWIFTLINT_BIN setzen oder CLI in PATH bereitstellen")
    entries = scan(root, config, files, tool)
    if inventory(root) != files or regular_bytes(config) != config_bytes:
        fail("Quellen oder Konfiguration wurden während des Scans geändert")
    # Auch Stringbeispiele gelten konservativ als Steuerung: kein Swift-Lexer.
    controlled = {path: digest(data) for path, data in files.items()
                  if re.search(r"swiftlint\s*:", data.decode("utf-8"), re.IGNORECASE)}
    actual = {"schema": 1, "tool_version": VERSION,
              "configuration_sha256": digest(config_bytes), "diagnostics": entries,
              "controlled_sources": controlled}
    if args.export:
        print(json.dumps(actual, indent=2, ensure_ascii=False))
        return 0
    baseline = load_json(regular_bytes(args.baseline or root / "app/swift-lint-baseline.json"))
    if (not isinstance(baseline, dict) or set(baseline) != set(actual)
            or type(baseline["schema"]) is not int or baseline["schema"] != 1
            or baseline["tool_version"] != VERSION
            or baseline["configuration_sha256"] != actual["configuration_sha256"]):
        fail("Baseline-Schema, Toolversion oder Konfigurationshash passt nicht")
    controls = baseline["controlled_sources"]
    if not isinstance(controls, dict):
        fail("Baseline-Steuerquellen müssen eine Pfad-Hash-Map sein")
    for path, source_hash in controls.items():
        if (path not in files or not isinstance(source_hash, str)
                or not re.fullmatch(r"[0-9a-f]{64}", source_hash)):
            fail("Ungültiger Baseline-Steuerquellpfad oder Vollbytehash")
    if controls != controlled:
        fail("Steuerquellen weichen ab; vollständige Quellen und Baseline bewusst prüfen")
    expected = validate_entries(baseline["diagnostics"])
    observed = validate_entries(entries)
    new, stale = observed - expected, expected - observed
    if new or stale:
        for label, differences in (("NEU", new), ("VERALTET", stale)):
            for entry, count in sorted(differences.items()):
                print(f"{label} ({count}): {entry}", file=sys.stderr)
        fail("Baseline weicht ab; Befunde und Baseline bewusst prüfen")
    print(f"SwiftLint-Gate bestanden: {len(files)} Dateien, {len(entries)} bekannte Diagnosen.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"SwiftLint-Gate fehlgeschlagen: {error}", file=sys.stderr)
        sys.exit(1)
