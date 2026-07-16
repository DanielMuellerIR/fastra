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
import pathlib
import re
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))["strings"]
english = json.load(open(sys.argv[2], encoding="utf-8"))
literal_pattern = re.compile(
    r'L10n\.(?:string|format)\(\s*"((?:\\.|[^"\\])*)"', re.DOTALL
)
literal_keys = set()
for source in pathlib.Path("Sources/Fastra").rglob("*.swift"):
    text = source.read_text(encoding="utf-8")
    for raw in literal_pattern.findall(text):
        # String-Interpolation ist kein statisch bestimmbarer Schlüssel. Alle
        # echten literalen Escapes entsprechen für unsere Schlüssel JSON.
        if r"\(" in raw:
            continue
        try:
            literal_keys.add(json.loads('"' + raw + '"'))
        except json.JSONDecodeError:
            print(f"Nicht lesbares L10n-Literal in {source}: {raw}", file=sys.stderr)
            raise SystemExit(1)
symbols_only = re.compile(r"[•∗$ %@()—·©0-9]+")
missing = [
    key for key in sorted(set(catalog) | literal_keys)
    if key and "%arg" not in key and key not in english
    and not symbols_only.fullmatch(key)
]
if missing:
    print("Fehlende englische SwiftUI-Schlüssel:", file=sys.stderr)
    for key in missing:
        print(f"  {key}", file=sys.stderr)
    raise SystemExit(1)

# Foundation-Formattypen, die in sichtbaren Fastra-Texten vorkommen bzw. für
# Zähler realistisch sind. Längere Integer-Typen müssen vollständig verglichen
# werden; `%lld` darf nicht als ein unbekannter Rest durchrutschen.
placeholder = re.compile(
    r"%(?:\d+\$)?(?:lld|llu|ld|lu|zd|zu|@|d|i|u|f|g|s)"
)
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
      f"{len(literal_keys)} literale L10n-Schlüssel, "
      f"{len(english)} englische Einträge")
PY
