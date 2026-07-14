import Testing
@testable import ClaudeNotch

/// Feature D: funcao pura que decide o pior % + cor do indicador colado no notch.
@Suite("compactUsageStatus: pior % + cor pro uso colado no notch")
struct CompactUsageStatusTests {
    private func snapshot(fiveHour: Int?, sevenDay: Int?, state: UsageState) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: fiveHour.map { Gauge(utilizationPct: $0, resetsAt: nil) },
            sevenDay: sevenDay.map { Gauge(utilizationPct: $0, resetsAt: nil) },
            opus: nil, sonnet: nil, planLabel: "", stale: nil, state: state,
            fetchedAt: nil, account: .none, extraUsage: nil
        )
    }

    @Test("estado .ok mostra o PIOR (max) dos dois medidores, com a cor do limiar")
    func picksWorstWhenOk() {
        let status = compactUsageStatus(for: snapshot(fiveHour: 21, sevenDay: 96, state: .ok))
        #expect(status.pct == 96)
        #expect(status.color == Theme.color(forPct: 96))
    }

    @Test("5h pior que semanal: ainda pega o maior dos dois")
    func picksWorstWhenFiveHourHigher() {
        let status = compactUsageStatus(for: snapshot(fiveHour: 82, sevenDay: 30, state: .ok))
        #expect(status.pct == 82)
        #expect(status.color == Theme.color(forPct: 82))
    }

    @Test("offline (mesmo com medidor de cache antigo) vira dot cinza, nunca numero")
    func offlineIsNeutralEvenWithStaleGauges() {
        let status = compactUsageStatus(for: snapshot(fiveHour: 21, sevenDay: 14, state: .offline))
        #expect(status.pct == nil)
        #expect(status.color == nil)
    }

    @Test("sem token vira dot cinza")
    func noTokenIsNeutral() {
        let status = compactUsageStatus(for: snapshot(fiveHour: nil, sevenDay: nil, state: .noToken))
        #expect(status.pct == nil)
        #expect(status.color == nil)
    }

    @Test("token expirado vira dot cinza")
    func expiredIsNeutral() {
        let status = compactUsageStatus(for: snapshot(fiveHour: nil, sevenDay: nil, state: .expired))
        #expect(status.pct == nil)
        #expect(status.color == nil)
    }

    @Test(".ok sem nenhum medidor (defensivo) tambem vira cinza, nunca 0%")
    func okWithoutGaugesIsNeutral() {
        let status = compactUsageStatus(for: snapshot(fiveHour: nil, sevenDay: nil, state: .ok))
        #expect(status.pct == nil)
        #expect(status.color == nil)
    }
}
