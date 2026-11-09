# Entscheidung nach F00–F04

Stand: 2026-11-04. Ausgang Fastra `55ca70579861954a21cfbd22d96e12059fec68db`
(1.157.1). Der Sammlungsfix ist Commit `4999717c1255`,
Version 1.157.2 / Build 365. **F05/F06 sind mit einem getrennten Suchkern begonnen,
aber nicht vollständig abgenommen. GTK4/GtkSourceView bildet inzwischen die
erste Linux-Anwendung. M0 bleibt bis zur nativen Desktop- und vollständigen
Transaktionsabnahme offen.**

## Aktuelle Entwicklungswahl vom 2026-11-05

GTK4/GtkSourceView ist die gemeinsame reversible Entwicklungsbasis der
Linux-Portierung. Die inzwischen implementierte native Anwendung und ihre
Funktionsbelege stehen unter [F07/F08](linux-port/F07-LINUX.md). Poor Man's Text
kann seine GTK4-Oberfläche parallel weiterentwickeln und wartet dafür nicht auf
Fastras vollständige Editor- oder Desktopabnahme. Der lokale CLI-Vertrag bleibt
die Kopplungsgrenze; gemeinsame Fenster- oder Editorabstraktionen entstehen nicht.

Die untenstehende Tabelle bewahrt den historischen Ausgang der Entscheidungsphase.
„Keine Toolkitfreigabe“ bedeutete dort keine endgültige Produktabnahme. Reale
Zieldesktops, Eingabemethoden und vollständige Funktionsgleichheit bleiben eigene
Tore; sie sind kein Wartevertrag für die weitere GTK-Entwicklung in PMT.

Die vorhandene Mac-Oberfläche bleibt erhalten. Die Proben begründen einen
gekapselten ICU-Kern und eine kleine Swift/Rust-Grenze; sie begründen weder einen
Mac-Neubau noch einen großen Editor-Fork. Die nächste Entscheidung betrifft die
fehlende Editorsemantik und den Wiederherstellungsvertrag, nicht die Sprache der
PMT-Konverter. Eine Funktionslücke wird nicht durch Umbenennen zur Parität.

| Paket | Beobachtetes Ergebnis | Entscheidung und Grenze |
| --- | --- | --- |
| F00 | [Funktionsmatrix](linux-port/F00-MATRIX.md), kleine unabhängige Referenzen; 2799 schnelle und 304 serielle Mac-Tests bestanden | Referenzen und native Sammlungsabnahme gesichert. |
| F01 | GtkSourceView mit gemeinsamem Buffer, Undo, Unicode/CRLF, Syntax und 4-/32-MiB-Fällen ausgeführt; GPUI 0.9.0 am gepinnten Quellstand geprüft | **Externe Entscheidung erforderlich.** Kein vollständiger Vergleich beider GUIs; keine Toolkitfreigabe. |
| F02 | 37 Fälle mit identischen Capture-Ranges/Ausgaben; ICU 78.3 in verschobenem Mac-Bundle sowie identischer Linux-Laufzeit auf beiden Zielsystemen; Zeitlimit und Callback-Abbruch | ICU 78.3 als Kandidat belegt. Produktionsadapter, breiteres Korpus und Lizenz-/Updatekonzept bleiben vor Auslieferung erforderlich. |
| F03 FFI | C-Schnittstelle und UniFFI 0.31.2 mit echten generierten Swift-Bindings aus verschobenem Bundle; Fehler, Panic, Speicherbesitz und aktiver Abbruch | Kleine, ausdrücklich fehlbare API ist tragfähig. Keine UI-Callbacks oder produktive Target-Auftrennung eingeführt. |
| F03 Dateien | Elf Exchange-/Recovery-Prüfpunkte auf Btrfs und Kernel-ext4 bestanden | **Vollständiges Tor offen.** Kein produktiver Journal-/Mehrdatei-/Crash-Durability-Nachweis. |
| F04 | WebKitGTK 6 rendert vorhandene JS-Ressourcen, Bild, KaTeX und Mermaid; Bearbeiten/Undo, Save und neuer Prozess; Bildwechsel und CSP-Netzsperre | Lokaler WebKitGTK-Weg belegt, an F01 gebunden. Vollständige WYSIWYG-Parität und produktive Bridge-Abwehr nicht abgenommen. Externe 4D-Ausführung bleibt offen. |

## Sammlungsimport und echte Mac-Programme

Die Tabelle oben dokumentiert die anfängliche Entscheidungsphase. Die
Fortsetzung implementiert inzwischen den [Suchkern](linux-port/F05-CORE.md),
eine [native portable Swift-FFI-Probe](linux-port/F05-MAC.md),
[Dateitransaktionen](linux-port/F03-TRANSACTIONS.md), das erste
[Linux-Fenster](linux-port/F07-LINUX.md),
[Dokumentcodecs und Abschnitte](linux-port/F07-DOCUMENTS.md),
[Textwerkzeuge](linux-port/F09-TEXT.md), [Git-Abfragen](linux-port/F11-GIT.md),
den [PMT-Verbraucher](linux-port/F13-IMPORT.md) und
[Paketwerkzeuge](linux-port/F16-PACKAGING.md). Die jeweiligen Belege trennen
Bibliothek, Host-Anbindung und noch offene Produktabnahme.

Der Fehler aus PMT P01 ist im Fastra-Consumer korrigiert: Vor dem Verschieben wird
am bereits geprüften Ausgabeordner der tatsächliche relative Markdownpfad
festgehalten. Nach der Übernahme wird dieser Pfad am endgültigen Ziel angehängt.
Dadurch bleiben `index.md` und verschachtelte Übersichten erhalten, auch wenn der
Zielordner wegen einer Kollision `-2` erhält. Der Einzeldateifall bleibt bei seinem
endgültigen Dateiziel.

Die bestehenden Prüfungen auf echten Ausgabeordner, aufgelöste Begrenzung und
reguläre Datei per `lstat` bleiben unverändert wirksam. Es gibt keinen ungeprüften
Fallback auf einen Quellnamen und keine zusätzliche Freigabe fremder Pfade. Die
bekannte vollständige Prüfung bösartiger Ergebnisbäume wurde nicht als Teil dieses
begrenzten Fixes ausgegeben.

Die 41 gezielten Importtests bestehen. Zwei unabhängige Sammlungsfälle mit
Kollision schlagen gegen den ursprünglichen Service fehl und bestehen gegen den
Fix; der kleine Nachweis benutzt ausdrücklich Framework-/Prozessstubs. Er ersetzt
keinen App-Test. Hilfe DE/EN beschreibt jetzt vollständige Sammlungen und die vom
Werkzeug gemeldete Übersicht. Das Layout änderte sich nicht; README-Bildpaare
benötigen deshalb keine neue Aufnahme.

Fastra und PMT wurden für die native Prüfung neu gebaut, signiert und über ihre
vollständigen notarisierten Installationswege installiert. Die maschinenlesbaren
[Buildidentitäten](linux-port/BUILD-IDENTITIES.json) binden Eingabebäume und
Binärdateien an diese Builds. Eine bloße Versionsgleichheit ist kein Quellbeleg.
PMTs Produktquellen sind zwischen dem P01-Ausgang `17328f17` und dem verwendeten
Planungsstand `5293eb6c` unverändert; die dazwischenliegenden Änderungen betreffen
Proben und Dokumentation. PMT wurde ausschließlich in temporären Kopien gebaut;
sein Arbeitsrepository wurde nicht verändert.

**Native Sammlungsabnahme bestanden:** MBOX und ENEX wurden von der echten
PMT-Oberfläche konvertiert. Jede Sammlung enthält Übersicht, beide Einzeldokumente
und das ursprüngliche PNG; MBOX hat vier, ENEX fünf Dateien. Ein zweiter PMT-Prozess
meldet die vorhandenen Ziele sichtbar als belegt und verändert deren Bäume nicht.
Die Beobachtung dieses Zustands erfolgte über den bereits berechtigten nativen
SSH-Beobachter: Im autonomen Testdienst blieb dessen AX-Liste leer und der erste
Prüfversuch endete deshalb mit einem Harnessfehler. Die echten Ausgaben und der
anschließend beobachtete Kollisionszustand wurden unabhängig weiter geprüft.

Fastras echter `markdowncollections`-Lauf übernimmt dieselben Quellen neben den
bereits belegten Zielnamen. Alle drei Markdown-Dateien jeder Sammlung werden im
Editor geöffnet. Nach Prozessende öffnet ein neuer Fastra-Prozess diese Dateien
ohne erneute Konvertierung. Beide nativen Läufe melden PASS. Die unabhängige
Baumprüfung vor und nach dem Neustart bestätigt identische vollständige Bäume
beider Apps, Quellhashes, PNG-Bytes und sieben auflösbare relative Verweise.
Die befristete Wachhaltung ist beendet, eigene App-Prozesse sind geschlossen,
Einstellungen restauriert und die Testressourcen mit erfolgreichem Cleanup frei.
Die kleinen Belege stehen in [EVIDENCE.json](linux-port/EVIDENCE.json).

Die frühere P01-Grenze dieser konkreten Sammlungspfade ist damit geschlossen.
Stale Tabs/Projekte, Kindprozessverlust und vollständige bösartige Ausgabebäume
bleiben eigenständige Vertrags-/Sicherheitsthemen; diese Abnahme meldet sie nicht
pauschal als erledigt.

## Einzelentscheidungen

- [F01: Editorvergleich und offene Bedienung](linux-port/F01-EDITOR.md)
- [F02: Regex-/Unicode-Korpus und portable ICU-Laufzeit](linux-port/F02-REGEX.md)
- [F03: UniFFI, Exchange und Wiederherstellungsgrenze](linux-port/F03-SAFETY.md)
- [F04: lokale WebKit-Probe und externe 4D-Grenzen](linux-port/F04-MARKDOWN.md)

## Übernommene PMT-Ergebnisse und Stoppgrenze

Verwendet wurden `docs/LINUX-DECISION.md`, P01-CONTRACT, P02-SWIFT, P03-SAFETY
und P04-BACKENDS aus PMT. Die fünf Linux-Formate samt SDK-freier Swift-Laufzeit,
Poppler/Tesseract/LibreOffice- und OCR-/Bildproben wurden nicht erneut ausgeführt.
Deren Sicherheits-, RTFD-, HEIC- und strukturierte-OCR-Grenzen bleiben erhalten.
Sie betreffen PMTs lokale CLI und wählen Fastras Oberfläche nicht vorab aus.

Die Proben und kleinen normalisierten Belege stehen unter
[tools/linux-probes](../tools/linux-probes/README.md). Quellarchive, Programme,
Containerlaufzeiten und Screenshots bleiben außerhalb des veröffentlichten
Quellbaums. Entbehrliche Arbeitskopien spätestens 30 Tage nach Abnahme entfernen;
Referenzgeneratoren für die hier offenen Tore erhalten.

**Fortsetzung F03:** Eine isolierte Probe ergänzt einen synchronisierten Intent
und die rein lesende Wiederanlaufprüfung. Auf Btrfs bestehen 17 Prüfpunkte mit
drei echten SIGKILL-Grenzen und manipulierten Dateien/Journalen. Sie gibt weder
automatischen Rollback noch Stromausfallfestigkeit oder eine Mehrdatei-Transaktion
frei; Details stehen im [F03-Vertrag](linux-port/F03-SAFETY.md).

**Nächste Schritte:** begrenzte Editorerweiterung in F01 und der noch offene
produktive Wiederherstellungspfad in F03. Die fortgesetzte GTK-Probe belegt eine
öffentliche Erweiterung für erste Editorfälle. Der
[F05/F06-Suchkern](linux-port/F05-CORE.md) besteht seine Linux-Quellreferenzen;
native Mac-Anbindung und vollständige Produktintegration bleiben offen.
