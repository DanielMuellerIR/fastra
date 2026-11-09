# F09 – Gespeicherte Textabläufe auf Datei, Ordner und Projekt

Der vorhandene Ablaufeditor bietet unter **Ablauf auf Dateien …** drei sichtbare
Einstiege: gespeicherte aktive Datei, Dateien aus einem Ordner und Dateien aus der
aktuellen Projektwurzel. Die bisherige Ausführung auf aktive Auswahl/Dokument und
auf offene Tabs bleibt separat erhalten. Die Dateiaktion liest ausdrücklich die
Plattenbasis; bereits ungesicherte betroffene Ansichten verhindern eine anwendbare
Vorschau und erneut die Übernahme.

## Gemeinsamer Plan und Sicherheitsgrenzen

`fastra-search::preview_workflow` verwendet denselben privaten Walker, dieselben
gehaltenen Verzeichnisdeskriptoren, strengen Decoder und `fastra-io::Snapshot`s wie
die Ordnersuche. Pro Datei rechnet die bestehende Workflow-Engine alle aktivierten
Stufen mit unveränderlicher Definition und ausdrücklich gebundener Locale.
Die Rückkodierung in die ursprüngliche Kodierung einschließlich BOM wird schon
vor Veröffentlichung der Vorschau geprüft. Jede fehlerhafte ausgewählte Eingabe
verweigert den vollständigen Plan. Anders als die normale Ordnersuche überspringt
der Workflow keine fehlerhaften ausgewählten Dateien, um den Rest anzuwenden.
Die erste konkrete Datei und Ursache werden sichtbar genannt.

Das vollständige Endergebnis wird durch das vorhandene
`BatchPreview::from_replacements` zu einem Freigabepunkt pro Datei. Die bereits
bestehende `FolderPreview::apply` führt weiterhin ausschließlich über
`Change::from_preview` zu `Transaction::apply`. Es gibt keinen weiteren
Dateischreibweg. Auch wirkungslose und abgewählte Dateien bleiben im abschließenden
Snapshot-Preflight und im gemeinsamen IO-Undo gebunden. Berechtigungen, Xattrs,
Identität, atomare Veröffentlichung und dauerhafte Journale folgen unverändert
dem bestehenden IO-Vertrag.

Der Projektmodus übernimmt `project_view::current_binding`, `Binding::work` und
`WorkBinding::validate`. Eine andere Auswahl oder ausgetauschte Wurzel verweigert
alte Aufträge. Generation und Abbruch gelten für den gesamten Lauf; Fehler
liefern keine teilweise anwendbare Vorschau. Kontext und Definition werden nicht
inzwischen aus dem Definitionsfenster neu gelesen. Der
[Titlecase-Systemlocale-Vertrag](F09-TITLECASE.md) gilt unverändert: vorhandener
GTK-Helper, expliziter Snapshot, sichtbare ID und keine ICU-Default-Locale.

## Native Darstellung und Übernahme

Der vorhandene Folder-Dialog hält die unveränderliche Definition einschließlich
aller Parameter in einem aufklappbaren Inspektor. **Endergebnisse und Freigaben**
verwendet das gemeinsame `ApprovalPane`. **Vollständige Zwischenstufen** wählt
Datei und Schritt und verwendet dieselbe Hintergrund-, Escape-, Grenz- und
portionierte Rendering-Pipeline. Dort sind keine Freigaberegler bedienbar;
Freigaben beziehen sich ausschließlich auf das Endergebnis im ersten Reiter.
Apply ist beim Wechsel auf die Stufenansicht gesperrt und wird erst nach
vollständiger Darstellung der Endansicht wieder freigegeben.

Vor dem Schreiben werden betroffene offene Text-, Rich-, Hex- und Save-Zustände
geprüft. Saubere Textansichten werden ausschließlich aus bestätigten
`applied_snapshots` aktualisiert; nach gemeinsamem Undo entsprechend aus
`restored_snapshots`. Recovery-Indizierung, originale Sicherungen und spätere
Wiederaufnahme verwenden den bisherigen Folder-Transaktionspfad. Fehler nach
Schreiben verwerfen keine Sicherungen. Ein eigener Datei-Workflow-Undo-Mechanismus
wurde nicht eingeführt.

## Bewusst begrenzter Umfang

Zunächst gelten höchstens 32 Dateien, 4 MiB pro Datei, jeweils 16 MiB für Eingaben
und Ausgaben sowie 32 MiB gehaltene Stufen. Die vorhandene Traversierungsgrenze
von 30 Sekunden und die Workflow-Grenze von fünf Sekunden pro Datei gelten
weiter; der letzte Abschluss prüft die Gesamtgrenze ebenfalls. Grenzen dürfen
konservativ früher greifen. NUL und logische Anzeigezeilen über 64 KiB werden
verweigert. Es wird nichts still abgeschnitten.

Der UI-Auftrag umfasst eine gespeicherte aktive Datei, einen Ordner oder eine
Projektwurzel. Es gibt keine Mehrordnerauswahl und keinen neuen Dialog für
erzwungene Dateikodierungen. Die bisherigen automatisch verlustfrei erkannten
Kodierungen einschließlich BOM bleiben erhalten. Schreibgeschützte geänderte
Dateien, doppelte explizite Eingaben, Verweise, besondere Dateien sowie unsicher
erhaltbare Metadaten verweigern den Plan. Schreiben bleibt auf unterstützte
lokale ext4-/Btrfs-Dateisysteme und ein gemeinsames Dateisystem begrenzt. Der
Swift-Umfang von 500 Dateien und allgemeine macOS-Parität werden nicht behauptet.

## Referenzen und Prüfstand

Die Swift-Vorlagen sind `TextWorkflowFilePlan.swift` (Snapshot, verlustfreie
Rückkodierung und Grenzen) und `TextWorkflowBatch.swift` (vollständige Ablehnung
bei einer fehlerhaften ausgewählten Eingabe). Die bestehenden 39 Kinds rechnen
weiter in derselben Workflow-Engine; die Datei-Brücke fügt keine Transformation
hinzu.

Vier gezielte Backendtests prüfen echte temporäre Btrfs-Dateien: UTF-8-BOM/CRLF und
UTF-16 samt tatsächlichen Ausgabebytes, atomare Übernahme/Undo, stale wirkungslose
und abgewählte Eingaben, Einzeldatei, Encoding-/Binary-/Cancel-Verweigerung sowie
schreibgeschützte und doppelte Eingaben. Alle elf bisherigen Suchtests bleiben
grün. Clippy für alle betroffenen Host-/Backendtargets läuft mit `-D warnings`.

Echte isolierte XTest-Läufe prüfen alle drei sichtbaren Menüpfade in DE/EN bei
760/1280 Pixeln: zwei vollständige Stufen, Endfreigaben, Transaktion und IO-Undo,
saubere Tabaktualisierung, stale Eingaben und erhaltene Dirty-Inhalte. Der
Projektlauf tauscht die Wurzel tatsächlich aus und belegt die Verweigerung ohne
Änderung beider Dateisätze. Zusätzliche reale Fälle prüfen vollständige
Encoding-Verweigerung, frühe Dirty-Verweigerung und türkisches/C-Titlecase im
Datei-Workflow. Die bisherigen Folder- und Projekt-GUI-Regressionen bleiben grün.
`linux/test.sh workflow-disk` nutzt den vorhandenen isolierten Testpfad;
`FASTRA_WORKFLOW_DISK_SCOPE=file|folder|project` wählt den Bereich. Eine native
macOS-, Mint-/Wayland- oder gesamte Releaseabnahme bleibt separat.

Gezielte Abschlussprüfung der Owner-Grenzen: Parent-Hide bricht den gehaltenen
Auftrag ab und schließt das Kind nach sicherer Worker-Abwicklung. Sichtbarkeit
wird vor Apply, nach ChangedPaths und unmittelbar vor Transaktionsstart geprüft;
Undo besitzt dieselbe Eintritts- und Abschlussgrenze. Ein verzögerter Worker
belegt unveränderte Quelldateibytes und Snapshot-Bindings; ein nach Hide noch
zugestellter Undo-Callback startet keinen frischen Auftrag. Der Visibility-Handler
wird beim Drop getrennt. Physisch schreibgeschützte Section-/Hex-/Viewer-Ziele
werden für tatsächlich freigegebene Schreibpfade über den gemeinsamen
`Document::disk_path()`-Getter erkannt, auch ohne `Document::snapshot`.
Wirkungslose oder abgewählte solche Ansichten werden nicht neu gebunden. Der
native Konfliktfall belegt einen unveränderten leeren Dummybuffer, fehlenden
Snapshot und unveränderte Quelldatei. Das zentrale Aktualisieren solcher Ansichten
bleibt zusätzlich durch den Root-Host gesperrt.
