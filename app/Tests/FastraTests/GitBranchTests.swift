import Testing
@testable import Fastra

@Suite("Git-Branch-Auswahl")
struct GitBranchTests {
    @Test("Parser erkennt aktuellen Branch und behält Leerzeichen")
    func parsesBranches() {
        let branches = GitBranchList.parse("feature/eins\t \nmain\t*\nmit leerzeichen\t \n")
        #expect(branches.map(\.name) == ["feature/eins", "main", "mit leerzeichen"])
        #expect(branches.map(\.isCurrent) == [false, true, false])
    }

    @Test("Leere Zeilen werden ignoriert")
    func ignoresEmptyLines() {
        #expect(GitBranchList.parse("\n\n").isEmpty)
    }
}
