import Foundation
import Darwin
enum L10n {
    static func string(_ value: String) -> String { value }
    static func format(_ value: String, _ args: CVarArg...) -> String { String(format:value,arguments:args) }
}
@main struct Regression {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("fastra-collection-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        var failures=0
        for (index,relative) in ["index.md","Übersicht/start.md"].enumerated() {
            let source=root.appendingPathComponent("mail\(index).mbox")
            try Data("Original".utf8).write(to:source)
            let occupied=root.appendingPathComponent("mail\(index)")
            try FileManager.default.createDirectory(at:occupied,withIntermediateDirectories:false)
            let service=MarkdownImportService();service.locateTool={URL(fileURLWithPath:"/fake-test-hook")}
            service.runProcess={_,args,_,_,completion in
                let output=URL(fileURLWithPath:args[args.firstIndex(of:"--output")!+1])
                let markdown=output.appendingPathComponent(relative)
                try! FileManager.default.createDirectory(at:markdown.deletingLastPathComponent(),withIntermediateDirectories:true)
                try! Data("Index".utf8).write(to:markdown)
                let asset=output.appendingPathComponent("note.md");try! Data("Note".utf8).write(to:asset)
                let json=try! JSONSerialization.data(withJSONObject:["ok":true,"markdownFile":markdown.path,"assets":[asset.path]])
                completion(MarkdownImportProcessOutcome(exitCode:0,stdout:json,stderr:Data(),outputIsComplete:true));return nil
            }
            var reported:URL?;service.convert(source){reported=$0}
            let expected=root.appendingPathComponent("mail\(index)-2/"+relative)
            let okay=reported==expected && FileManager.default.fileExists(atPath:expected.path)
            print("\(okay ? "PASS" : "FAIL") collection collision: \(relative)")
            if !okay {failures+=1}
        }
        exit(failures==0 ? 0 : 1)
    }
}
