import sys
path = sys.argv[1]
src = open(path).read()
old = '''            let typesetSubrange = NSRange(location: context.currentPosition - range.location, length: lineBreak)
            let typesetData = typesetLine(typesetter: typesetter, range: typesetSubrange)'''
new = '''            // Fastra-Patch: Break-Endindex in Fragmentlaenge umrechnen.
            // `lineBreak` ist ein absoluter Endindex im Content-Run, waehrend
            // NSRange.length eine Laenge erwartet. Ohne die Subtraktion
            // ueberlappt jedes Folgefragment den bereits umbrochenen Text.
            let relativeStart = context.currentPosition - range.location
            let typesetSubrange = NSRange(
                location: relativeStart,
                length: lineBreak - relativeStart
            )
            let typesetData = typesetLine(typesetter: typesetter, range: typesetSubrange)'''
if old not in src:
    sys.exit("Typesetter-Quelltext hat sich geaendert — Patch 4i passt nicht mehr")
open(path, "w").write(src.replace(old, new))
