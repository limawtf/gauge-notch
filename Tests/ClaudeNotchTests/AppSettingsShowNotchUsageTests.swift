import Testing
import Foundation
@testable import ClaudeNotch

/// Feature C/D: novo toggle `showNotchUsage` (config -> "Mostrar uso no notch"),
/// mesmo tratamento de default+persistencia que o `peekEnabled` ja tinha.
@Suite("AppSettings.showNotchUsage: default ligado + persiste")
@MainActor
struct AppSettingsShowNotchUsageTests {
    private static let key = "wtf.lima.claude-notch.showNotchUsage"

    @Test("default vem ligado quando nunca foi setado (1a instalacao)")
    func defaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let settings = AppSettings()
        #expect(settings.showNotchUsage == true)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test("desligar persiste no UserDefaults e sobrevive a uma nova instancia")
    func persistsAcrossInstances() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let settings = AppSettings()
        settings.showNotchUsage = false

        #expect(UserDefaults.standard.object(forKey: Self.key) != nil)
        #expect(UserDefaults.standard.bool(forKey: Self.key) == false)

        let reloaded = AppSettings()
        #expect(reloaded.showNotchUsage == false)

        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test("religar tambem persiste (nao fica preso no false)")
    func persistsReenabling() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let settings = AppSettings()
        settings.showNotchUsage = false
        settings.showNotchUsage = true

        let reloaded = AppSettings()
        #expect(reloaded.showNotchUsage == true)

        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
