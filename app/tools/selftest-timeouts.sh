#!/bin/bash
# Interne Runner-Fristen, auch unter Bash 3.2 ohne Runner-Nebenwirkungen sourcebar.
# Erst die Abfragen werten die Umgebung aus; das Sourcing definiert nur Daten/Funktionen.
TIMEOUT_SECS=60

# Name, normale Sonderfrist (sonst -), optionale Reviewvariable (sonst -).
# Lookup und Auflistungen lesen dieselben Regeln, damit kein Namenskatalog driftet.
selftest_timeout_rules() {
    printf '%s\n' 'print 240 -
jsonstress 360 -
softwrapindent 180 FASTRA_SOFTWRAPINDENT_REVIEW_DIR
cmdw 120 -
mdblocks 180 -
searchapproval 180 -
filedifftransfer 180 -
foldercompare 180 -
mdreferences 180 -
codeoutline 180 -
sourcesplit 180 -
snippets 180 -
snippetfiles 180 -
leakscenario 120 -
controlhost 130 -
tabfiledrag 60 -
diffexport 120 -
githistory - FASTRA_GITHISTORY_REVIEW_DIR
markdownimportui - FASTRA_MARKDOWN_IMPORT_REVIEW_DIR'
}

selftest_timeout_special_names() {
    local name seconds review_key
    while read -r name seconds review_key; do
        [[ "$seconds" == "-" ]] || printf '%s\n' "$name"
    done <<< "$(selftest_timeout_rules)"
}

selftest_timeout_review_mappings() {
    local name seconds review_key
    while read -r name seconds review_key; do
        [[ "$review_key" == "-" ]] || printf '%s %s\n' "$name" "$review_key"
    done <<< "$(selftest_timeout_rules)"
}

# Pro Test max. Wartezeit bis zur SELFTEST-Zeile. print rendert neun PDFs
# seriell; leakscenario hält zusätzlich 60 s für den externen leaks-Aufruf offen.
timeout_for_test() {
    local name seconds review_key
    while read -r name seconds review_key; do
        [[ "$name" == "$1" ]] || continue
        # Nur die passende nichtleere Reviewvariable gewährt fünf Minuten extra.
        if [[ "$review_key" != "-" && -n "${!review_key:-}" ]]; then
            echo 420
        elif [[ "$seconds" != "-" ]]; then
            echo "$seconds"
        else
            echo "$TIMEOUT_SECS"
        fi
        return
    done <<< "$(selftest_timeout_rules)"
    echo "$TIMEOUT_SECS"
}
