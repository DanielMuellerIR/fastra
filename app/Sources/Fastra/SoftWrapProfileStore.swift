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
/// Zielart und feste Spalte gelten pro Format. Spalte und Sichtbarkeit der
/// Seitenlinie sind dagegen appweite Editor-Einstellungen im selben Payload.
enum SoftWrapTarget: String, Codable, CaseIterable, Equatable {
    case window
    case pageGuide
    case fixedColumn
}

final class SoftWrapProfileStore: ObservableObject {
    struct StoredProfile: Codable, Equatable {
        var softWrapEnabled: Bool?
        var target: SoftWrapTarget?
        var fixedColumn: Int?

        init(softWrapEnabled: Bool? = nil,
             target: SoftWrapTarget? = nil,
             fixedColumn: Int? = nil) {
            self.softWrapEnabled = softWrapEnabled
            self.target = target
            self.fixedColumn = fixedColumn
        }

        var isEmpty: Bool {
            softWrapEnabled == nil && target == nil && fixedColumn == nil
        }
    }

    struct Payload: Codable, Equatable {
        var version: Int
        var formats: [String: StoredProfile]
        var pageGuideColumn: Int?
        var showPageGuide: Bool?

        init(version: Int,
             formats: [String: StoredProfile],
             pageGuideColumn: Int? = nil,
             showPageGuide: Bool? = nil) {
            self.version = version
            self.formats = formats
            self.pageGuideColumn = pageGuideColumn
            self.showPageGuide = showPageGuide
        }
    }

    enum Keys {
        static let profiles = "editor.formatProfiles"
        static let legacyGlobalWrap = "editor.wrapLines"
    }

    static let currentVersion = 2
    static let factoryColumn = 80
    static let validColumnRange = 20...500

    @Published private(set) var revision: UInt64 = 0

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var payload: Payload
    private var notificationObservation: AnyCancellable?

    init(defaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        if var loaded = Self.loadPayload(from: defaults) {
            let needsMigration = loaded.version < Self.currentVersion
            loaded = Self.normalized(loaded)
            payload = loaded
            if needsMigration {
                Self.persist(loaded, to: defaults)
            }
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
        payload.formats[formatID.rawValue]?.isEmpty == false
    }

    func target(for formatID: DocumentFormatID) -> SoftWrapTarget {
        payload.formats[formatID.rawValue]?.target ?? .window
    }

    func fixedColumn(for formatID: DocumentFormatID) -> Int {
        Self.validatedColumn(payload.formats[formatID.rawValue]?.fixedColumn)
    }

    var pageGuideColumn: Int {
        Self.validatedColumn(payload.pageGuideColumn)
    }

    var showPageGuide: Bool {
        payload.showPageGuide ?? false
    }

    func setEnabled(_ enabled: Bool, for formatID: DocumentFormatID) {
        let factoryValue = SoftWrapFactoryDefaults.isEnabled(for: formatID)
        updateProfile(for: formatID) {
            $0.softWrapEnabled = enabled == factoryValue ? nil : enabled
        }
        persistAndNotify()
    }

    func toggle(for formatID: DocumentFormatID) {
        setEnabled(!isEnabled(for: formatID), for: formatID)
    }

    func selectTarget(_ target: SoftWrapTarget, for formatID: DocumentFormatID) {
        updateProfile(for: formatID) {
            $0.target = target == .window ? nil : target
            let factoryEnabled = SoftWrapFactoryDefaults.isEnabled(for: formatID)
            $0.softWrapEnabled = factoryEnabled ? nil : true
        }
        persistAndNotify()
    }

    func setFixedColumn(_ column: Int, for formatID: DocumentFormatID) {
        let validated = Self.validatedColumn(column)
        updateProfile(for: formatID) {
            $0.fixedColumn = validated == Self.factoryColumn ? nil : validated
            $0.target = .fixedColumn
            let factoryEnabled = SoftWrapFactoryDefaults.isEnabled(for: formatID)
            $0.softWrapEnabled = factoryEnabled ? nil : true
        }
        persistAndNotify()
    }

    func setPageGuideColumn(_ column: Int) {
        let validated = Self.validatedColumn(column)
        payload.pageGuideColumn =
            validated == Self.factoryColumn ? nil : validated
        persistAndNotify()
    }

    func setShowPageGuide(_ show: Bool) {
        payload.showPageGuide = show ? true : nil
        persistAndNotify()
    }

    func resetToFactoryDefault(for formatID: DocumentFormatID) {
        guard payload.formats.removeValue(forKey: formatID.rawValue) != nil else {
            return
        }
        persistAndNotify()
    }

    private func persistAndNotify() {
        payload = Self.normalized(payload)
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

    static func validatedColumn(_ column: Int?) -> Int {
        guard let column, validColumnRange.contains(column) else {
            return factoryColumn
        }
        return column
    }

    private func updateProfile(
        for formatID: DocumentFormatID,
        _ update: (inout StoredProfile) -> Void
    ) {
        let key = formatID.rawValue
        var profile = payload.formats[key] ?? StoredProfile()
        update(&profile)
        if profile.isEmpty {
            payload.formats.removeValue(forKey: key)
        } else {
            payload.formats[key] = profile
        }
    }

    private static func normalized(_ source: Payload) -> Payload {
        var result = source
        result.version = currentVersion
        result.pageGuideColumn = {
            guard let value = source.pageGuideColumn else { return nil }
            let validated = validatedColumn(value)
            return validated == factoryColumn ? nil : validated
        }()
        result.formats = source.formats.compactMapValues { stored in
            var profile = stored
            if let column = profile.fixedColumn {
                let validated = validatedColumn(column)
                profile.fixedColumn =
                    validated == factoryColumn ? nil : validated
            }
            if profile.target == .window {
                profile.target = nil
            }
            return profile.isEmpty ? nil : profile
        }
        return result
    }

    private static func persist(_ payload: Payload, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Keys.profiles)
    }
}
