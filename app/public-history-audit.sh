#!/bin/zsh
# public-history-audit.sh — Wächter gegen interne Angaben in dem, was zum
# ÖFFENTLICHEN Remote geht. Gegenstück zu help-audit.sh, gleiche Mechanik.
#
# Warum überhaupt: Commit-Nachrichten entstehen im Moment der Arbeit, wo
# Rechnername und Testumgebung genau die nützliche Information sind — und sie
# werden erst Wochen später öffentlich. Am 2026-07-28 gingen so Rechnernamen
# und Personenbezüge in 50 Commits mit; im Dateiinhalt ließ sich das vor dem
# Push noch generalisieren, in der History nicht mehr.
#
# Geprüft wird ausschließlich der AUSGEHENDE Stand (`<remote>/<branch>..HEAD`).
# Bereits veröffentlichte Commits sind ohnehin nicht mehr zu korrigieren; sie
# hier zu melden würde den Wächter dauerhaft rot färben und damit wertlos machen.
#
# Zwei Musterquellen:
#   1. Eingebaut und public-safe: private IP-Bereiche, absolute Home-Pfade,
#      E-Mail-Adressen, ssh-Remotes. Nur gegen COMMIT-NACHRICHTEN — im Code
#      sind solche Zeichenketten oft legitime Beispiele (etwa „192.168.1.1"
#      als Beispieltreffer des IPv4-Suchmusters).
#   2. Optional und lokal: eine gitignorierte Datei mit den eigenen internen
#      Namen (Rechnernamen, interne Hosts). Die gehört NICHT ins öffentliche
#      Repo — sonst veröffentlicht der Wächter genau das, wovor er schützt.
#      Diese Muster laufen gegen Nachrichten UND hinzugefügte Zeilen.
#
# Aufruf:
#   ./public-history-audit.sh            Normallauf: Hinweis, Exit 0.
#   ./public-history-audit.sh --release  Release-Modus: harter Fehler (Exit 1).
#
# Exit-Codes:
#   0 = nichts gefunden (oder Fund im Normallauf, nur als Hinweis)
#   1 = Fund im Release-Modus
#   2 = Umgebungsproblem (kein öffentliches Remote bekannt) — kein Befund
#
# Steuerbar für Tests und andere Clones:
#   FASTRA_PUBLIC_REMOTE   Name des öffentlichen Remotes (Default: github)
#   FASTRA_PUBLIC_BRANCH   Branch dort (Default: main)
#   FASTRA_PRIVATE_PATTERNS  Pfad zur lokalen Musterdatei
#                            (Default: app/public-history-patterns.local)
set -euo pipefail

release=0
[[ "${1:-}" == "--release" ]] && release=1

cd "$(dirname "$0")/.."

remote="${FASTRA_PUBLIC_REMOTE:-github}"
branch="${FASTRA_PUBLIC_BRANCH:-main}"
patterns_file="${FASTRA_PRIVATE_PATTERNS:-app/public-history-patterns.local}"

if ! git rev-parse --verify --quiet "refs/remotes/$remote/$branch" >/dev/null; then
    echo "PUBLIC HISTORY AUDIT: SKIP — kein Ref $remote/$branch bekannt." >&2
    echo "  Erst 'git fetch $remote' ausführen, sonst ist der ausgehende Stand unbekannt." >&2
    exit 2
fi

range="$remote/$branch..HEAD"
if [[ -z "$(git log --oneline "$range")" ]]; then
    echo "PUBLIC HISTORY AUDIT: PASS — nichts Ausgehendes gegenüber $remote/$branch."
    exit 0
fi

# Eingebaute Muster. Bewusst eng: Jeder Treffer soll etwas bedeuten.
builtin_patterns=(
    '\b(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b'
    '/Users/[A-Za-z0-9._-]+'
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    '\b[a-z][a-z0-9._-]*@[a-z0-9.-]+:[a-z0-9]'
)

findings=0
report() {
    findings=$((findings + 1))
    printf '  %s\n' "$1"
}

messages="$(git log --format='%h %s%n%b' "$range")"

for pattern in "${builtin_patterns[@]}"; do
    while IFS= read -r line; do
        [[ -n "$line" ]] && report "Commit-Nachricht: $line"
    done < <(printf '%s\n' "$messages" | grep -nE "$pattern" || true)
done

# Lokale Musterliste: je Zeile ein erweiterter regulärer Ausdruck.
# Leerzeilen und Zeilen ab '#' werden übersprungen.
if [[ -f "$patterns_file" ]]; then
    while IFS= read -r pattern; do
        [[ -z "$pattern" || "$pattern" == \#* ]] && continue
        while IFS= read -r line; do
            [[ -n "$line" ]] && report "Commit-Nachricht: $line"
        done < <(printf '%s\n' "$messages" | grep -nE "$pattern" || true)
        while IFS= read -r line; do
            [[ -n "$line" ]] && report "Neue Zeile: $line"
        done < <(git diff "$range" | grep -E '^\+' | grep -vE '^\+\+\+' \
                 | grep -nE "$pattern" || true)
    done < "$patterns_file"
else
    echo "PUBLIC HISTORY AUDIT: Hinweis — keine lokale Musterdatei ($patterns_file)."
    echo "  Ohne sie greifen nur die eingebauten Muster; eigene Rechner- und"
    echo "  Hostnamen bleiben ungeprüft. Die Datei ist gitignoriert und gehört"
    echo "  bewusst nicht ins öffentliche Repo."
fi

count="$(git log --oneline "$range" | wc -l | tr -d ' ')"
if [[ $findings -eq 0 ]]; then
    echo "PUBLIC HISTORY AUDIT: PASS — $count ausgehende(r) Commit(s), keine internen Angaben gefunden."
    exit 0
fi

echo "PUBLIC HISTORY AUDIT: $findings Fund(e) in $count ausgehenden Commits:" >&2
if [[ $release -eq 1 ]]; then
    echo "PUBLIC HISTORY AUDIT: FAIL (Release-Modus)." >&2
    echo "  Dateiinhalte lassen sich vor dem Push noch generalisieren." >&2
    echo "  Bei Commit-NACHRICHTEN hilft nur Amend/Squash VOR dem ersten Push —" >&2
    echo "  danach bleibt der Text über seine SHA dauerhaft erreichbar." >&2
    exit 1
fi
echo "Hinweis: vor dem Push prüfen und generalisieren." >&2
exit 0
