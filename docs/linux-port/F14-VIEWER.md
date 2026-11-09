# F14: begrenzte native Bild-, SVG- und PDF-Vorschau

Stand: 2026-11-05. Diese erste Linux-Vorschau baut auf dem Quellstand
`f5fdc6268a5b07137fb35d522982d69068b5917c` auf. Die native Mac-App bleibt unverändert.

## Verhalten

PNG, JPEG, GIF, WebP, SVG und PDF öffnen aus dem normalen Dateidialog bzw. als
Dateiargument in einem schreibgeschützten Vorschau-Tab. GIF und WebP zeigen das
erste Einzelbild. SVGZ und andere Bildformate werden derzeit nicht unterstützt.
Bei erkanntem Vorschauformat gibt es bei Fehlern keinen stillen Wechsel in den
Texteditor. Ein ausdrücklich gewählter Textzeichensatz bleibt ein bewusster
Text-Ladeauftrag.

PDF bietet vorherige/nächste Seite und direkte Seitenwahl. Alle Formate bieten
25–400 Prozent Zoom, Einpassen und erneutes Öffnen des aktuellen Dateistands in
einem neuen Tab. Transparenz erscheint auf Weiß. Speichern, Ersetzen und die
Markdown-Vorschau bleiben gesperrt; die Originaldatei wird nie verändert.

Identität, aufgelöster Pfad, Größe, Änderungszeiten und Snapshotbytes werden vor
und nach jeder Berechnung geprüft. Auch ein Dateiaustausch mit identischen Bytes
wird abgewiesen. Die Bildanzeige wird dann geleert; ein sichtbarer Hinweis bietet
Neuöffnen an. Ein Tabwechsel verwirft verspätete Ergebnisse und bricht den
Kindprozess ab. Einpassen setzt die pausierte Vorschau fort.

## Begrenzung und Isolation

- Datei höchstens 32 MiB; SVG höchstens 4 MiB und 100.000 XML-Knoten.
- Bildquelle höchstens 32 Megapixel. Ausgabe höchstens 4096 Pixel pro Kante und
  16 Megapixel; Einpassen berechnet höchstens 1536 Pixel Kantenlänge.
- PDF höchstens 10.000 Seiten; genau eine ausgewählte Seite wird gerastert.
- Pro Decoder: 1 GiB Adressraum, 10 CPU-Sekunden, 15 Sekunden Laufzeit,
  64 MiB Ausgabedatei, begrenzte Standardausgabe/Fehlerausgabe und 64 Dateideskriptoren.
- ImageMagick zusätzlich: 128 MiB Pixelcache, kein Disk-/Map-Cache, ein Thread,
  keine Delegates oder Filter; nur PNG/JPEG/GIF/WebP/PPM als Codecs.

Unvertrauenswürdige Bild-, SVG- und PDF-Codecs laufen ausschließlich in einem
Bubblewrap-Kindprozess mit getrennten Benutzer-, Mount-, PID- und Netzräumen,
`NoNewPrivs`, ohne Fähigkeiten, Home oder Host-Netz. Sichtbar sind nur die private
Snapshotkopie, das private Ausgabeverzeichnis, das ausgewählte Programm sowie
notwendige Bibliotheken, Schriftarten und Poppler-Daten. GTK verarbeitet keine
komprimierten Decodergebnisse: Ein kleiner Parser akzeptiert ausschließlich ein
streng begrenztes P6-RGB-Bild und erzeugt daraus eine `GdkMemoryTexture`.

SVG wird zuvor strukturiert mit `roxmltree = 0.21.1` geprüft: keine DTD/Entitäten,
Verarbeitungsanweisungen, Skripte, `foreignObject`, XML-Basisadresse, externen
`href`-/`src`-Referenzen oder externen CSS-URLs. Interne `#`-Referenzen sind erlaubt.
CSS-Escapes und `@`-Regeln werden abgewiesen. Das schließt auch eingebettete
Datenbilder und externe Fonts aus. SVG muss UTF-8 sein. PDF-Links, JavaScript,
Formulare und eingebettete Anhänge werden nicht interaktiv ausgeführt.

Erreichte Grenzen, fehlende Programme oder verweigerte Benutzer-Namensräume
zeigen einen Fehler. Es gibt keinen unsandboxierten Ersatz. Größere Dateien und
Animationen benötigen eine spätere, gesonderte Erweiterung.

## Systemabhängigkeiten

Neben dem vorhandenen GTK-Stack werden Bubblewrap, `prlimit`, ImageMagick,
`rsvg-convert`, `pdfinfo` und `pdftoppm` benötigt. Programme werden ausschließlich
unter `/usr/bin` aufgerufen. Ubuntu/Mint-Pakete: `bubblewrap`, `util-linux`,
`imagemagick`, `librsvg2-bin`, `poppler-utils`; Arch: `bubblewrap`, `util-linux`,
`imagemagick`, `librsvg`, `poppler`. Die Anwendungen werden aus dem System bezogen,
nicht zusammen mit Fastra verteilt. Die Debian- und Arch-Paketmetadaten enthalten diese Laufzeitpakete bereits.

Geprüfte Decoderstände: Bubblewrap 0.13.1, util-linux 2.42.4, ImageMagick
7.1.2-35 Q16-HDRI, librsvg 2.63.4, Poppler 26.10.0 auf Linux x86-64.
Zusätzlich bestand die reale native Decoder-/Isolationsprüfung am 2026-11-05 im
Ubuntu-24.04-Paketbuilder: Bubblewrap 0.9.0, util-linux 2.39.3, ImageMagick
6.9.12-98, librsvg 2.58.0 und Poppler 24.02.0. PNG/JPEG/GIF/WebP, SVG und
zweiseitiges PDF liefen mit den vorhandenen Sandboxgrenzen. Der in Commit
`f6115b1` enthaltene numerische Weißwert `#ffffff` vermeidet unter ImageMagick 6
eine Abhängigkeit von der absichtlich ausgeblendeten `colors.xml`.
Dieser Backendbeleg ersetzt keine Freigabe eines Installationspakets.
Eine Systemrichtlinie, die Bubblewrap-Namensräume verbietet, bleibt eine sichtbare
Funktionsgrenze.

## Prüfung

`cargo test -p fastra-linux viewer::tests -- --include-ignored`: sechs Prüfungen
bestanden, darunter reale PNG/JPEG/GIF/WebP-, SVG- und zweiseitige PDF-Decoder.
Belegt sind außerdem bytegleiche Quellen, Symlinkziel, Dateigrößengrenze,
verweigerter Text-Rückfall, externe SVG-Referenzen einschließlich XML-Zeichenreferenzen,
Ausgabe-Symlinks, reine RGB-Übernahme, verweigerter Zugriff auf `/etc/passwd`,
`NoNewPrivs: 1`, tatsächlicher Prozessabbruch und Dateiaustausch gleicher Bytes.
Die native Decoderprüfung ist für gewöhnliche, eingeschränkte Testumgebungen
explizit ignoriert und wurde hier gesondert mit ausgeführt.

Build und `cargo clippy -p fastra-linux --all-targets -- -D warnings` bestanden.
Der echte GTK-Selbsttest `FASTRA_VIEWER_SELFTEST=1` lief auf vier getrennten
Xvfb-/D-Bus-Sitzungen: Deutsch/Englisch, 760 und 1600 Pixel Breite, hell/dunkel.
Er prüft schreibgeschützten Bildtab, SVG-Zoom/Einpassen, PDF-Seite 2,
Save-Sperre, verweigertes externes SVG, unveränderte Dateien, Tabwechselabbruch
mit Fortsetzen und sichtbare Ablehnung eines ausgetauschten PDFs.
Die betroffenen Ansichten wurden visuell geprüft. Diese Läufe verwenden
synthetische temporäre Daten und keinen Benutzerdesktop.

Primärquellen: [Poppler-Werkzeuge](https://poppler.freedesktop.org/),
[Ubuntu-24.04-Manpage pdftoppm](https://manpages.ubuntu.com/manpages/noble/en/man1/pdftoppm.1.html),
[librsvg rsvg-convert](https://gnome.pages.gitlab.gnome.org/librsvg/rsvg-convert.html),
[roxmltree 0.21.1](https://github.com/RazrFalcon/roxmltree/tree/v0.21.1),
[Bubblewrap](https://github.com/containers/bubblewrap),
[ImageMagick-Sicherheitsrichtlinie](https://imagemagick.org/script/security-policy.php).
