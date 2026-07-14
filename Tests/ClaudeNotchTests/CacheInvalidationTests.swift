import Foundation
import Testing
@testable import ClaudeNotch

@Suite("Invalidacao de cache quando o reset ja passou")
struct CacheInvalidationTests {
    @Test("reset no futuro -> cache ainda valido")
    func futureResetNotPassed() throws {
        let data = Fixtures.usageJSON(fiveHourResetsAt: "2099-01-01T00:00:00Z")
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(fiveHourResetPassed(resp) == false)
    }

    @Test("reset no passado -> cache invalidado (janela virou)")
    func pastResetPassed() throws {
        let data = Fixtures.usageJSON(fiveHourResetsAt: "2020-01-01T00:00:00Z")
        let resp = try JSONDecoder().decode(UsageResponse.self, from: data)
        #expect(fiveHourResetPassed(resp) == true)
    }

    @Test("resets_at ausente -> nunca invalida por conta disso")
    func missingResetsAtNeverPassed() throws {
        let json = Data("""
        { "five_hour": {"utilization": 10} }
        """.utf8)
        let resp = try JSONDecoder().decode(UsageResponse.self, from: json)
        #expect(fiveHourResetPassed(resp) == false)
    }

    @Test("UsageCache.readFresh respeita o TTL")
    func cacheTTL() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notch-tests-\(UUID().uuidString)")
        let cache = UsageCache(directory: tmpDir)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let payload = Fixtures.usageJSON()
        cache.write(cache.usageURL, data: payload)

        // TTL grande: ainda fresco.
        #expect(cache.readFresh(cache.usageURL, ttl: 300) == payload)
        // TTL zero (ja "expirado" no instante da escrita): nao deve servir fresco.
        #expect(cache.readFresh(cache.usageURL, ttl: 0) == nil)
    }
}
