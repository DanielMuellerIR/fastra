import SwiftUI
import AppKit

// SidebarScrollMemory.swift
//
// Merkt sich die Scrollposition der Seitenleisten-Listen über einen Wechsel
// des Seitenleisten-Tabs hinweg.
//
// Warum überhaupt: SwiftUI zeigt immer nur EINEN der drei Tabs (Dateien /
// Änderungen / Graph). Der Wechsel baut die vorherige Ansicht vollständig ab —
// mitsamt ihrer NSScrollView. Beim Zurückwechseln entsteht eine neue, die
// zwangsläufig am Listenanfang steht. Wer in einem langen Dateibaum weit unten
// arbeitet, verlor durch einen kurzen Blick in den Verlauf seine Stelle
// (Daniel-Befund 2026-08-24).

/// Speicher der zuletzt gesehenen Scrollpositionen, adressiert über einen
/// festen Schlüssel je Liste. Bewusst eine schlichte Klasse ohne
/// `@Published`: Der Wert ändert sich bei JEDER Scrollbewegung und dürfte
/// niemals ein SwiftUI-Update auslösen.
final class SidebarScrollMemory {
    /// Obergrenze der gemerkten Listen. Die Verlaufsansicht legt pro
    /// betrachteter Datei einen eigenen Schlüssel an; ohne Grenze wüchse der
    /// Speicher über eine lange Sitzung immer weiter.
    static let capacity = 64

    private var offsets: [String: CGFloat] = [:]
    /// Schlüssel in der Reihenfolge ihrer letzten Verwendung — ältester zuerst.
    private var order: [String] = []

    func offset(for key: String) -> CGFloat? { offsets[key] }

    func record(_ offset: CGFloat, for key: String) {
        offsets[key] = max(0, offset)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            offsets.removeValue(forKey: oldest)
        }
    }

    /// Wirft alle gemerkten Positionen weg.
    ///
    /// Nötig beim Projektwechsel: Die Schlüssel sind über alle Projekte hinweg
    /// dieselben (`fileTree`, `gitChanges`, `gitGraph` und je Datei ein
    /// Verlaufsschlüssel). Ohne Leerung öffnete ein neues Projekt an der
    /// Position, die im vorigen zuletzt galt — mitten im Dateibaum, in den
    /// Änderungen oder im Commit-Verlauf (Review-Fund 2026-08-25). Vorher gab
    /// es hier ein `forget(_:)` für einen einzelnen Schlüssel; es hatte im
    /// Produktcode nie einen Aufrufer.
    func removeAll() {
        offsets.removeAll()
        order.removeAll()
    }
}

/// Reine Rechnung der Wiederherstellung — ohne AppKit und deshalb testbar.
enum SidebarScrollRestore {
    /// Größtes tatsächlich erreichbares Scrollziel.
    ///
    /// `NSClipView.scroll(to:)` begrenzt ein Ziel NICHT selbst: Ein Wert
    /// jenseits der Dokumenthöhe wird scheinbar übernommen, und erst das
    /// nächste AppKit-Layout schnappt zurück an den Anfang (dieselbe Falle wie
    /// bei der Editor-Wiederherstellung, AGENTS.md). Deshalb hier selbst
    /// klemmen.
    static func reachable(target: CGFloat, documentHeight: CGFloat,
                          viewportHeight: CGFloat) -> CGFloat {
        let maximum = max(0, documentHeight - viewportHeight)
        return min(max(0, target), maximum)
    }

    /// Ist die Wiederherstellung fertig?
    ///
    /// Fertig heißt: Ziel erreicht oder Versuche aufgebraucht — sonst nichts.
    /// „Das Dokument gibt gerade nicht mehr her" wäre ein VERLOCKENDES, aber
    /// falsches Abbruchkriterium: Direkt nach dem Aufbau ist die LazyVStack
    /// noch leer, Dokumenthöhe und Sichtfenster sind gleich groß, und die
    /// Schleife bräche schon im ersten Versuch bei Position 0 ab — genau so
    /// blieb der Dateibaum nach dem Tab-Wechsel oben stehen (Selbsttest
    /// `sidebarstate`, 2026-08-24). Eine wirklich kürzer gewordene Liste
    /// kostet dafür ein paar wirkungslose Versuche; sichtbar ist davon
    /// nichts, weil jeder Versuch aufs Erreichbare geklemmt bleibt.
    static func isSettled(target: CGFloat, achieved: CGFloat,
                          attempt: Int, maximumAttempts: Int) -> Bool {
        attempt >= maximumAttempts || abs(achieved - target) < 1
    }
}

/// Null-große Brücke in die AppKit-Welt: Sie sitzt IM Inhalt der ScrollView
/// und findet darüber die echte `NSScrollView`, die auch der Nutzer bewegt.
struct SidebarScrollKeeper: NSViewRepresentable {
    let key: String
    let memory: SidebarScrollMemory

    func makeNSView(context: Context) -> SidebarScrollProbeView {
        let view = SidebarScrollProbeView(frame: .zero)
        view.configure(key: key, memory: memory)
        return view
    }

    func updateNSView(_ nsView: SidebarScrollProbeView, context: Context) {
        nsView.configure(key: key, memory: memory)
    }
}

/// Beobachtet die umgebende ScrollView und schreibt deren Position fort.
final class SidebarScrollProbeView: NSView {
    private var key = ""
    private var memory: SidebarScrollMemory?
    private var observation: NSObjectProtocol?
    /// Während der Wiederherstellung stammen die Bewegungen von uns selbst.
    /// Würden sie mitgeschrieben, überschriebe der Zwischenstand (typisch: 0
    /// direkt nach dem Aufbau) den gemerkten Wert, den wir gerade anstreben.
    private var isRestoring = false
    private static let maximumAttempts = 12

    func configure(key: String, memory: SidebarScrollMemory) {
        self.key = key
        self.memory = memory
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stopObserving()
            return
        }
        // Den Schutz VOR dem Observer setzen: Zwischen `startObserving()`
        // und dem absichtlich verzögerten `beginRestore()` kann AppKit schon
        // eine Bounds-Änderung für die frisch montierte ScrollView melden.
        // Ohne diesen frühen Wächter schrieb die Meldung Position 0 in den
        // Speicher und löschte genau das Ziel, das der nächste Main-Loop-
        // Durchlauf wiederherstellen sollte (CodeQA 2026-08-29).
        isRestoring = (memory?.offset(for: key) ?? 0) > 0
        startObserving()
        // Erst im nächsten Durchlauf: Direkt im Aufbau steht die Dokumenthöhe
        // der noch leeren LazyVStack fest bei null, jedes Ziel wäre auf null
        // geklemmt.
        DispatchQueue.main.async { [weak self] in
            self?.beginRestore()
        }
    }

    private func startObserving() {
        stopObserving()
        guard let clipView = enclosingScrollView?.contentView else {
            scrollDebug("\(key): keine ScrollView über dem Merker gefunden")
            return
        }
        clipView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isRestoring, self.window != nil,
                  let memory = self.memory,
                  let scrollView = self.enclosingScrollView else { return }
            memory.record(scrollView.contentView.bounds.origin.y, for: self.key)
        }
    }

    private func stopObserving() {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
        observation = nil
    }

    private func beginRestore() {
        guard let memory, let target = memory.offset(for: key), target > 0 else {
            // Der gespeicherte Wert kann zwischen Montage und diesem
            // verzögerten Einstieg entfernt worden sein, etwa beim
            // Projektwechsel. Dann darf der Observer wieder regulär
            // Nutzerbewegungen aufzeichnen.
            isRestoring = false
            scrollDebug("\(key): nichts wiederherzustellen "
                + "(gemerkt=\(memory?.offset(for: key).map { Int($0) }.map(String.init) ?? "nil"))")
            return
        }
        isRestoring = true
        restore(target: target, attempt: 0)
    }

    /// Zieht die Position in mehreren Anläufen nach. Ein LazyVStack legt seine
    /// Zeilen erst nach und nach aus; die Dokumenthöhe wächst also noch,
    /// während der erste Versuch längst gelaufen ist.
    private func restore(target: CGFloat, attempt: Int) {
        guard window != nil, let scrollView = enclosingScrollView else {
            isRestoring = false
            return
        }
        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let goal = SidebarScrollRestore.reachable(target: target,
                                                  documentHeight: documentHeight,
                                                  viewportHeight: viewportHeight)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: goal))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let achieved = scrollView.contentView.bounds.origin.y
        scrollDebug("\(key) versuch=\(attempt) ziel=\(Int(target)) "
            + "ist=\(Int(achieved)) dokHöhe=\(Int(documentHeight)) "
            + "sicht=\(Int(viewportHeight))")
        guard SidebarScrollRestore.isSettled(
            target: target, achieved: achieved,
            attempt: attempt, maximumAttempts: Self.maximumAttempts
        ) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.restore(target: target, attempt: attempt + 1)
            }
            return
        }
        isRestoring = false
        // Was am Ende wirklich eingestellt ist, gilt ab jetzt als gemerkter
        // Stand — sonst bliebe ein unerreichbares Ziel einer inzwischen
        // kürzeren Liste für immer stehen.
        memory?.record(achieved, for: key)
    }

    deinit {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    /// Diagnose der Positions-Wiederherstellung. Nur mit gesetzter
    /// Umgebungsvariable `FASTRA_SIDEBARSCROLL_DEBUG=1` aktiv; die
    /// `@autoclosure` baut den Text im Normalbetrieb gar nicht erst.
    private func scrollDebug(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["FASTRA_SIDEBARSCROLL_DEBUG"] == "1"
        else { return }
        FileHandle.standardError.write(Data(("SIDEBARSCROLL " + message() + "\n").utf8))
    }
}

extension View {
    /// Hängt den Positionsmerker in den Inhalt einer Seitenleisten-Liste.
    /// Aufzurufen INNERHALB der ScrollView (etwa am inneren Stack), sonst
    /// findet er die ScrollView nicht.
    func sidebarScrollRetention(key: String, memory: SidebarScrollMemory) -> some View {
        background(SidebarScrollKeeper(key: key, memory: memory)
            .frame(width: 0, height: 0))
    }
}
