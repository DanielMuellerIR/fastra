#!/usr/bin/env python3
"""Prüfbares Linux-Laufzeitverzeichnis ohne Build-Cache oder Systembibliotheken."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import identity


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--control-binary", type=Path, required=True)
    parser.add_argument("--diff-binary", type=Path, required=True)
    parser.add_argument("--icu-prefix", type=Path, required=True)
    parser.add_argument("--icu-license", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    repo = args.repo.resolve()
    bundle_build = identity.check_version(repo, args.version)
    source_sha256, _ = identity.snapshot_hash(repo)
    output = args.output.resolve()
    if output.exists():
        parser.error("Output must not exist; previous artifacts are never overwritten.")
    marker = args.icu_prefix / "ICU-SOURCE-SHA256"
    expected_icu = "3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0"
    if marker.read_text().strip() != expected_icu:
        parser.error("ICU source identity does not match the verified build-icu.sh input.")
    for binary in (args.binary, args.control_binary, args.diff_binary):
        header = subprocess.check_output(["readelf", "-h", str(binary)], text=True)
        if "Advanced Micro Devices X86-64" not in header:
            parser.error(f"{binary.name} is not an x86_64 ELF.")
        dynamic = subprocess.check_output(["readelf", "-d", str(binary)], text=True)
        if "RPATH" in dynamic or "RUNPATH" in dynamic:
            parser.error(f"Runtime search paths are forbidden in {binary.name}.")
        for component in (("uc", "i18n") if binary == args.binary else ()):
            if f"[libicu{component}.so.78]" not in dynamic:
                parser.error(f"{binary.name} does not link the required ICU {component} 78 runtime.")
    icu_dynamic = subprocess.check_output([
        "readelf", "-d", str(args.icu_prefix / "lib/libicuuc.so.78.3")
    ], text=True)
    if "[libicudata.so.78]" not in icu_dynamic:
        parser.error("ICU common library does not link the private ICU 78 data runtime.")
    elf_files = [args.binary, args.control_binary, args.diff_binary] + [args.icu_prefix / "lib" / f"libicu{part}.so.78.3" for part in ("data", "uc", "i18n")]
    for elf in elf_files:
        dynamic = subprocess.check_output(["readelf", "-d", str(elf)], text=True)
        if "RPATH" in dynamic or "RUNPATH" in dynamic:
            parser.error(f"Runtime search paths are forbidden in {elf.name}.")
        properties = subprocess.check_output(["readelf", "-n", str(elf)], text=True)
        if re.search(r"x86-64-v[234]", properties):
            parser.error(f"Non-baseline x86-64 ISA requirement in {elf.name}.")
        versions = subprocess.check_output(["readelf", "--version-info", str(elf)], text=True)
        if any((int(major), int(minor)) > (2, 39) for major, minor in re.findall(r"GLIBC_(\d+)\.(\d+)", versions)):
            parser.error(f"{elf.name} requires glibc newer than the Ubuntu 24.04 baseline.")
    metadata = json.loads(subprocess.check_output([
        "cargo", "metadata", "--locked", "--offline", "--format-version", "1",
        "--filter-platform", "x86_64-unknown-linux-gnu",
    ], cwd=repo))
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    wanted = set()

    def collect(package_id):
        if package_id in wanted:
            return
        wanted.add(package_id)
        for dependency in nodes[package_id]["deps"]:
            collect(dependency["pkg"])

    collect(next(p["id"] for p in packages.values() if p["name"] == "fastra-linux"))
    collect(next(p["id"] for p in packages.values() if p["name"] == "fastra-control"))
    output.mkdir(parents=True)

    def copy(source, target):
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

    copy(args.binary, output / "libexec/fastra-linux")
    (output / "libexec/fastra-linux").chmod(0o755)
    tools = Path(__file__).resolve().parent
    copy(tools / "fastra", output / "bin/fastra")
    (output / "bin/fastra").chmod(0o755)
    copy(args.control_binary, output / "libexec/fastra-control")
    (output / "libexec/fastra-control").chmod(0o755)
    copy(tools / "fastra-control", output / "bin/fastra-control")
    (output / "bin/fastra-control").chmod(0o755)
    copy(args.diff_binary, output / "libexec/fastra-diff")
    (output / "libexec/fastra-diff").chmod(0o755)
    copy(tools / "fastra-diff", output / "bin/fastra-diff")
    (output / "bin/fastra-diff").chmod(0o755)
    for name in ("update.py", "install.py", "verify.py"):
        copy(tools / name, output / "libexec/fastra-update" / name)
    for component in ("data", "uc", "i18n"):
        name = f"libicu{component}.so.78.3"
        source = args.icu_prefix / "lib" / name
        copy(source, output / "lib" / name)
        (output / "lib" / f"libicu{component}.so.78").symlink_to(name)
    licenses = output / "share/licenses/fastra"
    copy(repo / "LICENSE", licenses / "LICENSE")
    copy(repo / "app/Sources/Fastra/Resources/Brand/OFL.txt", licenses / "sora/OFL.txt")
    inter = repo / "crates/fastra-linux/resources/fonts/inter-4.1"
    inter_manifest = json.loads((inter / "SOURCE.json").read_text())
    for name, entry in inter_manifest["files"].items():
        if hashlib.sha256((inter / name).read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"Unverified Inter font resource: {name}")
    copy(inter / "LICENSE.txt", licenses / "inter-4.1/LICENSE.txt")
    copy(inter / "SOURCE.json", licenses / "inter-4.1/SOURCE.json")
    copy(args.icu_license, licenses / "icu78.3/LICENSE")
    copy(repo / "THIRD-PARTY-NOTICES.md", licenses / "THIRD-PARTY-NOTICES-upstream.md")
    cmark = repo / "crates/fastra-linux/native/cmark"
    cmark_manifest = json.loads((cmark / "UPSTREAM.json").read_text())
    if cmark_manifest["revision"] != "924936d0427cb25a61169739a7660230bffa6ea6":
        raise ValueError("Unverified native cmark revision")
    copy(cmark / "vendor/COPYING", licenses / "cmark/COPYING")
    copy(cmark / "UPSTREAM.json", licenses / "cmark/SOURCE.json")
    syntax = repo / "crates/fastra-core/native/regex-syntax"
    syntax_manifest = json.loads((syntax / "SOURCES.json").read_text())
    syntax_revisions = {name: syntax_manifest[name]["revision"] for name in ("runtime", "grammar")}
    if syntax_revisions != {"runtime": "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406", "grammar": "b2ac15e27fce703d2f37a79ccd94a5c0cbe9720b"}:
        raise ValueError("Unverified regex syntax sources")
    syntax_files = {file.relative_to(syntax).as_posix() for file in syntax.rglob("*") if file.is_file() and file != syntax / "SOURCES.json"}
    if syntax_files != set(syntax_manifest["files_sha256"]):
        raise ValueError("Incomplete regex syntax source inventory")
    for name, expected in syntax_manifest["files_sha256"].items():
        if hashlib.sha256((syntax / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Regex syntax source changed: {name}")
    for name in ("runtime/LICENSE", "grammar/LICENSE", "runtime/src/unicode/LICENSE", "SOURCES.json"):
        copy(syntax / name, licenses / "regex-syntax" / name)
    folding = repo / "crates/fastra-core/native/folding"
    folding_catalog = json.loads((folding / "catalog.json").read_text())
    if folding_catalog["mac_catalog_revision"] != "331d5dbc5fc8513be5848fce8a2a312908f36a11" or len(folding_catalog["grammars"]) != 29:
        raise ValueError("Unverified folding grammar catalog")
    copy(folding / "catalog.json", licenses / "folding/catalog.json")
    for grammar in folding_catalog["grammars"]:
        name = grammar["repository"]
        if not re.fullmatch(r"tree-sitter-[a-z-]+", name) or grammar["license"] != "MIT":
            raise ValueError("Unverified folding grammar license")
        for filename, expected in grammar["license_sha256"].items():
            if Path(filename).name != filename or hashlib.sha256((folding / name / filename).read_bytes()).hexdigest() != expected:
                raise ValueError(f"Folding license changed: {name}")
            copy(folding / name / filename, licenses / "folding" / name / filename)
    vendor = repo / "app/Sources/Fastra/Resources/MarkdownVendor"
    js_assets = json.loads((tools / "js-assets.json").read_text())
    for name, expected in js_assets.items():
        asset = vendor / name
        if hashlib.sha256(asset.read_bytes()).hexdigest() != expected:
            raise ValueError(f"JavaScript asset changed; review complete license inventory: {name}")
    js_manifest = json.loads((tools / "licenses/js/manifest.json").read_text())
    if hashlib.sha256((tools / "js-licenses.lock.json").read_bytes()).hexdigest() != js_manifest["lock_sha256"]:
        raise ValueError("JavaScript license lock changed without regenerating complete texts")
    for package in js_manifest["packages"]:
        slug = package["name"].replace("/", "_") + "-" + package["version"]
        for name, expected in package["files"].items():
            file = tools / "licenses/js" / slug / name
            if hashlib.sha256(file.read_bytes()).hexdigest() != expected:
                raise ValueError(f"JavaScript license missing or altered: {slug}/{name}")
    shutil.copytree(tools / "licenses/js", licenses / "javascript/js")
    copy(tools / "licenses/SOURCES.md", licenses / "javascript/SOURCES.md")
    copy(tools / "js-licenses.lock.json", licenses / "javascript/js-licenses.lock.json")
    copy(tools / "js-assets.json", licenses / "javascript/js-assets.json")
    for file in vendor.glob("LICENSE-*.txt"):
        copy(file, licenses / "javascript/vendor" / file.name)
    for name in js_assets:
        content = (vendor / name).read_text()
        blocks = [block for block in re.findall(r"/\*![\s\S]*?\*/", content) if "license" in block.lower() or "copyright" in block.lower()]
        if blocks:
            destination = licenses / "javascript/vendor" / (name + ".bundled-notices.txt")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text("\n\n".join(blocks) + "\n")
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    rust_licenses = sysroot / "share/doc/rust"
    copy(rust_licenses / "COPYRIGHT-library.html", licenses / "rust-standard-library/COPYRIGHT-library.html")
    shutil.copytree(rust_licenses / "licenses", licenses / "rust-standard-library/licenses")
    notices = ["Fastra Linux third-party notices", "Tree-sitter folding grammars — MIT; see folding/catalog.json and original licenses.", "", "ICU 78.3 — Unicode License V3 and bundled third-party notices; see icu78.3/LICENSE.", "Rust standard library — see rust-standard-library/COPYRIGHT-library.html and licenses/.", ""]
    for package_id in sorted(wanted):
        package = packages[package_id]
        if package["source"] is None:
            continue
        source = Path(package["manifest_path"]).parent
        name = f'{package["name"]}-{package["version"]}'
        files = set()
        for pattern in ("LICENSE*", "LICENCE*", "COPYING*", "COPYRIGHT*", "NOTICE*", "license*", "licence*"):
            files.update(source.glob(pattern))
        if package.get("license_file"):
            files.add(source / package["license_file"])
        actual = []
        for item in sorted(files):
            candidates = item.rglob("*") if item.is_dir() else [item]
            for file in candidates:
                if file.is_file():
                    relative = file.relative_to(source)
                    copy(file, licenses / "rust" / name / relative)
                    actual.append(str(relative))
        if not actual:
            overrides = json.loads((tools / "licenses/rust-overrides.json").read_text())
            override = overrides.get(name)
            if override is None:
                raise RuntimeError(f"Missing complete license text for {name}; distribution blocked")
            vcs = json.loads((source / ".cargo_vcs_info.json").read_text())
            license_file = tools / "licenses" / override["file"]
            if vcs["git"]["sha1"] != override["commit"] or hashlib.sha256(license_file.read_bytes()).hexdigest() != override["sha256"]:
                raise RuntimeError(f"Upstream license identity mismatch: {name}")
            copy(license_file, licenses / "rust" / name / "LICENSE")
            (licenses / "rust" / name / "SOURCE.txt").write_text(override["source"] + "\n")
            actual.append("LICENSE")
        notices.append(f'{name} | {package.get("license") or "see license files"} | {package.get("repository") or "crates.io"}')
    (licenses / "THIRD-PARTY-NOTICES.txt").write_text("\n".join(notices) + "\n")
    icon = repo / "app/Sources/Fastra/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png"
    copy(icon, output / "share/icons/hicolor/256x256/apps/fastra.png")
    copy(tools / "fastra.desktop", output / "share/applications/fastra.desktop")
    manifest = {
        "format": 1, "version": args.version, "architecture": "x86_64",
        "runtime": "ICU 78.3, baseline x86-64; distro GTK >=4.12, GtkSourceView >=5.6, WebKitGTK 6 >=2.40",
        "bundle_build": bundle_build,
        "source_sha256": source_sha256,
        "icu_source_sha256": expected_icu,
        "cmark_revision": cmark_manifest["revision"],
        "regex_syntax_revisions": syntax_revisions,
        "folding_catalog_revision": folding_catalog["mac_catalog_revision"],
        "source_date_epoch": int(os.environ.get("SOURCE_DATE_EPOCH", "0")),
        "sha256": {},
        "symlinks": {},
    }
    for file in sorted(output.rglob("*")):
        if file.is_symlink():
            manifest["symlinks"][str(file.relative_to(output))] = os.readlink(file)
        elif file.is_file():
            manifest["sha256"][str(file.relative_to(output))] = hashlib.sha256(file.read_bytes()).hexdigest()
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(output)


if __name__ == "__main__":
    main()
