import sys
path = sys.argv[1]
src = open(path).read()

old_property = '''    public var commands: Attribute
    public var types: Attribute'''
new_property = '''    public var commands: Attribute
    // Fastra-Patch: eigener Methoden-Slot fuer 4D. Optional im Initializer,
    // damit bestehende Themes unveraendert den commands-Slot verwenden.
    public var methods: Attribute
    public var types: Attribute'''
if old_property not in src:
    sys.exit("EditorTheme-Properties haben sich geaendert — Patch 4m pruefen")
src = src.replace(old_property, new_property, 1)

old_init = '''        characters: Attribute,
        comments: Attribute
    ) {'''
new_init = '''        characters: Attribute,
        comments: Attribute,
        methods: Attribute? = nil
    ) {'''
if old_init not in src:
    sys.exit("EditorTheme-Initializer hat sich geaendert — Patch 4m pruefen")
src = src.replace(old_init, new_init, 1)

old_assignment = '''        self.commands = commands
        self.types = types'''
new_assignment = '''        self.commands = commands
        self.methods = methods ?? commands
        self.types = types'''
if old_assignment not in src:
    sys.exit("EditorTheme-Assignments haben sich geaendert — Patch 4m pruefen")
src = src.replace(old_assignment, new_assignment, 1)

old_mapping = '''        case .function, .method: return commands'''
new_mapping = '''        case .function: return commands
        case .method: return methods'''
if old_mapping not in src:
    sys.exit("EditorTheme-Methoden-Mapping hat sich geaendert — Patch 4m pruefen")
src = src.replace(old_mapping, new_mapping, 1)
open(path, 'w').write(src)
