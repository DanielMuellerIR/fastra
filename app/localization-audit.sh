#!/bin/zsh
# Prüft, dass jeder statisch erkennbare SwiftUI-Text einen englischen Eintrag
# besitzt. Dynamische Enums, Vorlagen und Regex-Hilfen deckt LocalizationTests ab.
set -euo pipefail

cd "$(dirname "$0")"
tmp="$(mktemp -d /tmp/fastra-localization.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

sources=("${(@f)$(rg --files Sources/Fastra -g '*.swift')}")
xcrun xcstringstool extract --SwiftUI --legacy-localizable-strings \
  --modern-localizable-strings --output-format xcstrings \
  --output-directory "$tmp" "${sources[@]}"
plutil -convert json -o "$tmp/en.json" \
  Sources/Fastra/Resources/en.lproj/Localizable.strings

python3 - "$tmp/Localizable.xcstrings" "$tmp/en.json" <<'PY'
import json
import re
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))["strings"]
english = json.load(open(sys.argv[2], encoding="utf-8"))
symbols_only = re.compile(r"[•∗$ %@()—·©0-9]+")
missing = [
    key for key in sorted(catalog)
    if key and "%arg" not in key and key not in english
    and not symbols_only.fullmatch(key)
]
if missing:
    print("Fehlende englische SwiftUI-Schlüssel:", file=sys.stderr)
    for key in missing:
        print(f"  {key}", file=sys.stderr)
    raise SystemExit(1)

placeholder = re.compile(r"%(?:\d+\$)?(?:ld|@|d)")
def placeholder_kinds(text):
    return sorted(re.sub(r"%\d+\$", "%", match.group())
                  for match in placeholder.finditer(text))
format_mismatches = [
    key for key, value in english.items()
    if placeholder_kinds(key) != placeholder_kinds(value)
]
if format_mismatches:
    print("Unvereinbare Format-Platzhalter:", file=sys.stderr)
    for key in format_mismatches:
        print(f"  {key}", file=sys.stderr)
    raise SystemExit(1)
print(f"LOCALIZATION AUDIT: PASS — {len(catalog)} SwiftUI-Schlüssel, "
      f"{len(english)} englische Einträge")
PY
