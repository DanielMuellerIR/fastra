# Begrenzter GTK-NUL-Versuch

Mit installiertem GTK4-Entwicklungspaket und einem isolierten Display:

```sh
cc gtk-nul.c $(pkg-config --cflags --libs gtk4) -o /tmp/fastra-gtk-nul
xvfb-run -a /tmp/fastra-gtk-nul
```

Der Versuch benutzt ausschließlich Raw-FFI und eine explizite Länge von drei
Bytes. `gtk-nul-result.json` hält die tatsächlich beobachteten Counts und
Diagnosen fest. Erwartete GTK-Diagnosen gehören hier zur Prüfung; sie sind
keine erfolgreichen Textübernahmen. Kein Desktopzugriff und keine Installation.

## Foundation-Ganzzahlreferenz

`integer-boundaries.swift` und `integer-edges.swift` sind eigenständige
Foundation-Proben für Int64, UInt64 und UInt32. Die Zahlen stehen als Rawtexte
im JSON; dekodierte Ergebniswerte werden als Strings ausgegeben. So entsteht
bei der Belegsicherung keine zweite Zahlenrundung. Die tatsächlich auf macOS
erzeugten Ergebnisse liegen unter `crates/fastra-core/tests/fixtures/` als
`control-integer-{boundaries,edges}-macos.json`. Die Linux-Ganzzahlprüfung
übernimmt keine verlustbehaftete Rundung mathematisch gebrochener Werte.


## Native Anwendungslaufzeit

`application-lifecycle.py` prüft mehrere echte App-/CLI-Prozesse auf einem
isolierten X11-Display und einem eigenen Desktop-D-Bus. Der Debug-Build schreibt
nur mit `FASTRA_LIFECYCLE_SELFTEST_DIR` und `FASTRA_ISOLATED_DISPLAY=1` begrenzte
Prüfzustände in das private Testverzeichnis; eine dort angelegte Datei `quit`
fordert das reguläre native `GApplication.quit()` an. Release-Builds besitzen
diese Beobachtung nicht. Der Python-Prozess übernimmt automatisch gestartete
Dienstkinder, damit auch deren tatsächlicher Exit geprüft werden kann.

Nach dem Build genügt auf dem bestehenden isolierten Display:

```sh
FASTRA_ISOLATED_DISPLAY=1 FASTRA_UI_TEST_ROOT=/privater/btrfs-oder-ext4-pfad \
  ./linux/test.sh application-lifecycle
```

Die Geschwisterprogramme `fastra-linux` und `fastra-control` sind erforderlich.
Der Test benötigt Python 3, `xdotool` und ImageMagicks `import`. Er deckt
Dienststart vor GUI, GUI vor CLI, mehrere gewöhnliche Fenster, relative Pfade
aus dem Remote-Arbeitsverzeichnis, rohe Nicht-UTF-8-Pfade und Datei-URIs,
abgewiesenes Dirty-Close, Schließen/Wiederöffnen, Snapshot-Ready/Close,
Fensterinventar und Runtime-ID sowie gewöhnlichen und gehaltenen Shutdown ab.
Der CLI-Autostart wird ausschließlich über die benachbarte Binärdatei ausgelöst;
bei der nativen Containerprüfung werden keine Quellen eingehängt.
