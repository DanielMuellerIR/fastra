# F01: vorbereiteter privater Toolkitpfad

Stand 2026-11-06. Die ursprüngliche Machbarkeit ist inzwischen als separater,
optional wählbarer Paketkandidat integriert. Systembibliotheken bleiben der
Standard. Der [gebundene Stand 1.187.0](F16-1.187.0-EVIDENCE.md) und die
[Paketwerkzeuge](../../tools/linux-native/README.md) dokumentieren die tatsächliche
Integration. Die folgenden ursprünglichen Voraussetzungen bleiben als
Abnahmevertrag erhalten; insbesondere ist die allgemeine IME-Garantie offen.

## Nachgewiesener Umfang

Der erste unprivilegierte Mountnamespace stellte einen konsistenten privaten
Ubuntu-24.04-Laufzeitbaum als `/usr` bereit. Diese vollständige Überlagerung ist
kein geeigneter Produktpfad: Ein Dokument unter demselben `/usr`-Pfad kann dort
andere Bytes als bei Host-Git besitzen. Der folgende schmale Kandidat behält
deshalb den Host-Dateibaum und bindet nur den privaten ELF-Loader sowie die
benötigten WebKit-/Sandbox-Helfer an ihre festgelegten internen Pfade. GTK 4.14.5 aus dem authentifizierten
Quellpaket `4.14.5+ds-0ubuntu0.10` enthält alle 30 Distributionspatches und den
[neuen Commit-Vorprüfungspunkt](F01-NATIVE-BOUNDARIES.md). Pango 1.52.1 enthält
den dort beschriebenen Tab-Wrap-Patch. Beide sind zusammen mit GtkSourceView
5.12 und WebKitGTK 2.52.6 gebaut und ausgeführt.

Die sechs nativen Commitgegenfälle bestehen auch auf dieser Distributionsbasis.
WebKit führt JavaScript aus; NoNewPrivs 1, Seccomp 2 und privater PID-Namespace
belegen seine weiter aktive innere Sandbox. Der äußere Namespace isoliert die
Bibliotheksauflösung, nicht die Dateien des Nutzers. Er ist keine zusätzlich
behauptete Sicherheitsgrenze. Sieben zentrale ELF-Dateien bestehen den Linkaudit
ohne fehlende oder undefinierte Symbole. SourceView findet 176 Sprachdefinitionen;
PNG-/JPEG-Module werden geladen.

Die drei Quellarchive stimmen mit den authentifizierten APT-Quellmetadaten
überein; vier InRelease-Dateien wurden mit dem Ubuntu-Archivschlüssel geprüft.
Patchserie, eigener Hook, Binärdateien, Paketclosure, Symlinkziele und kleine
Laufbelege sind separat mit Hashmanifest versiegelt.

Der Kandidat umfasst 278 installierte Pakete. Allein der Laufzeitbaum benötigt
566.036.188 Bytes scheinbare Dateigröße (539,81 MiB), 618.864.640 Bytes
zugeordnete Blöcke (590,20 MiB) und 209.585.529 Bytes als tatsächlich gemessener
gzip-1-Stream (199,88 MiB). Fastra und sein ICU-78-Paket kommen hinzu. Dieses
Messarchiv ist kein freigegebenes Installationspaket: Distributionssymlinks und
privilegierte Dateimodi benötigen zuerst eine gezielte Normalisierung.

## Konkrete nächste Produktentscheidung

| Variante | Ergebnis und noch nötige Arbeit |
| --- | --- |
| Systempakete allein | Bestehende kleine Pakete bleiben unverändert; eigene GTK/Pango-Eingriffe und die davon abhängigen Merkmale bleiben Prototypen. |
| Separater optionaler Laufzeitkandidat | Empfohlener nächster Integrationsschritt. Systempakete bleiben Standard. Private glibc und Toolkitclosure werden ausdrücklich übernommen; Hostwerkzeuge, Grafik und Updates brauchen die untenstehenden Gates. |
| Privater Pfad als Standard | Erst nach derselben Integration und zusätzlicher Distributions-/Hardware-/IME-Abnahme sinnvoll. Aus dem jetzigen Machbarkeitsbeleg nicht ableitbar. |

Die Vorbereitung ist abgeschlossen. Der separate optionale Kandidat ist als
nächster Integrationspfad entschieden; Systempakete bleiben Standard. Zuerst
wird die Hostwerkzeuganbindung mit dem vorhandenen Prozessrunner geprüft.
Die Aktivierung und Auslieferung setzen weiterhin die folgenden Gates voraus;
eine Umstellung des Standardpfads ist nicht entschieden.

## Voraussetzungen für eine tatsächliche Integration

1. **Hostwerkzeuge bleiben Hostwerkzeuge.** Das private `/usr` darf Git, SSH,
   PMT, Pandoc und tool4d nicht auf andere Werkzeuge oder Credentials umlenken.
   Ein GTK-freier Launcher vor dem Namespace und ein privates geerbtes
   Socketpaar verwenden im geprüften Kandidaten den vorhandenen
   `fastra-process`-Runner.
   Getrennte argv-Bytes, cwd, begrenzte Environment-Deltas, Ausgabegrenzen,
   Frist, Cancel und Prozessgruppen müssen erhalten bleiben. Kein Shell-Eval,
   öffentlicher Dienst oder Credential-Logging. Interne gebündelte Helfer
   benötigen eine andere explizite Ausführungsdomäne als Hostprogramme.
   Die schmale Mountgegenprobe erhält die Bytes zweier Hostdateien unter
   `/usr/local` und `/usr/share`. Daraus folgt keine allgemeine
   Dateiidentitätsgarantie: Die gezielt überlagerten internen Pfade müssen für
   Dokumentzugriffe ausgeschlossen oder identisch aufgelöst werden. Fehlende
   Mountziele dürfen keine Verzeichnisse im Host-Dateibaum erzeugen; nicht
   unterstützte Layouts müssen vor dem Start mit einer Erklärung abbrechen.
2. **Grafik ist ein eigener Vertrag.** Xvfb-/Softwarebelege prüfen weder
   proprietäre Treiber noch die tatsächliche Wayland-/Mesa-Paarung. Ein
   definierter Driverimport oder gepflegter Extensionmechanismus muss diese
   ABI-Grenze schließen; beliebige Hostbibliotheken dürfen nicht blind in den
   privaten Baum gemischt werden.
3. **Eigene Wartung wird erforderlich.** Der private Baum enthält glibc 2.39
   und erhält durch Hostupdates keine Korrekturen. Exakte Paket-/Quellbindungen,
   vollständige Lizenztexte, reproduzierbarer Neuaufbau und eine verbindliche
   Reaktion auf Bibliotheks-/WebKit-Sicherheitsupdates gehören zum Produktpfad.
   Ein erfolgreicher Build allein ersetzt diesen Updatevertrag nicht.
4. **Vollständige IME-Transaktionen fehlen weiterhin.** Preedit darf Auswahl
   nicht vor der Prüfung zerstören; Surrounding-Delete, Commit und Cancel
   brauchen einen gemeinsamen Plan. GtkIMContext liefert für beliebig getrennte
   Signale keine allgemeine Transaktions-ID. Unterstützte native Adapter müssen
   daher echte Begin-/Commit-/Cancelgrenzen bereitstellen. Ein geratenes
   Idlefenster reicht nicht. SourceView-Autoindent/Tab, AT-SPI, überlange
   Zeilenjoins und Undo/Redo benötigen denselben atomaren Schutz. Quelle,
   gerichtete Auswahl, Revision, Dirty und Historie bleiben bei Ablehnung
   unverändert; Pane-/Dokument-/Fokuswechsel entwerten alte Pläne.
5. **Abnahme folgt der tatsächlichen Integration.** Temporäres Host-Git trotz
   gegensätzlichem privaten PATH, rohe Unixpfade, stdin, Ausgabegrenzen,
   Timeout/Cancel/Ownerverlust und TERM-resistente Enkel sind kleinste
   Hostspawn-Gegenfälle. Echte IBus-/Wayland-Komposition mit Kandidatenfenster,
   Auswahl, Overwrite, Surrounding-Delete, Cancel und Fokuswechsel bleibt eine
   zusätzlich abzustimmende physische Prüfung.

Es wurden keine Systembibliotheken ersetzt und keine vollständige allgemeine
IME-Garantie implementiert. Der positive Laufzeitbeleg erlaubt jetzt eine
konkrete Paketierungsentscheidung, ohne die offenen Kriterien umzubenennen.
