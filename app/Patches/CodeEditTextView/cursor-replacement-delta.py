import sys

update_path = sys.argv[1]
update_src = open(update_path).read()

old_delta = '''        let delta = replacementLength == 0 ? -range.length : replacementLength'''
new_delta = '''        // Fastra-Patch: echte Verschiebung auch beim ERSETZEN. Upstream nahm
        // bei einer Ersetzung (geloeschte Laenge > 0 und Einfuegelaenge > 0)
        // die volle Einfuegelaenge als Delta statt der Differenz. Beim Tippen
        // in eine Rechteckauswahl (ein Bereich pro Zeile) sammelte dadurch
        // jeder nachfolgende Cursor den Fehler aller vorigen Ersetzungen auf
        // und stand mitten in seiner Zeile — weiteres Tippen zerriss die
        // Zeilen. Die Differenz deckt alle
        // Faelle ab: reines Loeschen (-range.length), reines Einfuegen
        // (+replacementLength) und Ersetzen (Differenz).
        let delta = replacementLength - range.length'''
if old_delta not in update_src:
    raise SystemExit(
        f"{update_path}: didReplaceCharacters-Delta hat sich geaendert — Patch 4z15 pruefen"
    )
update_src = update_src.replace(old_delta, new_delta, 1)

open(update_path, "w").write(update_src)
