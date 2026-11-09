# Optionaler nativer Linux-Kandidat

Dieser getrennte Ablauf ergänzt einen bereits verifizierten Fastra-App-Stage um
GTK/Pango/GtkSourceView/WebKit und deren festgehaltene Ubuntu-Laufzeit. Er ändert
die normale Systempaketierung nicht. `bin/fastra` startet weiterhin den bisherigen
Systempfad; ausschließlich `bin/fastra-native` wählt den privaten Kandidaten.
Die normalen System-CLIs bleiben über `bin/fastra-control` und `bin/fastra-diff`
erreichbar. Die getrennten `bin/fastra-control-native` und `bin/fastra-diff-native`
weisen geerbte GUI-Runtime-, Shadow- oder Hostkanalmarker vor jedem Prozessstart
ab. Nur aus der ursprünglichen Hostumgebung setzen sie den internen
Servicezielmarker und starten das CLI mit dem
Host-ELFloader plus App-ICU-Suchpfad, ohne globale LD-Exporte. Ihr Coldstart darf
nur den verpackten nativen Launcher verwenden; `argv[0]` und Paketmanifest werden
dafür validiert. Der GUI-Launcher entfernt den Servicezielmarker vor dem Broker.

Der äußere Broker und die Host-CLIs verlangen die festgehaltene x86_64-/GLIBC-2.39-
Untergrenze; die private GUI-glibc senkt diese Hostanforderung nicht.

Es gibt hier keinen Systeminstaller, automatischen Download beim Appstart,
Versions-Bump, Signierlauf oder Upload.

## Gepinnte Pangoquelle bauen

```sh
SOURCE_DATE_EPOCH=1793955600 tools/linux-native/build-pango.sh NEW_BUILD_DIRECTORY
```

Der Build verlangt exakt das OCI-Image aus `pango-source.lock.json`. Ein anderes
Image oder ein ersatzweise aufgelöstes Tag wird nicht verwendet. Die Datei hält
Ubuntu 24.04, Pango `1.52.1+ds-1build1`, InRelease, Sources.xz, alle drei
Quellarchive, die vollständige Distributionspatchserie und beide eigenen Patches
per SHA256 fest. `fetch-pango.py` prüft die Ubuntu-Archivsignatur und die gesamte
Hashkette. Die zusätzliche Maintainersignatur der DSC-Datei ist nicht die
Vertrauensgrundlage. Nach `dpkg-source` müssen alle Distributionspatches tatsächlich
angewandt sein. Jeder eigene Patch wird ohne Fuzz angewandt und unmittelbar am
Quelltext geprüft. Der Build prüft anschließend den nativen Capability-Rückgabewert
`0x46570002` und verbietet RPATH/RUNPATH.

`SOURCE-BUILD.json` bindet Image, Source-Lock, eigene Patches und die drei
Bibliotheken. `builder-packages.tsv` hält die tatsächlichen Compiler- und
Buildpaketversionen fest. Das eingefrorene Image ist ein notwendiger Buildinput;
Bitgleichheit mit künftig neu gebauten Dockerimages wird nicht behauptet.

`build-gtk.sh AUTHENTICATED_UBUNTU_SOURCE_CACHE NEW_OUTPUT_DIRECTORY` baut die
bereits anhand signierter Paketindizes geprüfte GTK-Quelle `4.14.5+ds-0ubuntu0.10` neu. Der zugehörige
`gtk-source.lock.json` verlangt alle 30 Distributionspatches, den exakten
Eigenpatch und Vorher-/Nachher-Quellhash sowie die festgehaltenen zusätzlichen
Buildpakete. Der Sourcecache wird nur gelesen; Hostpakete werden nicht installiert.

## Rohbaum normalisieren

`collect-runtime.sh VERIFIED_GTK_BUILD_PREFIX NEW_DIRECTORY` rekonstruiert den Rohbaum aus exakt dem
installierten OCI-Snapshot in `runtime-input.lock.json`, offline ohne APT-Update
oder Tagfallback. Der Collector verlangt dieselben 278 Paketversionen und übernimmt
nur deren Dateien, erforderliche Konfigurationen und generierte Moduldaten. Er
ändert keine Hostpakete. Der geprüfte GTK-Rebuild ist verpflichtender Input und wird sofort hashgebunden
übernommen; Pango und die restliche Normalisierung folgen anschließend. Der Lock hält auch den ursprünglichen
Rohmanifesthash als Vergleichsbeleg fest; eine identische Ausgabedatei nach
unterschiedlicher Cacheerzeugung wird nicht behauptet.

Das eingefrorene OCI-Image bleibt notwendiger Rohinput. Der Lock ist kein
vollständiges Offline-Quellarchiv aller unveränderten Distributionspakete. Die
Paket-/Sourceversionen und Copyrighttexte dokumentieren deren Herkunft; vor einer
Weitergabe muss der passende vollständige Quellzugang für die konkrete Closure
zusätzlich gesichert werden.

Zuerst `collect-copyrights.py` innerhalb genau des identifizierten
Ubuntu-Paketbuilders gegen den unveränderten Rohmanifest ausführen. Es verlangt
übereinstimmende Paketversionen und materialisiert jeden vollständigen
Copyrighttext unabhängig von Debian-Doc-Verzeichnisaliases.

```sh
python3 tools/linux-native/normalize.py \
  --raw RAW_RUNTIME --copyrights VERIFIED_COPYRIGHT_DIRECTORY \
  --pango-prefix NEW_BUILD_DIRECTORY/pango-install \
  --pango-source-lock tools/linux-native/pango-source.lock.json \
  --patchelf PRIVATE_VERIFIED_PATCHELF --gtk-prefix NEW_GTK_BUILD/gtk-install \
  --output NEW_NATIVE_STAGE
python3 tools/linux-native/verify.py --runtime NEW_NATIVE_STAGE
```

Der Rohbaum muss vollständig zu seinem Manifest passen. Zulässig sind nur
reguläre Dateien, Verzeichnisse und Links. SUID/SGID/Sticky-Dateibits werden
entfernt und protokolliert. Absolute Links werden nur dann in interne relative
Links überführt, wenn ihr gesamter Zielpfad innerhalb des virtuellen Paketroots
existiert. Die Auflösung greift niemals auf zufällige Hostdateien unter `/usr`
oder `/etc` zu. Ausbrechende oder zyklische Links schlagen fehl.

Bekannte unvollständige, rein informative Doc-/Icon-/Coreutils-Localealiases und
der nicht mitgelieferte SSL-Privatschlüsselordner werden einzeln mit Grund
protokolliert und ausgelassen. Andere dangling Links werden nicht übergangen.
Alle 278 Copyrighttexte bleiben unabhängig davon vollständig enthalten. Der
Pango-Buildreceipt muss zum Source-Lock und zu den tatsächlich übernommenen
ELF-Dateien passen. Das neue Manifest bindet Dateien, relative Links,
Dateimodi, Paket-/Sourceversionen und jede Normalisierung.

`python3 tools/linux-native/fetch-patchelf.py --output NEW_TOOL_DIRECTORY`
holt und entpackt das in `patchelf.lock.json` gebundene Ubuntu-Werkzeug privat.
`NEW_TOOL_DIRECTORY/usr/bin/patchelf` ist der Normalisierungsparameter.
Dieses patchelf
normalisiert ausschließlich dynamische ELF-Suchpfade. Absolute interne
Distributions-RUNPATHs werden zu passenden `$ORIGIN`-Pfaden, die unbenutzte
fehlende LLVM-Suchdirectory wird ausdrücklich entfernt. Andere fehlende oder
ausbrechende Suchpfade schlagen fehl. Vorher-/Nachher-ELFhashes und sämtliche
verbleibenden internen Suchpfade stehen im Manifest; keine Hostinstallation.

## Separaten Paketbaum erzeugen

```sh
linux/native-package.sh \
  --app-stage VERIFIED_STANDARD_APP_STAGE --runtime-stage NEW_NATIVE_STAGE \
  --host-broker PATH/fastra-runtime-host \
  --git-helper PATH/fastra-git-commit-hook \
  --four-d-worker PATH/fastra-4d-worker \
  --host-proof REVIEWED_HOST_ELF_PROOF.json \
  --epoch 1793955600 --output NEW_PACKAGE_DIRECTORY \
  --archive NEW_ARCHIVE_OUTSIDE_PACKAGE.tar.gz
python3 tools/linux-native/verify.py --package NEW_PACKAGE_DIRECTORY
```

Das sind drei verpflichtende, geprüfte GTK-/ICU-freie Helfer neben der GUI. Ein
fehlender Helfer, unpassender ELF-Proof, RPATH, höhere ISA-/GLIBC-Anforderung oder
GUI-/ICU-Abhängigkeit schlägt fehl. Es gibt keinen Rückfall auf das GUI-ELF als
Host- oder 4D-Helfer. Der normale App-Stage wird mit seinem bestehenden
Paketverifier geprüft; `--app-verifier` kann dessen genaue Datei angeben.

Der neue Baum enthält `app/`, `runtime/`, die beiden Launcher und einen
vollständigen `native-package.json`. Die App-Lizenzsammlung einschließlich ICU,
Rust und JavaScript bleibt erhalten. Eine benachbarte `.sha256`-Datei enthält den relativen Archivnamen; das Archiv
wird erst nach vollständigem Schreiben sichtbar. Das TAR.GZ ist ein verifizierbarer portabler
Kandidat mit ausführbarem Launcher; es wird nicht als DEB oder als Eingabe des
bestehenden Systeminstallers ausgegeben. Nach dem Entpacken erneut prüfen und
`bin/fastra-native` ausdrücklich wählen. Der Kandidat wird in einem neuen
Verzeichnis erstellt; vorhandene Ergebnisse werden nicht ersetzt.

## Start, Relokation und Dateigrenze

Der äußere `fastra-runtime-host` startet vor allen privaten GTK-/GIO-/ICU-/Loader-
Exports. Sein Kind startet den schmalen Namespace-Entry mit der verpackten GUI.
AF_UNIX-Stream FD3 und `FASTRA_INTERNAL_HOST_FD=3` bleiben bis zur GUI erhalten;
es gibt keinen Dateisocket, öffentlichen Port oder `--preserve-fds`-Ersatz.

Der normale Hostbaum bleibt sichtbar. Gezielt überlagert werden ausschließlich
ELF-Loader, WebKit-Helferverzeichnis, Bubblewrap und D-Bus-Proxy. Alle Mountziele
müssen bereits existieren; es werden keine Hostverzeichnisse angelegt. Fehlende
Layouts, insbesondere ein fehlendes Ubuntu-WebKit-Helferziel auf einer anderen
Distribution, werden klar abgewiesen. Das ist keine vollständige Hostdateiparität.

Das Entry setzt ausschließlich im optionalen GUI-Kind:

- `FASTRA_NATIVE_RUNTIME=1`;
- `FASTRA_NATIVE_SHADOW_MANIFEST` auf eine absolute, atomar geschriebene Datei im
  benutzereigenen Cache mit Modus 0700;
- JSON `format: 1`, `scope: "known-runtime-shadow-paths"` und genau vier
  `shadowed_paths` mit `path`, tatsächlich vor dem Namespace aufgelöstem
  `canonical_target` und `kind: "file" | "directory"`.

Die GUI muss diesen Vertrag vor dem Start validieren. Fehlende oder fehlerhafte
Policy im optionalen Modus darf nicht als Systemmodus weiterlaufen. Dokument-I/O
muss sowohl Aliaspfad als auch kanonisches Ziel sperren, bei Verzeichnissen den
Unterbaum. Das Paketmanifest dokumentiert die bekannten Bindstellen; die
konkreten kanonischen Hostziele werden erst beim Start gebunden.

Pixbuf-Pfade werden für den aktuellen Präfix neu geschrieben. GStreamer erhält
eine eigene Registry pro kanonischem Präfix, private Plugin-/Scannerpfade und
keine geerbten versionsspezifischen Host-Pluginpfade. GIO-Module und kompilierte
Schemas sowie GTK-Modulsuchpfade zeigen in den privaten Baum. Der ursprüngliche
Fontconfig-/Hostfontzugang bleibt erhalten. Leerzeichen und tatsächlicher Umzug
werden im isolierten nativen Gate geprüft; Doppelpunkt oder Steuerzeichen im
Runtimepräfix ist kein unterstützter `LD_LIBRARY_PATH`-Pfad.

## Prüfgrenze

`test-normalization.py` prüft Linkausbruch, absolute Hostlinks, Loops,
Privilegienbits, Umzug, FIFOs und unklassifizierte dangling Links.
`probe.c` ist eine ausschließlich private native Komponentenprobe für
Capability, Source-Ressourcen, Pixbuf, GStreamer und tatsächlich ausgeführtes
WebKit-JavaScript. Sie verlangt den Broker und synthetische Hostfixtures in
einem Wegwerfcontainer; sie ist kein Produktprogramm. Die GStreamer-Abfragen
verwenden die öffentlichen APIs aus den
[offiziellen Headern](https://github.com/GStreamer/gstreamer/blob/1.24.2/subprojects/gstreamer/gst/gstpluginfeature.h).

Software-X11/Xvfb und ein belegter WebKit-Sandboxzustand ersetzen keine native
Hardware-, Hostfont-, Wayland-, CachyOS- oder IME-Abnahme. Die reale externe
4D-Engine bleibt ohne passende lokale Engine ebenfalls ungeprüft. Es wird keine
WebKit-Sandbox deaktiviert. Laufende Wartung der gepinnten Distributionsquellen,
Patches und vollständigen Lizenz-/Paketclosure bleibt erforderlich.

## Getrennte Runtime v2: native Editpläne und History

Die zusätzliche, ausdrücklich gewählte v2 übernimmt nur zwei neue Bibliotheken
in einen neuen Baum. Alle bisherigen Systempakete, Pango und die restlichen
278 Paket-/Copyrightzuordnungen bleiben erhalten. Die alte Runtime wird weder
umgeschrieben noch als neue Fassung ausgegeben.

`sourceview-source.lock.json` bindet Ubuntu-Noble-Source
`gtksourceview5 5.12.0-1build1` über dieselbe archivsignierte Hashkette wie Pango,
alle drei Archive, die leere Distributionspatchserie und die drei exakten
Ausgangs-/Zieldateihashes. Der offizielle Upstream-Tag allein ist kein Ersatz.

```sh
# Im gepinnten eigenen Builder mit Ubuntu-Archivkeyring:
python3 tools/linux-native/fetch-sourceview.py \
  --lock tools/linux-native/sourceview-source.lock.json --output NEW_SOURCE_CACHE
SOURCE_DATE_EPOCH=1793955600 tools/linux-native/build-native-v2.sh \
  AUTHENTICATED_GTK_SOURCE_CACHE NEW_SOURCE_CACHE NEW_BUILD_DIRECTORY
python3 tools/linux-native/upgrade-runtime-v2.py \
  --runtime-v1 VERIFIED_V4_RUNTIME \
  --gtk-prefix NEW_BUILD_DIRECTORY/gtk-install \
  --sourceview-prefix NEW_BUILD_DIRECTORY/sourceview-install \
  --output NEW_NATIVE_V2_RUNTIME
python3 tools/linux-native/verify.py --runtime NEW_NATIVE_V2_RUNTIME
```

Der Build läuft offline im exakt gepinnten nativen Builderimage. Er extrahiert
beide Distributionsquellen neu und prüft alle 30 GTK-Distributionspatches. Danach
folgen unverändert Phase 5, Delete-v1 und zuletzt der separate Historypatch;
GtkSourceView erhält ausschließlich sein gebundenes Delete-/Join-Delta. Sämtliche
sechs Ausgangsdateien und History müssen exakt passen, die Patches greifen ohne
Fuzz und die sieben Zielhashes werden sofort geprüft. Beide Bibliotheken werden
vollständig aus den Quellen gebaut; alte Buildobjekte sind kein Eingabeparameter.
Die Buildprefixes enthalten ihre SONAME-Links für tatsächlich eigene Testläufe.

Der Upgrader verlangt exakt den versiegelten V4-Manifesthash. Er ändert nur GTK
und GtkSourceView und fügt nachvollziehbare Quell-/Build-/Patchbelege hinzu. Die
vollständigen SourceView-Copyright-/COPYING-Texte werden zusätzlich eingebunden;
der originale Debian-Copyrighttext bleibt zur vorhandenen Paketlizenz bytegleich.
Der Verifier prüft beide Bibliotheks-/Receipt-/Source-Lock-Bindungen gemeinsam.
Ein einzelnes neues GTK bei Stock-SourceView ist kein nutzbarer nativer Editpfad.
Die Anwendung muss Signaltyp, Budgetproperty und SourceView-Plan-Magic zusätzlich
vor Dokumenten prüfen; diese Werkzeuge ersetzen das Startupgate nicht.

Der neue enge Vertrag betrifft Delete/Backspace/Join ohne aktive Komposition und
den nachgewiesenen GTK-Historyfehler nach Redo. Er ist keine allgemeine
Textbuffer-Transaktion und keine vollständige IME-, Return-, Autoindent-,
Cut-/Paste- oder AT-SPI-Freigabe. Spätere Prototypen gehören erst nach einem eigenen
unveränderlichen Handoff in eine weitere Runtimefassung. Ein gepinnter Snapshot
ersetzt weiterhin keine laufende Prüfung der Ubuntu-/WebKit-Sicherheitsupdates.

## Getrennte Runtime v3: eingebauter Default-Return

`sourceview-native-v3.lock.json` ergänzt die unveränderte authentifizierte
SourceView-Distrobasis um Delete-v1 und den eingefrorenen Return-v1-Patch.
Er betrifft ausschließlich `gtksourceview.c`; der eingebaute Indenter und die
übrigen Ausgangs-/Zieldateien müssen bytegenau passen. GTK bleibt exakt das
korrigierte History2-Artefakt; es wird für diese Stufe weder geändert noch neu
verlinkt.

```sh
SOURCE_DATE_EPOCH=1793955600 tools/linux-native/build-sourceview-v3.sh \
  AUTHENTICATED_SOURCEVIEW_SOURCE_CACHE NEW_BUILD_DIRECTORY
python3 tools/linux-native/upgrade-runtime-v3.py \
  --runtime-v2 VERIFIED_CORRECTED_HISTORY2_RUNTIME \
  --sourceview-prefix NEW_BUILD_DIRECTORY/sourceview-install \
  --output NEW_NATIVE_V3_RUNTIME
python3 tools/linux-native/verify.py --runtime NEW_NATIVE_V3_RUNTIME
```

Der neue Upgrader akzeptiert ausschließlich den gebundenen korrigierten
History2-Manifeststand, ersetzt allein SourceView und fügt seine Provenienz hinzu.
Die Verifierkette bleibt auch für die bisherigen Runtimefassungen gültig. Die
Anwendung muss gleichzeitig die native readonly UInt-Capability `RTN1` auf
GtkSourceView und ihre eigene readonly BOOL-Policy auf der Fastra-View prüfen
und den vorhandenen Planconsumer binden. Ohne diese gekoppelte App-Policy
aktiviert die Bibliothek allein keinen neuen Returnvertrag.

Die engere Planung gilt nur für den eingebauten Default-Indenter nach einem
nicht verbrauchten, hinsichtlich Buffer/Epoche unveränderten IM-Filterpfad.
Grid bleibt bei FALSE-Policy in seiner bisherigen Route. Komposition/IME,
Custom-Indenter, Tab/Snippet, Clipboard und AT-SPI erhalten dadurch keine
allgemeine Transaktionsgarantie. Systempakete bleiben der Standard.

## Getrennte Runtime v4: gültige Iterator-Bytewerte beim ersten Zugriff

`gtk-native-v4.lock.json` ergänzt die unveränderte GTK-Distro-/Phase5-/Delete-/
History2-Basis um den eingefrorenen Metadata-v1-Patch. Der Getter erneuert seinen
Indexsegmentcache, bevor er dessen Byteoffset liest. Ein zusätzlicher zweiter
Getteraufruf oder eine Zählerneuberechnung im Appcode ist kein Ersatz. Die zweite
Dateiänderung bindet die private readonly UInt-Kennung `ITR1` an GtkTextBuffer.
Die zwei Ausgangs-/Zieldateien werden exakt geprüft, kein Fuzz.

```sh
SOURCE_DATE_EPOCH=1793955600 tools/linux-native/build-gtk-v4.sh \
  AUTHENTICATED_GTK_SOURCE_CACHE NEW_BUILD_DIRECTORY
python3 tools/linux-native/upgrade-runtime-v4.py \
  --runtime-v3 VERIFIED_RETURN1_RUNTIME \
  --gtk-prefix NEW_BUILD_DIRECTORY/gtk-install --output NEW_NATIVE_V4_RUNTIME
python3 tools/linux-native/verify.py --runtime NEW_NATIVE_V4_RUNTIME
```

Der frische vollständige GTK-Build behält alle 30 Distributionspatches und alle
vorherigen privaten Fixes. SourceView wird weder geändert noch neu gebaut. Der
neue Upgrader akzeptiert ausschließlich den gebundenen V3-Manifeststand, ersetzt
nur GTK und fügt dessen neue Provenienz hinzu. Die Verifierkette validiert auch
die älteren Stufen weiter. Die Anwendung muss vor Dokumenten zusätzlich zu den alten
Native-/Return-Grenzen Owner GtkTextBuffer, UInt/readonly und tatsächliches ITR1
prüfen; die GTK-Versionsnummer ist kein Ersatz für diese Bindung. Systempakete
bleiben der Standard, bestehende Transaktions-/IME-/Hardwaregrenzen bleiben.
