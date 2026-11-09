# cmark für positionsbelegte GFM-Autolinkatome

Offline-Snapshot derselben Revision, die `app/Package.resolved` für den Mac
festhält: `924936d0427cb25a61169739a7660230bffa6ea6` (Swift-Paket 0.8.0).
`UPSTREAM.json` enthält ursprüngliche und gepatchte SHA-256 je Datei; neue
Metadatenquellen besitzen keinen Upstream-Hash. Die vier eingefrorenen Patches
liegen daneben. Der Builder prüft Revision, vollständige Dateimenge und alle
gepatchten Hashes, bevor er irgendetwas kompiliert. Keine Netzwerkanfrage und
kein Rückfall auf Systembibliotheken oder einen SwiftPM-Checkout.

Der native Parser liefert nur Atome. Die gemeinsame bestehende View erhält
Originalbytes/UTF16, die Math-/Mark-Pipeline und der Renderer bleiben maßgeblich.
Text-/Quellsegmente entstehen beim Dekodieren und Kürzen, nicht durch späteres
Suchen nach identischen Zielstrings. Math innerhalb von URIs wird ausschließlich
als roher Quelltext eingesetzt. Der explizite Footnote-Providermodus erhält
unreferenzierte Definitionen und lässt unbekannte Labels im normalen Inlinepfad.

Der Build aktiviert `CMARK_THREADING=1` und pthread. Der Rust-Consumer serialisiert
vollständige Parser-/Arena-Transaktionen; die globale Registry wird einmalig
initialisiert und nicht zwischen Dokumenten freigegeben. Eingabe, Ausgabe und
Arbeitsschritte sind begrenzt; Abbruch verwirft den gesamten Plan.

`vendor/COPYING` enthält die vollständigen ursprünglichen Copyright- und
Lizenzbedingungen einschließlich der MIT-Komponentenhinweise und wird im
Linux-Paket unter `share/licenses/fastra/cmark/COPYING` mitgeliefert.
