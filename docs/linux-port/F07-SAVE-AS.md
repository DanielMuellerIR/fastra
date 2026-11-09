# Linux: Speichern unter mit vollständiger Vorschau

Die sichtbare Schaltfläche „Speichern unter …“ und Ctrl+Shift+S kopieren ein
bestehendes editierbares Textdokument an ein ausdrücklich gewähltes Ziel.
Rich-Markdown wird zuvor mit seinem tatsächlichen letzten Editorstand abgeglichen.
Quelldokument, Kodierung/BOM, Sprachwahl, Revision und Fenster-/Projektkontext
bleiben bis zur Übernahme gebunden. Abschnitts-, Hex- und schreibgeschützte
Ansichten bieten diesen Schreibweg nicht an.

Die Vorschau zeigt den vollständigen Quell- und Zieltext, Kodierung, Zielpfad,
Byteumfang und Hash sowie jede neue Bildkopie. Ein vorhandenes Ziel wird separat
vollständig angezeigt und benötigt eine eigene Überschreibfreigabe. Geänderte
Ziele, ausgetauschte Pfade oder zwischenzeitliche Eingaben verhindern die
Veröffentlichung beziehungsweise die Übernahme in den Tab. Wurde das Ziel bereits
veröffentlicht, aber der ursprüngliche Tab inzwischen verändert, benennt Fastra
diesen Zustand ausdrücklich und erhält dessen neuere Eingaben und alten Pfad.

Bei einem Ordnerwechsel werden ausschließlich tatsächlich verwendete lokale
Rasterbilder inventarisiert, geprüft und unter neuen Namen mitgenommen. Die
Bilder werden über ihre wirklichen Dateisystempfade aufgelöst; `symlink/..`
darf keine andere Datei als die gerenderte Vorlage liefern. Quellalias und
aufgelöstes Ziel bleiben auch bei der abschließenden Prüfung gebunden.
Die ursprünglichen Dokumente und Bilddateien werden weder verschoben noch
bereinigt. Nicht sicher übertragbare HTML-/relative Fremdverweise führen beim
Ordnerwechsel zu einer sichtbaren Ablehnung. Im selben tatsächlichen Elternordner
behalten relative Verweise ihre Basis.

Ein Pfadwechsel mit übertragenen Bildern oder vorhandenen Bildtickets beginnt
Rückgängig ausdrücklich neu. Die alten Tickets bleiben ausschließlich mit ihrer
ursprünglichen Herkunft als Wiederherstellungsdaten erhalten. Sie werden nie
auf Bilder am neuen Ziel umgebogen. Ein einfacher Textpfadwechsel ohne diese
Herkunftsänderung erhält die Textrücknahme. Projektkontext, Sprachwahl und
Dateibeobachtung werden bei erfolgreicher Übernahme angepasst.

Die vollständige Vorschau ist auf 4 MiB je Textseite begrenzt. Es gelten höchstens
32 Rasterbilder, 32 MiB je Bild und 64 MiB gemeinsame Bilddaten. Diese Grenzen
werden vor der Zustimmung erklärt; größere Dokumente erhalten keinen versteckten
Schreibweg. Veröffentlichung und gegebenenfalls Kompensation laufen im Hintergrund.
Beenden bleibt während des gesamten Speichervorgangs gesperrt.

Die native Abnahme umfasst echten Dateidialog, vollständige Vorschau,
Überschreibfreigabe, veraltete Basen, Bildübertragung, erhaltene Ursprungsdateien,
Kodierung/BOM, Sprachwahl, Rücknahme und Öffnen ausschließlich aus dem Zielbaum.
Der konkrete Stand wird mit seinem [Paketnachweis](F16-1.174.0-EVIDENCE.md) gebunden.
