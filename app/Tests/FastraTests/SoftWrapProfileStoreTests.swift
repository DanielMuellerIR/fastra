import Foundation
import Testing
@testable import Fastra

private struct SoftWrapDefaultsFixture {
    let suiteName = "fastra-softwrap-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Suite("Soft-Wrap-Formatprofile")
struct SoftWrapProfileStoreTests {
    @Test("Abweichungen persistieren pro Format, Werkseinstellungen nicht")
    func persistenceAndMinimalOverrides() throws {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        let store = SoftWrapProfileStore(defaults: fixture.defaults)

        #expect(store.isEnabled(for: .plainText))
        #expect(!store.isEnabled(for: .fourD))
        store.setEnabled(true, for: .fourD)
        store.setEnabled(false, for: .plainText)

        let reloaded = SoftWrapProfileStore(defaults: fixture.defaults)
        #expect(reloaded.isEnabled(for: .fourD))
        #expect(!reloaded.isEnabled(for: .plainText))
        #expect(reloaded.hasOverride(for: .fourD))
        #expect(reloaded.hasOverride(for: .plainText))

        // Zurück auf den Default entfernt die Abweichung aus dem Profil.
        reloaded.setEnabled(false, for: .fourD)
        #expect(!reloaded.hasOverride(for: .fourD))
        let data = try #require(
            fixture.defaults.data(forKey: SoftWrapProfileStore.Keys.profiles)
        )
        let payload = try JSONDecoder().decode(
            SoftWrapProfileStore.Payload.self, from: data
        )
        #expect(payload.version == SoftWrapProfileStore.currentVersion)
        #expect(payload.formats[DocumentFormatID.fourD.rawValue] == nil)
        #expect(payload.formats[DocumentFormatID.plainText.rawValue] != nil)
    }

    @Test("Formatspezifisches Zurücksetzen entfernt nur die gewählte Abweichung")
    func resetOnlyCurrentFormat() {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        let store = SoftWrapProfileStore(defaults: fixture.defaults)
        store.setEnabled(true, for: .fourD)
        store.setEnabled(false, for: .grammar(.markdown))

        store.resetToFactoryDefault(for: .fourD)
        #expect(!store.hasOverride(for: .fourD))
        #expect(!store.isEnabled(for: .fourD))
        #expect(store.hasOverride(for: .grammar(.markdown)))
        #expect(!store.isEnabled(for: .grammar(.markdown)))
    }

    @Test("Alter globaler Wert migriert genau als Plain-Text-Abweichung")
    func legacyMigration() {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false,
                             forKey: SoftWrapProfileStore.Keys.legacyGlobalWrap)

        let migrated = SoftWrapProfileStore(defaults: fixture.defaults)
        #expect(!migrated.isEnabled(for: .plainText))
        #expect(migrated.hasOverride(for: .plainText))
        #expect(!migrated.isEnabled(for: .grammar(.json)))
        #expect(migrated.isEnabled(for: .grammar(.html)))
        #expect(fixture.defaults.object(
            forKey: SoftWrapProfileStore.Keys.legacyGlobalWrap
        ) == nil)

        // Ein später wieder auftauchender Altschlüssel überschreibt das
        // bereits versionierte Profil nicht erneut.
        migrated.resetToFactoryDefault(for: .plainText)
        fixture.defaults.set(false,
                             forKey: SoftWrapProfileStore.Keys.legacyGlobalWrap)
        let secondLaunch = SoftWrapProfileStore(defaults: fixture.defaults)
        #expect(secondLaunch.isEnabled(for: .plainText))
        #expect(!secondLaunch.hasOverride(for: .plainText))
    }

    @Test("Ohne ausdrücklich vorhandenen Altschlüssel gibt es keine Migration")
    func noLegacyValueMeansNoMigration() {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        _ = SoftWrapProfileStore(defaults: fixture.defaults)
        #expect(fixture.defaults.data(
            forKey: SoftWrapProfileStore.Keys.profiles
        ) == nil)
    }

    @Test("Getrennte Store-Instanzen derselben Suite reagieren sofort global")
    func globalNotification() {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        let first = SoftWrapProfileStore(defaults: fixture.defaults)
        let second = SoftWrapProfileStore(defaults: fixture.defaults)
        let previousRevision = second.revision

        first.setEnabled(true, for: .fourD)
        #expect(second.isEnabled(for: .fourD))
        #expect(second.revision > previousRevision)
    }

    @Test("Injizierte Defaults-Suites bleiben vollständig isoliert")
    func isolatedDefaults() {
        let firstFixture = SoftWrapDefaultsFixture()
        let secondFixture = SoftWrapDefaultsFixture()
        defer {
            firstFixture.cleanUp()
            secondFixture.cleanUp()
        }
        let first = SoftWrapProfileStore(defaults: firstFixture.defaults)
        let second = SoftWrapProfileStore(defaults: secondFixture.defaults)

        first.setEnabled(true, for: .fourD)
        #expect(first.isEnabled(for: .fourD))
        #expect(!second.isEnabled(for: .fourD))
        #expect(secondFixture.defaults.data(
            forKey: SoftWrapProfileStore.Keys.profiles
        ) == nil)
    }

    @Test("Version 1 migriert ohne Verlust auf Fensterziel und Spalte 80")
    func versionOneMigration() throws {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        let oldJSON = """
        {
          "version": 1,
          "formats": {
            "4d": { "softWrapEnabled": true }
          }
        }
        """
        fixture.defaults.set(Data(oldJSON.utf8),
                             forKey: SoftWrapProfileStore.Keys.profiles)

        let store = SoftWrapProfileStore(defaults: fixture.defaults)
        #expect(store.isEnabled(for: .fourD))
        #expect(store.target(for: .fourD) == .window)
        #expect(store.fixedColumn(for: .fourD) == 80)
        #expect(store.pageGuideColumn == 80)
        #expect(!store.showPageGuide)

        let data = try #require(
            fixture.defaults.data(forKey: SoftWrapProfileStore.Keys.profiles)
        )
        let migrated = try JSONDecoder().decode(
            SoftWrapProfileStore.Payload.self, from: data
        )
        #expect(migrated.version == SoftWrapProfileStore.currentVersion)
    }

    @Test("Ziel und feste Breite gelten pro Format und schalten Umbruch ein")
    func targetAndColumnAreFormatSpecific() {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        let store = SoftWrapProfileStore(defaults: fixture.defaults)

        store.setFixedColumn(100, for: .fourD)
        #expect(store.isEnabled(for: .fourD))
        #expect(store.target(for: .fourD) == .fixedColumn)
        #expect(store.fixedColumn(for: .fourD) == 100)
        #expect(store.target(for: .grammar(.markdown)) == .window)
        #expect(store.fixedColumn(for: .grammar(.markdown)) == 80)

        store.selectTarget(.pageGuide, for: .grammar(.markdown))
        #expect(store.target(for: .grammar(.markdown)) == .pageGuide)
        #expect(store.target(for: .fourD) == .fixedColumn)
    }

    @Test("Seitenlinie ist appweit; ungültige Altwerte fallen sicher auf 80 zurück")
    func pageGuideIsGlobalAndValidated() throws {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        let first = SoftWrapProfileStore(defaults: fixture.defaults)
        let second = SoftWrapProfileStore(defaults: fixture.defaults)

        first.setPageGuideColumn(120)
        first.setShowPageGuide(true)
        #expect(second.pageGuideColumn == 120)
        #expect(second.showPageGuide)

        let bad = SoftWrapProfileStore.Payload(
            version: SoftWrapProfileStore.currentVersion,
            formats: [
                DocumentFormatID.fourD.rawValue:
                    .init(target: .fixedColumn, fixedColumn: 999)
            ],
            pageGuideColumn: 3,
            showPageGuide: true
        )
        fixture.defaults.set(try JSONEncoder().encode(bad),
                             forKey: SoftWrapProfileStore.Keys.profiles)
        let repaired = SoftWrapProfileStore(defaults: fixture.defaults)
        #expect(repaired.pageGuideColumn == 80)
        #expect(repaired.fixedColumn(for: .fourD) == 80)
    }

    @Test("Format-Reset entfernt Ziel und Breite, aber nicht die globale Seitenlinie")
    func resetKeepsGlobalGuide() {
        let fixture = SoftWrapDefaultsFixture()
        defer { fixture.cleanUp() }
        let store = SoftWrapProfileStore(defaults: fixture.defaults)
        store.setFixedColumn(120, for: .fourD)
        store.setPageGuideColumn(100)
        store.setShowPageGuide(true)

        store.resetToFactoryDefault(for: .fourD)
        #expect(store.target(for: .fourD) == .window)
        #expect(store.fixedColumn(for: .fourD) == 80)
        #expect(store.pageGuideColumn == 100)
        #expect(store.showPageGuide)
    }

    @Test("Zahleneingabe akzeptiert nur ganze Spalten im gültigen Bereich")
    func numericInputValidation() {
        #expect(SoftWrapColumnInput.parse("20") == 20)
        #expect(SoftWrapColumnInput.parse(" 500 ") == 500)
        #expect(SoftWrapColumnInput.parse("19") == nil)
        #expect(SoftWrapColumnInput.parse("501") == nil)
        #expect(SoftWrapColumnInput.parse("80.5") == nil)
        #expect(SoftWrapColumnInput.parse("abc") == nil)
    }
}
