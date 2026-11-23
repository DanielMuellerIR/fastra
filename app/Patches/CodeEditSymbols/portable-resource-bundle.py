import argparse
from pathlib import Path
import re


MARKER = "// Fastra-Patch: portables CodeEditSymbols-Ressourcenbundle."
ACCESSOR = '''private let fastraCodeEditSymbolsBundle: Bundle = {
    if let resources = Bundle.main.resourceURL,
       let packaged = Bundle(
           url: resources.appendingPathComponent("CodeEditSymbols_CodeEditSymbols.bundle")
       ) {
        return packaged
    }
    return Bundle.module
}()'''
CALLS = (
    "        self.init(symbol, bundle: Bundle.module)",
    "        Bundle.module.image(forResource: named)",
)
DIRECT_ACCESS = re.compile(r"\bBundle\s*\.\s*module\b")


def redirected(call):
    return call.replace("Bundle.module", "fastraCodeEditSymbolsBundle")


def check(source):
    lines = source.splitlines()
    if source.count(MARKER) != 1 or source.count(ACCESSOR) != 1:
        raise SystemExit("CodeEditSymbols: Portabler Ressourcen-Accessor fehlt oder wurde geändert.")
    if any(lines.count(redirected(call)) != 1 for call in CALLS):
        raise SystemExit("CodeEditSymbols: Beide Aufrufstellen müssen den portablen Accessor verwenden.")
    # Nur der Fallback im Accessor darf SwiftPMs absoluten Build-Pfad erreichen.
    if DIRECT_ACCESS.search(source.replace(ACCESSOR, "", 1)):
        raise SystemExit("CodeEditSymbols: Direkter Bundle.module-Zugriff außerhalb des Accessors.")


parser = argparse.ArgumentParser()
parser.add_argument("path", type=Path)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
source = args.path.read_text(encoding="utf-8")
if not args.check:
    lines = source.splitlines()
    if lines.count("import SwiftUI") != 1 or any(lines.count(call) != 1 for call in CALLS):
        raise SystemExit("CodeEditSymbols: Erwarteter Import oder erwartete Aufrufstellen haben sich geändert.")
    for call in CALLS:
        source = source.replace(call, redirected(call), 1)
    header = "\n".join((
        "import SwiftUI", "", MARKER,
        "// Gepackte Apps verwenden Contents/Resources. SwiftPM-CLI-Builds und",
        "// Tests behalten den Fallback auf das generierte Ressourcenbundle.",
        ACCESSOR, "",
    ))
    source = source.replace("import SwiftUI\n", header, 1)
check(source)
if not args.check:
    args.path.write_text(source, encoding="utf-8")
