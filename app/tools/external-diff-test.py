#!/usr/bin/env python3
"""CLI- und LaunchServices-Integration gegen eine isolierte Bundle-Kopie.

Die Kopie liegt im Build-Verzeichnis, besitzt eine eigene Bundle-ID und
Test-Preferences und wird nie nach /Applications installiert.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT.parent / "Fastra.app"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], capture_output=True, timeout=20, **kwargs)


def check(helper, args, expected):
    result = run([helper, *args])
    assert result.returncode == expected, (args, result.returncode, result.stderr.decode())
    if expected:
        assert result.stdout == b"" and len(result.stderr.splitlines()) == 1, result
        assert result.stderr.startswith(b"fastra-diff: "), result.stderr
    else:
        assert result.stderr == b"", result.stderr
    return result


def stop_owned_app(app):
    binary = str(app / "Contents/MacOS/Fastra")
    # Nur exakt diese Wegwerf-Kopie, niemals eine App über ihren Namen beenden.
    rows = run(["/bin/ps", "-axo", "pid=,command="]).stdout.decode().splitlines()
    for row in rows:
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and (fields[1] == binary or fields[1].startswith(binary + " ")):
            pid = int(fields[0])
            os.kill(pid, signal.SIGTERM)
            for _ in range(40):
                if run(["/bin/ps", "-p", pid, "-o", "command="]).stdout.strip() == b"":
                    break
                time.sleep(0.05)
            else:
                # PID nur nach erneuter Prüfung der ausführbaren Datei benutzen.
                command = run(["/bin/ps", "-p", pid, "-o", "command="]).stdout.decode().strip()
                if command == binary or command.startswith(binary + " "):
                    os.kill(pid, signal.SIGKILL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--visual", type=Path, help="Fensteraufnahmen und Fokusbeleg hier speichern")
    options = parser.parse_args()
    if options.visual:
        options.visual = options.visual.resolve()
        options.visual.mkdir(parents=True, exist_ok=True)
    assert (SOURCE / "Contents/Helpers/fastra-diff").is_file(), "Zuerst build.sh ausführen"
    with tempfile.TemporaryDirectory(prefix="external-diff-", dir=ROOT / ".build") as temp:
        base = Path(temp)
        app = base / "Fastra.app"
        domains = []
        registry = base / "defaults-registry"
        try:
            assert run(["/bin/cp", "-cR", SOURCE, app]).returncode == 0
            helper = app / "Contents/Helpers/fastra-diff"
            left, right = base / "-ä links.txt", base / "右 rechts.txt"
            left.write_bytes(b"one\nold\nthree\n")
            right.write_bytes(b"one\nnew\nthree\n")
            originals = left.read_bytes(), right.read_bytes()
            args = ["--read-only", "--focus-diff", "--left-label", "Links α",
                    "--right-label", "Rechts β", "--", str(left), str(right)]
            # Fähigkeiten müssen auch ohne startbare App funktionieren.
            info_path = app / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info_path.unlink()
            result = check(helper, ["--capabilities", "--json"], 0)
            assert json.loads(result.stdout) == dict(protocol=1, fileDiff=True, readOnly=True,
                                                    focusDiff=True, labels=True, existingInstanceIpc=True)
            check(helper, args, 5)
            check(helper, ["--", str(left)], 2)
            check(helper, ["--unsupported", "--", str(left), str(right)], 4)
            check(helper, ["--", str(base / "missing"), str(right)], 3)
            left.chmod(0)
            try:
                if os.getuid() != 0:
                    check(helper, args, 3)
            finally:
                left.chmod(0o600)
            print("PASS: Fähigkeiten ohne startbare App; Argumente, Dateien, Optionen und Startfehler")

            for count in (1, 4):
                identifier = "org.fastra.external-diff-test." + uuid.uuid4().hex
                suite = "Fastra-" + str(uuid.uuid4())
                domains.extend([identifier, suite])
                result_path = base / ("cold-%s.result" % count)
                cfhome = base / ("home-%s" % count)
                (cfhome / "Library/Preferences").mkdir(parents=True)
                info["CFBundleIdentifier"] = identifier
                info["LSEnvironment"] = {
                    "FASTRA_SELFTEST": "externaldiffcold",
                    "FASTRA_SELFTEST_ALLOW_ACTIVATION": "0",
                    "FASTRA_SELFTEST_DEFAULTS_SUITE": suite,
                    "FASTRA_TEST_DEFAULTS_REGISTRY": str(registry),
                    "FASTRA_DIFF_COLD_RESULT": str(result_path),
                    "FASTRA_DIFF_COLD_COUNT": str(count),
                    "CFFIXED_USER_HOME": str(cfhome),
                    "TMPDIR": str(base) + "/",
                }
                if options.visual and count == 1:
                    info["LSEnvironment"]["FASTRA_DIFF_COLD_SCREENSHOTS"] = str(options.visual)
                info_path.write_bytes(plistlib.dumps(info))
                signed = run(["/usr/bin/codesign", "--force", "--sign", "-", app])
                assert signed.returncode == 0, signed.stderr
                assert run([LSREGISTER, "-f", app]).returncode == 0
                with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
                    results = list(pool.map(lambda _: check(helper, args, 0), range(count)))
                assert all(result.stdout == b"" for result in results)
                deadline = time.monotonic() + 18
                while not result_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                assert result_path.exists(), "Kaltstart lieferte keinen frischen Testbericht"
                report = result_path.read_text()
                assert report.startswith("SELFTEST-RESULT v=1 test=externaldiffcold status=PASS\n"), report
                assert "windows=%s rendered=true" % count in report, report
                if options.visual and count == 1:
                    assert "active=true key=true" in report, report
                    (options.visual / "external-diff-visual.txt").write_text(report)
                    assert (options.visual / "external-diff.png").is_file()
                    assert (options.visual / "normal-window.png").is_file()
                assert (left.read_bytes(), right.read_bytes()) == originals
                print("PASS: %s gleichzeitige Kaltstart-Helfer → %s gerenderte Diff-Fenster; Quellen unverändert" % (count, count))
                stop_owned_app(app)
                run([LSREGISTER, "-u", app])

            # Start gelingt, aber diese bewusst leere Test-App bietet keinen
            # IPC-Endpunkt: der Helfer muss nach seiner festen Frist abbrechen.
            info.pop("LSEnvironment", None)
            info["CFBundleIdentifier"] = "org.fastra.external-diff-test." + uuid.uuid4().hex
            domains.append(info["CFBundleIdentifier"])
            info_path.write_bytes(plistlib.dumps(info))
            shutil.copyfile("/usr/bin/true", app / "Contents/MacOS/Fastra")
            assert run(["/usr/bin/codesign", "--force", "--sign", "-", app]).returncode == 0
            run([LSREGISTER, "-f", app])
            started = time.monotonic()
            check(helper, args, 6)
            assert time.monotonic() - started < 12
            print("PASS: unbeantwortete IPC-Übergabe endet mit Code 6 innerhalb der festen Frist")
        finally:
            stop_owned_app(app)
            run([LSREGISTER, "-u", app])
            if registry.exists():
                domains.extend(registry.read_text().splitlines())
            # cfprefsd kann Domains nach Prozessende nochmals schreiben.
            for _ in range(3):
                for domain in set(domains):
                    if re.fullmatch(r"Fastra-[0-9A-Fa-f-]+|org\.fastra\.external-diff-test\.[0-9a-f]+", domain):
                        run(["/usr/bin/defaults", "delete", domain])
                time.sleep(0.5)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    main()
