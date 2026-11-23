import sys

textline_path, typesetter_path = sys.argv[1:]
textline = open(textline_path).read()
typesetter = open(typesetter_path).read()

old_textline = '''        let string = stringRef.attributedSubstring(from: clampedRange)
        let maxWidth = typesetter.typeset('''
new_textline = '''        // Fastra-Patch: dokumentweite Megazeile ohne Attributkopie.
        // NSTextStorage ist selbst ein NSAttributedString und bleibt waehrend
        // des synchronen Typesettings unveraendert. Nur echte Teilbereiche
        // brauchen weiterhin einen eigenen Substring.
        let string: NSAttributedString = if clampedRange.location == 0
            && clampedRange.length == stringRef.length {
            stringRef
        } else {
            stringRef.attributedSubstring(from: clampedRange)
        }
        let maxWidth = typesetter.typeset('''
if "Fastra-Patch: dokumentweite Megazeile ohne Attributkopie" not in textline:
    if old_textline not in textline:
        raise SystemExit(
            f"{textline_path}: TextLine-Substring hat sich geaendert — Patch 4z8 pruefen"
        )
    textline = textline.replace(old_textline, new_textline, 1)

old_content_run = '''                    let range = NSRange(location: currentPosition, length: maxPosition - currentPosition)
                    let substring = string.attributedSubstring(from: range)
                    runs.append(
                        ContentRun(
                            range: range,
                            type: .string(CTTypesetterCreateWithAttributedString(substring))
                        )
                    )'''
new_content_run = '''                    let range = NSRange(location: currentPosition, length: maxPosition - currentPosition)
                    // Fastra-Patch: vollstaendigen Content-Run direkt an CoreText.
                    // Ohne Attachments deckt dieser Range die bereits fertige
                    // Zeile ab; ein weiterer attributedSubstring waere nur
                    // eine vollstaendige, synchrone Kopie.
                    let attributedRun: NSAttributedString = if range.location == 0
                        && range.length == string.length {
                        string
                    } else {
                        string.attributedSubstring(from: range)
                    }
                    runs.append(
                        ContentRun(
                            range: range,
                            type: .string(CTTypesetterCreateWithAttributedString(attributedRun))
                        )
                    )'''
if "Fastra-Patch: vollstaendigen Content-Run direkt an CoreText" not in typesetter:
    if old_content_run not in typesetter:
        raise SystemExit(
            f"{typesetter_path}: Content-Run hat sich geaendert — Patch 4z8 pruefen"
        )
    typesetter = typesetter.replace(old_content_run, new_content_run, 1)

old_layout_run = '''        let substring = string.attributedSubstring(from: range)
        let isUnwrapped = displayData.maxWidth == .greatestFiniteMagnitude'''
new_layout_run = '''        // Fastra-Patch: vollstaendigen Layout-Run nicht erneut kopieren.
        let substring: NSAttributedString = if range.location == 0
            && range.length == string.length {
            string
        } else {
            string.attributedSubstring(from: range)
        }
        let isUnwrapped = displayData.maxWidth == .greatestFiniteMagnitude'''
if "Fastra-Patch: vollstaendigen Layout-Run nicht erneut kopieren" not in typesetter:
    if old_layout_run not in typesetter:
        raise SystemExit(
            f"{typesetter_path}: Layout-Run hat sich geaendert — Patch 4z8 pruefen"
        )
    typesetter = typesetter.replace(old_layout_run, new_layout_run, 1)

open(textline_path, "w").write(textline)
open(typesetter_path, "w").write(typesetter)
