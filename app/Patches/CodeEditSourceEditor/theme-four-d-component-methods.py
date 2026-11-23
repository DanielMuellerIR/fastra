import sys
theme_path, capture_path = sys.argv[1], sys.argv[2]
theme = open(theme_path).read()
capture = open(capture_path).read()

old_property = '''    public var methods: Attribute
    public var types: Attribute'''
new_property = '''    public var methods: Attribute
    // Fastra-Patch: eigener Component-Methoden-Slot fuer 4D. Der optionale
    // Initializer-Parameter erbt fuer bestehende Themes den commands-Slot.
    public var componentMethods: Attribute
    public var types: Attribute'''
if old_property not in theme:
    sys.exit("EditorTheme-Properties haben sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_property, new_property, 1)

old_init = '''        comments: Attribute,
        methods: Attribute? = nil
    ) {'''
new_init = '''        comments: Attribute,
        methods: Attribute? = nil,
        componentMethods: Attribute? = nil
    ) {'''
if old_init not in theme:
    sys.exit("EditorTheme-Initializer hat sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_init, new_init, 1)

old_assignment = '''        self.methods = methods ?? commands
        self.types = types'''
new_assignment = '''        self.methods = methods ?? commands
        self.componentMethods = componentMethods ?? commands
        self.types = types'''
if old_assignment not in theme:
    sys.exit("EditorTheme-Assignments haben sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_assignment, new_assignment, 1)

old_mapping = '''        case .method: return methods
        case .number, .float: return numbers'''
new_mapping = '''        case .method: return methods
        case .componentMethod: return componentMethods
        case .number, .float: return numbers'''
if old_mapping not in theme:
    sys.exit("EditorTheme-Component-Mapping hat sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_mapping, new_mapping, 1)

old_cases = '''    case keywordReturn
    case keywordFunction'''
new_cases = '''    case keywordReturn
    case keywordFunction
    // Fastra-Patch: eigener Component-Methoden-Slot fuer 4D.
    // Am Ende angehaengt, damit alle vorhandenen Int8-Rohwerte stabil bleiben.
    case componentMethod'''
if old_cases not in capture:
    sys.exit("CaptureName-Cases haben sich geaendert — Patch 4m2 pruefen")
capture = capture.replace(old_cases, new_cases, 1)

old_from_string = '''        case "keyword.function":
            return .keywordFunction
        default:'''
new_from_string = '''        case "keyword.function":
            return .keywordFunction
        case "component.method":
            return .componentMethod
        default:'''
if old_from_string not in capture:
    sys.exit("CaptureName.fromString hat sich geaendert — Patch 4m2 pruefen")
capture = capture.replace(old_from_string, new_from_string, 1)

old_string_value = '''        case .keywordFunction:
            return "keywordFunction"
        }'''
new_string_value = '''        case .keywordFunction:
            return "keywordFunction"
        case .componentMethod:
            return "component.method"
        }'''
if old_string_value not in capture:
    sys.exit("CaptureName.stringValue hat sich geaendert — Patch 4m2 pruefen")
capture = capture.replace(old_string_value, new_string_value, 1)

open(theme_path, 'w').write(theme)
open(capture_path, 'w').write(capture)
