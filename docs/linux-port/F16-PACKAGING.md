# F16: Linux-Build und Paketierung

Die Linux-Einstiegsskripte erzeugen GUI und Steuerungshelfer, ein verschiebbares
tar.gz-Archiv, ZIP, Debian-Paket und einen mit dem konkreten Archiv-Hash
gefüllten Arch-PKGBUILD. Ein Benutzerinstaller und ausdrückliche OpenPGP-Signierung
stehen ebenfalls bereit. Die Entwicklungsprüfungen der Installation erfolgen
ausschließlich in Wegwerf-Containern. Ein Paket macht den Linux-Produktumfang nicht
vollständig; die übrigen Grenzen stehen in der Roadmap.

## Laufzeit und Herkunft

Ziel ist x86_64 mit glibc 2.39 oder neuer, GTK mindestens 4.12, GtkSourceView
mindestens 5.6 und WebKitGTK 6 mindestens 2.40. Ubuntu 24.04 ist die
Build-Untergrenze. GTK, GtkSourceView, WebKit und ihre Abhängigkeiten stammen
vom Betriebssystem. Das Archiv ist verschiebbar und benötigt diese
Systembibliotheken; es ist kein unabhängiges AppImage.

Die native Bild-/SVG-/PDF-Vorschau benötigt zusätzlich Bubblewrap, `prlimit`,
ImageMagick, `rsvg-convert`, `pdfinfo` und `pdftoppm`. Debian/Mint beziehen sie
über `bubblewrap`, `util-linux`, `imagemagick`, `librsvg2-bin` und `poppler-utils`;
Arch über `bubblewrap`, `util-linux`, `imagemagick`, `librsvg` und `poppler`.
Builder, Smokeimage und Paketabhängigkeiten führen diese Pakete ausdrücklich.
Fehlt ein Backend oder verbietet das System die Isolation, bleibt die Vorschau
mit sichtbarem Fehler gesperrt.

ICU 78.3 wird mitgeliefert: `libicudata`, `libicuuc` und `libicui18n` mit
relativen SONAME-Verweisen. Der Launcher ermittelt auch über `/usr/bin/fastra`
sein wirkliches Verzeichnis und setzt den privaten Bibliothekspfad vor den
bisherigen Suchpfad. Absolute Build-Pfade sind kein Laufzeit-Rückfall.
`stage.py` weist App-RPATHs, falsche ICU-SONAMEs, deklarierte x86-64-v2/v3/v4-
Anforderungen und GLIBC-Symbole oberhalb 2.39 ab.

`build-icu.sh` prüft das offizielle ICU-78.3-Quellarchiv gegen SHA256
`3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0`
und baut mit `-march=x86-64 -mtune=generic`. Rust verwendet ebenfalls
`-C target-cpu=x86-64`. Eine distributionsseitig auf x86-64-v4 optimierte
ICU darf nicht kopiert werden. Der vom Build erzeugte Identitätsmarker muss
bei seinem Runtime-Präfix bleiben; ein fremder Marker ersetzt keine
Herkunftsprüfung.

Der Builder pinnt das Ubuntu-Basisimage per Digest und Rust auf 1.99.1.
Cargo baut mit `--locked`. Ubuntu-Pakete kommen aus den beim Image-Bau
verfügbaren Paketquellen. Für identische spätere Compiler-/SDK-Bedingungen
muss das erzeugte Image erhalten bleiben; ein erneuter Image-Bau zu einem
anderen Zeitpunkt ist damit nicht als bitgleich belegt. Der Ausgabeordner
enthält Image-ID, Compiler- und Ubuntu-Paketliste.

## Vollständige Eingaben und Lizenzen

Der Quell-Snapshot enthält Cargo-Dateien, Crates, `linux/`, `Info.plist`,
`THIRD-PARTY-NOTICES.md` und die vollständigen eingebetteten App-Ressourcen,
einschließlich MarkdownVendor. `identity.py` prüft die Paketversion gegen die
Linux-Crate und `CFBundleShortVersionString`. Der separate numerische
`CFBundleVersion` wird validiert und im Beleg festgehalten, nicht mit der
Semver gleichgesetzt. Die sortierte Datei-SHA256-Liste identifiziert den
wirklich gebauten Snapshot auch bei weiterlaufender Entwicklung.

Das Staging übernimmt vollständige Rust-Lizenztexte, die
Standardbibliotheks-Hinweise und die komplette ICU-Lizenz. Bei vier
veröffentlichten WebKit-Rust-Crates fehlt die Lizenz im Crate-Archiv. Der
Fallback übernimmt deshalb die vollständige upstream MIT-Lizenz nur bei
passender Paketversion, dem in `.cargo_vcs_info.json` nachgewiesenen Commit
und passendem Lizenz-SHA256. Ein unbekannter fehlender Text blockiert weiter.

Für die eingebetteten JavaScript-Bibliotheken liegen vollständige Texte aus
145 integritätsgepinnten npm-Archiven vor. Grundlage sind Mermaids
Release-Lock und die mitgebündelten Parser-Abhängigkeiten, ergänzt um die
exakten eigenständig eingebetteten Versionen. Die Menge enthält vorsorglich
auch erreichbare Typ-/Build-Abhängigkeiten. Der Collector führt keine
Paketskripte aus und speichert Archive nur im angegebenen Cache außerhalb
des Repos. Die ursprünglichen Vendor-Lizenzen, Mermaids erhaltene gebündelte
Copyright-Blöcke und die vollständige DOMPurify-Apache-/MPL-Lizenz bleiben
als Text zugänglich. `js-assets.json` bindet dieses Inventar an die wirklich
eingebetteten JS-/CSS-Dateien; Änderungen verlangen eine neue Prüfung.

## Bauen, signieren und installieren

Die Rootskripte wählen unter macOS weiterhin `app/`, unter Linux `linux/`.
Die Linuxversion und die native Buildnummer werden aus Cargo und `Info.plist`
ermittelt und auf Konsistenz geprüft; kein Skript erhöht selbst die Version.

```bash
./build.sh                    # nativer Debugbuild, drei ELF
./build.sh --release          # nativer optimierter Build
./linux/run.sh                # verwendet dieselbe private ICU
./linux/run.sh --release
./release.sh --unsigned       # lokale DEB-, tar.gz- und ZIP-Pakete
./release.sh --key FULL_SIGNING_FINGERPRINT --output dist/local-release
./install.sh --package dist/local-release/packages/fastra-VERSION-linux-x86_64.tar.gz
```

`build.sh` braucht Rust gemäß `rust-toolchain.toml`, C/C++, Make, pkg-config und
GTK4 >=4.12, GtkSourceView >=5.6 sowie WebKitGTK 6 >=2.40 einschließlich ihrer
Entwicklungspakete. Fehlende Voraussetzungen werden benannt; die Skripte
installieren keine Systempakete. Zusätzliche Cargoargumente folgen nach `--`,
etwa `./build.sh -- --offline`. `--release` wird an Cargo korrekt als Option
weitergereicht. Der nativen App stehen die externen Vorschauwerkzeuge weiterhin
nur zur Verfügung, wenn die Distribution sie installiert hat; siehe F16.

Fehlt `--icu-prefix` beziehungsweise `FASTRA_ICU_PREFIX`, lädt der Build
`https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz`,
prüft SHA256 `3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0`
und baut ICU78.3 ohne Rootpräfix. Der geprüfte Präfix enthält `ICU-LICENSE`
und `ICU-SOURCE-SHA256`. Native ICU-Builds landen unter
`${FASTRA_LINUX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/fastra-linux}`.

`release.sh` beziehungsweise `linux/package.sh` braucht zusätzlich Docker.
Der vorhandene Ubuntu-24.04-Builder ist per Basisimage-Digest gepinnt. Beim
Standardweg baut er ICU innerhalb dieser glibc-2.39-Untergrenze; ein manuell
übergebener ICU-Präfix muss dieselbe ELF-Prüfung bestehen. Der Builder läuft
mit der aufrufenden UID/GID, damit Ergebnisse anschließend signierbar sind.
`FASTRA_PACKAGE_CACHE` bestimmt den separaten Cargo-/Target-/ICU-Cache.
`--skip-image-build` verwendet das bestehende `FASTRA_PACKAGE_BUILDER`-Image.
Das Image muss aus dem mitgelieferten Dockerfile stammen. Der tatsächliche
Imagehash, Rustversion und die Distributionspakete werden am Ergebnis gesichert.
Aus Quellarchiven ohne Gitmetadaten muss `SOURCE_DATE_EPOCH` vorgegeben werden.

Paketierung baut `fastra-linux`, `fastra-control` und `fastra-diff` gemeinsam. Alle drei ELF
werden auf x86_64, GLIBC-Symbole oberhalb 2.39 und RPATH/RUNPATH geprüft.
Die GTK-freien Helfer liegen unter `libexec/` neben der GUI; ihre festen
`bin/`-Launcher setzen ausschließlich für den Kindprozess die private ICU.
Alle Formate enthalten Lizenzen und `manifest.json` mit Quellidentität,
Buildnummer, Runtime-Dateihashes und relativen Symlinkzielen. TAR/DEB/ZIP
verwenden feste Metadaten aus `SOURCE_DATE_EPOCH`. `SHA256SUMS` enthält nur
relative Paketnamen. Ein vorhandener Ergebnisordner wird nie ersetzt; erst
der vollständige Erfolg macht den neuen Ordner sichtbar. Bitgleichheit über
später neu gebaute Dockerimages hinweg ist dadurch nicht behauptet.

`release.sh` verlangt entweder `--key FINGERPRINT`/`FASTRA_SIGNING_KEY` oder
bewusst `--unsigned`. Der Fingerprint muss vollständig sein und einen
vorhandenen Signierschlüssel bezeichnen. Signierung erfolgt ausschließlich
lokal außerhalb Docker; `gpg --verify` prüft die erzeugte detached Signatur
`SHA256SUMS.asc` tatsächlich. Bestehende Signaturen werden nie überschrieben.
Es gibt keine automatische Schlüsselauswahl oder -erzeugung, keinen Pass-Store,
keinen Gitpush, Tag oder Upload. Bereits erzeugte Pakete signiert
`./linux/sign.sh --key FINGERPRINT PAKETVERZEICHNIS`.

Der Benutzerinstaller akzeptiert tar.gz oder ZIP samt benachbarten
`SHA256SUMS`. `--key FINGERPRINT` verlangt zusätzlich eine gültige Signatur
von diesem Fingerprint. Er entpackt ohne ausführbaren Paketcode, prüft sämtliche
Manifestdateien/Links und installiert unter `~/.local/share/fastra/versions/`.
Ein atomarer `current`-Link wählt die Fassung; `~/.local/bin/fastra`,
`fastra-control`, `fastra-diff` und der Desktopeintrag verweisen darauf. `--prefix` unterstützt
auch Pfade mit Leerzeichen. Fehler/Signale beim Austausch stellen den alten
Link und den bisherigen Desktopeintrag wieder her. Altversionen bleiben für
eine Rücknahme erhalten. Fremde Launcher, Desktopeinträge, aktuelle Links oder
nichtleere unmarkierte Runtimeverzeichnisse werden nicht überschrieben.
Ohne `--package` wird das zuletzt erzeugte tar.gz unter `dist/*/packages/`
verwendet. `--system-deb PAKET` ist eine ausdrückliche Alternative: sie prüft
Paket und Runtimemanifest und ruft nur bei bereits als Root gestarteter
Aufruf `dpkg --install` auf. Sie startet niemals selbst sudo.

## Installierte und verschobene GUI prüfen

```bash
docker build -f tools/linux-package/Dockerfile.smoke \
  -t fastra-linux-package-smoke:local tools/linux-package
mkdir -p "$work/evidence"
docker run --rm --network none \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  --security-opt apparmor=unconfined \
  -v "$work/result/packages:/packages:ro" \
  -v "$repo/tools/linux-package:/tools:ro" -v "$work/evidence:/evidence" \
  -e FASTRA_DISPOSABLE_CONTAINER=1 -e FASTRA_SMOKE_EVIDENCE=/evidence \
  fastra-linux-package-smoke:local bash /tools/smoke.sh \
  /packages/fastra_1.158.0_amd64.deb /packages/fastra-1.158.0-linux-x86_64.tar.gz
```

Die beiden äußeren Docker-Ausnahmen erlauben verschachtelte User-/PID-
Namespaces und einen privaten Proc-Mount für WebKits eigene Sandbox. Ohne
sie blockiert Docker diesen Aufbau. Es werden weder `--privileged` noch
zusätzliche Capabilities verwendet und WebKits Sandbox wird nicht abgeschaltet.
Der Test läuft als eigener unprivilegierter Benutzer. Er verlangt im
WebKit-Webprozess `NoNewPrivs=1`, `Seccomp=2` und einen verschachtelten PID-
Namespace. Das App-Netzwerk ist vollständig abgeschaltet.

Der Test installiert das Debian-Paket, prüft sämtliche Runtime-Dateihashes,
die Auflösung der drei privaten ICU-Bibliotheken und startet den echten
installierten `/usr/bin/fastra` sowie das zufällig verschobene Archiv in
getrennten privaten Xvfb-/DBus-Sitzungen. Er aktiviert die tatsächliche
Markdown-Checkbox und sichert Fensterbilder für Überschrift, KaTeX,
Mermaid und Tabelle. Die Bilder müssen auf tatsächliche Darstellung geprüft
werden; das bloße Vorhandensein eines WebKit-Prozesses belegt keine korrekte
DOM-Darstellung. Die getestete Checkbox-Position gehört zu 1.158.0 bei
1400 × 900; nach Layoutänderungen anhand der Vorher-Aufnahme kontrollieren
und nötigenfalls `FASTRA_SMOKE_MARKDOWN_POINT="x y"` anpassen.

Für Arch/CachyOS liegen Archiv und ausgefüllter `PKGBUILD` gemeinsam im
Paketordner. `makepkg` erzeugt daraus das Paket ohne Installation. `!strip`
und `!debug` bewahren die Runtime-Hashes. Die Repo-Vorlage akzeptiert keinen
Platzhalter-Hash; `package.sh` setzt den konkreten SHA256. Vor öffentlicher
Verteilung bleiben die normale Produkt- und Veröffentlichungsprüfung nötig.

## Belegter Snapshot, 2026-11-05

Die geprüfte Anwendung hat Version 1.158.0, native Buildnummer 366 und
Quell-SHA256
`f709b775480f214194cca1c2fe561ed99559b900fb5a8860e74ab01b4a506ca8`.
`SOURCE_DATE_EPOCH` war `1793827545`.

- Der tatsächliche Ubuntu-24.04-WebKit-Releasebuild bestand. Ein unabhängiger
  Neuaufbau in einem leeren Rust-Targetordner erzeugte dasselbe Binary:
  `e83f7e59677a39db95f60a5b9501746a3a8df492b0fcd086f7fa356480e03582`.
- Staging und Paketierung dieses unabhängigen Neubaus ergaben identische
  Debian- und Tar-Archive. Debian-SHA256:
  `1b095e0b00de6d53a1eb093d5fd5b98157923d7e2e477d6fff41fcbaf9f0e946`;
  Tar-SHA256: `66fb56ea647a9bb36d34bc3a6c38140d7873becae99e5b3837e6e5b98555772f`.
- Das Debian-Paket ließ sich im Runtime-Container installieren. Installierte
  und verschobene GUI zeigten offline die tatsächliche Markdown-Überschrift,
  KaTeX-Formel, das Mermaid-Diagramm und die Tabelle. Die eigenen Bibliotheken
  wurden relativ geladen; die aktive innere WebKit-Sandbox wurde gemessen.
- Der erzeugte Arch-PKGBUILD bestand `makepkg --nodeps`; alle 366 regulären
  Runtime-Dateihashes blieben nach dem Auspacken erhalten. Eine native
  Paketinstallation und Desktop-Abnahme auf CachyOS ist damit nicht belegt.

Der Beleg gilt für genau diesen eingefrorenen Quellsatz. Er behauptet weder
zwei unabhängige ICU-Neubauten noch eine vollständige Produktabnahme oder
die Prüfung nachfolgender Änderungen. Ein abweichender Commit-/Quellsnapshot
braucht einen neuen Paket- und Laufzeittest.

### Gezielter Checkpoint-Neubau

Commit `f5fdc6268a5b07137fb35d522982d69068b5917c` wurde anschließend separat
archiviert und vollständig neu paketiert: Version 1.158.0, Build 366,
`SOURCE_DATE_EPOCH=1793834606`, Quell-SHA256
`6ccbc5ebafc1e58f71aecc567e7b69ee6097cdc0c98c4a6e5495aa90f1d52739`.
Sein Debian-Paket hat SHA256
`e57f86c021aeaf29773d1b4d1283f1f38dfda414d1193182f3e8d7b564b49c57`,
sein Tar-Archiv
`7d1d6cf042d743d9a748831119cdb55f1d17e4119333e15d9fbce3be971aa21d`.
Der Arch-Paketbau bestand ebenfalls und bewahrte alle 366 Runtime-Dateihashes.

Installierte und verschobene Checkpoint-GUI bestanden denselben Offline-
Markdown-/Sandbox-Test; die Aufnahmen wurden geprüft. Der im Checkpoint auf
zwei Reihen umgebrochene Haupttoolbar verschiebt die Markdown-Checkbox nach
`FASTRA_SMOKE_MARKDOWN_POINT="969 235"`; diese Position wurde anhand der
Vorher-Aufnahme bestimmt. Der unabhängige Clean-Target-Vergleich weiter oben
bezieht sich auf den vorherigen eingefrorenen Quellsatz.


## Decoder- und Rich-Vorbereitung nach dem Checkpoint

Die Vorbereitung für den nächsten integrierten Commit enthält die oben genannten
Decoder-Pakete und Turndown 7.2.0 im JS-Inventar. Das eingebettete Turndown ist
bytegleich zu `package/dist/turndown.js` aus dem integritätsgepinnten npm-Archiv
(SHA256 `ae3605eb07ab920a2d181008ace692ec560fa6cd67d2e291f77cbc5c4322cd38`).
Seine vollständige MIT-Lizenz ist enthalten. Das Node-Paket
`@mixmark-io/domino` wird laut upstream Browser-Mapping nicht in diesem
Browser-Asset verteilt. Alle 145 Lizenzpakete, Asset- und Lizenzhashes wurden
geprüft. Shellsyntax und Arch-Abhängigkeitsmetadaten wurden geprüft.

Mit Ubuntu 24.04 wurden Bubblewrap 0.9.0, ImageMagick 6.9.12-98 Q16,
librsvg 2.58.0, Poppler 24.02.0 und util-linux 2.39.3 tatsächlich ausgeführt.
Dabei fiel ein notwendiger Viewer-Fix auf: der Farbname `white` lädt bei
ImageMagick 6 `colors.xml`, die absichtlich außerhalb der Sandbox bleibt.
`-background #ffffff` löst dieselbe Farbe direkt auf. Warnungsprüfung und
Mountfreigaben bleiben unverändert. Die
[ImageMagick-Farbdokumentation](https://imagemagick.org/color/) beschreibt
diesen Unterschied.

Der gesondert geprüfte Viewer hatte nach dieser Ein-Zeilen-Korrektur SHA256
`7d66b49f5b942c470d1f183cd36044c5e42830d8f90ea8250c963798657a94a4`.
Der bestehende native Regressionstest bestand mit echten PNG/JPEG/GIF/WebP-,
SVG- und zweiseitigen PDF-Decodern, Quellvergleich, `NoNewPrivs`, verweigertem
Hostdateizugriff, Abbruch und Austausch gleicher Bytes. Echte GTK-Läufe bei
760 Pixel/Deutsch/hell und 1600 Pixel/Englisch/dunkel bestanden und wurden
visuell geprüft. Fehlendes librsvg, fehlendes Bubblewrap und verweigerte
Benutzernamensräume zeigten jeweils einen sichtbaren Fehler, unveränderte
Quellbytes und keinen unsicheren Editor- oder Decoder-Rückfall.

Diese Belege prüfen die Decoder-Vorbereitung und den beschriebenen isolierten
Viewerstand. Neue Debian-/Tar-/Arch-Artefakte werden erst gegen den nächsten
benannten integrierten Commit erzeugt; die Checkpoint-Pakete oben bleiben
unverändert diesem älteren Quellstand zugeordnet.

Ein zusätzlicher funktionaler Versuch lief auf einem privaten Weston 13.0.0 mit
Headless-Backend und Pixman, ohne X11-Display, Hostinstallation oder Änderung von
Systemrichtlinien. Der Viewer-Selbsttest und echte WebKit-Rich-Bearbeitung mit
Formatierung, Undo/Redo, Tabelle, Save/Close und frischem Prozess-Reopen
bestanden. Beim tatsächlichen Wayland-WebKit-Prozess wurden verschachtelte
PID-Namensräume, `NoNewPrivs: 1` und `Seccomp: 2` erfasst. Die Rendering-Fallback-
und fehlenden Cursorfont-Warnungen der minimalen Testumgebung wurden nicht als
Produktfehler gewertet; die genannten Funktionsprüfungen waren erfolgreich.
Dieser fensterlose Versuch ersetzt ausdrücklich keine visuelle Desktop-,
Drucker-, Eingabemethoden- oder Hardware-Abnahme.

Der getrennte [Paketbeleg für den benannten Stand 1.159.0](F16-1.159.0-EVIDENCE.md)
prüft reproduzierte Artefakte, reale Installation, Relocation, WebKit-Sandbox und
Viewerpfade. Er ist keine Freigabe späterer Quellstände.

Der exakte Stand 1.160.0 ist zusätzlich mit installierter DEB und zufällig
relokiertem Tar geprüft: [Artefakt- und Laufbeleg](F16-1.160.0-EVIDENCE.md).
Die erneute Paketierung derselben Stage ist bytegleich; dieser Nachweis
behauptet keinen unabhängigen Rust-Neubau und keine Arch-Installation.

Der [Paketnachweis 1.161.0](F16-1.161.0-EVIDENCE.md) ergänzt die tatsächlich
gebündelte 4D-Grammatik und Hexansicht. Der PDF-Lauf wartet auf eine fertige
Ansicht; eine frühe leere Aufnahme ist ausdrücklich kein Erfolgsbeleg.

Der geprüfte Stand 1.168.0 einschließlich ZIP, CLI und Benutzerinstaller ist im
[zugehörigen Paketbeleg](F16-1.168.0-EVIDENCE.md) festgehalten.


Der [externe Linux-Vergleichshelfer](../EXTERNAL-DIFF.md#linux) besitzt einen eigenen
isolierten Prüfeinstieg `linux/external-diff-test.sh BINARY_DIRECTORY NEW_OUTPUT`.
Ältere Laufzeitmanifeste mit zwei Executables bleiben zulässig. Neue Pakete ab
1.182.0 müssen auch den Diff-Helfer enthalten; ein Rückwechsel entfernt nur dessen
eigenen Launcher und stellt ihn bei einem Fehler wieder her.
