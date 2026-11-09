import Foundation
@main struct Probe {
    static func main() throws {
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        var normalized = [[String: Any]]()
        var results = [[String: Any]]()
        for var c in cases {
            let text = c["text"] as! String
            var pattern = c["pattern"] as! String
            var template = c["template"] as! String
            if c["wildcard"] as? Bool == true {
                let compiled = WildcardPattern.compileFind(pattern)
                pattern = compiled.regexPattern
                template = WildcardPattern.compileReplace(template, captureCount: compiled.starCount)
            }
            let flags = c["flags"] as? UInt ?? 0
            let selected = c["range"] as? [Int]
            let searchRange = selected.map { NSRange(location: $0[0],length: $0[1]) } ?? NSRange(location: 0,length: text.utf16.count)
            // ICU-Flags sind bewusst getrennt von Foundations OptionSet.
            let options: NSRegularExpression.Options = flags == 2 ? [.caseInsensitive] : []
            c["regex"] = pattern; c["template"] = template; normalized.append(c)
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: options)
                let matches = regex.matches(in: text, range: searchRange)
                let ranges = matches.map { match in (0..<match.numberOfRanges).map { group in
                    let r = match.range(at: group); return [r.location == NSNotFound ? -1 : r.location, r.length]
                } }
                let output = c["caseTemplate"] as? Bool == true
                    ? CaseTemplate.replaceAllAssembling(in: text, regex: regex, template: template, range: searchRange)
                    : regex.stringByReplacingMatches(in: text, range: searchRange, withTemplate: template)
                results.append(["id": c["id"]!, "ranges": ranges, "output": output])
            } catch { results.append(["id": c["id"]!, "error": "compile"]) }
        }
        try JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
}
