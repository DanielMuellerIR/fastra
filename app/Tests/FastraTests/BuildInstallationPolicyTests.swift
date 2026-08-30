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

    private var repositoryDirectory: URL {
        appDirectory.deletingLastPathComponent()
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

    @Test("Installer prüft eine Zwischenkopie und kann den alten Stand zurückrollen")
    func installationStagesAndKeepsRollbackCopy() throws {
        let script = try String(
            contentsOf: appDirectory.appendingPathComponent("install.sh"),
            encoding: .utf8
        )

        let stagedCopy = try #require(
            script.range(of: "ditto \"$APP\" \"$STAGED_APP\"")
        ).lowerBound
        let stagedGatekeeper = try #require(
            script.range(of: "spctl --assess --type execute --verbose=2 \"$STAGED_APP\"")
        ).lowerBound
        let backup = try #require(
            script.range(of: "mv \"$DEST\" \"$BACKUP_APP\"")
        ).lowerBound
        let install = try #require(
            script.range(of: "mv \"$STAGED_APP\" \"$DEST\"")
        ).lowerBound

        #expect(stagedCopy < stagedGatekeeper)
        #expect(stagedGatekeeper < backup)
        #expect(backup < install)
        #expect(script.contains("restore_previous_installation"))
    }

    @Test("Release verwendet private Mountpunkte und hängt fremde Volumes nicht aus")
    func releaseUsesPrivateMountDirectories() throws {
        let script = try String(
            contentsOf: appDirectory.appendingPathComponent("release.sh"),
            encoding: .utf8
        )

        #expect(script.contains("MOUNT_DIR=\"$DMG_STAGING/mount\""))
        #expect(script.contains("VERIFY_MOUNT=\"$DMG_STAGING/verify\""))
        #expect(!script.contains("MOUNT_DIR=\"/Volumes/$VOL_NAME\""))
        #expect(!script.contains("Altes Volume von früherem Lauf aushängen"))
        // Nur der Finder-Layout-Schritt hängt am Standardort unter /Volumes
        // (macOS 26.6 registriert private Mountpunkte nicht mehr als
        // Finder-Disk). Der echte Mountpunkt wird dabei aus der
        // hdiutil-plist-Ausgabe GELESEN statt angenommen, und bei einem
        // unerwarteten Pfad (fremdes gleichnamiges Volume kam dazwischen)
        // wird das Layout übersprungen — kopiert wird nie in ein fremdes
        // Volume.
        #expect(script.contains("hdiutil attach -readwrite -noverify -noautoopen -plist"))
        #expect(script.contains("if [ \"$ACTUAL_MOUNT\" != \"/Volumes/$VOL_NAME\" ]"))
    }

    @Test("Release-Trap hängt nur die eigene Geräteidentität aus")
    func releaseTrapDetachesOnlyOwnDeviceIdentity() throws {
        let script = try String(
            contentsOf: appDirectory.appendingPathComponent("release.sh"),
            encoding: .utf8
        )

        // Statischer Wächter: Das eigene RW-Volume wird nirgends mehr über
        // seinen Mountpfad ausgehängt. Der Pfad /Volumes/Fastra kann nach dem
        // eigenen Detach (z. B. während der Notarisierung) von einem fremden
        // gleichnamigen Volume neu belegt sein — nur die beim Attach gemerkte
        // Geräteidentität bezeichnet sicher das eigene Volume.
        #expect(!script.contains("hdiutil detach \"$MOUNT_DIR\""))
        #expect(script.contains("hdiutil detach \"$ATTACHED_DEV\""))
        #expect(script.contains("hdiutil info -plist"))

        // Funktionale Prüfung mit kontrolliertem hdiutil-Ersatz: Der ECHTE
        // Trap-Code aus release.sh läuft gegen ein protokollierendes
        // Fake-hdiutil, einmal mit gemerkter Geräteidentität und einmal ohne
        // (Zustand nach erfolgreichem eigenem Detach).
        let withDevice = try runReleaseCleanupTrap(attachedDevice: "/dev/disk93")
        #expect(withDevice.contains { $0.contains("/dev/disk93") })
        #expect(!withDevice.contains { $0.contains("/Volumes/Fastra") },
                "Der Trap darf nie über den wiederbelegbaren Finder-Pfad aushängen")

        let afterOwnDetach = try runReleaseCleanupTrap(attachedDevice: "")
        #expect(!afterOwnDetach.contains { $0.contains("/dev/") },
                "Ohne gemerkte Identität darf der Trap kein Volume mehr anfassen")
        #expect(!afterOwnDetach.contains { $0.contains("/Volumes/Fastra") })

        let reusedDevice = try runReleaseCleanupTrap(
            attachedDevice: "/dev/disk93", imageBelongsToDevice: false)
        #expect(!reusedDevice.contains { $0.contains("detach /dev/disk93") },
                "Eine wiedervergebene Gerätenummer darf nie ausgehängt werden")
    }

    /// Führt die unveränderte `cleanup_release`-Funktion aus release.sh in
    /// einer Sandbox aus, in der ein Fake-`hdiutil` alle Aufrufe protokolliert.
    /// Liefert die protokollierten hdiutil-Aufrufzeilen.
    private func runReleaseCleanupTrap(
        attachedDevice: String,
        imageBelongsToDevice: Bool = true
    ) throws -> [String] {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fastra-release-trap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let log = sandbox.appendingPathComponent("hdiutil.log")
        let fakeHdiutil = sandbox.appendingPathComponent("hdiutil")
        let reportedImage = imageBelongsToDevice
            ? sandbox.appendingPathComponent("fastra_rw.dmg").path
            : sandbox.appendingPathComponent("foreign.dmg").path
        try """
        #!/bin/bash
        echo "$@" >> "\(log.path)"
        if [ "$1" = "info" ]; then
          cat <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>images</key><array><dict>
        <key>image-path</key><string>\(reportedImage)</string>
        <key>system-entities</key><array><dict>
        <key>dev-entry</key><string>/dev/disk93</string>
        </dict></array></dict></array></dict></plist>
        PLIST
        fi
        exit 0
        """.write(to: fakeHdiutil, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeHdiutil.path)

        // Der Harness lädt NUR die Trap-Funktion aus dem echten Skript und
        // ruft sie mit dem Zustand des Release-Laufs auf (Finder-Layout-Fall:
        // MOUNT_DIR zeigt auf /Volumes/Fastra).
        let harness = sandbox.appendingPathComponent("harness.sh")
        try """
        #!/bin/bash
        set -u
        eval "$(/usr/bin/sed -n '/^fastra_attached_device_belongs_to_rw_image()/,/^}/p' "$1")"
        eval "$(/usr/bin/sed -n '/^fastra_detach_attached_rw_image()/,/^}/p' "$1")"
        eval "$(/usr/bin/sed -n '/^cleanup_release()/,/^}/p' "$1")"
        DMG_STAGING="$3/staging"
        mkdir -p "$DMG_STAGING"
        VERIFY_MOUNT="$DMG_STAGING/verify"
        MOUNT_DIR="/Volumes/Fastra"
        RW_DMG="$3/fastra_rw.dmg"
        ATTACHED_DEV="$2"
        cleanup_release
        """.write(to: harness, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: harness.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            harness.path,
            appDirectory.appendingPathComponent("release.sh").path,
            attachedDevice,
            sandbox.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(sandbox.path):/usr/bin:/bin"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return logged.split(separator: "\n").map(String.init)
    }

    @Test("Appcast signiert nur ein geprüftes und zur Version passendes DMG")
    func appcastVerifiesReleaseBeforeSigning() throws {
        let workflow = try String(
            contentsOf: repositoryDirectory
                .appendingPathComponent(".github/workflows/publish-appcast.yml"),
            encoding: .utf8
        )
        let verification = try #require(
            workflow.range(of: "name: Release-DMG vor Appcast prüfen")
        ).lowerBound
        let signing = try #require(
            workflow.range(of: "name: Signierten Appcast erzeugen")
        ).lowerBound
        let verificationBlock = workflow[verification..<signing]

        #expect(verification < signing)
        #expect(verificationBlock.contains("xcrun stapler validate"))
        #expect(verificationBlock.contains("codesign --verify --deep --strict"))
        #expect(verificationBlock.contains("spctl --assess --type execute"))
        #expect(verificationBlock.contains("CFBundleIdentifier"))
        #expect(verificationBlock.contains("CFBundleShortVersionString"))
        #expect(verificationBlock.contains("de.dm0.fastra"))
    }
}
