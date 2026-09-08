#!/bin/bash

# Liest das versionierte Ergebnisprotokoll der App. Sobald mindestens eine
# `SELFTEST-RESULT`-Zeile vorhanden ist, ist sie verbindlich: Unbekannte
# Versionen, Statuswerte, Testnamen oder beschädigte Zeilen werden zu einem
# echten Fehler. Nur alte Bundles ohne Maschinenzeile benutzen weiterhin die
# bisherige Begleitzeile.
SELFTEST_RESULT_STATUS=""
SELFTEST_PROTOCOL_ERROR=""
classify_selftest_result() {
    local expected_test="$1"
    local errfile="$2"
    local legacy_line="$3"
    local structured_line=""
    local candidate=""
    local candidate_rank=-1
    local highest_rank=-1
    local saw_structured=0
    local field1=""
    local field2=""
    local field3=""
    local field4=""
    local extra=""
    SELFTEST_RESULT_STATUS=""
    SELFTEST_PROTOCOL_ERROR=""

    while IFS= read -r structured_line; do
        [ -n "$structured_line" ] || continue
        saw_structured=1
        # Die vier Felder enthalten absichtlich keine freien Texte. `read`
        # vermeidet dabei sowohl Dateinamen-Expansion als auch eine Änderung
        # der Positionsparameter unter macOS-Bash 3.2.
        field1=""; field2=""; field3=""; field4=""; extra=""
        IFS=' ' read -r field1 field2 field3 field4 extra <<< "$structured_line"
        if [ -n "$extra" ] \
           || [ "$field1" != "SELFTEST-RESULT" ] \
           || [ "$field2" != "v=1" ] \
           || [ "$field3" != "test=$expected_test" ] \
           || [[ "$field4" != status=* ]]; then
            SELFTEST_PROTOCOL_ERROR="ungültige Ergebniszeile: $structured_line"
            continue
        fi
        candidate="${field4#status=}"
        case "$candidate" in
            PASS) candidate_rank=0 ;;
            SKIP) candidate_rank=1 ;;
            ENV)  candidate_rank=2 ;;
            FAIL) candidate_rank=3 ;;
            *)
                SELFTEST_PROTOCOL_ERROR="unbekannter Status in: $structured_line"
                continue
                ;;
        esac
        if [ "$candidate_rank" -gt "$highest_rank" ]; then
            highest_rank="$candidate_rank"
        fi
    done < <(grep '^SELFTEST-RESULT' "$errfile" 2>/dev/null || true)

    if [ -n "$SELFTEST_PROTOCOL_ERROR" ]; then
        SELFTEST_RESULT_STATUS="FAIL"
        return
    fi
    if [ "$saw_structured" -eq 1 ]; then
        case "$highest_rank" in
            0) SELFTEST_RESULT_STATUS="PASS" ;;
            1) SELFTEST_RESULT_STATUS="SKIP" ;;
            2) SELFTEST_RESULT_STATUS="ENV" ;;
            3) SELFTEST_RESULT_STATUS="FAIL" ;;
            *)
                SELFTEST_RESULT_STATUS="FAIL"
                SELFTEST_PROTOCOL_ERROR="Ergebniszeile enthält keinen gültigen Status"
                ;;
        esac
        return
    fi

    # Kompatibilität mit bereits installierten Bundles vor Protokollversion 1.
    if [[ "$legacy_line" == "SELFTEST $expected_test: PASS"* ]]; then
        SELFTEST_RESULT_STATUS="PASS"
    elif [[ "$legacy_line" == "SELFTEST $expected_test: SKIP"* ]]; then
        SELFTEST_RESULT_STATUS="SKIP"
    elif [[ "$legacy_line" == "SELFTEST $expected_test: "*"Umgebungsproblem"* ]]; then
        SELFTEST_RESULT_STATUS="ENV"
    else
        SELFTEST_RESULT_STATUS="FAIL"
    fi
}

