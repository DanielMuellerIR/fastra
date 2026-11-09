# F01: Rücknahmegrenzen der privaten GTK-Laufzeit

Der private Laufzeitkandidat für 1.188.0 korrigiert einen GTK-Historyfall, den die
neuen Markdown-Quellbefehle unabhängig vom Produkt reproduziert haben: Nach
Redo konnte ein neuer nativer Edit in die wiederhergestellte Gruppe geraten.
Eine pauschal nach Redo eingeschobene leere Useraktion wäre kein allgemeiner
Fix, weil System-GTK dabei weitere Redos löscht.

Der gebundene Patch `tools/linux-native/gtk-history-v2.patch` setzt nach Redo
eine Gruppengrenze, ohne die übrige Redoqueue zu löschen. Gruppen-/Grenzmarker
und leere Aktionen verwerfen keine zukünftigen Schritte; erst eine tatsächliche
Einfügung oder Löschung tut das. Die Historiengrenze zählt echte Aktionen statt
Barriers und leerer Gruppen. Bereits zusammengefasste Aktionen werden nicht
nach ihrer Freigabe erneut gelesen. Es gibt weder einen Historyreset noch ein
Abschalten von Undo.

Ein unabhängiges Review fand im ersten Prototyp einen neuen Absturz: Bei Limit 1
blieb nach Trunkierung zweier echter Mehraktionsgruppen eine führende Barrier
zurück. Undo und anschließendes Setzen des Savepunkts griffen auf deren fehlenden
Vorgänger zu. Dieser Kandidat ist verworfen. Version 2 entfernt die verwaiste
führende Grenze; derselbe Review hat die Korrektur ohne neue Funde geprüft.
Die Buildlocks binden ausschließlich die korrigierte vollständige Patchfassung.

Programmedits und echte XTest-Tasten prüfen neue Aktionen nach Redo, mehrere
Redo-Schritte, ältere History, NoOps, interaktiv verweigerte Readonlyänderungen,
Save/Modified und Limits 1/2. Der neue Gegenfall verwendet echte nicht benachbarte
Mehraktionsgruppen, vollständiges Undo bis zum Limit und 1.000 Save-/Redozyklen.
Je 100.000 verschachtelte NoOps zeigen im beobachteten Test keinen zusätzlichen
belegten Heap. Die drei C-Reporter bestehen zusätzlich mit instrumentiertem
Historyobjekt unter ASAN/LSAN; damit wird keine vollständige GTK-Instrumentierung
behauptet. Die 5.252 dynamischen GTK-Exporte bleiben unverändert.

Der Paketpfad baut GTK vollständig neu aus der authentifizierten
Distributionsquelle mit allen Distributionspatches, Commit-/Editplanpatches
und dieser Historyfassung. Der Systempfad verwendet weiter unverändertes GTK;
seine allgemeine After-Redo-Grenze bleibt bestehen. Die enge lokale Boundary
der vier Markdown-Quellbefehle schützt dort ausschließlich diesen Befehlsweg.
