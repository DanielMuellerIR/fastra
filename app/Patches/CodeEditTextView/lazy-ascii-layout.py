#!/usr/bin/env python3
"""Langzeilen: ASCII-Geometrie ohne dokumentweite CoreText-Glyphenobjekte."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
base = root / 'Sources/CodeEditTextView'
paths = {
 'fragment': base / 'TextLine/LineFragment.swift',
 'typesetter': base / 'TextLine/Typesetter/Typesetter.swift',
 'line': base / 'TextLine/TextLine.swift',
 'public': base / 'TextLayoutManager/TextLayoutManager+Public.swift',
}
source = {key: path.read_text() for key, path in paths.items()}
marker = 'Fastra-Patch: ASCII-Megazeilen mit bedarfsgesteuerten Glyphen'


def prepare_color_sources(source, paths, base):
    def once(old, new):
        if source['typesetter'].count(old) != 1:
            raise SystemExit('Farbmetrik-Anker fehlt oder ist mehrdeutig')
        source['typesetter'] = source['typesetter'].replace(old, new, 1)
    if 'func preservesGeometry(afterAttributeChangeIn' not in source['typesetter']:
        once('    let cellWidth: CGFloat', '    let cellWidth: CGFloat\n    private let initialMetrics: [NSAttributedString.Key: Any]')
        once('init(storage: NSTextStorage, documentStart: Int, cellWidth: CGFloat)',
             'init(storage: NSTextStorage, documentStart: Int, cellWidth: CGFloat, attributes: [NSAttributedString.Key: Any])')
        once('        self.cellWidth = cellWidth\n', '''        self.cellWidth = cellWidth
        self.initialMetrics = Dictionary(uniqueKeysWithValues: Self.metricKeys.compactMap { key in
            guard let value = attributes[key] else { return nil }
            return (key, (value as? NSCopying)?.copy(with: nil) ?? value)
        })
''')
        once('cellWidth: cellWidth)\n        fastraASCIITextSource',
             'cellWidth: cellWidth, attributes: attributes)\n        fastraASCIITextSource')
        once('    func line(in range: NSRange) -> CTLine {', '''    private static let metricKeys: [NSAttributedString.Key] = [.font, .kern, .paragraphStyle, .ligature]
    private static let safeKeys: Set<NSAttributedString.Key> = [
        .font, .foregroundColor, .backgroundColor, .kern, .paragraphStyle, .ligature,
        .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor, .toolTip, .link, .cursor
    ]

    // Nur Attribute mit unveraenderter Metrik duerfen die vollstaendige
    // Rangetabelle behalten; neue Glyphen lesen Farben stets aktuell.
    func preservesGeometry(afterAttributeChangeIn range: NSRange, storage: NSTextStorage) -> Bool {
        guard range.location >= 0, range.location <= storage.length,
              range.length <= storage.length - range.location else { return false }
        var unchanged = true
        storage.enumerateAttributes(in: range) { current, _, stop in
            let matches = Self.metricKeys.allSatisfy { key in
                if current[key] == nil && self.initialMetrics[key] == nil { return true }
                guard let lhs = current[key] as? NSObject,
                      let rhs = self.initialMetrics[key] as? NSObject else { return false }
                return lhs.isEqual(rhs)
            }
            if !matches || !Set(current.keys).isSubset(of: Self.safeKeys) {
                unchanged = false
                stop.pointee = true
            }
        }
        return unchanged
    }

    func line(in range: NSRange) -> CTLine {''')
    edits_path = base / 'TextLayoutManager/TextLayoutManager+Edits.swift'
    edits = edits_path.read_text()
    color_marker = 'Fastra-Patch: reine Farbwechsel behalten die Festzellengeometrie'
    if color_marker not in edits:
        old = '''            if editedMask.contains(.editedAttributes) && delta == 0 {
                invalidateLayoutForRange(editedRange)
            }'''
        if edits.count(old) != 1: raise SystemExit('Attribut-Aenderungsanker fehlt')
        edits = edits.replace(old, '''            if editedMask.contains(.editedAttributes) && delta == 0 {
                fastraInvalidateChangedAttributes(in: editedRange, storage: textStorage)
            }''', 1)
        edits += '''

extension TextLayoutManager {
    // Fastra-Patch: reine Farbwechsel behalten die Festzellengeometrie.
    // Der Aufruf liegt ausschliesslich im Zweig ohne Zeichen-Aenderung;
    // echtes Tippen, Einfuegen und Loeschen invalidiert weiterhin normal.
    private func fastraInvalidateChangedAttributes(in range: NSRange, storage: NSTextStorage) {
        var needsRelayout = false
        for line in lineStorage.linesInRange(range) {
            if let source = line.data.typesetter.fastraASCIITextSource,
               let changed = range.intersection(line.range),
               source.preservesGeometry(afterAttributeChangeIn: changed, storage: storage) {
                source.rebase(documentStart: line.range.location)
                continue
            }
            line.data.setNeedsLayout()
            needsRelayout = true
        }
        if range.location == storage.length, !lineStorage.isEmpty {
            lineStorage.last?.data.setNeedsLayout()
            needsRelayout = true
        }
        if needsRelayout { layoutView?.needsLayout = true }
        // Auch die Minimap haelt farbige Zeichenlaeufe im View vor. Nur den
        // sichtbaren Ausschnitt neu befuellen; keine Millionen Zeilen bauen.
        for case let view as LineFragmentView in layoutView?.subviews ?? [] {
            // Versteckte Wiederverwendungs-Views behalten ihre Null-Geometrie.
            guard !view.isHidden, let fragment = view.lineFragment,
                  fragment.documentRange.location != NSNotFound,
                  let intersection = fragment.documentRange.intersection(range),
                  intersection.length > 0 else { continue }
            view.setLineFragment(fragment, fragmentRange: fragment.documentRange,
                                 renderer: lineFragmentRenderer)
            view.needsDisplay = true
        }
    }
}
'''
    old_refresh = '            guard let fragment = view.lineFragment,'
    if color_marker in edits and old_refresh in edits:
        edits = edits.replace(old_refresh, '            guard !view.isHidden, let fragment = view.lineFragment,', 1)
    required = ['fastraInvalidateChangedAttributes(in: editedRange, storage: textStorage)',
                'source.preservesGeometry(afterAttributeChangeIn: changed, storage: storage)',
                'view.setLineFragment(fragment, fragmentRange: fragment.documentRange,',
                'guard editedMask.contains(.editedCharacters) else {', 'guard !view.isHidden, let fragment = view.lineFragment,']
    if any(value not in edits for value in required): raise SystemExit('Farbinvalidierung-Selbstpruefung fehlgeschlagen')
    if 'func preservesGeometry(afterAttributeChangeIn' not in source['typesetter'] or 'private let initialMetrics:' not in source['typesetter']:
        raise SystemExit('Farbmetrik-Selbstpruefung fehlgeschlagen')
    return edits_path, edits


def finalize_sources():
    # V2 uebernimmt auch einen bereits angewandten V1-Patch. Ein unveraenderter
    # Lauf prueft alle Integrationsstellen erneut, nicht bloss den Marker.
    iterator_path = base / 'TextLayoutManager/TextLayoutManager+Iterator.swift'
    iterator = iterator_path.read_text()
    v2 = 'Fastra-Patch: Lazy-Quellen folgen verschobenen logischen Zeilen'
    if v2 not in source['typesetter']:
        def once(key, old, new):
            if source[key].count(old) != 1:
                raise SystemExit(f'{paths[key]}: V2-Anker fehlt oder ist mehrdeutig')
            source[key] = source[key].replace(old, new, 1)
        once('typesetter', '    private lazy var fragmentGeneration = UUID()',
             '    private lazy var fragmentGeneration = UUID()\n    var fastraASCIITextSource: FastraASCIITextSource?')
        once('typesetter', '    private let documentStart: Int', '    private var documentStart: Int')
        once('typesetter', '    func line(in range: NSRange) -> CTLine {',
             '    // Fastra-Patch: Lazy-Quellen folgen verschobenen logischen Zeilen.\n'
             '    func rebase(documentStart: Int) { self.documentStart = documentStart }\n\n'
             '    func line(in range: NSRange) -> CTLine {')
        once('typesetter', '        let source = FastraASCIITextSource(storage: storage, documentStart: documentRange.location)',
             '        let source = FastraASCIITextSource(storage: storage, documentStart: documentRange.location)\n'
             '        fastraASCIITextSource = source')
        once('typesetter', '        let string = makeString(string: string, markedRanges: markedRanges)',
             '        fastraASCIITextSource = nil\n        let string = makeString(string: string, markedRanges: markedRanges)')
    if v2 not in iterator:
        old = '        let attachments = attachments.getAttachmentsOverlapping(originalPosition.position.range)'
        if iterator.count(old) != 1:
            raise SystemExit(f'{iterator_path}: V2-Rebase-Anker fehlt oder ist mehrdeutig')
        iterator = iterator.replace(old,
            '        // Fastra-Patch: Lazy-Quellen folgen verschobenen logischen Zeilen.\n'
            '        // Auch unveraenderte Folgezeilen verschieben sich nach einer\n'
            '        // Aenderung davor; Glyphen lesen stets den aktuellen Bereich.\n'
            '        originalPosition.position.data.typesetter.fastraASCIITextSource?.rebase(\n'
            '            documentStart: originalPosition.position.range.location\n'
            '        )\n\n' + old, 1)
    if 'public var fastraIsText: Bool' not in source['fragment']:
        old = '        var fastraASCIIStart: Int? { asciiSource == nil ? nil : asciiRange.location }'
        if source['fragment'].count(old) != 1:
            raise SystemExit('ASCII-Textart-Anker fehlt')
        source['fragment'] = source['fragment'].replace(old, old + '\n\n'
            '        /// Textart ohne die bedarfsgesteuerte CTLine zu erzeugen.\n'
            '        public var fastraIsText: Bool {\n'
            '            if asciiSource != nil { return true }\n'
            '            if case .text = eagerData! { return true }\n'
            '            return false\n'
            '        }', 1)
    if 'func fastraASCIIXPosition(' not in source['fragment']:
        def once_geometry(key, old, new):
            if source[key].count(old) != 1:
                raise SystemExit(f'{paths[key]}: ASCII-Geometrie-Anker fehlt')
            source[key] = source[key].replace(old, new, 1)
        once_geometry('typesetter', '    private var documentStart: Int',
                      '    private var documentStart: Int\n    let cellWidth: CGFloat')
        once_geometry('typesetter', '    init(storage: NSTextStorage, documentStart: Int) {',
                      '    init(storage: NSTextStorage, documentStart: Int, cellWidth: CGFloat) {')
        once_geometry('typesetter', '        self.documentStart = documentStart\n',
                      '        self.documentStart = documentStart\n        self.cellWidth = cellWidth\n')
        once_geometry('typesetter', 'let source = FastraASCIITextSource(storage: storage, documentStart: documentRange.location)',
                      'let source = FastraASCIITextSource(storage: storage, documentStart: documentRange.location, cellWidth: cellWidth)')
        once_geometry('fragment', '        var fastraASCIIStart: Int?',
            '        /// Die gepruefte Zellmetrik braucht auch fuer ferne Cursor keine Glyphen.\n'
            '        func fastraASCIIXPosition(_ offset: Int) -> CGFloat? {\n'
            '            guard let asciiSource else { return nil }\n'
            '            return min(width, CGFloat(max(offset, 0)) * asciiSource.cellWidth)\n'
            '        }\n\n        var fastraASCIIStart: Int?')
        once_geometry('fragment', '        switch content.data {',
                      '        if let x = content.fastraASCIIXPosition(offset - position.offset) {\n'
                      '            return position.xPos + x\n        }\n        switch content.data {')
    if 'public var fastraHasFixedCells: Bool' not in source['fragment']:
        old = '        var fastraASCIIStart: Int?'
        if source['fragment'].count(old) != 1: raise SystemExit('Festzellen-Marker-Anker fehlt')
        source['fragment'] = source['fragment'].replace(old,
            '        public var fastraHasFixedCells: Bool { asciiSource != nil }\n\n' + old, 1)
        old = '    public let id: FragmentID'
        if source['fragment'].count(old) != 1: raise SystemExit('Fragment-Marker-Anker fehlt')
        source['fragment'] = source['fragment'].replace(old,
            '    /// Nur gepruefte, monotone Festzellen duerfen arithmetisch beschnitten werden.\n'
            '    public var fastraHasFixedCells: Bool {\n'
            '        !contents.isEmpty && contents.allSatisfy(\\.fastraHasFixedCells)\n'
            '    }\n\n' + old, 1)
    edits_path, edits = prepare_color_sources(source, paths, base)
    if 'static func equalMetric(' not in source['typesetter']:
        old = '    private static let metricKeys: [NSAttributedString.Key]'
        if source['typesetter'].count(old) != 1: raise SystemExit('Kern-Normalisierungsanker fehlt')
        source['typesetter'] = source['typesetter'].replace(old,
            '    // Die initialen Textattribute lassen Kern aus; der Highlighter\n'
            '    // ergaenzt explizit null. Beide bedeuten hier dieselbe Zellmetrik.\n'
            '    static func equalMetric(_ key: NSAttributedString.Key, _ lhs: Any?, _ rhs: Any?) -> Bool {\n'
            '        let left: Any? = key == .kern ? (lhs ?? NSNumber(value: 0)) : lhs\n'
            '        let right: Any? = key == .kern ? (rhs ?? NSNumber(value: 0)) : rhs\n'
            '        if left == nil && right == nil { return true }\n'
            '        guard let left = left as? NSObject, let right = right as? NSObject else { return false }\n'
            '        return left.isEqual(right)\n    }\n\n' + old, 1)
        old = '''                if current[key] == nil && self.initialMetrics[key] == nil { return true }
                guard let lhs = current[key] as? NSObject,
                      let rhs = self.initialMetrics[key] as? NSObject else { return false }
                return lhs.isEqual(rhs)'''
        if source['typesetter'].count(old) != 1: raise SystemExit('Farb-Kern-Normalisierungsanker fehlt')
        source['typesetter'] = source['typesetter'].replace(old,
            '                Self.equalMetric(key, current[key], self.initialMetrics[key])', 1)
        old = '!Self.fastraEqualAttribute(attributes[$0], current[$0])'
        if source['typesetter'].count(old) != 1: raise SystemExit('Uniform-Kern-Normalisierungsanker fehlt')
        source['typesetter'] = source['typesetter'].replace(old,
            '!FastraASCIITextSource.equalMetric($0, attributes[$0], current[$0])', 1)
        old = '''    private static func fastraEqualAttribute(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }

'''
        if source['typesetter'].count(old) != 1: raise SystemExit('Alter Metrikvergleich fehlt oder ist mehrdeutig')
        source['typesetter'] = source['typesetter'].replace(old, '', 1)
    if ('!FastraASCIITextSource.equalMetric($0, attributes[$0], current[$0])' not in source['typesetter']
            or 'Self.equalMetric(key, current[key], self.initialMetrics[key])' not in source['typesetter']
            or 'key == .kern ? (lhs ?? NSNumber(value: 0)) : lhs' not in source['typesetter']):
        raise SystemExit('Kern-Normalisierungs-Selbstpruefung fehlgeschlagen')
    required = {
        'fragment': ['return .text(line: asciiSource!.line(in: asciiRange))',
                     'if asciiSource != nil { return asciiRange.length }',
                     'return switch eagerData!', 'var fastraASCIIStart: Int?', 'public var fastraIsText: Bool', 'func fastraASCIIXPosition(', 'content.fastraASCIIXPosition(offset - position.offset)', 'public var fastraHasFixedCells: Bool'],
        'line': ['if typesetter.typesetFastraASCII(', 'stringRef, documentRange: clampedRange'],
        'public': ['content.fastraASCIIStart ?? contentPosition.offset'],
        'typesetter': ['var fastraASCIITextSource: FastraASCIITextSource?',
                      'fastraASCIITextSource = source', 'fastraASCIITextSource = nil',
                      'private var documentStart: Int', 'func rebase(documentStart: Int)',
                      'CTLineCreateWithAttributedString(storage.attributedSubstring(from: safe))',
                      'units[..<textEnd]', 'let extraLetters =', 'CTLineGetGlyphCount(probeLine)',
                      'lineFragments.build(from: fragments,', 'Fastra-Patch: ASCII-Megazeilen']
    }
    for key, snippets in required.items():
        if marker not in source[key] or any(snippet not in source[key] for snippet in snippets):
            raise SystemExit(f'{paths[key]}: ASCII-Selbstpruefung fehlgeschlagen')
    if source['line'].index('if typesetter.typesetFastraASCII(') > source['line'].index('let string: NSAttributedString = if'):
        raise SystemExit('ASCII-Schnellpfad laeuft erst nach der Attributkopie')
    if v2 not in iterator or 'originalPosition.position.data.typesetter.fastraASCIITextSource?.rebase(' not in iterator:
        raise SystemExit(f'{iterator_path}: Lazy-Rebase-Selbstpruefung fehlgeschlagen')
    structs_path = base / 'TextLineStorage/TextLineStorage+Structs.swift'
    structs = structs_path.read_text()
    # Der V1-Minimap-Patch brauchte einen öffentlichen Initializer. Nach dem
    # Höhenabgleich im vorhandenen Baum bleibt nur der interne Memberwise-Init.
    legacy_initializer = '''
        // Fastra-Patch: linearer Geometrieaufbau fuer Render-Delegates.
        public init(data: Data, length: Int, height: CGFloat?) {
            self.data = data
            self.length = length
            self.height = height
        }
'''
    structs = structs.replace(legacy_initializer, '')
    if 'Fastra-Patch: linearer Geometrieaufbau fuer Render-Delegates' in structs:
        raise SystemExit(f'{structs_path}: unbekannter alter BuildItem-Initializer')
    changed = False
    for key, value in source.items():
        if paths[key].read_text() != value:
            paths[key].chmod(paths[key].stat().st_mode | 0o200)
            paths[key].write_text(value)
            changed = True
    if iterator_path.read_text() != iterator:
        iterator_path.chmod(iterator_path.stat().st_mode | 0o200)
        iterator_path.write_text(iterator)
        changed = True
    if structs_path.read_text() != structs:
        structs_path.chmod(structs_path.stat().st_mode | 0o200)
        structs_path.write_text(structs)
        changed = True
    if edits_path.read_text() != edits:
        edits_path.chmod(edits_path.stat().st_mode | 0o200)
        edits_path.write_text(edits)
        changed = True
    print('changed' if changed else 'unchanged')

if all(marker in value for value in source.values()):
    finalize_sources()
    sys.exit(0)
if any(marker in value for value in source.values()):
    raise SystemExit('ASCII-Megazeilen-Patch ist nur teilweise vorhanden')

def replace(key, old, new):
 if source[key].count(old) != 1:
  raise SystemExit(f'{paths[key]}: erwarteter ASCII-Patch-Anker fehlt oder ist mehrdeutig')
 source[key] = source[key].replace(old, new, 1)

replace('fragment', '''        public let data: Content
        public let width: CGFloat

        public var length: Int {
            switch data {''', '''        // Fastra-Patch: ASCII-Megazeilen mit bedarfsgesteuerten Glyphen.
        // Offscreen-Fragmente speichern nur eine Range. Erst Zeichnen oder
        // Hit-Testing erzeugt eine kleine CTLine aus dem aktuellen Textspeicher.
        private let eagerData: Content?
        private let asciiSource: FastraASCIITextSource?
        private let asciiRange: NSRange
        public let width: CGFloat

        public var data: Content {
            if let eagerData { return eagerData }
            return .text(line: asciiSource!.line(in: asciiRange))
        }

        var fastraASCIIStart: Int? { asciiSource == nil ? nil : asciiRange.location }

        init(data: Content, width: CGFloat) {
            self.eagerData = data
            self.asciiSource = nil
            self.asciiRange = .zero
            self.width = width
        }

        init(asciiSource: FastraASCIITextSource, range: NSRange, width: CGFloat) {
            self.eagerData = nil
            self.asciiSource = asciiSource
            self.asciiRange = range
            self.width = width
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            if lhs.asciiSource != nil || rhs.asciiSource != nil {
                return lhs.asciiSource === rhs.asciiSource
                    && lhs.asciiRange == rhs.asciiRange && lhs.width == rhs.width
            }
            return lhs.eagerData == rhs.eagerData && lhs.width == rhs.width
        }

        public var length: Int {
            if asciiSource != nil { return asciiRange.length }
            return switch eagerData! {''')
replace('public', '''            return fragmentIndex + contentPosition.offset + linePosition.range.location''', '''            // Fastra-Patch: ASCII-Megazeilen mit bedarfsgesteuerten Glyphen.
            // Eine lokale CTLine beginnt bei null; ihre Quellrange beginnt
            // dagegen auch mitten in einer logischen Zeile.
            return fragmentIndex + (content.fastraASCIIStart ?? contentPosition.offset)
                + linePosition.range.location''')
replace('line', '''        // Fastra-Patch: dokumentweite Megazeile ohne Attributkopie.''', '''        // Fastra-Patch: ASCII-Megazeilen mit bedarfsgesteuerten Glyphen.
        // Vor attributedSubstring pruefen, damit auch ein grosses Stringfeld
        // in mehrzeiligem JSON keine vollstaendige Attributkopie erzeugt.
        if typesetter.typesetFastraASCII(
            stringRef, documentRange: clampedRange, displayData: displayData,
            markedRanges: markedRanges, attachments: attachments
        ) {
            self.maxWidth = displayData.maxWidth
            lastSoftWrapIndentation = displayData.softWrapIndentation
            lastSoftWrapIndentationColumns = displayData.softWrapIndentationColumns
            needsLayout = false
            return
        }
        // Fastra-Patch: dokumentweite Megazeile ohne Attributkopie.''')
source['typesetter'] += r'''

// Fastra-Patch: ASCII-Megazeilen mit bedarfsgesteuerten Glyphen.
// Ein Objekt pro logischer Zeile; es haelt weder eine Attributkopie noch
// CTLines fest. Alle Zugriffe erfolgen wie das regulaere Layout auf Main.
final class FastraASCIITextSource {
    private weak var storage: NSTextStorage?
    private let documentStart: Int

    init(storage: NSTextStorage, documentStart: Int) {
        self.storage = storage
        self.documentStart = documentStart
    }

    func line(in range: NSRange) -> CTLine {
        guard let storage else {
            return CTLineCreateWithAttributedString(NSAttributedString(string: ""))
        }
        // Undo darf waehrend einer Layouttransaktion alte Views noch kurz
        // vorhalten. Die Range wird wie im regulaeren TextLine-Pfad geklemmt.
        let start = min(documentStart + range.location, storage.length)
        let safe = NSRange(location: start, length: min(range.length, storage.length - start))
        return CTLineCreateWithAttributedString(storage.attributedSubstring(from: safe))
    }
}

extension Typesetter {
    /// Reiner ASCII in einheitlicher Festbreitenschrift hat exakte Zellbreiten.
    /// Unicode, Tabs, Attachments und abweichende Metrik bleiben bei CoreText.
    /// Die Range-/Hoehenstruktur bleibt vollstaendig, nur Glyphen sind lazy.
    func typesetFastraASCII(
        _ storage: NSTextStorage,
        documentRange: NSRange,
        displayData: TextLine.DisplayData,
        markedRanges: MarkedRanges?,
        attachments: [AnyTextAttachment]
    ) -> Bool {
        guard documentRange.length >= 256 * 1024,
              markedRanges == nil, attachments.isEmpty,
              displayData.maxWidth > 0, !displayData.maxWidth.isNaN else { return false }
        let attributes = storage.attributes(at: documentRange.location, effectiveRange: nil)
        guard let font = attributes[.font] as? NSFont,
              font.isFixedPitch,
              (attributes[.kern] as? NSNumber)?.doubleValue ?? 0 == 0 else { return false }
        let allowed: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .backgroundColor, .kern, .paragraphStyle,
            .ligature, .underlineStyle, .underlineColor, .strikethroughStyle,
            .strikethroughColor, .toolTip, .link, .cursor
        ]
        let metrics: [NSAttributedString.Key] = [.font, .kern, .paragraphStyle, .ligature]
        var uniform = true
        storage.enumerateAttributes(in: documentRange) { current, _, stop in
            if !Set(current.keys).isSubset(of: allowed)
                || metrics.contains(where: {
                    !Self.fastraEqualAttribute(attributes[$0], current[$0])
                }) {
                uniform = false
                stop.pointee = true
            }
        }
        guard uniform else { return false }
        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            guard paragraph.baseWritingDirection != .rightToLeft,
                  paragraph.firstLineHeadIndent == 0, paragraph.headIndent == 0,
                  paragraph.tailIndent == 0 else { return false }
        }

        // UTF-16 ist fuer ASCII und einzelne lateinische Buchstaben ein
        // Zeichen je Zelle. Kombinationszeichen, Bidi und Surrogate behalten
        // CoreText; ein einzelnes Umlautzeichen im JSON-Namen ist erlaubt.
        var units = [UInt16](repeating: 0, count: documentRange.length)
        (storage.string as NSString).getCharacters(&units, range: documentRange)
        var textEnd = units.count
        if textEnd > 0, units[textEnd - 1] == 10 { textEnd -= 1 }
        if textEnd > 0, units[textEnd - 1] == 13 { textEnd -= 1 }
        var latin = Set<UInt16>()
        for unit in units[..<textEnd] {
            if unit >= 32 && unit <= 126 { continue }
            guard unit >= 0x00a1 && unit <= 0x024f && unit != 0x00ad else { return false }
            latin.insert(unit)
        }
        // Die Probe prueft auch die aktuelle Ligaturkonfiguration. Eine
        // nominell monospaced Schrift allein garantiert keine Einzelzellen.
        let alphabet = String((32...126).map { Character(UnicodeScalar($0)!) })
        let extraLetters = String(String.UnicodeScalarView(latin.sorted().map { UnicodeScalar($0)! }))
        let probe = NSAttributedString(string: alphabet + "fifflflffi" + extraLetters, attributes: attributes)
        let probeLine = CTLineCreateWithAttributedString(probe)
        guard CTLineGetGlyphCount(probeLine) == probe.length else { return false }
        let cellWidth = CTLineGetOffsetForStringIndex(probeLine, 1, nil)
        guard cellWidth > 0, cellWidth.isFinite else { return false }
        for offset in 1...probe.length {
            let actual = CTLineGetOffsetForStringIndex(probeLine, offset, nil)
            guard abs(actual - CGFloat(offset) * cellWidth) < 0.001 else { return false }
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(probeLine, &ascent, &descent, &leading)
        let height = ascent + descent + leading
        guard height > 0 else { return false }

        let wrapped = displayData.maxWidth < .greatestFiniteMagnitude
        var continuation: CGFloat = 0
        if wrapped && displayData.softWrapIndentation != .flushLeft {
            var indentationEnd = 0
            let limit = min(textEnd, Int(min(ceil(displayData.maxWidth / cellWidth) + 1, CGFloat(Int.max / 2))))
            while indentationEnd < limit, units[indentationEnd] == 32 { indentationEnd += 1 }
            let extra = displayData.softWrapIndentation == .reverse
                ? CGFloat(max(displayData.softWrapIndentationColumns, 1)) * cellWidth : 0
            continuation = min(CGFloat(indentationEnd) * cellWidth + extra,
                               max(displayData.maxWidth - 1, 0))
        }
        let source = FastraASCIITextSource(storage: storage, documentStart: documentRange.location)
        var fragments: [TextLineStorage<LineFragment>.BuildItem] = []
        if wrapped {
            fragments.reserveCapacity(min(textEnd / max(Int(min(displayData.maxWidth / cellWidth, CGFloat(Int.max / 2))), 1) + 2, 2_000_000))
        }
        var start = 0
        var fragmentIndex = 0
        var contents: [LineFragment.FragmentContent] = []
        var totalWidth: CGFloat = 0
        while start < units.count {
            let inset = wrapped && fragmentIndex > 0 ? continuation : 0
            let columns = wrapped
                ? max(1, Int(min(floor(max(displayData.maxWidth - inset, 1) / cellWidth), CGFloat(Int.max / 2))))
                : 16 * 1024
            var end = min(start + columns, textEnd)
            if wrapped && displayData.breakStrategy == .word && end < textEnd {
                let lower = max(start, end - 100)
                var cursor = end
                while cursor > lower {
                    cursor -= 1
                    if Self.fastraASCIIWordBreak(units[cursor])
                        || (units[cursor] > 126 && CharacterSet.punctuationCharacters.contains(UnicodeScalar(units[cursor])!)) {
                        end = cursor + 1
                        break
                    }
                }
            }
            // Zeilenenden haben keine sichtbare Breite und bleiben am letzten
            // Fragment. Auch eine Zeile nur aus Leerraum bleibt vollstaendig.
            let visibleLength = max(end - start, 0)
            if end >= textEnd { end = units.count }
            let range = NSRange(location: start, length: end - start)
            let width = CGFloat(visibleLength) * cellWidth
            let content = LineFragment.FragmentContent(asciiSource: source, range: range, width: width)
            if wrapped {
                let fragment = LineFragment(
                    id: .init(generation: fragmentGeneration, index: fragmentIndex),
                    contents: [content], width: width, height: height, descent: descent,
                    lineHeightMultiplier: displayData.lineHeightMultiplier
                )
                fragment.xOffset = inset
                fragment.documentRange = NSRange(location: documentRange.location + start, length: range.length)
                fragments.append(.init(data: fragment, length: range.length, height: fragment.scaledHeight))
                fragmentIndex += 1
            } else {
                contents.append(content)
                totalWidth += width
            }
            start = end
        }
        if !wrapped {
            let fragment = LineFragment(
                id: .init(generation: fragmentGeneration, index: 0),
                contents: contents, width: totalWidth, height: height, descent: descent,
                lineHeightMultiplier: displayData.lineHeightMultiplier
            )
            fragment.documentRange = documentRange
            fragments.append(.init(data: fragment, length: documentRange.length, height: fragment.scaledHeight))
        }
        lineFragments.removeAll()
        lineFragments.build(from: fragments, estimatedLineHeight: height * displayData.lineHeightMultiplier)
        self.documentRange = documentRange
        return true
    }

    private static func fastraEqualAttribute(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }

    /// Dieselbe ASCII-Teilmenge wie im regulaeren Wortumbruch-Helfer.
    private static func fastraASCIIWordBreak(_ c: UInt16) -> Bool {
        c == 32 || (c >= 0x21 && c <= 0x23) || (c >= 0x25 && c <= 0x2a)
            || (c >= 0x2c && c <= 0x2f) || (c >= 0x3a && c <= 0x3b)
            || (c >= 0x3f && c <= 0x40) || (c >= 0x5b && c <= 0x5d)
            || c == 0x5f || c == 0x7b || c == 0x7d
    }
}
'''
for key, value in source.items():
 if marker not in value: raise SystemExit(f'{paths[key]}: Selbstpruefung fehlgeschlagen')
 if key == 'line' and 'typesetter.typesetFastraASCII(' not in value: raise SystemExit('ASCII-Aufruf fehlt')
 if key == 'fragment' and 'if asciiSource != nil { return asciiRange.length }' not in value: raise SystemExit('Lazy-Laenge fehlt')
finalize_sources()
