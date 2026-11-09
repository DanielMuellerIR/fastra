# F07: zugängliche Textfelder

Ab 1.186.2 besitzen beide Quellansichten, Suchen und Ersetzen sowie die
Vorher-/Nachher-Vorschau eigene deutsche und englische zugängliche Namen.
Suchmodus und Suchbereich ergänzen den von GTK als Namen gemeldeten gewählten
Wert um eine Beschreibung ihres Zwecks. Die sichtbare Oberfläche bleibt gleich.

Die Änderung folgt einer physischen AT-SPI-Gegenprobe: Die sechs Textfelder
lieferten zuvor Inhalte und Cursorpositionen, aber leere Namen. Das tatsächlich
optimierte Paket besteht jetzt auf einem Cinnamon-/X11-Desktop bei Skalierung 2
beide Sprachfassungen. AT-SPI liefert alle sechs Namen, beide Beschreibungen,
Unicode-Text beider Sourcebuffer und den nach Ctrl+F fokussierten Suchtext.
Beide Läufe enden über die sichtbare Beenden-Schaltfläche.

Eine zunächst versuchte Label-Property an den Auswahllisten wurde durch GTKs
gewählten Wert überlagert; die geprüfte Fassung verwendet dort die Description.
Der erste englische Steuerungsversuch benutzte die deutsche Splitposition und
blendete Source B nicht ein. Die anhand der echten englischen Ansicht
korrigierte Bedienung besteht; der Vorversuch ist kein Produktbefund.

Direkte AT-SPI-Aktions-/Fokusaufrufe und globale Checkboxgeometrie waren in
dieser GTK-Umgebung nicht hinreichend verfügbar. Die funktionierende normale
Maus-/Tastaturbedienung und der lesende Textzugriff ersetzen daher keine
vollständige Screenreader-Abnahme. Kandidatenfenster-IME und physische
Wayland-/Accessibility-Abnahme bleiben separat offen.
