import Foundation

enum GitAutomaticFetchDecision: String, CaseIterable, Equatable {
    case ask
    case automatic
    case disabled
}

enum GitRemoteScope: String, CaseIterable, Equatable {
    case relevant
    case all
}

enum GitPullStrategy: String, CaseIterable, Equatable {
    case unselected
    case rebase
    case merge
    case ffOnly
}

/// App-weite Git-Präferenzen. Sie beschreiben ausschließlich Fastras Verhalten
/// und schreiben niemals in `.git/config` oder die globale Git-Konfiguration.
struct GitPreferences: Equatable {
    static let defaultFetchInterval = 180
    static let fetchIntervalRange = 60...3600

    var automaticFetchDecision: GitAutomaticFetchDecision = .ask
    var fetchIntervalSeconds: Int = defaultFetchInterval
    var fetchOnActivation = true
    var remoteScope: GitRemoteScope = .relevant
    var prune = false
    var pullStrategy: GitPullStrategy = .unselected

    static func clampedFetchInterval(_ value: Int) -> Int {
        min(max(value, fetchIntervalRange.lowerBound), fetchIntervalRange.upperBound)
    }

    mutating func normalize() {
        fetchIntervalSeconds = Self.clampedFetchInterval(fetchIntervalSeconds)
    }
}

/// Kleiner, injizierbarer UserDefaults-Adapter. Einzelne typisierte Schlüssel
/// vermeiden, dass ein beschädigter Wert die übrigen Einstellungen verwirft.
struct GitPreferencesStore {
    enum Keys {
        static let decision = "git.fetch.decision"
        static let interval = "git.fetch.intervalSeconds"
        static let fetchOnActivation = "git.fetch.onActivation"
        static let remoteScope = "git.fetch.remoteScope"
        static let prune = "git.fetch.prune"
        static let pullStrategy = "git.pull.strategy"
        static let promptDeferredUntil = "git.fetch.promptDeferredUntil"

        /// Kurzer Übergangspfad für frühe experimentelle Builds. Er wird nur
        /// gelesen, niemals gelöscht oder überschrieben.
        static let legacyAutoFetch = "git.autoFetch"
        static let legacyInterval = "git.autoFetchInterval"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> GitPreferences {
        var preferences = GitPreferences()

        if let raw = defaults.string(forKey: Keys.decision),
           let value = GitAutomaticFetchDecision(rawValue: raw) {
            preferences.automaticFetchDecision = value
        } else if defaults.object(forKey: Keys.legacyAutoFetch) != nil {
            preferences.automaticFetchDecision = defaults.bool(forKey: Keys.legacyAutoFetch)
                ? .automatic : .disabled
        }

        if defaults.object(forKey: Keys.interval) != nil {
            preferences.fetchIntervalSeconds = defaults.integer(forKey: Keys.interval)
        } else if defaults.object(forKey: Keys.legacyInterval) != nil {
            preferences.fetchIntervalSeconds = defaults.integer(forKey: Keys.legacyInterval)
        }
        preferences.fetchIntervalSeconds = GitPreferences.clampedFetchInterval(
            preferences.fetchIntervalSeconds
        )

        if defaults.object(forKey: Keys.fetchOnActivation) != nil {
            preferences.fetchOnActivation = defaults.bool(forKey: Keys.fetchOnActivation)
        }
        if let raw = defaults.string(forKey: Keys.remoteScope),
           let value = GitRemoteScope(rawValue: raw) {
            preferences.remoteScope = value
        }
        if defaults.object(forKey: Keys.prune) != nil {
            preferences.prune = defaults.bool(forKey: Keys.prune)
        }
        if let raw = defaults.string(forKey: Keys.pullStrategy),
           let value = GitPullStrategy(rawValue: raw) {
            preferences.pullStrategy = value
        }
        return preferences
    }

    func save(_ value: GitPreferences) {
        var value = value
        value.normalize()
        defaults.set(value.automaticFetchDecision.rawValue, forKey: Keys.decision)
        defaults.set(value.fetchIntervalSeconds, forKey: Keys.interval)
        defaults.set(value.fetchOnActivation, forKey: Keys.fetchOnActivation)
        defaults.set(value.remoteScope.rawValue, forKey: Keys.remoteScope)
        defaults.set(value.prune, forKey: Keys.prune)
        defaults.set(value.pullStrategy.rawValue, forKey: Keys.pullStrategy)
        NotificationCenter.default.post(name: .fastraGitPreferencesChanged,
                                        object: defaults)
    }

    var promptDeferredUntil: Date? {
        defaults.object(forKey: Keys.promptDeferredUntil) as? Date
    }

    func deferAutomaticFetchPrompt(from date: Date = Date()) {
        defaults.set(date.addingTimeInterval(GitFetchPromptPolicy.deferral),
                     forKey: Keys.promptDeferredUntil)
    }

    func clearAutomaticFetchPromptDeferral() {
        defaults.removeObject(forKey: Keys.promptDeferredUntil)
    }
}

extension Notification.Name {
    static let fastraGitPreferencesChanged = Notification.Name(
        "fastra.git.preferences.changed"
    )
}
