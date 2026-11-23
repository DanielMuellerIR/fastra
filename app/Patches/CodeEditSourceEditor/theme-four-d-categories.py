import sys
path = sys.argv[1]
src = open(path).read()
old = '''        case .include, .constructor, .keyword, .boolean, .variableBuiltin,
                .keywordReturn, .keywordFunction, .repeat, .conditional, .tag:
            return keywords
        case .comment: return comments
        case .variable, .property: return variables
        case .function, .method: return variables'''
new = '''        // Fastra-Patch: eigene Slots fuer 4D-Kategorien (Etappe 4).
        // commands/values/characters waren upstream ungenutzt; die
        // Standard-Themes belegen sie mit den bisherigen Sammelfarben,
        // bestehende Sprachen aendern sich dadurch nicht.
        case .include, .constructor, .keyword, .boolean,
                .keywordReturn, .keywordFunction, .repeat, .conditional, .tag:
            return keywords
        case .variableBuiltin: return values
        case .comment: return comments
        case .variable: return variables
        case .property: return characters
        case .function, .method: return commands'''
if old not in src:
    sys.exit("EditorTheme.mapCapture hat sich geaendert — Patch 4l pruefen")
open(path, 'w').write(src.replace(old, new, 1))
