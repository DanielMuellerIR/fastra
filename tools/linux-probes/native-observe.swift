import AppKit
import ApplicationServices
import Foundation
let arguments = CommandLine.arguments
if arguments.count < 2 { exit(64) }
func value(_ element: AXUIElement, _ key: String) -> Any? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
    return result
}
if arguments[1] == "trust" { print(AXIsProcessTrusted()); exit(0) }
if arguments[1] == "dump", arguments.count == 3, let pid = Int32(arguments[2]) {
    var rows = [[String: String]]()
    func visit(_ element: AXUIElement, _ depth: Int) {
        guard depth < 14, rows.count < 1500 else { return }
        var row = [String: String]()
        for key in [kAXRoleAttribute,kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute] {
            if let string = value(element,key) as? String, !string.isEmpty { row[key] = String(string.prefix(500)) }
        }
        if !row.isEmpty { rows.append(row) }
        for child in value(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child,depth+1) }
    }
    visit(AXUIElementCreateApplication(pid),0)
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys])
    FileHandle.standardOutput.write(data)
} else if arguments[1] == "apps" {
    let rows = NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
        guard let bundle = app.bundleIdentifier,
              ["de.dm0.fastra","org.poormanstext.PoorMansText"].contains(bundle) else { return nil }
        return ["pid": app.processIdentifier,"bundle":bundle,"executable":app.executableURL?.path ?? ""]
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]))
} else { exit(64) }
