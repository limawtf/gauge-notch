import Foundation
import Testing
@testable import ClaudeNotch

/// Bug real (2026-09-04): a `oauth/usage` devolvia 429 com `retry-after: 3090` (51 min) e o
/// app IGNORAVA. Como o cache so' e' escrito em fetch BEM-SUCEDIDO, uma falha deixava o
/// disco vazio, e ai o timer de 60s (mais cada hover) batia na rede A CADA TICK: ~60
/// requests/hora contra um endpoint que pediu quase uma hora de espera. O painel ficava
/// "cached"/sem numero pra sempre. Estes testes travam o portao de fetch.
@Suite("Backoff da usage API (respeitar Retry-After em vez de bater a cada 60s)")
struct UsageBackoffTests {
    @Test("Retry-After em segundos e' lido do header")
    func parsesRetryAfterSeconds() {
        #expect(UsageBackoff.parseRetryAfter("3090") == 3090)
        #expect(UsageBackoff.parseRetryAfter(" 45 ") == 45)
    }

    @Test("Retry-After ausente/invalido -> nil (cai na curva exponencial)")
    func parsesRetryAfterGarbage() {
        #expect(UsageBackoff.parseRetryAfter(nil) == nil)
        #expect(UsageBackoff.parseRetryAfter("") == nil)
        #expect(UsageBackoff.parseRetryAfter("depois") == nil)
        // Data HTTP (formato alternativo da RFC) nao e' suportada: melhor cair na curva
        // do que inventar um deadline errado.
        #expect(UsageBackoff.parseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        // Zero/negativo nao vale como espera.
        #expect(UsageBackoff.parseRetryAfter("0") == nil)
        #expect(UsageBackoff.parseRetryAfter("-5") == nil)
    }

    @Test("com Retry-After: a espera e' a do servidor (fonte da verdade)")
    func honorsServerRetryAfter() {
        #expect(UsageBackoff.delay(consecutiveFailures: 1, retryAfter: 3090) == 3090)
        // Mesmo na 1a falha, um Retry-After grande manda: nunca voltar antes da hora.
        #expect(UsageBackoff.delay(consecutiveFailures: 1, retryAfter: 600) == 600)
    }

    @Test("Retry-After absurdo e' limitado ao teto de 1h (nunca congela o app pra sempre)")
    func clampsAbsurdRetryAfter() {
        #expect(UsageBackoff.delay(consecutiveFailures: 1, retryAfter: 99999) == 3600)
    }

    @Test("sem Retry-After: curva exponencial 1min -> 2 -> 4 -> ... com teto de 15min")
    func exponentialWithoutHeader() {
        #expect(UsageBackoff.delay(consecutiveFailures: 1, retryAfter: nil) == 60)
        #expect(UsageBackoff.delay(consecutiveFailures: 2, retryAfter: nil) == 120)
        #expect(UsageBackoff.delay(consecutiveFailures: 3, retryAfter: nil) == 240)
        #expect(UsageBackoff.delay(consecutiveFailures: 4, retryAfter: nil) == 480)
        #expect(UsageBackoff.delay(consecutiveFailures: 5, retryAfter: nil) == 900)
        #expect(UsageBackoff.delay(consecutiveFailures: 50, retryAfter: nil) == 900)
    }

    @Test("mapUsageError propaga o Retry-After do 429 pra quem decide o backoff")
    func mapUsageErrorCarriesRetryAfter() {
        let mapped = mapUsageError(UsageAPIError.http(429, retryAfter: 3090))
        #expect(mapped.reason == "429 (busy)")
        #expect(mapped.expired == false)
        #expect(mapped.retryAfter == 3090)
    }
}

@Suite("UsageFetchGate: so bate na rede quando pode (falha nao vira martelo de 60s)")
struct UsageFetchGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("estado inicial: pode buscar")
    func allowsFirstFetch() {
        let gate = UsageFetchGate()
        #expect(gate.shouldFetch(now: t0, force: false) == true)
    }

    @Test("apos falha com Retry-After: bloqueia ate o deadline, libera depois")
    func blocksUntilDeadline() {
        var gate = UsageFetchGate()
        gate.recordFailure(retryAfter: 300, now: t0)

        #expect(gate.shouldFetch(now: t0, force: false) == false)
        #expect(gate.shouldFetch(now: t0.addingTimeInterval(299), force: false) == false)
        #expect(gate.shouldFetch(now: t0.addingTimeInterval(300), force: false) == true)
    }

    @Test("o tick de 60s NAO fura o backoff (era o bug: 60 requests/hora sob 429)")
    func sixtySecondTickDoesNotBypass() {
        var gate = UsageFetchGate()
        gate.recordFailure(retryAfter: 3090, now: t0)

        // Simula uma hora inteira de ticks do timer: nenhum deles pode bater na rede.
        var permitidos = 0
        for minuto in 1...50 {
            if gate.shouldFetch(now: t0.addingTimeInterval(Double(minuto) * 60), force: false) {
                permitidos += 1
            }
        }
        #expect(permitidos == 0)
    }

    @Test("falhas seguidas sem header aumentam a espera (1min, 2min, 4min)")
    func consecutiveFailuresBackOff() {
        var gate = UsageFetchGate()
        gate.recordFailure(retryAfter: nil, now: t0)
        #expect(gate.shouldFetch(now: t0.addingTimeInterval(59), force: false) == false)
        #expect(gate.shouldFetch(now: t0.addingTimeInterval(60), force: false) == true)

        let t1 = t0.addingTimeInterval(60)
        gate.recordFailure(retryAfter: nil, now: t1)
        #expect(gate.shouldFetch(now: t1.addingTimeInterval(119), force: false) == false)
        #expect(gate.shouldFetch(now: t1.addingTimeInterval(120), force: false) == true)

        let t2 = t1.addingTimeInterval(120)
        gate.recordFailure(retryAfter: nil, now: t2)
        #expect(gate.shouldFetch(now: t2.addingTimeInterval(239), force: false) == false)
        #expect(gate.shouldFetch(now: t2.addingTimeInterval(240), force: false) == true)
    }

    @Test("sucesso zera o backoff (proxima falha volta a esperar 1min, nao 15)")
    func successResetsBackoff() {
        var gate = UsageFetchGate()
        gate.recordFailure(retryAfter: nil, now: t0)
        gate.recordFailure(retryAfter: nil, now: t0)
        gate.recordFailure(retryAfter: nil, now: t0)
        gate.recordSuccess()

        #expect(gate.shouldFetch(now: t0, force: false) == true)
        gate.recordFailure(retryAfter: nil, now: t0)
        #expect(gate.shouldFetch(now: t0.addingTimeInterval(60), force: false) == true)
    }

    @Test("refresh MANUAL (botao do rodape) fura o backoff: e' o usuario pedindo")
    func forceBypassesBackoff() {
        var gate = UsageFetchGate()
        gate.recordFailure(retryAfter: 3090, now: t0)
        #expect(gate.shouldFetch(now: t0, force: true) == true)
    }
}
