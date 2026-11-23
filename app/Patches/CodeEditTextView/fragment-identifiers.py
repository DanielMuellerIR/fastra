import sys

fragment_path, typesetter_path, context_path = sys.argv[1:]
fragment = open(fragment_path).read()
typesetter = open(typesetter_path).read()
context = open(context_path).read()

old_fragment_id = '''public final class LineFragment: Identifiable, Equatable {
    public struct FragmentContent: Equatable {'''
new_fragment_id = '''public final class LineFragment: Identifiable, Equatable {
    /// Fastra-Patch: eine UUID pro Typesetter statt pro Fragment.
    /// Die Generation trennt Neuaufbauten; der Index ist darin eindeutig.
    public struct FragmentID: Hashable {
        let generation: UUID
        let index: Int
    }

    public struct FragmentContent: Equatable {'''
if "Fastra-Patch: eine UUID pro Typesetter statt pro Fragment" not in fragment:
    if old_fragment_id not in fragment:
        raise SystemExit(
            f"{fragment_path}: Fragmenttyp hat sich geaendert — Patch 4z11 pruefen"
        )
    fragment = fragment.replace(old_fragment_id, new_fragment_id, 1)

old_id_property = '''    public let id = UUID()
    public var documentRange: NSRange = .notFound'''
new_id_property = '''    public let id: FragmentID
    public var documentRange: NSRange = .notFound'''
if old_id_property in fragment:
    fragment = fragment.replace(old_id_property, new_id_property, 1)
elif new_id_property not in fragment:
    raise SystemExit(
        f"{fragment_path}: ID-Eigenschaft hat sich geaendert — Patch 4z11 pruefen"
    )

old_fragment_init = '''    init(
        contents: [FragmentContent],
        width: CGFloat,'''
new_fragment_init = '''    init(
        id: FragmentID,
        contents: [FragmentContent],
        width: CGFloat,'''
if "        self.id = id\n        self.contents = contents" not in fragment:
    if old_fragment_init not in fragment:
        raise SystemExit(
            f"{fragment_path}: Fragment-Initializer hat sich geaendert — "
            "Patch 4z11 pruefen"
        )
    fragment = fragment.replace(old_fragment_init, new_fragment_init, 1)
    fragment = fragment.replace(
        '''    ) {
        self.contents = contents''',
        '''    ) {
        self.id = id
        self.contents = contents''',
        1
    )

old_typesetter_state = '''    public var documentRange: NSRange?
    public var lineFragments = TextLineStorage<LineFragment>()'''
new_typesetter_state = '''    public var documentRange: NSRange?
    public var lineFragments = TextLineStorage<LineFragment>()
    private lazy var fragmentGeneration = UUID()'''
if "private lazy var fragmentGeneration = UUID()" not in typesetter:
    if "private let fragmentGeneration = UUID()" in typesetter:
        typesetter = typesetter.replace(
            "private let fragmentGeneration = UUID()",
            "private lazy var fragmentGeneration = UUID()",
            1
        )
    elif old_typesetter_state not in typesetter:
        raise SystemExit(
            f"{typesetter_path}: Typesetter-Zustand hat sich geaendert — "
            "Patch 4z11 pruefen"
        )
    else:
        typesetter = typesetter.replace(old_typesetter_state, new_typesetter_state, 1)

old_context_call = '''        var context = TypesetContext(documentRange: documentRange, displayData: displayData)'''
new_context_call = '''        var context = TypesetContext(
            documentRange: documentRange,
            displayData: displayData,
            fragmentGeneration: fragmentGeneration
        )'''
if "fragmentGeneration: fragmentGeneration" not in typesetter:
    if old_context_call not in typesetter:
        raise SystemExit(
            f"{typesetter_path}: TypesetContext-Aufruf hat sich geaendert — "
            "Patch 4z11 pruefen"
        )
    typesetter = typesetter.replace(old_context_call, new_context_call, 1)

old_empty_fragment = '''        let fragment = LineFragment(
            contents: [.init(data: .text(line: ctLine), width: 0.0)],'''
new_empty_fragment = '''        let fragment = LineFragment(
            id: .init(generation: fragmentGeneration, index: 0),
            contents: [.init(data: .text(line: ctLine), width: 0.0)],'''
if "id: .init(generation: fragmentGeneration, index: 0)" not in typesetter:
    if old_empty_fragment not in typesetter:
        raise SystemExit(
            f"{typesetter_path}: Leerfragment hat sich geaendert — Patch 4z11 pruefen"
        )
    typesetter = typesetter.replace(old_empty_fragment, new_empty_fragment, 1)

old_context_state = '''    let documentRange: NSRange
    let displayData: TextLine.DisplayData

    /// Accumulated generated line fragments.'''
new_context_state = '''    let documentRange: NSRange
    let displayData: TextLine.DisplayData
    let fragmentGeneration: UUID
    var nextFragmentIndex: Int = 0

    /// Accumulated generated line fragments.'''
if "var nextFragmentIndex: Int = 0" not in context:
    if old_context_state not in context:
        raise SystemExit(
            f"{context_path}: TypesetContext-Zustand hat sich geaendert — "
            "Patch 4z11 pruefen"
        )
    context = context.replace(old_context_state, new_context_state, 1)

obsolete_reservation = '''
    init(
        documentRange: NSRange,
        displayData: TextLine.DisplayData,
        fragmentGeneration: UUID
    ) {
        self.documentRange = documentRange
        self.displayData = displayData
        self.fragmentGeneration = fragmentGeneration

        // Fastra-Patch: Fragmentarray fuer Megazeilen vorab reservieren.
        // Eine typische Editorbreite fasst deutlich mehr als 64 Zeichen;
        // der konservative Schaetzwert verhindert die Array-Umschichtungen,
        // begrenzt die Vorabbelegung aber auch bei extremen Dateien.
        if displayData.maxWidth != .greatestFiniteMagnitude,
           documentRange.length >= 64 * 1024 {
            lines.reserveCapacity(min(documentRange.length / 80 + 1, 100_000))
        }
    }
'''
if "Fastra-Patch: Fragmentarray fuer Megazeilen vorab reservieren" in context:
    if obsolete_reservation not in context:
        raise SystemExit(
            f"{context_path}: alter Reservierungsversuch hat sich geaendert — "
            "Patch 4z11 pruefen"
        )
    context = context.replace(obsolete_reservation, "", 1)

old_pop = '''    mutating func popCurrentData() {
        let fragment = LineFragment(
            contents: fragmentContext.contents,'''
new_pop = '''    mutating func popCurrentData() {
        let fragment = LineFragment(
            id: .init(generation: fragmentGeneration, index: nextFragmentIndex),
            contents: fragmentContext.contents,'''
if "id: .init(generation: fragmentGeneration, index: nextFragmentIndex)" not in context:
    if old_pop not in context:
        raise SystemExit(
            f"{context_path}: Fragmentaufbau hat sich geaendert — Patch 4z11 pruefen"
        )
    context = context.replace(old_pop, new_pop, 1)

old_append = '''        lines.append(
            .init(data: fragment, length: currentPosition - fragmentContext.start, height: fragment.scaledHeight)
        )
        maxHeight = max(maxHeight, fragment.scaledHeight)'''
new_append = '''        lines.append(
            .init(data: fragment, length: currentPosition - fragmentContext.start, height: fragment.scaledHeight)
        )
        nextFragmentIndex &+= 1
        maxHeight = max(maxHeight, fragment.scaledHeight)'''
if "nextFragmentIndex &+= 1" not in context:
    if old_append not in context:
        raise SystemExit(
            f"{context_path}: Fragmentindex hat sich geaendert — Patch 4z11 pruefen"
        )
    context = context.replace(old_append, new_append, 1)

open(fragment_path, "w").write(fragment)
open(typesetter_path, "w").write(typesetter)
open(context_path, "w").write(context)
