#!/usr/bin/env python3
"""Echte CLI-/AppleEvent-Prüfung mit eigener Bundle-ID, ohne Aktivierung."""
import hashlib
from contextlib import nullcontext
from concurrent.futures import ThreadPoolExecutor
import sys
sys.dont_write_bytecode = True
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import uuid

from importlib.util import module_from_spec, spec_from_file_location
spec = spec_from_file_location("diff_test", Path(__file__).with_name("external-diff-test.py"))
diff_test = module_from_spec(spec)
spec.loader.exec_module(diff_test)
ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT.parent / "Fastra.app"
LSREGISTER = diff_test.LSREGISTER


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], capture_output=True, timeout=20, **kwargs)


def request(operation, **fields):
    return dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 10,
                operation=operation, **fields)


def installed_apple(args, script, base, binding, helper):
    """Ein langsamer Sender bleibt für die Diagnose am Leben; kein Retry."""
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        try:
            stdout, stderr = process.communicate(script, timeout=1.5)
        except subprocess.TimeoutExpired:
            folder = base / ("ae-diagnostic-" + uuid.uuid4().hex)
            folder.mkdir()
            # Beide Stacks entstehen während desselben noch ausstehenden Events.
            # Ein separater readonly CLI-Aufruf unterscheidet einen blockierten
            # MainActor von einem Hänger vor dem Cocoa-Handler.
            def sample(pid, name):
                try:
                    result = subprocess.run(["/usr/bin/sample", str(pid), "1", "-file", str(folder / name)],
                                            capture_output=True, timeout=2.5)
                    return dict(exit=result.returncode, captured=(folder / name).is_file())
                except subprocess.TimeoutExpired:
                    return dict(expired=True)

            def probe():
                value = dict(request("capabilities"), runtimeID=binding["runtimeID"])
                try:
                    result = subprocess.run([str(helper), "--no-launch", "--request", "-"],
                                            input=json.dumps(value).encode(), capture_output=True, timeout=2.5)
                    (folder / "cli.json").write_bytes(result.stdout)
                    return dict(exit=result.returncode)
                except subprocess.TimeoutExpired:
                    return dict(expired=True)

            with ThreadPoolExecutor(max_workers=3) as pool:
                sender = pool.submit(sample, process.pid, "sender.sample")
                receiver = pool.submit(sample, int(binding["pid"]), "receiver.sample")
                cli = pool.submit(probe)
                (folder / "result.json").write_text(json.dumps(dict(sender=sender.result(),
                    receiver=receiver.result(), cli=cli.result()), indent=2))
            print("Diagnose eines langsamen AppleEvents:", folder, flush=True)
            stdout, stderr = process.communicate(timeout=2)
        return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate()


def main():
    existing_root = os.environ.get("FASTRA_CONTROL_TEST_HOST_DIR")
    context = nullcontext(existing_root) if existing_root else tempfile.TemporaryDirectory(prefix="local-control-", dir=ROOT / ".build")
    with context as temp:
        base = Path(temp)
        installed = os.environ.get("FASTRA_CONTROL_TEST_APP")
        app = Path(installed).resolve() if installed else base / "Fastra.app"
        identifier = "org.fastra.local-control-test." + uuid.uuid4().hex
        suite = "Fastra-" + str(uuid.uuid4())
        registry = base / "defaults-registry"
        domains = [] if installed else [identifier, suite]
        cli_only = os.environ.get("FASTRA_CONTROL_CLI_ONLY") == "1"
        applescript = os.environ.get("FASTRA_CONTROL_APPLESCRIPT") == "1"
        language = os.environ.get("FASTRA_CONTROL_TEST_LANGUAGE")
        visual = os.environ.get("FASTRA_CONTROL_SCREENSHOTS")
        host = None
        try:
            home = base / "home"
            (home / "Library/Preferences").mkdir(parents=True)
            environment = dict(
                FASTRA_SELFTEST="controlhost", FASTRA_SELFTEST_ALLOW_ACTIVATION="0",
                FASTRA_CONTROL_HOST_DIR=str(base),
                FASTRA_SELFTEST_DEFAULTS_SUITE=suite,
                FASTRA_TEST_DEFAULTS_REGISTRY=str(registry),
                CFFIXED_USER_HOME=str(home), TMPDIR=str(base) + "/")
            if visual:
                environment["FASTRA_CONTROL_SCREENSHOTS"] = str(Path(visual).resolve())
            if language:
                assert language in ("de", "en")
                environment["FASTRA_CONTROL_TEST_LANGUAGE"] = language
            if installed:
                # Ein vorhandener selftest.sh-Runner besitzt Prozess und
                # Sandbox samt Backup/Wiederherstellung des Produktzustands.
                # Dieser Treiber verbindet sich nur; er startet/ändert nichts.
                assert existing_root and (base / "host-ready").is_file(), "Start protected controlhost with selftest.sh first"
                assert app.parent == Path("/Applications"), "Installed tests require /Applications"
                assert run(["/usr/bin/xcrun", "stapler", "validate", app]).returncode == 0, "Notarized app required"
                info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                identifier = info["CFBundleIdentifier"]
            else:
                assert run(["/bin/cp", "-cR", SOURCE, app]).returncode == 0
                info_path = app / "Contents/Info.plist"
                info = plistlib.loads(info_path.read_bytes())
                info["CFBundleIdentifier"] = identifier
                info["LSEnvironment"] = environment
                info_path.write_bytes(plistlib.dumps(info))
                assert run(["/usr/bin/codesign", "--force", "--sign", "-", app]).returncode == 0
                assert run([LSREGISTER, "-f", app]).returncode == 0
                if language:
                    # Sichtprüfung belegt die echte Prozess-Lokalisierung.
                    host = subprocess.Popen([str(app / "Contents/MacOS/Fastra"), "-selftest", "controlhost",
                                             "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", f"({language})"],
                                            env=dict(os.environ, **environment), stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL)
                    deadline = time.monotonic() + 10
                    while not (base / "host-ready").exists() and time.monotonic() < deadline:
                        assert host.poll() is None, "localized host exited before readiness"
                        time.sleep(.05)
                    assert (base / "host-ready").exists(), "localized host did not become ready"
            helper = app / "Contents/Helpers/fastra-control"

            def bind(value):
                if installed:
                    value = dict(value, runtimeID=json.loads((base / "host-binding").read_text())["runtimeID"])
                return value

            def cli(value):
                value = bind(value)
                args = [helper, "--no-launch", "--request", "-"] if installed else [helper, "--request", "-"]
                result = run(args, input=json.dumps(value).encode())
                reply = json.loads(result.stdout)
                assert result.returncode == (1 if "error" in reply else 0), result
                return reply

            def apple(command, expected_error=None, javascript=None):
                # Jeder Aufruf kompiliert das tatsächliche Dictionary und
                # sendet von osascript einen echten AppleEvent in die Test-App.
                script = f'using terms from application "{app}"\ntell application "{app}"\n{command}\nend tell\nend using terms from\n'
                if installed:
                    assert javascript is not None, "Installed AE tests require a PID-addressed expression"
                    binding = json.loads((base / "host-binding").read_text())
                    os.kill(int(binding["pid"]), 0)
                    if applescript:
                        # Kein Kaltstart: nur der bereits geschützte Host darf
                        # Empfänger sein; die Antworten bestätigen seine Runtime.
                        script = (f'using terms from application "{app}"\n'
                                  f'if application id "{identifier}" is not running then error "Protected host is not running" number -600\n'
                                  f'with timeout of 3 seconds\n'
                                  f'tell application id "{identifier}"\n{command}\nend tell\n'
                                  'end timeout\nend using terms from\n')
                        args = ["/usr/bin/osascript", "-"]
                    else:
                        script = f'const app = Application({int(binding["pid"])});\n{javascript};\n'
                        args = ["/usr/bin/osascript", "-l", "JavaScript", "-"]
                else:
                    args = ["/usr/bin/osascript", "-"]
                result = (installed_apple(args, script.encode(), base, binding, helper)
                          if installed else run(args, input=script.encode()))
                if expected_error is not None:
                    assert result.returncode != 0 and f"({expected_error})" in result.stderr.decode(), result.stderr
                    return
                assert result.returncode == 0, result.stderr.decode()
                return result.stdout.decode().strip()

            def ae(value, expected_error=None):
                value = bind(value)
                payload = json.dumps(json.dumps(value))
                return apple("control request " + payload, expected_error, "app.controlRequest(" + payload + ")")

            if not installed and not language:
                no_launch = run([helper, "--no-launch", "--request", "-"], input=json.dumps(request("capabilities")).encode())
                assert no_launch.returncode == 1 and json.loads(no_launch.stdout)["error"]["code"] == "delivery"
            offline = json.loads(run([helper, "--capabilities", "--json"]).stdout)
            assert offline["capabilities"]["readOnly"]
            caps = cli(request("capabilities"))
            deadline = time.monotonic() + 10
            while not (base / "host-ready").exists() and time.monotonic() < deadline:
                assert not (base / "host-failed").exists(), (base / "host-failed").read_text()
                time.sleep(.05)
            assert (base / "host-ready").exists(), "normal fixture editors not ready"

            if installed:
                binding = json.loads((base / "host-binding").read_text())
                assert binding["runtimeID"] == caps["runtimeID"], "wrong runtime control host"
            script_caps = caps if cli_only else json.loads(apple("control capabilities", javascript="app.controlCapabilities()"))
            assert caps["runtimeID"] == script_caps["runtimeID"]
            windows = cli(request("objects")) if cli_only else json.loads(apple("control inventory", javascript="app.controlInventory()"))
            assert windows["runtimeID"] == caps["runtimeID"]
            assert len({obj["id"] for obj in windows["objects"]}) == len(windows["objects"])
            normal_document = next(obj for obj in windows["objects"] if obj["kind"] == "document")
            normal_target = request("navigate", sessionID=normal_document["windowID"],
                                    documentID=normal_document["id"], sha256="0" * 64,
                                    location=0, length=0)
            assert cli(normal_target)["error"]["code"] == "invalidID"
            normal_close = request("close", sessionID=normal_document["windowID"])
            assert cli(normal_close)["error"]["code"] == "invalidID"
            assert cli(request("status", jobID=str(uuid.uuid4())))["error"]["code"] == "invalidID"
            if not cli_only:
                ae(request("status", jobID=str(uuid.uuid4())), -1728)
                ae(request("unknown"), -1708)
                ae(normal_target, -1728)
                ae(normal_close, -1728)
                ae(dict(request("capabilities"), unexpected=True), -1700)
                normal_id = next(obj["id"] for obj in windows["objects"] if obj["kind"] == "window")
                assert apple(f'get id of control window id "{normal_id}"', javascript=f'app.controlWindows.byId("{normal_id}").id()') == normal_id
                apple(f'get id of control window id "missing"', -1728, 'app.controlWindows.byId("missing").id()')
                print("PASS: echtes Dictionary, CLI und AppleEvent teilen Controller; native Fehler -1728/-1708")
            else:
                print("PASS: CLI-Vertrag und Fehler; AppleEvents in diesem Teillauf ausdrücklich ungeprüft")
            if os.environ.get("FASTRA_CONTROL_PROBE_ONLY") == "1":
                return

            # Die vollständige Snapshot-Abnahme folgt auf derselben Instanz.
            text = "first\r\nsecond 😀 e\u0301\nlast\n"
            source = base / "Quelle ä.txt"
            raw = text.encode("utf-8")
            source.write_bytes(raw)
            sha = hashlib.sha256(raw).hexdigest()
            start = len("first\r\n".encode("utf-16-le")) // 2
            value = request("snapshot", path=str(source), sha256=sha, location=start, length=6)
            accepted = cli(value)
            assert accepted["job"]["state"] == "accepted", accepted
            same = cli(value) if cli_only else json.loads(ae(value))
            assert same["job"]["id"] == accepted["job"]["id"], (same, accepted)
            conflict = dict(value, location=0)
            assert cli(conflict)["error"]["code"] == "invalidRequest"

            def ready(job):
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    report = cli(request("status", jobID=job["id"]))
                    state = report["job"]["state"]
                    if state in ("ready", "failed", "cancelled"):
                        return report["job"]
                    time.sleep(.03)
                raise AssertionError("job never completed")

            job = ready(accepted["job"])
            assert job["state"] == "ready", job
            assert job["sha256"] == sha and job["selection"] == dict(location=start, length=6), job
            session, document = job["sessionID"], job["documentID"]
            if not cli_only:
                assert apple(f'get id of control session id "{session}"', javascript=f'app.controlSessions.byId("{session}").id()') == session
                assert apple(f'get id of control document id "{document}"', javascript=f'app.controlDocuments.byId("{document}").id()') == document
                native_job = json.loads(apple(f'get details of control job id "{job["id"]}"', javascript=f'app.controlJobs.byId("{job["id"]}").details()'))
                assert native_job["state"] == "ready" and native_job["id"] == job["id"]
                # JXA weist den Setter schon am ScriptingBridge-Zugang mit
                # -10003 ab; AppleScript meldet Cocoas readonly-Fehler -10006.
                setter_error = -10003 if installed and not applescript else -10006
                apple(f'set details of control job id "{job["id"]}" to "changed"', setter_error, f'app.controlJobs.byId("{job["id"]}").details = "changed"')
                unchanged = json.loads(apple(f'get details of control job id "{job["id"]}"', javascript=f'app.controlJobs.byId("{job["id"]}").details()'))
                assert unchanged == native_job, "readonly setter changed job details"
                apple(f'set id of control job id "{job["id"]}" to "changed"', setter_error,
                      f'app.controlJobs.byId("{job["id"]}").id = "changed"')
                assert apple(f'get id of control job id "{job["id"]}"',
                             javascript=f'app.controlJobs.byId("{job["id"]}").id()') == job["id"]
                assert json.loads(ae(request("status", jobID=job["id"])))["job"] == job

            if visual:
                (base / "host-capture").write_text("ready")
                deadline = time.monotonic() + 5
                while not (base / "host-captured").exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                capture = (base / "host-captured").read_text()
                assert capture.startswith("PASS "), capture
                print(capture)
            # Snapshot bleibt eingefroren, auch nachdem die Datei geändert wurde.
            source.write_text("new disk contents")
            nav = request("navigate", sessionID=session, documentID=document, sha256=sha,
                          location=len(text.encode("utf-16-le")) // 2, length=0)
            moved = ready((cli(nav) if cli_only else json.loads(ae(nav)))["job"])
            assert moved["state"] == "ready" and moved["sha256"] == sha, moved
            assert moved["selection"] == dict(location=nav["location"], length=0)
            stale = dict(nav, id=str(uuid.uuid4()), sha256="0" * 64)
            assert cli(stale)["error"]["code"] == "stale"
            if not cli_only: ae(stale, -2700)
            assert cli(request("close", sessionID=session)).get("error") is None
            if not cli_only:
                ae(dict(nav, id=str(uuid.uuid4())), -1728)
                apple(f'get id of control session id "{session}"', -1728,
                      f'app.controlSessions.byId("{session}").id()')
            assert cli(request("navigate", sessionID=session, documentID=document, sha256=sha,
                               location=0, length=0))["error"]["code"] == "invalidID"
            if visual:
                # Derselbe echte Capture-Pfad zeigt eine lokalisierte Fehlerlage.
                rejected = ready(cli(request("snapshot", path=str(source), sha256=sha, location=0, length=0))["job"])
                assert rejected["state"] == "failed" and rejected["error"]["code"] == "stale", rejected
                (base / "host-captured").unlink()
                (base / "host-capture").write_text("failure")
                deadline = time.monotonic() + 5
                while not (base / "host-captured").exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                assert (base / "host-captured").read_text().startswith("PASS ")
                cli(request("close", sessionID=rejected["sessionID"]))
            if os.environ.get("FASTRA_CONTROL_EXPLANATION_TEST") == "1":
                player_spec = spec_from_file_location("explanation_test", Path(__file__).with_name("code-explanation-test.py"))
                player_test = module_from_spec(player_spec)
                player_spec.loader.exec_module(player_test)
                player_test.verify(base, cli, ae, ready, cli_only, visual)
            (base / "host-check").write_text("check")
            deadline = time.monotonic() + 5
            while not (base / "host-result").exists() and time.monotonic() < deadline:
                time.sleep(.05)
            report = (base / "host-result").read_text()
            assert report.startswith("PASS "), report
            print("PASS: accepted!=ready, Hashbindung, echte Auswahl, EOF, idempotente Wiederholung und geschlossene ID")
            print(report)

        finally:
            if installed:
                # Erst nach allen Senderaufrufen beenden. Auch ein externer
                # Fehler darf den geschützten Runner nicht bis zur Frist halten.
                (base / "host-finish").write_text("external driver finished")
            if not installed:
                diff_test.stop_owned_app(app)
                if host is not None:
                    host.wait(timeout=5)
                run([LSREGISTER, "-u", app])
            if not installed and registry.exists():
                domains.extend(registry.read_text().splitlines())
            # cfprefsd kann nach dem Prozessende nochmals schreiben. Dieselbe
            # kleine Nachlauf-Prüfung wie die vorhandenen Runner hält nur die
            # ausdrücklich eigenen Test-Domains im Bereinigungsumfang.
            for _ in range(3):
                time.sleep(.5)
                for domain in set(domains):
                    assert domain == identifier or domain == suite, "unexpected defaults registry entry"
                    run(["/usr/bin/defaults", "delete", domain])


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, interrupted)
    main()
