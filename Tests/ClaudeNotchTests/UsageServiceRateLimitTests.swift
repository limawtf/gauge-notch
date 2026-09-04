import Foundation
import Testing
@testable import ClaudeNotch

/// Duble da rede: conta quantas vezes o servico bateu na API e responde o que o teste mandar.
private final class FakeUsageAPI: UsageFetching, @unchecked Sendable {
    enum Behavior {
        case ok(Data)
        case fail(Error)
    }

    private let lock = NSLock()
    private var _behavior: Behavior
    private var _usageCalls = 0

    init(_ behavior: Behavior) { _behavior = behavior }

    var usageCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _usageCalls
    }

    func set(_ behavior: Behavior) {
        lock.lock(); defer { lock.unlock() }
        _behavior = behavior
    }

    func fetchUsageRaw(token: String) async throws -> Data {
        lock.lock()
        _usageCalls += 1
        let behavior = _behavior
        lock.unlock()
        switch behavior {
        case .ok(let data): return data
        case .fail(let error): throw error
        }
    }

    func fetchProfileRaw(token: String) async throws -> Data {
        throw UsageAPIError.network(URLError(.notConnectedToInternet))
    }
}

/// Comportamento do UsageService quando a `oauth/usage` esta rate-limitada (429). Nasceu
/// do bug de 2026-09-04: com 429 o app perdia o dado, mostrava 0% e continuava batendo na
/// API a cada tick de 60s.
@Suite("UsageService sob 429: nao martela a API e nao perde o ultimo valor bom")
@MainActor
struct UsageServiceRateLimitTests {
    private func makeCache() -> (UsageCache, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notch-rl-\(UUID().uuidString)")
        return (UsageCache(directory: tmpDir), tmpDir)
    }

    private func makeService(api: FakeUsageAPI, cache: UsageCache) -> UsageService {
        UsageService(
            api: api, cache: cache,
            credentialsProvider: {
                KeychainReader.Credentials(accessToken: "sk-test", subscriptionType: "max")
            }
        )
    }

    @Test("429 com cache no disco: mantem os numeros e marca stale (nao zera o painel)")
    func keepsCachedNumbersOn429() async {
        let (cache, tmpDir) = makeCache()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        cache.write(cache.usageURL, data: Fixtures.usageJSON(fiveHourPct: 42))

        let api = FakeUsageAPI(.fail(UsageAPIError.http(429, retryAfter: 3090)))
        let service = makeService(api: api, cache: cache)

        // TTL do cache e' 300s e o arquivo acabou de ser escrito, entao um refresh normal
        // nem iria na rede: e' o refresh MANUAL que expoe o caminho de falha.
        await service.forceRefresh()

        #expect(service.snapshot.fiveHour?.utilizationPct == 42)
        #expect(service.snapshot.stale == "429 (busy)")
        #expect(service.snapshot.hasAnyGauge == true)
    }

    @Test("refresh manual que falha NAO destroi o cache (bug: apagava antes de tentar)")
    func forceRefreshKeepsCacheFileOnFailure() async {
        let (cache, tmpDir) = makeCache()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        cache.write(cache.usageURL, data: Fixtures.usageJSON(fiveHourPct: 42))

        let api = FakeUsageAPI(.fail(UsageAPIError.http(429, retryAfter: 3090)))
        let service = makeService(api: api, cache: cache)
        await service.forceRefresh()

        #expect(cache.read(cache.usageURL) != nil)
        // E segue servindo depois: um segundo clique ainda acha o valor bom.
        await service.forceRefresh()
        #expect(service.snapshot.fiveHour?.utilizationPct == 42)
    }

    @Test("depois de um 429, os refreshes automaticos param de bater na API ate o deadline")
    func backoffStopsAutomaticRefreshes() async {
        let (cache, tmpDir) = makeCache()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let api = FakeUsageAPI(.fail(UsageAPIError.http(429, retryAfter: 3090)))
        let service = makeService(api: api, cache: cache)

        await service.refresh()
        #expect(api.usageCalls == 1)

        // Estes seriam os ticks do timer de 60s / hovers: antes do fix, cada um era uma
        // request nova contra um endpoint que pediu 51 min de espera.
        for _ in 1...10 { await service.refresh() }
        #expect(api.usageCalls == 1)
    }

    @Test("o refresh manual continua furando o backoff (o usuario pediu)")
    func manualRefreshBypassesBackoff() async {
        let (cache, tmpDir) = makeCache()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let api = FakeUsageAPI(.fail(UsageAPIError.http(429, retryAfter: 3090)))
        let service = makeService(api: api, cache: cache)

        await service.refresh()
        await service.refresh()
        #expect(api.usageCalls == 1)

        await service.forceRefresh()
        #expect(api.usageCalls == 2)
    }

    @Test("sem cache e sem rede: painel fica sem numero (nao inventa 0%) e diz o motivo")
    func noCacheNoNetworkShowsNoNumbers() async {
        let (cache, tmpDir) = makeCache()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let api = FakeUsageAPI(.fail(UsageAPIError.http(429, retryAfter: 3090)))
        let service = makeService(api: api, cache: cache)
        await service.refresh()

        #expect(service.snapshot.fiveHour == nil)
        #expect(service.snapshot.sevenDay == nil)
        #expect(service.snapshot.hasAnyGauge == false)
        #expect(service.snapshot.stale == "429 (busy)")
    }

    @Test("fetch que da certo escreve o cache e limpa o stale")
    func successWritesCacheAndClearsStale() async {
        let (cache, tmpDir) = makeCache()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let api = FakeUsageAPI(.ok(Fixtures.usageJSON(fiveHourPct: 77)))
        let service = makeService(api: api, cache: cache)
        await service.refresh()

        #expect(service.snapshot.fiveHour?.utilizationPct == 77)
        #expect(service.snapshot.stale == nil)
        #expect(cache.read(cache.usageURL) != nil)
    }

    @Test("sucesso depois de falha reabre o portao (backoff nao gruda)")
    func successAfterFailureReopensGate() async {
        let (cache, tmpDir) = makeCache()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let api = FakeUsageAPI(.fail(UsageAPIError.http(429, retryAfter: 3090)))
        let service = makeService(api: api, cache: cache)
        await service.refresh()
        #expect(api.usageCalls == 1)

        // Refresh manual passa pelo portao e desta vez a API responde.
        api.set(.ok(Fixtures.usageJSON(fiveHourPct: 12)))
        await service.forceRefresh()
        #expect(service.snapshot.fiveHour?.utilizationPct == 12)
        #expect(service.snapshot.stale == nil)

        // Portao aberto de novo: um refresh automatico volta a poder ir na rede quando o
        // cache expirar (aqui forcamos expirando o TTL na marra).
        cache.remove(cache.usageURL)
        await service.refresh()
        #expect(api.usageCalls == 3)
    }
}
