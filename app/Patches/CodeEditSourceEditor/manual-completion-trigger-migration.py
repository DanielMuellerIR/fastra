import os, stat, sys

path = sys.argv[1]
src = open(path).read()
note = ('            NotificationCenter.default.post(name: Notification.Name('
        '"fastra.completion.manualTrigger"), object: self)'
        '  // Fastra-Patch: manueller Aufruf (Esc/Ctrl-Space) erlaubt Ein-Zeichen-Vorschlaege\n')
visible = ('            if SuggestionController.shared.isVisible {\n'
           '                SuggestionController.shared.close()\n'
           '                return event\n'
           '            }\n')
old = note + visible      # v1.66.0: Meldung vor dem isVisible-Zweig
new = visible + note      # ab v1.68.1: Meldung danach
if old not in src:
    sys.exit(3)           # nichts zu migrieren
print("→ Migriere CodeEditSourceEditor (4b-2: Manuell-Trigger hinter den isVisible-Zweig)")
os.chmod(path, os.stat(path).st_mode | stat.S_IWUSR)
open(path, "w").write(src.replace(old, new, 1))
