import Foundation
import Combine

/// Preferencias persistidas do app (UserDefaults).
@MainActor
final class AppSettings: ObservableObject {
    private static let peekEnabledKey = "wtf.lima.claude-notch.peekEnabled"
    private static let showNotchUsageKey = "wtf.lima.claude-notch.showNotchUsage"
    private static let syncAcrossMacsKey = "wtf.lima.claude-notch.syncAcrossMacs"

    @Published var peekEnabled: Bool {
        didSet {
            UserDefaults.standard.set(peekEnabled, forKey: Self.peekEnabledKey)
        }
    }

    /// Mostrar o uso (pior % colorido) colado no notch, sempre visivel (estado compacto
    /// do DynamicNotch), mesmo com o painel fechado. Default ligado.
    @Published var showNotchUsage: Bool {
        didSet {
            UserDefaults.standard.set(showNotchUsage, forKey: Self.showNotchUsageKey)
        }
    }

    /// Sync de gasto entre Macs (feature multimac-sync): pasta compartilhada no iCloud
    /// Drive, particionada por maquina. DEFAULT DESLIGADO (feature nova nunca muda
    /// comportamento existente sem acao explicita do usuario): so ao ligar e' que o app
    /// resolve/cria a pasta, deriva/persiste o machineId e comeca a escrever
    /// spend/<machineId>.json no proximo refresh.
    @Published var syncAcrossMacs: Bool {
        didSet {
            UserDefaults.standard.set(syncAcrossMacs, forKey: Self.syncAcrossMacsKey)
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.peekEnabledKey) == nil {
            peekEnabled = true // default ligado (spec)
        } else {
            peekEnabled = UserDefaults.standard.bool(forKey: Self.peekEnabledKey)
        }

        if UserDefaults.standard.object(forKey: Self.showNotchUsageKey) == nil {
            showNotchUsage = true // default ligado (spec)
        } else {
            showNotchUsage = UserDefaults.standard.bool(forKey: Self.showNotchUsageKey)
        }

        // Sem default especial aqui: `bool(forKey:)` ja devolve false pra chave ausente,
        // que e' exatamente o default desejado (desligado na 1a instalacao).
        syncAcrossMacs = UserDefaults.standard.bool(forKey: Self.syncAcrossMacsKey)
    }
}
