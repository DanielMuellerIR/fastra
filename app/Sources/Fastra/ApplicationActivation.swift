import AppKit

/// Normale Produktaufrufe und manuelle Selbsttest-Starts dürfen Fastra
/// unverändert nach vorn holen. Der Runner kann diesen Aktivierungsschritt
/// für hintergrundfähige Tests sperren. Die übrigen Fensteraktionen bleiben
/// davon unberührt.
enum ApplicationActivation {
    static func allowsActivation(
        isSelfTestRun: Bool,
        environment: [String: String]
    ) -> Bool {
        guard isSelfTestRun else { return true }
        return environment["FASTRA_SELFTEST_ALLOW_ACTIVATION"] != "0"
    }

    static func activate(ignoringOtherApps: Bool) {
        guard allowsActivation(
            isSelfTestRun: AppDefaults.launch.isSelfTestRun,
            environment: ProcessInfo.processInfo.environment
        ) else { return }
        NSApp.activate(ignoringOtherApps: ignoringOtherApps)
    }
}
