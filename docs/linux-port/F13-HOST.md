# Nativer PMT-Host unter Linux

Der Host ergänzt den vorhandenen [Importvertrag](F13-IMPORT.md), ohne ein neues
Protokoll einzuführen. Normales Öffnen, Projektdateien und Desktop-Drops führen
über eine gemeinsame Katalogentscheidung. Paketordner werden vor der nativen
Projektöffnung geprüft; gewöhnliche Ordner bleiben ohne verfügbaren Konverter
als Projekte benutzbar. Vorhandene Ladebesitzer und Quellvalidatoren bleiben
auch nach der ausdrücklichen Wahl „Originalquelle öffnen“ wirksam.

Der Katalogcache enthält höchstens acht Werkzeugidentitäten für fünf Minuten.
Pfad, Inode, Größe und Zeitstempel gehören zur Identität. Die bestehende
`--help`-Ausgabe bestimmt die Unterstützung von `--progress`; eine Versionsnummer
wird nicht als Fähigkeit interpretiert. Die begrenzte fragmentierte stderr-
Auswertung liegt im gemeinsamen Prozessrunner. Der Importer bindet den Parser
an dieselbe aufgelöste Quelle wie die Prozessargumente, auch bei anders
benannten symbolischen Links. Unbekannte Zeilen bleiben Diagnoseausgabe;
Fortschrittszahlen werden nicht erfunden. Die Oberfläche erklärt bekannte
Diagnosegruppen auf Deutsch und Englisch und bietet das unveränderte JSON
zusätzlich an.

Vorschau, Veröffentlichung und spätes Öffnen prüfen den tatsächlichen
Projektbesitzer einschließlich seiner Auswahlgeneration. A→B→A macht eine alte
Freigabe nicht wieder gültig. Eine gerade geänderte, noch nicht bestätigte
Projektwurzel erlaubt keine Adoption. Nicht-UTF-8-Pfade werden vor jeder
verlustbehafteten Umwandlung kontrolliert zurückgewiesen; ähnlich angezeigte
andere Dateien sind kein Ersatz.

`ParentLoss::Terminate` signalisiert bei hartem GUI-Verlust den direkten
Importprozess. Die PPID-Prüfung erfolgt vor und nach `prctl`; bestehende Git-
Runner behalten ihre bisherige Policy. Der bestehende PMT-Namespacewächter
räumt seine Konvertierungsnachkommen auf. Das ist keine allgemeine Zusage für
beliebige fremde Programme. Nach GUI-SIGKILL kann Fastras leerer äußerer
Stagingordner zurückbleiben, da kein Destructor mehr läuft; es erfolgt keine
Adoption.

Die Producer-Paarung für diesen Stand ist PMT 0.41.15 aus
`1b45bacec52e953a849fb2759aa08004f2c35795`, Vertragsdokumentation 5:

- CLI SHA-256: `d354636d818849f8acbea9ad59a41aa91caf5083a07eda4331897288bb6c85e6`.
- Wächter SHA-256: `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`.

Der private native Handoff prüfte zwölf DE/EN-Fälle für Import, Routing und
Projektwechsel bei Mindestbreite und breitem Fenster. Ein gesonderter echter
PMT-Lauf beobachtete GUI, CLI, Namespace-Launcher, PMT-Wächter, TERM-resistenten
Konverter und dessen aus der Prozessgruppe ausgetretenen Enkel. Nach GUI-SIGKILL
blieb keiner dieser Prozesse lebend; ein unbeteiligter Testprozess lief weiter.
Vorheriger, geladener und nachheriger CLI-Hash waren identisch. Die Prüfung des
zusammengeführten Produktstands wird zusätzlich als Versionsbeleg festgehalten.

## Additiver Metadatenstand 6

PMT 0.41.16 (`9f8fadd4e1a0c749ac1469c6bfe1c879d5ccd523`) ergänzt bei RTFD
den optionalen `sourceIdentity.memberPath` mit `TXT.rtf`. Der Verbraucher bewahrt
bekannte und unbekannte Mitgliedsnamen unverändert als Metadaten. Er verwendet
sie nicht als frei lesbare oder schreibbare Pfade. Der normale Konverteraufruf
ändert sich nicht; Quellidentitäten werden nur geliefert, wenn der Aufrufer
`--source-map` verlangt.

Die zusätzliche echte RTFD-Probe verwendete die CLI-Prüfsumme
`7df0dff563ac2027d49e116816e61bab586b666695d004e2b49b1ff67daf635f`
und denselben Wächter wie Stand 5. Sie belegt mit Pandoc: Die Eingabe bleibt das
RTFD-Paket, Mitglied ist `TXT.rtf`, Hash und Bytezahl erfassen ausschließlich die
ursprüngliche RTF-Datei, Änderungen an Anlagen ändern diesen Fingerprint nicht.
Die Übernahme öffnet das richtige Ergebnis und erhält das Original. Die oben
beschriebene SIGKILL-Probe bleibt ausdrücklich ein Beleg für Stand 5.

## Portabler Werkzeugeinstieg

PMT 0.41.17 aus `886ef96d87c40af32f253ec2ec88820de69d3afb` liefert einen
portablen Launcher, der seine eigenen Laufzeitbibliotheken einrichtet. Dieser
Launcher ist als Werkzeug auszuwählen. Das rohe ELF ohne diese Umgebung ist
kein gleichwertiger Einstieg. Der Launcher-SHA-256 lautet
`385d2389430500df83d54bee3a364d198f4ef057936e64ca48df67f0b0573029`.

Zwei zusätzliche deutsche/englische MBOX-Importläufe mit vollständiger Vorschau
und Übernahme bestehen mit diesem Einstieg. Sie sind als Debug-Smoke eines
explizit gebundenen Arbeitssnapshots dokumentiert; die älteren Belege für Stand
5 und die RTFD-Metadatenerweiterung werden dadurch nicht neu etikettiert.
Optionale OCR-Modelle sind keine Voraussetzung des normalen Importvertrags.


## Aktuelle Paarung und RTF-Clipboard

Der eingefrorene Producer 0.41.19 aus
`e2f0b8866aa3acc9b9dd8bf474ffd11d031f4adb` verwendet denselben portablen
Launchereinstieg. Das rohe CLI-ELF besitzt SHA-256
`f2be32db3964282bbce75e4a03ff320f88833081e0abfd808a3fcea95446fe9b`;
die Handoffdateiliste bezieht sich auf dessen `runtime/`-Unterverzeichnis.
Alle deklarierten Laufzeitdateien sind geprüft. Optionale OCR-Modelle gehören
nicht zum normalen Fastra-Import und werden nicht still nachgeladen.

Reines RTF aus dem tatsächlichen GDK-Clipboard öffnet den vorhandenen
Importdialog mit sichtbarer Verlustgrenze. Quelle und vollständiger Ergebnistext
werden vor der ausdrücklichen Übernahme geprüft. Die aktuelle RTF-Konvertierung
erhält Fetttext, Unicode und Textmarker; ursprüngliche Markerfarben werden
vereinheitlicht und mit `richText.highlightColorApproximation` erklärt.
Originalmeldungen und unbekannte Diagnosefelder bleiben erhalten.
Die Übernahme erzeugt ein eigenes Dokument; der ursprüngliche Editorpuffer und
seine Datei bleiben unverändert. Das ist keine verlustfreie Inline-RTF-Bearbeitung.

Die tatsächliche native Paarung ist in
[den Belegen für Linux 1.171.0](F16-1.171.0-EVIDENCE.md) gebunden.
Ältere Stände oben behalten ihre ursprüngliche Zuordnung. Insbesondere ersetzt
eine erfolgreiche Consumerstrecke keine allgemeine PDF-/OCR-Inhaltsabnahme.


## Tatsächliche optimierte Releasepaarung

Die [Abnahme von Fastra 1.185](F16-1.185.0-EVIDENCE.md) ergänzt den bisherigen
WIP-Debugbeleg durch reguläre RTF-/MBOX-Dateiimporte und tatsächliches
RTF-MIME→Rich-Paste mit unverändertem PMT 0.41.19. Vollständige native Vorschauen,
ausdrückliche Adoption, Producer-/Buffer-/Dateibytes, sichtbare Farbverlustgrenze
und echte Fett-/Textmarkerdarstellung sind belegt. Originalbuffer, Originale,
Paket und Producer bleiben auch nach normalem Quit unverändert. Keine
Debugflags oder Produktneubauten wurden verwendet. Die ältere Debugprüfung
wird nicht umetikettiert. Die Releaseabnahme gilt für die dort benannten
einfachen EN-Fixtures; natürliche PDF-/OCR-Qualität und die gesamte Formatmatrix
bleiben davon getrennt.
