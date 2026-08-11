#!/usr/bin/env python3
"""Lokale, begrenzte Fastra-Testzeiten je Mac speichern und vergleichen."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import contextlib
import io

VERSION = 1
MAX_RUNS = 20
LONG_MAX_AGE_DAYS = 7
LONG_MAX_RELEVANT_COMMITS = 20
RELEVANT_PATHS = [
    "app/Sources",
    "app/Tests",
    "app/Patches",
    "app/build.sh",
    "app/selftest.sh",
    "app/soak-test.sh",
    "app/Package.swift",
    "app/Package.resolved",
]


def run_text(arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            arguments,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def machine_key() -> str:
    # Die rohe UUID dient nur als lokale Eingabe des Hashes und wird weder
    # gespeichert noch ausgegeben.
    output = run_text(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
    match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', output)
    seed = match.group(1) if match else platform.node() + "|" + platform.machine()
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:20]


def data_path() -> Path:
    override = os.environ.get("FASTRA_PERFORMANCE_DATA_DIR")
    root = Path(override).expanduser() if override else (
        Path.home() / "Library" / "Application Support" / "Fastra" / "SelfTests"
    )
    return root / machine_key() / "performance-v1.json"


def display_path(path: Path) -> str:
    """Verbirgt den lokalen Accountnamen in kopierbaren Testausgaben."""
    try:
        relative = path.resolve().relative_to(Path.home().resolve())
        return str(Path("$HOME") / relative)
    except (OSError, ValueError):
        return str(path)


def display_error(error: BaseException) -> str:
    """Maskiert Home-Pfade, die Betriebssystemfehler in ihren Text einbauen."""
    return str(error).replace(str(Path.home()), "$HOME")


def empty_data() -> dict:
    return {
        "version": VERSION,
        "machine": {
            "key": machine_key(),
            "model": run_text(["/usr/sbin/sysctl", "-n", "hw.model"]),
        },
        "standard": {},
        "long": {},
    }


def validate_timestamp(value: object, label: str) -> None:
    if not isinstance(value, str):
        raise ValueError(f"{label} enthält keinen gültigen finished_at-Zeitpunkt")
    try:
        parsed = dt.datetime.fromisoformat(value)
    except ValueError as error:
        raise ValueError(
            f"{label} enthält keinen gültigen finished_at-Zeitpunkt"
        ) from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError(f"{label} enthält keinen UTC-Zeitpunkt mit Zeitzone")


def validate_standard_run(run: dict) -> None:
    validate_timestamp(run.get("finished_at"), "Standardlauf")
    for field in ("head", "binary_sha256"):
        if not isinstance(run.get(field), str):
            raise ValueError(f"Standardlauf enthält kein gültiges {field}")
    tests = run.get("tests")
    if not isinstance(tests, dict):
        raise ValueError("Standardlauf enthält keine Testwerte")
    for name, sample in tests.items():
        if not isinstance(name, str) or not isinstance(sample, dict):
            raise ValueError("Standardlauf enthält ungültige Testwerte")
        if not isinstance(sample.get("status"), str) \
                or not isinstance(sample.get("mode"), str):
            raise ValueError("Testwert enthält keinen gültigen Status oder Startweg")
        for field in ("app_ms", "launch_ms", "total_ms", "cleanup_ms"):
            # bool ist in Python eine int-Unterklasse, aber kein Messwert.
            if not isinstance(sample.get(field), int) \
                    or isinstance(sample.get(field), bool):
                raise ValueError(f"Testwert enthält kein gültiges {field}")


def validate_long_run(run: dict) -> None:
    validate_timestamp(run.get("finished_at"), "Langlauf")
    for field in ("head", "binary_sha256"):
        if not isinstance(run.get(field), str):
            raise ValueError(f"Langlauf enthält kein gültiges {field}")
    for field in ("rounds_per_phase", "actions", "wall_ms"):
        if not isinstance(run.get(field), int) or isinstance(run.get(field), bool):
            raise ValueError(f"Langlauf enthält kein gültiges {field}")
    if not isinstance(run.get("ms_per_action"), (int, float)) \
            or isinstance(run.get("ms_per_action"), bool):
        raise ValueError("Langlauf enthält kein gültiges ms_per_action")


def load_data(path: Path) -> dict:
    if not path.exists():
        return empty_data()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("version") != VERSION:
            raise ValueError("unbekannte Version")
        if not isinstance(data.get("machine"), dict):
            raise ValueError("machine ist kein Objekt")
        for section in ("standard", "long"):
            groups = data.get(section)
            if not isinstance(groups, dict):
                raise ValueError(f"{section} ist kein Objekt")
            for key, runs in groups.items():
                if not isinstance(key, str) or not isinstance(runs, list) \
                        or not all(isinstance(run, dict) for run in runs):
                    raise ValueError(f"{section} enthält eine ungültige Historie")
                for run in runs:
                    if section == "standard":
                        validate_standard_run(run)
                    else:
                        validate_long_run(run)
        return data
    except (OSError, ValueError, json.JSONDecodeError) as error:
        quarantine = path.with_name(
            path.name + ".corrupt-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        )
        try:
            path.replace(quarantine)
            print(
                "PERFORMANCE-WARN Beschädigte Messdatei wurde nach "
                f"{display_path(quarantine)} verschoben: {display_error(error)}",
                file=sys.stderr,
            )
        except OSError:
            print(
                "PERFORMANCE-WARN Messdatei ist unlesbar: "
                + display_error(error),
                file=sys.stderr,
            )
        return empty_data()


def save_data(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def parse_samples(path: Path) -> dict[str, dict]:
    tests: dict[str, dict] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = raw.split("\t")
        if len(fields) != 7:
            raise ValueError(f"Messzeile {number} hat {len(fields)} statt 7 Felder")
        name, status, app_ms, launch_ms, total_ms, cleanup_ms, mode = fields
        tests[name] = {
            "status": status,
            "app_ms": int(app_ms),
            "launch_ms": int(launch_ms),
            "total_ms": int(total_ms),
            "cleanup_ms": int(cleanup_ms),
            "mode": mode,
        }
    return tests


def regression_warnings(previous: list[dict], current: dict) -> None:
    for name, sample in current["tests"].items():
        historical = [
            run["tests"][name]["launch_ms"]
            for run in previous[-5:]
            if name in run.get("tests", {})
            and run["tests"][name].get("status") == "PASS"
            and run["tests"][name].get("mode") == sample.get("mode")
        ]
        if not historical or sample["status"] != "PASS":
            continue
        median = statistics.median(historical)
        # Das Beenden des vorherigen App-Prozesses ist separat als cleanup_ms
        # gespeichert. Für die Regression des aktuellen Tests zählt nur sein
        # eigener Prozessstart bis zur Ergebniszeile.
        current_ms = sample["launch_ms"]
        if current_ms > median * 1.30 and current_ms > median + 1000:
            print(
                "PERFORMANCE-WARN "
                f"{name}: {current_ms / 1000:.2f}s statt Median "
                f"{median / 1000:.2f}s (>30 % und >1 s langsamer)"
            )


def record_standard(args: argparse.Namespace) -> int:
    path = data_path()
    try:
        tests = parse_samples(Path(args.samples))
        data = load_data(path)
        runs = data.setdefault("standard", {}).setdefault(args.configuration, [])
        current = {
            "finished_at": utc_now(),
            "head": args.head,
            "binary_sha256": args.binary_sha256,
            "os_build": platform.version(),
            "load_average": [round(value, 2) for value in os.getloadavg()],
            "tests": tests,
        }
        if args.qualified:
            regression_warnings(runs, current)
            runs.append(current)
            del runs[:-MAX_RUNS]
            save_data(path, data)
            print(f"PERFORMANCE gespeichert: {display_path(path)}")
        else:
            print("PERFORMANCE nicht als Baseline gespeichert: Lauf war nicht vollständig, sauber und stabil.")
        report_long_status(data, args.repository)
        return 0
    except (OSError, ValueError) as error:
        print(
            "PERFORMANCE-WARN Messung konnte nicht gespeichert werden: "
            + display_error(error),
            file=sys.stderr,
        )
        return 2


def record_soak(args: argparse.Namespace) -> int:
    path = data_path()
    try:
        data = load_data(path)
        runs = data.setdefault("long", {}).setdefault(args.profile, [])
        current = {
            "finished_at": utc_now(),
            "head": args.head,
            "binary_sha256": args.binary_sha256,
            "rounds_per_phase": args.rounds,
            "actions": args.actions,
            "wall_ms": args.wall_ms,
            "ms_per_action": round(args.wall_ms / args.actions, 3),
        }
        if args.qualified:
            runs.append(current)
            del runs[:-MAX_RUNS]
            save_data(path, data)
            print(f"PERFORMANCE-LANGLAUF gespeichert: {display_path(path)}")
        else:
            print("PERFORMANCE-LANGLAUF nicht gespeichert: nur vollständige grüne Läufe ab 60 Runden je Phase qualifizieren sich.")
        return 0
    except (OSError, ValueError, ZeroDivisionError) as error:
        print(
            "PERFORMANCE-WARN Langlauf konnte nicht gespeichert werden: "
            + display_error(error),
            file=sys.stderr,
        )
        return 2


def newest_long_run(data: dict) -> dict | None:
    runs = [run for profile in data.get("long", {}).values() for run in profile]
    return max(runs, key=lambda run: run.get("finished_at", ""), default=None)


def git_result(repository: str, arguments: list[str]) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            ["git", "-C", repository, *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None


def report_long_status(data: dict, repository: str) -> None:
    latest = newest_long_run(data)
    if latest is None:
        print("PERFORMANCE-WARN Auf diesem Mac wurde noch kein qualifizierter Langlauf gespeichert.")
        return
    try:
        finished = dt.datetime.fromisoformat(latest["finished_at"])
        age = dt.datetime.now(dt.timezone.utc) - finished
    except (KeyError, ValueError):
        print("PERFORMANCE-WARN Der gespeicherte Langlauf hat keinen lesbaren Zeitpunkt.")
        return
    if age > dt.timedelta(days=LONG_MAX_AGE_DAYS):
        print(f"PERFORMANCE-WARN Der letzte Langlauf ist {age.days} Tage alt.")

    head = latest.get("head", "")
    ancestor = git_result(repository, ["merge-base", "--is-ancestor", head, "HEAD"])
    if ancestor is None or ancestor.returncode != 0:
        print("PERFORMANCE-WARN Der letzte Langlauf gehört nicht zur aktuellen Historie.")
        return
    count = git_result(
        repository,
        ["rev-list", "--count", f"{head}..HEAD", "--", *RELEVANT_PATHS],
    )
    try:
        relevant = int(count.stdout.strip()) if count and count.returncode == 0 else 0
    except ValueError:
        relevant = 0
    if relevant >= LONG_MAX_RELEVANT_COMMITS:
        print(
            f"PERFORMANCE-WARN Seit dem letzten Langlauf gab es {relevant} relevante Änderungen."
        )


def status(args: argparse.Namespace) -> int:
    path = data_path()
    data = load_data(path)
    print(f"PERFORMANCE-DATEI {display_path(path)}")
    standard_count = sum(len(runs) for runs in data.get("standard", {}).values())
    print(f"PERFORMANCE-STANDARD {standard_count} qualifizierte Läufe")
    report_long_status(data, args.repository)
    return 0


def self_test(_: argparse.Namespace) -> int:
    """Kleine echte Datei-Gegenprobe für den Swift-Test der Hilfslogik."""
    previous_override = os.environ.get("FASTRA_PERFORMANCE_DATA_DIR")
    try:
        with tempfile.TemporaryDirectory(prefix="fastra-performance-test-") as directory:
            os.environ["FASTRA_PERFORMANCE_DATA_DIR"] = directory
            samples = Path(directory) / "samples.tsv"
            samples.write_text("search\tPASS\t100\t200\t250\t10\tdirect\n",
                               encoding="utf-8")
            path = data_path()
            data = empty_data()
            data["standard"]["debug"] = [
                {
                    "finished_at": utc_now(),
                    "head": str(index),
                    "binary_sha256": "test-binary",
                    "tests": {
                        "search": {
                            "status": "PASS", "app_ms": 100,
                            "launch_ms": 200, "total_ms": 250,
                            "cleanup_ms": 10, "mode": "direct",
                        }
                    },
                }
                for index in range(MAX_RUNS + 4)
            ]
            save_data(path, data)
            arguments = argparse.Namespace(
                samples=str(samples),
                configuration="debug",
                head="test-head",
                binary_sha256="test-binary",
                repository=directory,
                qualified=True,
            )
            with contextlib.redirect_stdout(io.StringIO()):
                assert record_standard(arguments) == 0
            stored = load_data(path)
            assert len(stored["standard"]["debug"]) == MAX_RUNS

            arguments.qualified = False
            with contextlib.redirect_stdout(io.StringIO()):
                assert record_standard(arguments) == 0
            assert len(load_data(path)["standard"]["debug"]) == MAX_RUNS

            path.write_text("{kaputt", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                recovered = load_data(path)
            assert recovered["version"] == VERSION
            assert list(path.parent.glob("performance-v1.json.corrupt-*"))

            path.write_text(
                '{"version": 1, "machine": {}, "standard": [], "long": {}}',
                encoding="utf-8",
            )
            with contextlib.redirect_stderr(io.StringIO()):
                recovered = load_data(path)
            assert recovered["standard"] == {}
        print("PERFORMANCE-SELFTEST PASS")
        return 0
    finally:
        if previous_override is None:
            os.environ.pop("FASTRA_PERFORMANCE_DATA_DIR", None)
        else:
            os.environ["FASTRA_PERFORMANCE_DATA_DIR"] = previous_override


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)
    standard = commands.add_parser("record-standard")
    standard.add_argument("--samples", required=True)
    standard.add_argument("--configuration", required=True)
    standard.add_argument("--head", required=True)
    standard.add_argument("--binary-sha256", required=True)
    standard.add_argument("--repository", required=True)
    standard.add_argument("--qualified", action="store_true")
    standard.set_defaults(function=record_standard)

    soak = commands.add_parser("record-soak")
    soak.add_argument("--profile", required=True)
    soak.add_argument("--head", required=True)
    soak.add_argument("--binary-sha256", required=True)
    soak.add_argument("--rounds", required=True, type=int)
    soak.add_argument("--actions", required=True, type=int)
    soak.add_argument("--wall-ms", required=True, type=int)
    soak.add_argument("--qualified", action="store_true")
    soak.set_defaults(function=record_soak)

    show = commands.add_parser("status")
    show.add_argument("--repository", required=True)
    show.set_defaults(function=status)
    check = commands.add_parser("self-test")
    check.set_defaults(function=self_test)
    return result


def main() -> int:
    arguments = parser().parse_args()
    return arguments.function(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
