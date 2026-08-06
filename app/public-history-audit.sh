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
#   1 = Fund im Release-Modus ODER ein Muster ließ sich nicht anwenden
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

# Treffer des letzten `scan`-Laufs, eine Zeile je Fund.
scan_output=""

# grep über stdin MIT ehrlichem Status. grep unterscheidet drei Fälle:
#   0 = Treffer, 1 = kein Treffer, ab 2 = grep selbst ist gescheitert
#       (typisch: ein ungültiger regulärer Ausdruck in der lokalen Musterdatei).
# Das frühere `|| true` warf alle drei in einen Topf: Ein kaputtes privates
# Muster galt damit als „nichts gefunden" und der Wächter meldete PASS,
# obwohl er gar nicht geprüft hatte (Review 2026-08-02). Ein solcher Fehler
# ist deshalb ein harter Abbruch, kein stiller Durchlauf.
scan() {
    # `status` ist in zsh ein reservierter Name (Zweitname für `$?`) und
    # lässt sich nicht überschreiben — daher `rc`.
    local pattern="$1" rc=0
    scan_output="$(grep -nE "$pattern")" || rc=$?
    if [[ $rc -ge 2 ]]; then
        echo "PUBLIC HISTORY AUDIT: FEHLER — grep endete mit Status $rc beim Muster:" >&2
        printf '  %s\n' "$pattern" >&2
        echo "  Ein unanwendbares Muster darf nicht als „nichts gefunden“ durchgehen." >&2
        exit 1
    fi
}

# Wie `scan`, aber ohne Zeilennummern und mit frei wählbaren grep-Argumenten.
# Ergebnis steht in `grep_output`; Status 1 („kein Treffer") liefert einen
# leeren Wert, ab Status 2 bricht der Wächter hart ab.
filter() {
    local rc=0
    grep_output="$(grep "$@")" || rc=$?
    if [[ $rc -ge 2 ]]; then
        echo "PUBLIC HISTORY AUDIT: FEHLER — grep endete mit Status $rc beim Filtern" >&2
        echo "  der hinzugefügten Zeilen. Ein Fehler darf nicht als „nichts" >&2
        echo "  gefunden“ durchgehen." >&2
        exit 1
    fi
    [[ $rc -eq 0 ]] || grep_output=""
}

messages="$(git log --format='%h %s%n%b' "$range")"

for pattern in "${builtin_patterns[@]}"; do
    scan "$pattern" <<< "$messages"
    while IFS= read -r line; do
        [[ -n "$line" ]] && report "Commit-Nachricht: $line"
    done <<< "$scan_output"
done

# Lokale Musterliste: je Zeile ein erweiterter regulärer Ausdruck.
# Leerzeilen und Zeilen ab '#' werden übersprungen.
if [[ -f "$patterns_file" ]]; then
    # Hinzugefügte Zeilen JE AUSGEHENDEM COMMIT sammeln, nicht aus dem
    # Netto-Diff `Basis..HEAD`. Wer eine interne Angabe in einem Commit
    # hinzufügt und in einem späteren wieder entfernt, hat sie im Netto-Diff
    # nicht mehr — nach dem Push bleibt der Zwischen-Commit aber über seine
    # SHA dauerhaft erreichbar und damit auch die Angabe darin
    # (Review 2026-08-02). Jede Zeile trägt vorn die Commit-Kurz-SHA, damit
    # der Fund benennbar ist.
    added_lines=""
    while IFS= read -r sha; do
        [[ -z "$sha" ]] && continue
        # `git show` MUSS gelingen. Vorher stand es mit den beiden Filtern in
        # EINER Pipe, die auf `|| true` endete: Wegen `pipefail` verschluckte
        # das nicht nur den erwartbaren Status 1 eines ergebnislosen `grep`,
        # sondern auch einen echten Fehler von `git show` — der Commit lief
        # dann mit leerem Inhalt durch die Prüfung (Review 2026-08-06).
        commit_diff=""
        if ! commit_diff="$(git show --format='' --unified=0 "$sha")"; then
            echo "PUBLIC HISTORY AUDIT: FEHLER — „git show $sha“ scheiterte." >&2
            echo "  Ein ungeprüfter Commit darf nicht als sauber gelten." >&2
            exit 1
        fi
        filter -E '^\+' <<< "$commit_diff"
        [[ -z "$grep_output" ]] && continue
        filter -vE '^\+\+\+' <<< "$grep_output"
        commit_added="$grep_output"
        [[ -z "$commit_added" ]] && continue
        added_lines+="$(printf '%s\n' "$commit_added" | sed "s|^|${sha:0:9} |")"$'\n'
    done < <(git rev-list --reverse "$range")

    while IFS= read -r pattern; do
        [[ -z "$pattern" || "$pattern" == \#* ]] && continue
        scan "$pattern" <<< "$messages"
        while IFS= read -r line; do
            [[ -n "$line" ]] && report "Commit-Nachricht: $line"
        done <<< "$scan_output"
        scan "$pattern" <<< "$added_lines"
        while IFS= read -r line; do
            [[ -n "$line" ]] && report "Neue Zeile: $line"
        done <<< "$scan_output"
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
