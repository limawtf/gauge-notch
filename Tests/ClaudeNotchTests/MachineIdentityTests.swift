import Testing
import Foundation
@testable import ClaudeNotch

@Suite("MachineIdentity: machineId estavel, cacheado em UserDefaults")
struct MachineIdentityTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "wtf.lima.claude-notch.tests.machine-identity.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("1a chamada deriva do provider injetado (nao do IOKit de verdade) e persiste")
    func derivesFromInjectedProviderAndPersists() {
        let defaults = freshDefaults()
        let id = MachineIdentity.currentMachineId(defaults: defaults, platformUUIDProvider: { "FAKE-UUID-123" })
        #expect(id == "FAKE-UUID-123")
    }

    @Test("chamadas seguintes reusam o cache, mesmo se o provider mudar de resposta")
    func reusesCacheAcrossCalls() {
        let defaults = freshDefaults()
        let first = MachineIdentity.currentMachineId(defaults: defaults, platformUUIDProvider: { "FIRST" })
        let second = MachineIdentity.currentMachineId(defaults: defaults, platformUUIDProvider: { "SECOND" })
        #expect(first == "FIRST")
        #expect(second == "FIRST") // cacheado, nao rele do provider
    }

    @Test("provider retornando nil (IOKit falhou) ainda devolve um id nao-vazio, nunca crasha")
    func nilProviderStillYieldsAnId() {
        let defaults = freshDefaults()
        let id = MachineIdentity.currentMachineId(defaults: defaults, platformUUIDProvider: { nil })
        #expect(!id.isEmpty)
    }

    @Test("readPlatformUUID de verdade (IOKit real) devolve algo plausivel neste Mac")
    func readsRealPlatformUUID() {
        // So roda em macOS de verdade (ambiente de CI/dev): confere que a chamada real
        // ao IOKit nao crasha e devolve uma string nao-vazia.
        let uuid = MachineIdentity.readPlatformUUID()
        #expect(uuid != nil)
        #expect((uuid ?? "").isEmpty == false)
    }
}
