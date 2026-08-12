// LongLinePerformancePolicy.swift
//
// Schutz vor pathologischen Layoutkosten einzelner Megazeilen. Der Editor
// arbeitet intern mit UTF-16-Offsets; deshalb misst auch diese pure Regel in
// UTF-16-Codeunits und nicht in Bytes oder Swift-Graphemen.

import Foundation

enum LongLinePerformancePolicy {
    /// Ab dieser Länge wird Soft Wrap für das betroffene Dokument ausgesetzt.
    /// 128 Ki UTF-16 liegen weit über üblichen Quelltextzeilen, verhindern
    /// aber, dass eine Base64-/JSON-Zeile zehntausende Umbruchfragmente erzeugt.
    static let wrappedLineLimit = 128 * 1024

    static func requiresSoftWrapSuppression(in text: String) -> Bool {
        var lineLength = 0
        for codeUnit in text.utf16 {
            switch codeUnit {
            case 0x000A, 0x000D, 0x0085, 0x2028, 0x2029:
                lineLength = 0
            default:
                lineLength += 1
                if lineLength >= wrappedLineLimit { return true }
            }
        }
        return false
    }
}
