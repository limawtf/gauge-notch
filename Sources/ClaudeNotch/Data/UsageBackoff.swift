import Foundation

/// Politica de espera depois de um fetch da `oauth/usage` que falhou.
///
/// Existe por causa de um bug real (2026-09-04): a API respondeu 429 com
/// `retry-after: 3090` (51 min) e o app ignorou o header. Como o cache em disco so' e'
/// escrito em fetch BEM-SUCEDIDO, a falha deixava o disco sem nada -- e o passo 1 de
/// `loadUsage` (servir cache fresco) nunca acionava. Resultado: o timer de 60s, mais cada
/// hover no notch, batia na rede a cada tick contra um endpoint que tinha acabado de
/// pedir quase uma hora de espera, e o painel ficava "cached"/sem numero pra sempre.
enum UsageBackoff {
    /// Sem `Retry-After`: 1a falha espera isto, e dobra a cada falha seguida.
    static let baseDelay: TimeInterval = 60
    /// Teto da curva exponencial (o app volta a tentar de 15 em 15 min no pior caso).
    static let maxDelay: TimeInterval = 900
    /// Teto pro que o servidor pede: um `Retry-After` absurdo nao pode congelar o app.
    static let maxRetryAfter: TimeInterval = 3600

    /// Quanto esperar antes do proximo fetch. `Retry-After` do servidor manda (limitado ao
    /// teto); sem ele, exponencial 60s -> 120 -> 240 ... ate `maxDelay`.
    static func delay(consecutiveFailures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(retryAfter, maxRetryAfter)
        }
        let exponent = max(0, consecutiveFailures - 1)
        // Cap no expoente antes do pow: 2^grande vira infinito e min() com infinito
        // funciona, mas evita depender disso.
        let factor = pow(2.0, Double(min(exponent, 16)))
        return min(baseDelay * factor, maxDelay)
    }

    /// Le o header `Retry-After` em SEGUNDOS. A forma alternativa da RFC (data HTTP) e'
    /// deliberadamente ignorada (-> nil): melhor cair na curva exponencial do que inventar
    /// um deadline errado a partir de um formato que este endpoint nao usa.
    static func parseRetryAfter(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let seconds = TimeInterval(trimmed), seconds > 0 else { return nil }
        return seconds
    }
}

/// Portao de fetch da usage: guarda ate quando a rede esta proibida e quantas falhas
/// seguidas houve. Puro (sem I/O, sem relogio proprio: o `now` vem de fora), pra o
/// comportamento sob 429 ser testavel sem rede.
struct UsageFetchGate {
    private(set) var consecutiveFailures: Int = 0
    private(set) var nextAllowedAt: Date?

    /// `force` = refresh manual do usuario (botao do rodape): sempre passa. Ele pediu.
    func shouldFetch(now: Date, force: Bool) -> Bool {
        if force { return true }
        guard let nextAllowedAt else { return true }
        return now >= nextAllowedAt
    }

    mutating func recordFailure(retryAfter: TimeInterval?, now: Date) {
        consecutiveFailures += 1
        nextAllowedAt = now.addingTimeInterval(
            UsageBackoff.delay(consecutiveFailures: consecutiveFailures, retryAfter: retryAfter)
        )
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        nextAllowedAt = nil
    }
}
