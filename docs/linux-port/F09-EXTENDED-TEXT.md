# F09: weitere reine Textoperationen

Dieser Teilstand ergänzt den vorhandenen `fastra-core::text_operations` um
13 Operationen. Die native Text-Menüanbindung und gespeicherte Textabläufe nutzen
denselben Kern; es gibt keine zusätzliche Transformations- oder Dateischreibengine.

## Verhalten und Parameter

- `detab` / `entab` rechnen Tabstopps mit Graphemspalten. Ein grafisch breites
  Zeichen zählt wie im vorhandenen Swift-Original als ein Graphem, nicht als
  Terminalbreite. Die Tabbreite beträgt 1–16.
- `shiftRight` / `shiftLeft` verwenden Tabs oder Leerzeichen sowie Einrückungs-
  und Tabbreite. Einzelbefehle lesen das Profil des aktiven Editors beim Aufruf;
  Abläufe speichern ihr eigenes Profil unverändert im bisherigen JSON-Schema.
- `hardWrap` verwendet Spalten 1–10000, trennt Wörter an ASCII-Space/Tab und
  zerlegt lange einzelne Wörter nicht. Es gibt weder Silbentrennung noch einen
  visuellen Umbruch als Dokumentänderung.
- `straightenQuotes` und `educateQuotes` übernehmen die vorhandene Zuordnung
  beziehungsweise die ausdrücklich englischen typografischen Anführungszeichen.
  Eine gewählte Betriebssystemsprache ändert diese Regeln nicht.
- `convertEscapeSequences` liest die vorhandenen Backslash-, numerischen HTML-,
  kuratierten benannten HTML- und UTF-8-Prozent-Escapes. Ungültige Sequenzen
  bleiben wie im Original stehen. Erzeugtes U+0000 darf nicht in den GTK-Editor;
  der vorhandene Ergebnisguard sperrt die Übernahme sichtbar.
- `exchangeCharacters` / `exchangeWords` verwenden die tatsächliche Einfügestelle
  oder die zusammenhängende Auswahl. Zeichen sind Grapheme; die Worterkennung
  folgt dem bestehenden UTF-16-basierten Foundation-Vertrag. Supplementäre
  Buchstaben werden deshalb nicht als Wortbestandteil nachträglich erfunden.
- `stripDiacriticals` entspricht der engen Foundation-Faltung des Originals,
  nicht einem pauschalen Entfernen aller Unicode-Marks. Japanische, indische und
  Hangul-Zeichen bleiben entsprechend erhalten. Die Schwelle U+0510 und der
  begrenzte Faltpuffer folgen dem beobachteten CoreFoundation-Verhalten.
- `addEmojiPresentation` / `removeEmojiPresentation` ergänzen beziehungsweise
  entfernen VS16 gemäß den bestehenden Ausnahmen und erweitern geteilte
  Zeichenbereiche auf vollständige Grapheme. Bestehende Textdarstellung VS15
  wird beim Ergänzen nicht überstimmt.

Zeichen-/Worttausch bewahrt auch die historische Unterscheidung zwischen einem
LF-Graphem und dem CRLF-Graphem: Ein einzelnes LF verhindert den Nachbartausch,
CRLF wird vom Original dabei nicht gesperrt. Dies ist mit einem eigenen
Vergleichsfall belegt; dieses Paket verändert die Produktsemantik nicht beiläufig.

Der vorhandene Swift-Ablaufadapter stellt bei gleicher Inhaltszeilenzahl
individuelle LF-/CRLF-/CR-Trenner nach zeilenweisen Operationen wieder her.
Rechteckauswahlen werden vor Einzelbefehlen abgewiesen. Ein während der
Hintergrundrechnung verschobener Cursor beziehungsweise eine geänderte Auswahl
verhindert die Übernahme ebenso wie Revision oder Suchgeneration.

## Native Bedienung und Grenzen

Das sichtbare Textmenü gruppiert Zeilen, Einrückung/Tabs, Unicode,
Anführungszeichen/Escapes und Vertauschen als native Untermenüs. Harter Umbruch
fragt die Spalte ausdrücklich ab. Ein einzelner nativer Undo-Schritt stellt die
vorherigen Inhalte zurück. Speichern bleibt ein eigener Schritt.

Der Ablaufeditor bietet bearbeitbare Tab-/Einrückungsbreite, Tabs-Wahl und
Umbruchspalte. Irrelevante Felder sind deaktiviert; die zusätzliche Parametergruppe
erscheint nur für die betroffenen Schrittarten. Änderungen invalidieren die
bestehende Freigabe. Die vollständige Zwischen-/Endvorschau bleibt verpflichtend.
Bei Emoji-Schritten wird die exakte Zeichenansicht wie bei NFC/NFD vorgewählt.

Dieses Teilpaket stellte zunächst 36 von 39 Swift-Schrittarten bereit. Die
anschließenden zwei 4D-Transformationen sind in
[F09-4D-TOKENS](F09-4D-TOKENS.md) beschrieben. Mit dem ausdrücklichen
[Titlecase-Systemlocale-Vertrag](F09-TITLECASE.md) sind nun alle 39 Arten verfügbar;
Definitionen bleiben verlustfrei gespeichert/exportierbar. Root-Sortierung und
Root-Casing behaupten keine benutzerlokalisierte macOS-Parität.

Bestehende Größen-/Zeitgrenzen gelten weiter. Die neuen Funktionen prüfen Cancel,
Ausgabelimits und die maximale erzeugte Zeilenzahl; sie liefern keine Teilübernahme.
Die Prozent-Escape-Verarbeitung bleibt bei langen ungültigen Folgen linear,
obwohl das Original denselben Suffix wiederholt versuchen kann. Der sichtbare
GTK-Ergebnisguard verweigert NUL und zu lange logische Zeilen.

## Referenzen und Prüfung

Produktquellen sind `TextOperations.swift`, `LineOperations.swift`,
`TextWorkflow.swift` und `IndentationProfile` aus `TextView.swift`.
Für die eng begrenzte Diakritikfaltung wurde zusätzlich die primäre
[CoreFoundation-Quelle](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFString.c)
(`__CFStringFoldCharacterClusterAtIndex`, `CFStringFold`) gelesen. Die Umsetzung
verwendet vorhandenes ICU 78.3 und dessen öffentliche Unicode-Eigenschaften;
es wird kein zusätzlicher Parser oder Locale-Ersatz eingeführt.

Die Fixtures `swift-extended-text.json` (203 Fälle) und
`swift-extended-workflow-results.json` (fünf mehrstufige Abläufe) wurden mit
Swift 6.2.1/Foundation aus den unveränderten reinen Textfunktionen erzeugt. Der
Ablaufharness verwendet zusätzlich den unveränderten Originaladapter für
Zeilenenden und die bestehenden Codable-Typen. Dies ist keine native macOS-Abnahme.
Die zugehörige Archivdatei lässt sich in der tatsächlichen GTK-Oberfläche
importieren und als bestehendes Schema 1 exportieren.

```sh
cargo test --locked -p fastra-core
cargo test --locked -p fastra-workflow
cargo clippy --locked -p fastra-core -p fastra-workflow -p fastra-linux --all-targets -- -D warnings
# In einer privaten Xvfb-/D-Bus-Sitzung:
FASTRA_ISOLATED_DISPLAY=1 FASTRA_UI_TEST_ROOT=/var/tmp/fastra-text-test \
  linux/test.sh extended-text
```

Der native Test benutzt echte XTest-Klicks für Text-Untermenüs, Detab,
Zeichentausch an einer von null verschiedenen Einfügestelle, Undo, Werkzeugmenü,
Importfreigabe, Berechnung, Übernahme und Export. Harter Umbruch wird über den
echten Parameterdialog geprüft; ein erzeugtes U+0000 bleibt sichtbar gesperrt. Er prüft die vollständige
Zwischenstufe, Auswahlbegrenzung, Änderung eines Spin-Feldes per Tastatur und die
anschließend gesperrte Freigabe. Mindestbreite und breite Ansicht werden in Deutsch
und Englisch gezielt aufgenommen. Native Mint-/Wayland- und macOS-Abnahmen bleiben
getrennte offene Produktprüfungen.

Geprüfter Teilstand: Vollständige Core-/Workflow-Suiten und All-Targets-Clippy
mit `-D warnings` sind grün. Der neue native Test lief in Deutsch und Englisch;
die bestehende Ablauf-/Bausteinbedienfolge und der vollständige Editor-Selbsttest
liefen zusätzlich als Regressionen. Alle vier neuen Mindest-/Breitansichten wurden
visuell geprüft. Die Prüfung verwendete die stabile Dokumentansicht vor dem
separaten Hex-Edit-Paket und ließ die eigene WebKit-Sandbox eingeschaltet.
