// FourDSignatureHelpTests.swift
//
// Pure Logik der 4D-Parameterhilfe: Signatur-Parser für beide
// Deklarationsstile, Kommentarkopf und Aufrufkontext unter dem Cursor.
// Alle Fixtures sind selbst geschrieben (nichts aus Arbeitsprojekten).

import Foundation
import Testing
@testable import Fastra

private final class SignatureWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}

// MARK: - Parser: #DECLARE

@Test("#DECLARE mit benannten Parametern, Typen und Rückgabe")
func parsesDeclareSignature() {
    let source = """
    //%attributes = {}
    // Liefert eine Grußformel.
    // Zweite Kopfzeile.
    #DECLARE($name_t : Text; $anzahl_i : Integer)->$gruss_t : Text
    $gruss_t:="Hallo "+$name_t
    """
    let signature = FourDSignatureParser.parse(methodSource: source)
    #expect(signature.parameters == [
        .init(name: "$name_t", type: "Text"),
        .init(name: "$anzahl_i", type: "Integer"),
    ])
    #expect(signature.returnParameter == .init(name: "$gruss_t", type: "Text"))
    #expect(signature.headerComment == "// Liefert eine Grußformel.\n// Zweite Kopfzeile.")
}

@Test("#DECLARE mit tokenisiertem Export-Suffix und Klassentyp")
func parsesDeclareWithClassTypes() {
    let source = "#DECLARE($kunde_e : cs.Kunde; $datei : 4D.File)"
    let signature = FourDSignatureParser.parse(methodSource: source)
    #expect(signature.parameters == [
        .init(name: "$kunde_e", type: "cs.Kunde"),
        .init(name: "$datei", type: "4D.File"),
    ])
    #expect(signature.returnParameter == nil)
}

@Test("#DECLARE ohne Parameter")
func parsesEmptyDeclare() {
    let signature = FourDSignatureParser.parse(methodSource: "#DECLARE()")
    #expect(signature.parameters.isEmpty)
}

// MARK: - Parser: klassische C_-Deklarationen

@Test("C_-Deklarationen: $N-Parameter, $0-Rückgabe, Nicht-Parameter bleiben außen vor")
func parsesClassicDeclarations() {
    // Wie im 4D-Export: `:Cnnn`-Suffix und gemischte Deklarationen, in denen
    // Prozess-/Interprozessvariablen zusammen mit Parametern stehen.
    let source = """
    // Alte Methode.
    C_BOOLEAN:C305($1)
    C_TEXT:C284($2;$4;$keinParameter_t;prozessVar_t;<>interprozessVar_t)
    C_LONGINT:C283($0)
    C_DATE:C307($lokal_d)
    """
    let signature = FourDSignatureParser.parse(methodSource: source)
    #expect(signature.parameters == [
        .init(name: "$1", type: "Boolean"),
        .init(name: "$2", type: "Text"),
        .init(name: "$3", type: nil),
        .init(name: "$4", type: "Text"),
    ])
    #expect(signature.returnParameter == .init(name: "$0", type: "Longint"))
}

@Test("C_-Deklaration mit ${N} kennzeichnet variable Parameter")
func parsesClassicVariadic() {
    let source = "C_TEXT:C284($1;${2})"
    let signature = FourDSignatureParser.parse(methodSource: source)
    #expect(signature.parameters == [
        .init(name: "$1", type: "Text"),
        .init(name: "${2}…", type: "Text"),
    ])
}

// MARK: - Parser: Kommentarkopf

@Test("Kommentarkopf endet an der ersten Nicht-Kommentar-Zeile")
func headerCommentStopsAtCode() {
    let source = """
    //%attributes = {}
    // Kopfzeile eins
    /* Blockkommentar
    über mehrere Zeilen
    */
    ALERT("Code")
    // Dieser Kommentar gehört nicht mehr zum Kopf.
    """
    let signature = FourDSignatureParser.parse(methodSource: source)
    #expect(signature.headerComment == """
    // Kopfzeile eins
    /* Blockkommentar
    über mehrere Zeilen
    */
    """.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test("Methode ohne Kopfkommentar liefert leeren Kopf")
func headerCommentEmptyWithoutComments() {
    let signature = FourDSignatureParser.parse(methodSource: "ALERT(\"x\")")
    #expect(signature.headerComment.isEmpty)
}

// MARK: - Aufrufkontext

@Test("Cursor direkt hinter der offenen Klammer: Parameter 0")
func contextAfterOpenParen() {
    let text = "Meine Methode("
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context == FourDCallContext(
        methodName: "Meine Methode",
        openParenLocation: 13,
        activeParameterIndex: 0
    ))
}

@Test("Semikolons bestimmen den aktiven Parameter")
func contextCountsSemicolons() {
    let text = "Rechne($a;$b;$c"
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context?.activeParameterIndex == 2)
}

@Test("Mit geschlossener Klammer gilt die Hilfe zwischen beiden Klammern")
func contextInsideClosedParens() {
    let text = "Rechne($a;$b) und mehr"
    let inside = FourDSignatureHelpLogic.callContext(in: text, utf16CursorLocation: 9)
    #expect(inside?.methodName == "Rechne")
    let behind = FourDSignatureHelpLogic.callContext(in: text, utf16CursorLocation: 14)
    #expect(behind == nil)
}

@Test("Verschachtelte Aufrufe: der innerste gewinnt")
func contextInnermostCall() {
    let text = "Aussen(Innen($x"
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context?.methodName == "Innen")
    #expect(context?.activeParameterIndex == 0)
}

@Test("Keywords, Strings und Kommentare liefern keinen Kontext")
func contextSkipsKeywordsStringsComments() {
    #expect(FourDSignatureHelpLogic.callContext(
        in: "If (True", utf16CursorLocation: 8
    ) == nil)
    let inString = "ALERT(\"Methode(\")"
    #expect(FourDSignatureHelpLogic.callContext(
        in: inString, utf16CursorLocation: 15
    )?.methodName == "ALERT")
    #expect(FourDSignatureHelpLogic.callContext(
        in: "// Methode(", utf16CursorLocation: 11
    ) == nil)
}

@Test("Semikolons in String-Argumenten zählen nicht")
func contextIgnoresSemicolonsInStrings() {
    let text = "Rechne(\"a;b\";$c"
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context?.activeParameterIndex == 1)
}

@Test("Member- und Variablenaufrufe sind keine Methodenhilfe-Ziele")
func contextSkipsMembersAndVariables() {
    let member = "$obj.machWas($x"
    #expect(FourDSignatureHelpLogic.callContext(
        in: member, utf16CursorLocation: (member as NSString).length
    ) == nil)
}

// MARK: - Methodendatei-Auflösung

@Test("methodFileURL findet die Methode unter Project/Sources/Methods")
func resolvesMethodFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-sig-\(UUID().uuidString)")
    let methods = root.appendingPathComponent("Project/Sources/Methods")
    try FileManager.default.createDirectory(
        at: methods, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let file = methods.appendingPathComponent("Begruessung.4dm")
    try "#DECLARE($n : Text)\n".write(to: file, atomically: true, encoding: .utf8)

    let viaProject = FourDSignatureHelpLogic.methodFileURL(
        named: "Begruessung", projectURL: root, documentURL: nil
    )
    #expect(viaProject?.lastPathComponent == "Begruessung.4dm")

    // Auch ohne Projekt: Nachbarmethode der gerade geöffneten Datei.
    let sibling = methods.appendingPathComponent("Aufrufer.4dm")
    let viaDocument = FourDSignatureHelpLogic.methodFileURL(
        named: "Begruessung", projectURL: nil, documentURL: sibling
    )
    #expect(viaDocument?.lastPathComponent == "Begruessung.4dm")
}

@Test("Signatur-Cache folgt einem umgehängten Methoden-Symlink")
func signatureCache_resolvesSymlinkBeforeKeying() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-siglink-\(UUID().uuidString)")
    let methods = root.appendingPathComponent("Project/Sources/Methods")
    try FileManager.default.createDirectory(at: methods,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("erste.4dm")
    let second = root.appendingPathComponent("zweite.4dm")
    try "#DECLARE($a : Text)".write(to: first, atomically: true, encoding: .utf8)
    try "#DECLARE($a : Integer)".write(to: second, atomically: true, encoding: .utf8)
    let sameDate = Date(timeIntervalSince1970: 1_800_000_000)
    try FileManager.default.setAttributes([.modificationDate: sameDate],
                                          ofItemAtPath: first.path)
    try FileManager.default.setAttributes([.modificationDate: sameDate],
                                          ofItemAtPath: second.path)
    let link = methods.appendingPathComponent("Methode.4dm")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
    let request = FourDSignatureResolver.Request(
        lowered: "methode", projectMethodFileName: "Methode",
        projectURL: root, documentURL: nil, componentMethod: nil)
    let cache = FourDSignatureResolver.Cache()

    guard case .signature(let firstSignature, _) =
            FourDSignatureResolver.title(for: request, cache: cache) else {
        Issue.record("Erste Signatur fehlt")
        return
    }
    #expect(firstSignature.parameters.first?.type == "Text")

    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
    guard case .signature(let secondSignature, _) =
            FourDSignatureResolver.title(for: request, cache: cache) else {
        Issue.record("Zweite Signatur fehlt")
        return
    }
    #expect(secondSignature.parameters.first?.type == "Integer")
}

@Test("Signatur-Auflösung führt nur laufende und jüngste Anforderung aus")
@MainActor
func signatureResolution_coalescesArchiveWork() async {
    let scheduler = FourDSignatureResolutionScheduler()
    let recorder = SignatureWorkRecorder()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func request(_ name: String) -> FourDSignatureResolver.Request {
        .init(lowered: name, projectMethodFileName: nil,
              projectURL: nil, documentURL: nil, componentMethod: nil)
    }

    scheduler.submit(key: request("erste"), work: {
        recorder.append("erste")
        started.signal()
        _ = release.wait(timeout: .now() + 10)
        return .command("erste")
    }, completion: { _ in })
    #expect(started.wait(timeout: .now() + 10) == .success)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        for name in ["zweite", "dritte", "letzte"] {
            scheduler.submit(key: request(name), work: {
                recorder.append(name)
                return .command(name)
            }, completion: { _ in
                if name == "letzte" { continuation.resume() }
            })
        }
        release.signal()
    }
    #expect(recorder.snapshot == ["erste", "letzte"])
}

// MARK: - Kommentare (Review 2026-08-02)

@Test("Blockkommentar in der Zeile: Cursor darin bekommt keine Hilfe")
func contextInsideInlineBlockComment() {
    let text = "Rechne($a) /* Notiz("
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context == nil)
}

@Test("Geschlossener Blockkommentar vor dem Aufruf stört die Hilfe nicht")
func contextAfterClosedBlockComment() {
    let text = "/* Kopf */ Rechne($a"
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context?.methodName == "Rechne")
}

@Test("Mehrzeiliger Blockkommentar: Zeile darin bekommt keine Hilfe")
func contextInsideMultilineBlockComment() {
    let text = "/* Anfang\nRechne($a"
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context == nil)
    // Nach dem schließenden `*/` gilt die Hilfe wieder.
    let closed = "/* Anfang\n*/\nRechne($a"
    let after = FourDSignatureHelpLogic.callContext(
        in: closed, utf16CursorLocation: (closed as NSString).length
    )
    #expect(after?.methodName == "Rechne")
}

@Test("isInsideCommentOrString erkennt Zeilen-, Block-Kommentar und String")
func insideCommentOrString() {
    // Zeilenkommentar.
    let line = "code // Prosa"
    #expect(FourDSignatureHelpLogic.isInsideCommentOrString(
        in: line, utf16Location: (line as NSString).length))
    // Blockkommentar über Zeilen hinweg.
    let block = "/* Anfang\nmitten"
    #expect(FourDSignatureHelpLogic.isInsideCommentOrString(
        in: block, utf16Location: (block as NSString).length))
    // String-Literal — auch mit escaptem Anführungszeichen.
    let string = "ALERT(\"Hallo \\\"Du"
    #expect(FourDSignatureHelpLogic.isInsideCommentOrString(
        in: string, utf16Location: (string as NSString).length))
    // Normaler Code bleibt frei.
    let code = "ALERT(Variable"
    #expect(!FourDSignatureHelpLogic.isInsideCommentOrString(
        in: code, utf16Location: (code as NSString).length))
    // Hinter einem GESCHLOSSENEN String/Kommentar ebenfalls frei.
    let closed = "\"Text\" /* x */ code"
    #expect(!FourDSignatureHelpLogic.isInsideCommentOrString(
        in: closed, utf16Location: (closed as NSString).length))
}
