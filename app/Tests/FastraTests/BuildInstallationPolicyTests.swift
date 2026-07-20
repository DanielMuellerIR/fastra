import Foundation
import Testing

@Suite("Build- und Installationsrichtlinie")
struct BuildInstallationPolicyTests {
    private var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FastraTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
    }

    @Test("build.sh installiert niemals nach Applications")
    func buildStaysInProjectRoot() throws {
        let script = try String(
            contentsOf: appDirectory.appendingPathComponent("build.sh"),
            encoding: .utf8
        )

        #expect(!script.contains("APPLICATIONS_APP="))
        #expect(!script.contains("DEST=\"/Applications/Fastra.app\""))
        #expect(script.contains("ROOT_APP=\"../Fastra.app\""))
    }

    @Test("Nicht notarisierter Installer endet vor Applications")
    func nonNotarizedInstallStopsBeforeApplications() throws {
        let script = try String(
            contentsOf: appDirectory.appendingPathComponent("install.sh"),
            encoding: .utf8
        )
        let noNotarizeStart = try #require(
            script.range(of: "if [ \"$NOTARIZE\" -eq 0 ]; then")
        )
        let applicationsDestination = try #require(
            script.range(of: "DEST=\"/Applications/Fastra.app\"")
        )
        let branch = script[noNotarizeStart.lowerBound..<applicationsDestination.lowerBound]

        #expect(branch.contains("exit 0"))
        #expect(!branch.contains("/Applications/Fastra.app"))
    }

    @Test("Installer gibt weder Signaturidentität noch Profilnamen aus")
    func installerKeepsSigningDetailsOutOfOutput() throws {
        let script = try String(
            contentsOf: appDirectory.appendingPathComponent("install.sh"),
            encoding: .utf8
        )

        #expect(!script.contains("echo \"→ Signatur-Identität: $SIGN_IDENTITY\""))
        #expect(!script.contains("echo \"→ Notarisiere via Profil '$NOTARY_PROFILE'"))
    }

    @Test("Notary-, Gatekeeper- und Signaturprüfung liegen vor der Installation")
    func notarizationChecksPrecedeInstallation() throws {
        let script = try String(
            contentsOf: appDirectory.appendingPathComponent("install.sh"),
            encoding: .utf8
        )
        let destination = try #require(
            script.range(of: "DEST=\"/Applications/Fastra.app\"")
        ).lowerBound
        let stapler = try #require(
            script.range(of: "xcrun stapler validate \"$APP\"", options: .backwards)
        ).lowerBound
        let gatekeeper = try #require(
            script.range(of: "spctl --assess --type execute --verbose=2 \"$APP\"")
        ).lowerBound
        let signature = try #require(
            script.range(of: "codesign --verify --deep --strict --verbose=2 \"$APP\"")
        ).lowerBound

        #expect(stapler < destination)
        #expect(gatekeeper < destination)
        #expect(signature < destination)
    }
}
