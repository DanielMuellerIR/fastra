import sys

path = sys.argv[1]
src = open(path).read()
note = ('            NotificationCenter.default.post(name: Notification.Name('
        '"fastra.completion.manualTrigger"), object: self)'
        '  // Fastra-Patch: manueller Aufruf (Esc/Ctrl-Space) erlaubt Ein-Zeichen-Vorschlaege\n')
visible = ('            if SuggestionController.shared.isVisible {\n'
           '                SuggestionController.shared.close()\n'
           '                return event\n'
           '            }\n')
if note + visible in src:
    print("  Meldung steht noch VOR dem isVisible-Zweig.", file=sys.stderr)
    sys.exit(1)
if visible + note not in src:
    print("  Meldung samt isVisible-Kontext nicht gefunden.", file=sys.stderr)
    sys.exit(1)
