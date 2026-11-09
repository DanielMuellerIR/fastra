# F01: Hostwerkzeuge im optionalen Laufzeitkandidaten

Der optionale Toolkitpfad darf Host-Git, SSH, Konverter oder andere installierte
Werkzeuge nicht durch Programme aus seinem privaten Laufzeitbaum ersetzen.
`fastra-runtime-host` startet deshalb vor Namespace und privaten LD-/ICU-
Exporten. Sein unveränderter Host-Environment-Snapshot ist die Grundlage für
Discovery und Ausführung. Der Standardpfad ohne geerbten Kanal verwendet weiter
den bisherigen lokalen Prozessrunner.

Der private Kanal ist ein geerbter UnixStream, ohne Socketdatei oder Listener.
Eine Anfrage übergibt genau einen neuen Antwortkanal per SCM_RIGHTS. Getrennte
argv-/cwd-Bytes, binäres stdin, Clear-versus-Inherit-Environment und begrenzte
stderr-/Antwortframes bleiben erhalten. Es gibt kein Shell-Eval und keine
Rekonstruktion der Hostumgebung aus der später geänderten GUI-Umgebung. Private
LD-/GTK-/GIO-/GStreamer-Injektionen sind in Host-Deltas gesperrt.

`Domain::Host` verwendet diesen Kanal; `Bundled` erlaubt bewusst geerbte interne
Helfer. `Isolated` startet lokal ohne Marker oder Kanal-FD. Ein vorhandener
ungültiger Kanal ist ein Fehler und löst keinen lokalen Ersatz aus. Höchstens
vier Anfragen sind gleichzeitig aktiv. Das bestehende Prozessgruppen-,
Cancel-, Frist-, Capture- und Reap-Verhalten bleibt im vorhandenen Runner.

Der Owner beobachtet sein UI-Kind unabhängig davon, ob ein interner Helfer den
Kanal noch offen hält. SIGTERM, SIGINT und SIGHUP lösen denselben Abbruch der
Hostaufträge aus und beenden die eigene UI-Prozessgruppe nach einer begrenzten
Gracephase. Hosttools erhalten beim Exec ihre ursprüngliche Signalmaske,
damit ihre eigenen TERM-Aufräumhandler weiterhin arbeiten. SIGKILL kann der
getötete Userspace-Owner selbst nicht behandeln; eine zusätzliche Cgroup-
oder Guardian-Garantie wird nicht behauptet.

Der Git-Commit verwendet im optionalen Pfad den festen GTK-freien
Geschwisterhelfer `fastra-git-commit-hook`. Ein Host-Git startet dort kein
GTK-abhängiges GUI-ELF. Fehlende Helfer führen zu einem Fehler. Der Systempfad
behält seinen bisherigen Einstieg.

Die isolierten Gegenproben erfassen rohe Unixpfade, Clear-Environment, binäre
Eingabe, Ausgabegrenzen, parallele UI-/Helferanfragen, Timeout, Cancel und
Ownerverlust mit TERM-resistenten Enkeln. Reguläre Stopps prüfen zusätzlich
normale TERM-Handler. Ein privater Testsocket prüft den Agent-Socketvertrag;
echte Credentials werden dafür weder gelesen noch übertragen.

Die drei GTK-freien Hosthelfer verlangen glibc höchstens 2.39 und x86-64-Baseline,
ohne RPATH oder GTK-/ICU-Abhängigkeit. Native Desktop-, Credential-, Hardware-
und Waylandabnahme sowie die Dateipfadgrenze des schmalen Namespace bleiben
separate Kriterien des [Laufzeitkandidaten](F01-NATIVE-RUNTIME.md).

Externe HTTP(S)- und Mailto-Links verwenden im optionalen Pfad ausdrücklich das
Desktopportal. Ein tatsächlicher Gegenbeleg mit eigenem harmlosen URI-Handler
zeigte, dass der bisherige GIO-Desktopstart private LD-Werte weitervererbt.
Der native Portalpfad bietet deshalb keinen direkten Desktop-Exec-Ersatz.
Anfragen besitzen einen eindeutigen Handle, abonnieren ihre Antwort vor dem
Aufruf und warten asynchron. Abbruch, Quellwechsel und Frist entfernen den
Auftrag samt Subscription; ein fehlendes Portal meldet einen verständlichen
Fehler. Der Systempfad behält seinen bisherigen GIO-Einstieg.
Die Primärverträge sind [OpenURI](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html)
und [Request](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html).
