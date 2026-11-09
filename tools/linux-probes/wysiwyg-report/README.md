# Gemeinsame WYSIWYG-Regressionen

Die Probe lädt Turndown und die unveränderten lokalen Editor-Einstiegspunkte
in frische GTK4/WebKit6-Dokumente. Python benötigt PyGObject und GI-Bindungen
für Gtk4 und WebKit6. Auf einer isolierten Anzeige ausführen:

```sh
python3 tools/linux-probes/wysiwyg-report/run.py "$PWD"
```

Ohne weitere Argumente laufen alle Fälle. Einzelne Namen können nach dem
Repo-Pfad folgen. Pro Fall wird ein JSON-Objekt ausgegeben; eine fehlgeschlagene
Bedingung oder Frist ergibt Exit1. Die Prüfung verwendet synthetische Inhalte
und eine private JS-Nachrichtenaufnahme statt des echten Desktop-Clipboards.
Das native Clipboard sowie die Speicherrundreise werden zusätzlich durch
`MarkdownVisualTests/reportHighlightClipboardMetadata` geprüft.

`FASTRA_WYSIWYG_VENDOR` kann auf die drei Skripte des unveränderten Ausgangs-
stands zeigen. So wird dieselbe neue Prüfung für den Gegenbeweis verwendet.
Die Fälle umfassen NBSP und sichere Formatgrenzen, verschachtelte Formate,
Return/Delete/Undo, bytegenaue Nachbar-/Nachlaufblöcke, Referenzdefinitionen,
Highlight-Export, fremde Clipboard-Metadaten und tatsächliches Scrollen.
Kein Test greift auf Nutzerdokumente oder Netzwerk zu.
