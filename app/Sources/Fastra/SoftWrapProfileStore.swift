import Foundation
import Combine

extension Notification.Name {
    /// Store-Instanzen verschiedener Dokumentfenster laden nach einer
    /// Profiländerung dieselben Defaults neu. Das hält auch separat erzeugte
    /// Fenster sofort synchron.
    static let fastraSoftWrapProfilesChanged =
        Notification.Name("fastra.softWrapProfiles.changed")
}

/// Testbarer, versionierter Store für Formatprofile.
///
/// Das JSON enthält pro Format ein Objekt statt eines nackten Bool-Werts.
/// Spätere Etappen können dort Zielbreite und Folgezeilen-Einrückung ergänzen,
/// ohne die stabile Formatidentität oder vorhandene Abweichungen umzubauen.
final class SoftWrapProfileStore: ObservableObject {
    struct StoredProfile: Codable, Equatable {
        var softWrapEnabled: Bool?
    }

    struct Payload: Codable, Equatable {
        var version: Int
        var formats: [String: StoredProfile]
    }

    enum Keys {
        static let profiles = "editor.formatProfiles"
        static let legacyGlobalWrap = "editor.wrapLines"
    }

    static let currentVersion = 1

    @Published private(set) var revision: UInt64 = 0

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var payload: Payload
    private var notificationObservation: AnyCancellable?

    init(defaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        if let loaded = Self.loadPayload(from: defaults) {
            payload = loaded
        } else if let legacy = Self.explicitLegacyValue(in: defaults) {
            var migrated = Payload(version: Self.currentVersion, formats: [:])
            if legacy != SoftWrapFactoryDefaults.isEnabled(for: .plainText) {
                migrated.formats[DocumentFormatID.plainText.rawValue] =
                    StoredProfile(softWrapEnabled: legacy)
            }
            payload = migrated
            // Der alte globale Wert darf nach erfolgreicher Übernahme nicht
            // als zweite widersprüchliche Quelle zurückbleiben.
            defaults.removeObject(forKey: Keys.legacyGlobalWrap)
            Self.persist(migrated, to: defaults)
        } else {
            payload = Payload(version: Self.currentVersion, formats: [:])
        }

        notificationObservation = notificationCenter
            .publisher(for: .fastraSoftWrapProfilesChanged)
            .sink { [weak self] note in
                guard let self, note.object as AnyObject? !== self else { return }
                self.reloadAfterExternalChange()
            }
    }

    func isEnabled(for formatID: DocumentFormatID) -> Bool {
        payload.formats[formatID.rawValue]?.softWrapEnabled
            ?? SoftWrapFactoryDefaults.isEnabled(for: formatID)
    }

    func hasOverride(for formatID: DocumentFormatID) -> Bool {
        payload.formats[formatID.rawValue]?.softWrapEnabled != nil
    }

    func setEnabled(_ enabled: Bool, for formatID: DocumentFormatID) {
        let factoryValue = SoftWrapFactoryDefaults.isEnabled(for: formatID)
        if enabled == factoryValue {
            payload.formats.removeValue(forKey: formatID.rawValue)
        } else {
            payload.formats[formatID.rawValue] =
                StoredProfile(softWrapEnabled: enabled)
        }
        persistAndNotify()
    }

    func toggle(for formatID: DocumentFormatID) {
        setEnabled(!isEnabled(for: formatID), for: formatID)
    }

    func resetToFactoryDefault(for formatID: DocumentFormatID) {
        guard payload.formats.removeValue(forKey: formatID.rawValue) != nil else {
            return
        }
        persistAndNotify()
    }

    private func persistAndNotify() {
        payload.version = Self.currentVersion
        Self.persist(payload, to: defaults)
        revision &+= 1
        notificationCenter.post(name: .fastraSoftWrapProfilesChanged, object: self)
    }

    private func reloadAfterExternalChange() {
        guard let loaded = Self.loadPayload(from: defaults), loaded != payload else {
            return
        }
        payload = loaded
        revision &+= 1
    }

    private static func explicitLegacyValue(in defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: Keys.legacyGlobalWrap) else {
            return nil
        }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func loadPayload(from defaults: UserDefaults) -> Payload? {
        guard let data = defaults.data(forKey: Keys.profiles),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data),
              decoded.version >= 1 else {
            return nil
        }
        return decoded
    }

    private static func persist(_ payload: Payload, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Keys.profiles)
    }
}
