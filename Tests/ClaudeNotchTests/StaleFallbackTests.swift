import Foundation
import Testing
@testable import ClaudeNotch

@Suite("Fallback stale em erro (mapeamento de erro da API)")
struct StaleFallbackTests {
    @Test("401 -> HTTP 401, expirado")
    func unauthorized() {
        let mapped = mapUsageError(UsageAPIError.http(401))
        #expect(mapped.reason == "HTTP 401")
        #expect(mapped.expired == true)
    }

    @Test("403 -> HTTP 403, expirado")
    func forbidden() {
        let mapped = mapUsageError(UsageAPIError.http(403))
        #expect(mapped.reason == "HTTP 403")
        #expect(mapped.expired == true)
    }

    @Test("429 -> '429 (busy)', nao expirado (serve cache)")
    func rateLimited() {
        let mapped = mapUsageError(UsageAPIError.http(429))
        #expect(mapped.reason == "429 (busy)")
        #expect(mapped.expired == false)
    }

    @Test("outro HTTP -> 'HTTP n', nao expirado")
    func otherHTTP() {
        let mapped = mapUsageError(UsageAPIError.http(500))
        #expect(mapped.reason == "HTTP 500")
        #expect(mapped.expired == false)
    }

    @Test("erro de rede -> offline")
    func networkError() {
        struct Whatever: Error {}
        let mapped = mapUsageError(UsageAPIError.network(Whatever()))
        #expect(mapped.reason == "offline")
        #expect(mapped.expired == false)
    }

    @Test("fallback: cache antigo ainda decodifica mesmo apos erro (nao existe mais TTL, so leitura crua)")
    func staleCacheStillReadable() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notch-tests-\(UUID().uuidString)")
        let cache = UsageCache(directory: tmpDir)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let payload = Fixtures.usageJSON(fiveHourPct: 33)
        cache.write(cache.usageURL, data: payload)

        // mesmo com TTL zerado (cache "velho"), read() cru ainda devolve o ultimo bom valor.
        let raw = cache.read(cache.usageURL)
        #expect(raw != nil)
        let decoded = try JSONDecoder().decode(UsageResponse.self, from: raw!)
        #expect(decoded.fiveHour?.utilization == 33)
    }
}
