# F07: Dateien im Desktop-Dateimanager zeigen

Ab 1.186.0 bietet das Projektfenster einen beschrifteten Knopf
„Im Dateimanager zeigen“. Er markiert den gewählten Projektordner in dessen
Elternordner. Dieselbe Aktion im Kontextmenü gespeicherter Dokumenttabs markiert
die Datei in ihrem Ordner. Ungespeicherte Dokumente besitzen keine aktive Aktion.

Der zentrale Adapter ruft asynchron `org.freedesktop.FileManager1.ShowItems`
mit einer `as`-Liste genau einer lokalen Datei-URI und leerer Startup-ID auf.
Gio bildet rohe Unix-Pfadbytes ab; es gibt weder verlustbehaftete Stringpfade
noch Shellaufrufe oder einen stillen Ersatzweg. Die Sitzungverbindung der
bestehenden Anwendung wird wiederverwendet. Ein Auftrag hat eine Frist von
zehn Sekunden; ein nicht erreichbarer oder fehlerhafter Dienst wird sichtbar
mit lokalisiertem Kontext und tatsächlicher Transportfehlermeldung erklärt.

Eine eigene Generation und Cancellation verhindern Doppelaufträge und alte
Rückmeldungen nach einem neuen Auftrag. Projektwechsel und Schließen entwerten
laufende Aufträge; Dokumentantworten prüfen Mitgliedschaft, gespeicherten Pfad
und ursprünglichen aktiven Tab. Der externe Dateimanager kann einen bereits
empfangenen Auftrag schon ausgeführt haben: diese UI-Bindung behauptet keine
Rücknahme einer fremden Desktopaktion. Fastra schreibt dabei keine Dokumente.

Ein eigener D-Bus-Sentinel prüft URI-Bytes einschließlich Leerzeichen, Prozent-,
Rautezeichen, Unicode und ungültigem UTF-8, echte Servicefehler, Doppelaufträge
und verspätete Antworten. Native XTest-Flüsse bedienen Projektknopf und
Tabkontextmenü tatsächlich; DE/EN bei 640 und 1100 Pixel wurden ausgeführt und
alle acht zugehörigen Ansichten visuell geprüft. Die privaten Anzeigen sind
keine physische Desktop-/Compositorabnahme.

Quelle: [freedesktop File Manager Interface](https://www.freedesktop.org/wiki/Specifications/file-manager-interface/).
