# Nebenläufigkeit und Zustandsbesitz

Fastra trennt sichtbaren Dokumentzustand, Hintergrundarbeit und gemeinsam genutzte Dienste. `Task.detached` oder `@unchecked Sendable` macht ein UI-Modell nicht nebenläufig nutzbar. Die folgenden Verträge beschreiben die aktuelle Implementierung; sie sind keine Zusage vollständiger Swift-6-Isolation.

## Fenster und Ergebnisse

Im Produkt werden Fenster, Editor, Tabs und sichtbarer Workspacezustand auf Main gelesen und geändert. `Workspace` ist noch nicht als ganze Klasse MainActor-isoliert. Isolierte Tests dürfen unabhängige Workspaces auf anderen Threads erzeugen und abbauen. Das Vorwärmen von `objectWillChange` vor der Weitergabe sowie die Locks für die schwachen Workspace-Registrierungen schützen diese besonderen Übergänge, nicht beliebige gleichzeitige Modellzugriffe.

Die drei fensterlokalen Besitzer `ScrollRestoreDiagnostics`, `MarkdownImportDecisions` und `GitInteraction` enthalten keine Workspace-Rückreferenz. Ihre Konstruktion bleibt fensterlos; Observer, Provider, Gitdarstellung und native Dialoge folgen danach demselben Main-Aufrufervertrag wie der Workspace. Asynchrone Importfortsetzungen halten ihren konkreten Besitzer bis zum Cleanup, Auto-Fetch-Beobachtungen halten GitInteraction schwach und antworten auch nach dessen Abbau genau einmal mit „Später“. Das ist keine Zusage beliebiger gleichzeitiger Zugriffe auf dieselbe Instanz.

`SearchResultSession` besitzt pro Dokumentfenster die Suchbasis, Laufgeneration und Freigabe auf dem MainActor. Ein Worker bekommt Text-/Optionensnapshots oder einen fertigen `SearchPlan`. Vor der Veröffentlichung prüft Main Session, Generation, unveränderte Eingabebasis und Fenster. Datenübernahme und Freigabe erfolgen im selben Durchlauf. Abbruch allein genügt nicht: Eine bereits wartende Antwort muss auch diese Gültigkeitsprüfung bestehen.

Die MainActor-Besitzer `DocumentWindowController`, `SessionRestorationCoordinator`, `TextWorkflowSession`, `FourDSignatureHelpController` und die Editorcoordinatoren verwalten ihren UI-Zustand dort. Einige ältere Helfer wie `SearchRunner`, `FileDiffComputations`, `FourDProjectIndexController` und `ProjectFileWatcher` halten Main weiterhin per Aufrufkonvention. `@preconcurrency TextViewCoordinator` verbindet die MainActor-Coordinatoren mit dem älteren CodeEdit-Protokoll; dessen Lifecycleaufrufe müssen Main bleiben. `MainActor.assumeIsolated` führt keinen Threadwechsel aus und benötigt daher einen bereits gesicherten Main-Einstieg.

## Tabs, Dokumente und native Editoren

Der Workspace hält pro Dokumentfenster Tabliste, aktive Auswahl und
Vergleichsauswahl. `EditorTab` trennt Tabplatz-ID, Dokument-ID und
Inhaltsrevision. Ein sauberer Vorschauplatz darf Position und Tab-ID behalten,
erhält beim Ersetzen aber ein neues Dokument samt eigenem Undo-Verlauf.
Eingaben im Quelltext-/Visualeditor und die erste Byteänderung heften die
Vorschau an; ungesicherte Arbeit darf nicht als Vorschauplatz wiederverwendet
werden.

Jeder Tab teilt seinen [DocumentUndoHistory](../app/Sources/Fastra/DocumentUndoHistory.swift)
zwischen seinen Wertkopien. Dieser Besitzer hält nativen Undo-Manager und
Textspeicher. [SourcePaneRegistry und SourcePaneMemory](../app/Sources/Fastra/SourceSplitEditor.swift)
registrieren native Pane-Views schwach und halten dokumentgebundene Cursor- und
Scrollzustände.
Der Workspace spiegelt die aktive Auswahl und Footerwerte. Dokumentbefehle holen
zusammengehörige Fenster-, Workspace- und Editorziele über `CommandTargeting`.
Source-Bindings weisen Antworten eines alten Dokuments oder Editoraufbaus anhand
von Dokument-ID und Reload-Nonce ab.

[TextWorkflowOpenDocumentsPlan](../app/Sources/Fastra/TextWorkflowOpenDocumentsPlan.swift)
prüft für Änderungen in offenen Dokumenten Fenster, Dokumentidentitäten,
Revisionen, URLs und exakte Ausgangsinhalte. Er registriert Textersetzungen im
jeweiligen Dokumentverlauf vor der gemeinsamen Modellpublikation. Seine
Rücknahme gilt nur auf der unveränderten angewandten Basis. Native Eingaben sind
bereits im Editorverlauf registriert. Die angeschlossenen Speicher-, Schließen-,
Tab- und Ansichtsaktionen müssen ausstehende Visual-Markdown- und Bild-Undo-Arbeit
zuerst gesichert abschließen.

Speichern, Hex-Save, Restore und normale Datei-Reads behalten ihre eigenen
Identitäts-, Generations- und Abschlussprüfungen. Eine alte Tab-ID allein genügt
keiner verzögerten Inhaltsübernahme. Die endgültige Einzelauswahl über
`selectTab` synchronisiert zusätzlich den Projektkontext; eine direkte Zuweisung
an `activeTabID` tut das nicht allgemein.
Die Referenznavigation im Markdown verwendet einen solchen direkten Anschluss.
Der Workspace bleibt der fenstereigene Aggregationspunkt mit breiter
Viewbeobachtung. Daraus folgt keine gemessene UI-Verzögerung. Modelltests und
Fensterselbsttests ersetzen keine Abnahme zusammenhängender normaler Bedienwege.

SwiftUI kann Kontextmenübefehle verzögert nach einem zwischenzeitlichen
Tabwechsel ausführen (beobachtet rund 435 ms später). Aktionen wie
„Duplizieren“, die Folgeverhalten an den ursprünglichen Bedienkontext binden,
müssen Tab- und Projektkontext bereits beim Öffnen des Kontextmenüs erfassen,
nicht erst im Action-Closure; die Dateioperation läuft am ursprünglichen Ziel
weiter, ein automatisches Öffnen erfolgt nur bei unverändertem Kontext.

## Worker und Antworten

Dateilesen, Suche, Git-Prozesse und Parser laufen außerhalb Main mit kopierten Eingaben. Dateiladen und externe Änderungsprüfung übernehmen Ergebnisse erst Main nach erneuter Dokument-/Pfad-/Generationsprüfung. `FileLoadAcceptance` ist eine Main-Freigabeclosure: ihre Aufrufer müssen sie auch beim synchronen Start der Lademethode Main ausführen. `TextWorkflowDiskMutation` darf UI-Referenzen bis zum Abschluss halten; der Worker verwendet die eingefrorenen Dateidaten und fragt aktuellen Modellzustand synchron Main ab. Sein `preflight` darf deshalb nicht Main ausgeführt werden.

`DocumentFileLoads` besitzt pro Fenster normale Erst-/Preview-/Hash-Reads,
Encoding-Reopen sowie einzelne und nach Plattenmutationen angestoßene Reloads
auf dem MainActor. Eine gemeinsame Generationstabelle gilt für alle normalen
Readarten; Gitpreview, Dateivergleich und Abschnittslesen behalten ihre eigenen
Besitzer. `Workspace.init` bleibt nichtisoliert. Der Owner wird erst am ersten
belegten Main-Einstieg synchron angeheftet, auch vor Fensterregistrierung. Die
bestehende starke Visualsync-Vorstartaktion bleibt bis zu ihrem bisherigen
Idle-/Editorabschluss erhalten.

Der schwache Workspace-Adapter hält weder Tabs noch Undo. Er liest aktuelle
Main-Metadaten und publiziert freigegebene Änderungen synchron im selben
Durchlauf. Die Worker bekommen kopierte Loader und Readwerte; `Task.detached`
hält den Owner bis zur Mainantwort am Leben. Terminale Readrecords werden vor
Rückrufen entnommen. Tabs und Dokumentmetadaten bleiben beim Workspace; Textspeicher und Undo beim
zugehörigen `DocumentUndoHistory`, Panezustände bei `SourcePaneRegistry` und
`SourcePaneMemory`. Explizite Reloads dürfen bestätigte Dirty-Inhalte verwerfen;
automatische Reloads nach Plattenmutationen prüfen zusätzlich weiterhin Dirty.

Zusammengeführte Ordner-Sprünge teilen je zugeordnetem Read genau einen
`FolderMatchFileLoadWaiter` zwischen Owner-Dictionary und Readabschluss. Main
ersetzt oder entnimmt dessen aktuellen logischen Auftrag vor jedem Rückruf.
Snapshot- und Pfadneustarts übertragen den Auftrag und lassen den alten
Wartenden leer. Nach Workspace-Freigabe erhält der aktuelle Folderwartende
einmal `cancelled`, der gewöhnliche Einzel-Load weiterhin `failed`. Invalidierung
nimmt Annahmerechte, ohne diese Rückmeldungen vor dem ursprünglichen Readende
vorzuziehen. Projektwechsel brechen weiterhin nur Preview-Reads kooperativ ab.
Dafür laufen weder Rückrufe noch Actorwechsel im `deinit` des Workspace.

`DocumentLanguageDetector` schützt Aufträge und Generationen mit einem Lock, analysiert begrenzte Textproben und liefert ausschließlich Main. Dort werden Tab, Dokument und Revision erneut geprüft. Die Ergebniswerte `Analysis` und `DetectionResult` transportieren unveränderliche Beschreibungen. Injizierte Scheduler müssen dieselben Executorregeln einhalten.

## Plattenänderungen und Rücknahme

Ordner-/Projekt-Apply und Textabläufe haben unterschiedliche Auftragslebensdauern.
Ihre gemeinsame Pfadreservierung und der Reload nach dem Schreiben sind eigene
Dienste. Die Koordination verteilt sich wie folgt:

| Zustand oder Arbeit | Besitzer |
| --- | --- |
| Ordner-/Projekt-Apply mit Task, Generation, Fortschrittsannahme und Abbruchanforderung | `Workspace`, nach dem Main-Aufrufervertrag. `folderApplying` sperrt auch weitere Aktionen und Close-/Quitpfade. |
| Platten-Apply und Platten-Rücknahme eines Textablaufs einschließlich Visualsync und gehaltenen Editoren | `TextWorkflowSession` auf dem MainActor. Ihr `task`, `isBusy` und `isDiskOperation` gehören auch zum Dialogabschluss. |
| Historische Dateiwiederherstellung mit eigener Auswahl, vollständiger Vorschau und verbrauchbarer Freigabe | `ApplyRecoverySession` auf dem MainActor. Der Worker hält Sitzung, Workspace, Pfadreservierung und Verzeichnisclaim bis zur Reload-Antwort und Schlussprüfung. `fileRecoveryApplying` schützt Close/Quit. |
| Jüngster gemeinsamer Rücknahme-/Recoverygriff | `Workspace.lastApplySession`; ein veröffentlichter Slot für einen `ApplySession`-Wert. |
| Rücknahmegriff des einzelnen Textablaufs | `TextWorkflowSession.diskAppliedSession`; er darf älter als der gemeinsame Workspacegriff sein. |

`ApplySession` und `UndoEntry` sind unveränderliche Werte. Ihre Dateiartefakte
und der persistierte Fortschritt werden weiterhin vom Dateikern geprüft und
fortgeschrieben. Zwei gespeicherte Werte sind kein gemeinsam mutiertes
Sessionobjekt. Bei der Rücknahme eines älteren Textablaufs vergleicht der
Abschluss `sessionDirectory`, bevor er den gemeinsamen Workspacegriff entfernt
oder ersetzt. Eine neuere unabhängige Rücknahmearbeit bleibt dadurch erreichbar.

`WorkspacePathOperationRegistry` reserviert Ressourcen appweit unter einem
Lock, auch für Hex-Save, Move und Trash. Die Reservierung schützt kooperierende
Operationen innerhalb der App; die bestehenden Dateiidentitäts- und
Atomicprüfungen bleiben zusätzlich nötig. Eine Abbruchanforderung gibt den
laufenden Claim nicht vor der Engineantwort frei. Ordner-Undo hält seine
Reservierung synchron bis zum Ausgang. Text-Undo läuft asynchron und hält die
nötigen Session-, Workspace- und Editorreferenzen bis zum vollständigen
Mainabschluss. Dieser Abschluss führt Claimfreigabe und Editorfreigabe auch nach
Dialogentwertung aus. `deinit` ist dafür kein Ersatz.

Der Reloadfanout übergibt geänderte URLs an `DocumentFileLoads`. Dessen
Annahmeprüfung und die Veröffentlichung von Inhalt, Diskbasis und gespeicherter
Undo-Basis bleiben beim Dokumentpfad. Der Plattenauftrag erhält dadurch keinen
zweiten Tab- oder Undo-Verlauf. Die historische Wiederherstellung wartet auf
alle physischen Reload-Antworten, auch bei verworfener Übernahme, geschlossenem
Tab oder abgebautem Workspace. Nur ein an den bestätigten restaurierten Snapshot
gebundener Read darf Daten übernehmen. Erst nach der Schlussprüfung werden der
Verzeichnisclaim, die exklusive Pfadreservierung und gehaltene Editoren freigegeben.
Ein Retry liest dieselbe Sitzung neu; der normale RAM-Undo-Slot bleibt unabhängig.
Die Prozessprüfung weist jede beobachtete zweite Fastra-Kopie ab. Eine erst nach
der letzten Prüfung startende, nicht mitwirkende App wird dadurch nicht verhindert.

Regressionsfälle für ältere/neue Sessiongriffe und Cleanup-only-Retry stehen in
[TextWorkflowSessionTests](../app/Tests/FastraTests/TextWorkflowSessionTests.swift);
Dateibasis, Teilfortschritt und gespeicherte Dokumentbasis werden zusätzlich in
[ApplySafetyTests](../app/Tests/FastraTests/ApplySafetyTests.swift) und
[HexEditLifecycleTests](../app/Tests/FastraTests/HexEditLifecycleTests.swift)
behandelt. Diese Modell- und Dateiprüfungen ersetzen die Bedienprüfung der
ursprünglichen Ordner- und Textabläufe nicht.

## Geteilte Daten und serielle Dateiarbeit

`SearchPlan` teilt nur eine fertig aufgebaute, unveränderliche Regex. Caches für Makrokataloge und Signaturen, Abbruchsignale, Git-Leases/-Gates, Deadline-/Entscheidungsboxen und die ripgrep-Ergebnisbox schützen ihren veränderlichen Zustand mit eigenen Locks. `BackgroundOnceResolver` schützt die einmalige Berechnung und Veröffentlichung; ausgegebene Werte müssen selbst sicher teilbar bleiben. Der Produktaufrufer verwendet `String?`.

Markdown rendert auf einer appweiten seriellen Queue, weil cmark globale Erweiterungen registriert. `MarkdownRenderCoalescer` verriegelt wartende Aufträge und prüft seine Revision nochmals vor der Mainantwort. Bild-Undo besitzt einen anderen Vertrag: Die Dateiphasen von `MarkdownImageUndoSideEffect` und `MarkdownImageUndoFiles` werden über die gemeinsame I/O-Queue serialisiert. Sie sind nicht frei parallel aufrufbar. Am Ende jedes I/O-Arbeitsblocks werden die vorhandenen Removal- und Restorefehler als unveränderliche Zeichenketten gesichert. Main erhält diesen `Sendable`-Wert mit der Completion und liest keine veränderlichen Fehlerfelder der Dateibesitzer. Die Reporter halten die bisherigen Dateibesitzer weiterhin bis zu ihrem Abschluss am Leben. Ein nachfolgender I/O-Auftrag kann so den bereits übergebenen Befund nicht ersetzen. Der Referenzwrapper reicht nur das Ergebnis seines terminalen Versuchs weiter. Nach der Completion folgen die Invalidierungen und zuletzt der `pendingIO`-Abschluss; ein Referenzretry tritt vorher ein. Der appweite `MarkdownImageUndoBuffer` ist selbst gelockt und schützt ausgeliehene Daten vor Verdrängung. Die Verzeichnislockregistry serialisiert Bildveröffentlichungen je Zielordner. `MarkdownImageRemovalCheck` überträgt das Ergebnis des Main-Referenzgates gelockt zurück.

Der bestehende Bild-Dateibesitzer hält zusätzlich einen zusammengeführten,
noch relevanten echten Entnahmefehler. Vor dem Ersetzen des jüngsten Resultats
übernimmt er dessen Ursachen und beobachtete Pfadfolgen. Nur eine explizit
referenzbedingte Ablehnung ohne betretenen Commitbody und mit sauber beendetem
Arbeitsordner darf ein späterer positiver Bildschutz vergessen. Alte Bool-Gates
und Generation-/Sessionablehnungen bleiben unklassifiziert beziehungsweise echte
Abbrüche. Die vorhandene erfolgreiche Wiederherstellung oder permanente Entnahme
quittiert echte Altfehler nur, soweit ihre Dateiauflösung belegt ist. Restherkunft
und erfolgreiche Ordnerabschlüsse stammen aus der ohnehin laufenden Operation;
es gibt keinen zusätzlichen Scan. Abgetrennte Restpfade bleiben als frühere
Beobachtung erhalten. Ein bereits gesicherter Stringpayload ändert sich dadurch
nicht; die Meldung selbst quittiert keinen Befund.

Die 4D-Makroengine serialisiert ihre Watchdatei-Transaktionen appweit; die Backuphülle überträgt ihren gebundenen Deskriptor genau einmal. `SiblingFolderMenuContext` und `FolderApplyProgressRelay` tragen schwache UI-Referenzen über Workergrenzen, lesen sie aber erst Main. Der `PrintCompletionRelay` darf den Rückruf auf dem Druckthread erhalten und verschiebt Auswertung, Genau-einmal-Abschluss und WebViewabbau Main; bis dahin hält ihn seine aktive Main-Liste.

## Git und Lebensdauer

GitCoordinator und RepositoryStore schützen Warteschlangen, Snapshots und Beobachter mit Locks. Callbacks laufen außerhalb dieser Locks. Der Store stellt UI-Beobachter Main zu. Beim Coordinator erbt eine normale Completion den Executor des Starters; eine Lease-Cancellation antwortet synchron auf dem Thread des Abbruchaufrufers. `GitRunner.runExecutable` erlaubt eine eigene Completionqueue. UI-Adapter müssen deshalb ihren tatsächlichen Main-Einstieg sichern.

Fensterlokale Arbeit verwendet schwache Besitzer und generationengebundene Antworten. Transaktionen halten notwendige Startobjekte bis Cleanup ausdrücklich stark. Cancellation verhindert nicht jede laufende Datei-/Parseroperation und nicht jede bereits eingereihte Antwort. Ein neuer Workerpfad muss deshalb Eigentümer, Snapshot, Rückgabeexecutor, Gültigkeitsprüfung und Abschluss-/Aufräumweg benennen. Locks schützen nur den aufgeführten Speicher; Dateikonflikte benötigen zusätzlich die bestehenden Identitäts-, Snapshot- und atomaren Schreibprüfungen.

Für Regressionen dienen insbesondere `WorkspaceParallelStressTests`, `DocumentLanguageDetectorTests`, Suchfreigabe-/verspätete-Antwort-Tests sowie die gezielten Git-, Markdown-Undo- und Drucktests. Ausgeführt werden sie über den [verbindlichen Build-/Testpfad](BUILD-AND-TEST.md); ein bestandener Stresstest beweist keine allgemeine Threadsicherheit.


## Verträge der ungeprüften Sendable-Typen

`@unchecked Sendable` bestätigt hier jeweils nur den folgenden Vertrag. Eine
Änderung an gespeichertem Zustand, Dispatcher oder Aufrufer muss ihn erneut
prüfen; die Annotation schützt den Typ nicht selbst.

| Typ | Schutz und Grenze |
| --- | --- |
| `SearchPlan` | Fertige, unveränderliche Regex und Wertdaten; keine spätere Regexmutation. |
| `DocumentLanguageDetector` | Lock für Aufträge und Generationen; Antwort auf Main, auch bei injiziertem Scheduler. |
| `DocumentLanguageDetector.Analysis` | Unveränderliche Format- und Grammatikdeskriptoren; kein geteilter Parser. |
| `DocumentLanguageDetector.DetectionResult` | Unveränderliche IDs, Revision und Analyse; erneute Prüfung auf Main. |
| `DocumentLanguageDetector.Cancellation` | Abbruchflag unter Lock; kein harter Parserabbruch. |
| `ExternalChangeInspector` | Lock für Request-IDs, unveränderlicher Reader; Abschluss auf Main. |
| `MarkdownRenderCoalescer` | Lock für wartende Aufträge und Revision; Parser seriell, gültige Antwort auf Main. |
| `FourDMacroCatalogCache` | Gesamter Cache einschließlich LRU unter Lock; Rückgabe von Wertarrays. |
| `FourDSignatureResolver.Cache` | Lesen und Schreiben der Signaturwerte unter Lock. |
| `FourDSignatureResolutionScheduler` | Lock für Aufträge und Generation; Dispatcher muss den Main-Vertrag erhalten. |
| `MarkdownImageStore.DirectoryLockRegistry` | Lock für Registry, eigener Lock je Zielordner; keine Sperre gegen Fremdprogramme. |
| `MarkdownImageUndoBuffer` | Lock für Einträge und Borrower; geliehene Daten bleiben bis zur Rückgabe erhalten. |
| `MarkdownImageUndoSideEffect` | Serielle Dateimutationen auf der Bild-I/O-Queue; Fehlertexte werden dort vor der Main-Completion als unveränderlicher Wert gesichert. Kein Instanzlock. |
| `MarkdownImageUndoFiles` | Dateimutationen und Fehlerabruf unter demselben seriellen Aufrufervertrag; Main erhält ausschließlich zuvor gesicherte Fehlertexte. Eigener Verzeichnis-FD und RAM-Ticket. |
| `MarkdownImageRemovalCheck` | Gelocktes Bool für die Main-Referenzfreigabe des Dateiarbeiters. |
| `SiblingFolderMenuContext` | Schwacher Workspace wird durch Worker mitgeführt, ausschließlich auf Main gelesen. |
| `PrintCompletionRelay` | Callback verschiebt Verarbeitung auf Main; dort genau ein Abschluss und WebViewabbau. |
| `GitCancellationToken` | Prozess- und Abbruchzustand unter Lock; Signale nach Unlock an gebundene Prozessidentitäten. |
| `GitPostSubmitDeadline` | Workitem und Ablaufstatus unter Lock; Cancel ist keine Barriere gegen einen schon laufenden Timeout. |
| `GitLockDecision` | Gelockte Entscheidung, die genau einmal gesetzt wird. |
| `BackgroundOnceResolver<Value>` | Lock für Veröffentlichung; ausgegebener Wert muss selbst sicher teilbar sein. Produktwert ist `String?`. |
| `GitOperationLease` | Cancellationclosure wird genau einmal unter Lock entnommen und danach auf dem Aufruferthread ausgeführt. |
| `GitOperationCancellationGate` | Gelockter Zustandsautomat für Abbruch und irreversible Schutzgrenze. |
| `FourDMacroEngine.DebuggerWatchesBackup` | Verzeichnis-FD wird unter Lock genau einmal übertragen; verbleibender Besitz endet in deinit. |
| `PreviewLoadCancellation` | Gelocktes Flag zwischen Main und Dateiarbeiter. |
| `FileLoadAcceptance` | Unveränderliche Closure mit Main-Aufrufervertrag; der Typ erzwingt diesen Executor noch nicht. |
| `Workspace.FolderApplyProgressRelay` | Worker dispatcht vor Zugriff auf den schwachen Workspace nach Main; Applygeneration erneut prüfen. |
| `Workspace.TextWorkflowDiskMutation` | Snapshot auf Worker, Modellfreigabe synchron auf Main, Editorzugriff erst im Main-Abschluss. |
| `RipgrepFileEnumerator.OutcomeBox` | Ergebnis unter Lock vor Semaphorsignal; Warten ausschließlich auf Worker. |

Neue UI-Besitzer sollen ihre Isolation wie `SearchResultSession` durch den
Compiler absichern. Der Swift-6-Sprachmodus bleibt ein Migrationsziel: Zuerst die
oben noch durch Aufrufer gesicherten Grenzen einzeln isolieren und ihre
Callbackreihenfolge prüfen. Eine globale Actorannotation oder ein bloßer Wechsel
des Sprachmodus ersetzt diese Arbeit nicht.
