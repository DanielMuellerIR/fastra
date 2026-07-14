import AppKit
import Testing
@testable import Fastra

@Test("Gebündelte Sora-Schrift lässt sich unter ihrem PostScript-Namen laden")
func bundledBrandFontRegisters() {
    #expect(BrandFont.register())
    #expect(NSFont(name: BrandFont.postScriptName, size: 34) != nil)
}
