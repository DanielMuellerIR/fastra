import sys
path = sys.argv[1]
src = open(path).read()
helper = '''import Foundation

// Fastra-Patch: portables CodeEditLanguages-Ressourcenbundle. In der
// gepackten App liegt es unter Contents/Resources; Bundle.module bleibt der
// Fallback fuer SwiftPM-CLI-Builds und Tests.
private let fastraCodeEditLanguagesResourceURL: URL? = {
    if let resources = Bundle.main.resourceURL,
       let packaged = Bundle(
           url: resources.appendingPathComponent("CodeEditLanguages_CodeEditLanguages.bundle")
       ) {
        return packaged.resourceURL
    }
    return Bundle.module.resourceURL
}()'''
if 'import Foundation' not in src:
    sys.exit("CodeEditLanguages-Import hat sich geaendert")
src = src.replace('import Foundation', helper, 1)
old = 'internal var resourceURL: URL? = Bundle.module.resourceURL'
if old not in src:
    sys.exit("CodeEditLanguages-resourceURL hat sich geaendert")
src = src.replace(old, 'internal var resourceURL: URL? = fastraCodeEditLanguagesResourceURL', 1)
open(path, 'w').write(src)
