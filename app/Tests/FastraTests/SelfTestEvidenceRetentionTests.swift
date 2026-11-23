import Foundation
import Testing

@Suite("Aufbewahrung von Selbsttest-Rettungsbackups")
struct SelfTestEvidenceRetentionTests {
    @Test("Rotation löscht nur entbehrliche alte Belege", arguments: [false, true])
    func rotationPreservesRecoveryAndUncertainDirectories(aliasedRoot: Bool) throws {
        let root = testTemporaryDirectory().appendingPathComponent(
            "fastra-evidence-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let retention = appDirectory.appendingPathComponent("tools/test-evidence-retention.sh")
        let result = try runTestProcess(
            "/bin/bash", arguments: ["-c", evidenceRetentionFixture, "evidence-retention", root.path,
                                      aliasedRoot ? "alias" : "direct", retention.path], timeout: 15)
        #expect(result.status == 0, "Ausgabe:\n\(result.output)")
    }
}

private let evidenceRetentionFixture = #"""
set -eu
. "$3"
EVIDENCE_ROOT="$1/evidence with spaces"
if [ "$2" = alias ]; then
    mkdir "$1/physical evidence"
    ln -s "$1/physical evidence" "$EVIDENCE_ROOT"
else
    mkdir "$EVIDENCE_ROOT"
fi
mkdir "$1/foreign evidence"
ln -s "$1/foreign evidence" "$EVIDENCE_ROOT/fastra-selftest-befunde-foreign-link"
REMOVALS="$1/removals"
: > "$REMOVALS"
for index in 1 2 3 4 5 6 7; do
    path="$EVIDENCE_ROOT/fastra-selftest-befunde-ordinary $index"
    mkdir "$path"
    touch -t "20200101010$index" "$path"
done
printf 'own recovery fixture\000unchanged\n' > "$1/reference"
for kind in regular unreadable-marker dangling linked directory unreadable-directory read-error foreign unknown-owner; do
    path="$EVIDENCE_ROOT/fastra-selftest-befunde-$kind"
    mkdir "$path"
    case "$kind" in
        regular|unreadable-marker)
            cp "$1/reference" "$path/pasteboard-backup.plist"
            ;;
        dangling)
            ln -s missing-backup "$path/pasteboard-backup.plist"
            ;;
        linked)
            ln -s "$1/reference" "$path/pasteboard-backup.plist"
            ;;
        directory)
            mkdir "$path/pasteboard-backup.plist"
            ;;
        unreadable-directory)
            cp "$1/reference" "$path/pasteboard-backup.plist"
            ;;
    esac
    touch -t 199901010101 "$path"
done
chmod 000 "$EVIDENCE_ROOT/fastra-selftest-befunde-unreadable-marker/pasteboard-backup.plist"
chmod 000 "$EVIDENCE_ROOT/fastra-selftest-befunde-unreadable-directory"
trap 'chmod 700 "$EVIDENCE_ROOT/fastra-selftest-befunde-unreadable-directory" 2>/dev/null || true' EXIT

# Fehler und fremder Besitzer sind deterministisch, ohne chown oder fremde
# Dateien. Die echte find/stat-Implementierung verarbeitet alle übrigen Pfade.
find() {
    local root="$1"
    if [ "$1" = -H ]; then root="$2"; fi
    case "$root" in
        "$EVIDENCE_ROOT/fastra-selftest-befunde-read-error") return 1 ;;
        "$EVIDENCE_ROOT")
            command /usr/bin/find "$@"
            printf '1 %s/fastra-selftest-befunde-missing\n' "$EVIDENCE_ROOT"
            ;;
        *) command /usr/bin/find "$@" ;;
    esac
}
stat() {
    case "${!#}" in
        "$EVIDENCE_ROOT/fastra-selftest-befunde-foreign") printf '%s\n' "$((UID + 1))" ;;
        "$EVIDENCE_ROOT/fastra-selftest-befunde-unknown-owner") return 1 ;;
        *) command /usr/bin/stat "$@" ;;
    esac
}
# Auch ein versehentlich erweitertes Löschziel darf nur dieses Fixture treffen.
rm() {
    [ "$#" -eq 3 ] && [ "$1" = -rf ] && [ "$2" = -- ] || exit 90
    case "$3" in "$EVIDENCE_ROOT"/fastra-selftest-befunde-*) ;; *) exit 91 ;; esac
    printf '%s\n' "$3" >> "$REMOVALS"
    command /bin/rm "$@"
}

# Der Runner selbst setzt kein errexit: Ein einzelner rm-Fehler darf die
# Gegenprobe auf den Verlust anderer Rettungsbackups nicht verdecken.
set +e
SELFTEST_RUNS_INSIDE_TEST_FIXTURE=1 prune_selftest_evidence "$EVIDENCE_ROOT"
[ ! -s "$REMOVALS" ] || exit 20
SELFTEST_RUNS_INSIDE_TEST_FIXTURE=0 prune_selftest_evidence "$EVIDENCE_ROOT"
set -e
for index in 1 2; do
    [ ! -e "$EVIDENCE_ROOT/fastra-selftest-befunde-ordinary $index" ] || exit 10
done
for index in 3 4 5 6 7; do
    [ -d "$EVIDENCE_ROOT/fastra-selftest-befunde-ordinary $index" ] || exit 11
done
for kind in regular unreadable-marker dangling linked directory unreadable-directory read-error foreign unknown-owner; do
    [ -d "$EVIDENCE_ROOT/fastra-selftest-befunde-$kind" ] || exit 12
done
[ -L "$EVIDENCE_ROOT/fastra-selftest-befunde-dangling/pasteboard-backup.plist" ] || exit 13
[ ! -e "$EVIDENCE_ROOT/fastra-selftest-befunde-dangling/pasteboard-backup.plist" ] || exit 14
[ -L "$EVIDENCE_ROOT/fastra-selftest-befunde-linked/pasteboard-backup.plist" ] || exit 15
[ -d "$EVIDENCE_ROOT/fastra-selftest-befunde-directory/pasteboard-backup.plist" ] || exit 16
[ -L "$EVIDENCE_ROOT/fastra-selftest-befunde-foreign-link" ] && [ -d "$1/foreign evidence" ] || exit 19
chmod 700 "$EVIDENCE_ROOT/fastra-selftest-befunde-unreadable-directory"
chmod 600 "$EVIDENCE_ROOT/fastra-selftest-befunde-unreadable-marker/pasteboard-backup.plist"
for kind in regular unreadable-marker linked unreadable-directory; do
    cmp "$1/reference" "$EVIDENCE_ROOT/fastra-selftest-befunde-$kind/pasteboard-backup.plist" || exit 17
done
[ "$(wc -l < "$REMOVALS" | tr -d ' ')" = 2 ] || exit 18
printf 'PASS: two ordinary old directories removed; five newest and all recovery/uncertain paths preserved\n'
"""#
