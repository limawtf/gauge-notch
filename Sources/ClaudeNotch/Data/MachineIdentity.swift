import Foundation
import IOKit

/// Identidade estavel desta maquina pro sync entre Macs (feature multimac-sync):
/// deriva do hardware via IOKit (IOPlatformUUID), cacheada em UserDefaults pra nao
/// reconsultar o IOKit toda hora. Estavel entre reinstalacoes do app (o UUID e' do
/// hardware, nao de nenhum dado do app), so muda se a placa logica trocar.
enum MachineIdentity {
    private static let cacheKey = "wtf.lima.claude-notch.machineId"

    /// machineId estavel: le do cache se ja existir, senao deriva via
    /// `platformUUIDProvider` (IOKit de verdade por padrao, injetavel pra teste) e
    /// persiste. Nunca nil: se o IOKit falhar por algum motivo, cai pra um UUID
    /// aleatorio (so nesse boot ele nao vai ser IGUAL entre maquinas por coincidencia,
    /// e a partir do cache ele fica estavel dali em diante).
    static func currentMachineId(
        defaults: UserDefaults = .standard,
        platformUUIDProvider: () -> String? = readPlatformUUID
    ) -> String {
        if let cached = defaults.string(forKey: cacheKey), !cached.isEmpty {
            return cached
        }
        let id = platformUUIDProvider() ?? UUID().uuidString
        defaults.set(id, forKey: cacheKey)
        return id
    }

    /// Nome amigavel default da maquina (editavel numa fase seguinte): o nome do Mac
    /// no System Settings > General > Sharing, o mesmo que aparece no Finder/AirDrop.
    static func defaultLabel() -> String {
        Host.current().localizedName ?? "Mac"
    }

    /// IOPlatformUUID de verdade via IOKit (kIOPlatformUUIDKey em
    /// "IOPlatformExpertDevice"). nil so se o IOKit falhar (nao deveria em macOS real).
    static func readPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return prop.takeRetainedValue() as? String
    }
}
