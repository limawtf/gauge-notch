import Testing
import Foundation
@testable import ClaudeNotch

@Suite("Formula de contexto, media e burn-rate")
struct AgentSessionTests {
    @Test("Ate 200K, janela nominal e conhecida")
    func windowKnownUnder200k() {
        #expect(contextWindow(forTokens: 199_999) == 200_000)
        #expect(contextWindow(forTokens: 200_000) == 200_000)
    }

    @Test("Acima de 200K a janela e ambigua (nil): nao afirma % sem base")
    func windowAmbiguousAbove200k() {
        // ressalva real do spec: turno mediu ~390K com cache_read alto
        #expect(contextWindow(forTokens: 390_000) == nil)
    }

    @Test("contextPct usa contextWindow; nil quando a janela e ambigua")
    func contextPctRespectsAmbiguousWindow() {
        var session = makeSession(contextTokens: 100_000, contextWindow: 200_000)
        #expect(session.contextPct == 50)

        session.contextTokens = 390_000
        session.contextWindow = nil
        #expect(session.contextPct == nil)
    }

    @Test("Media de tokens por turno = total / turnos, 0 turnos nao divide por zero")
    func avgTokensPerTurn() {
        var session = makeSession(contextTokens: 1000, contextWindow: 200_000)
        session.turns = 4
        session.totalTokens = 4000
        #expect(session.avgTokensPerTurn == 1000)

        session.turns = 0
        #expect(session.avgTokensPerTurn == 0)
    }

    @Test("agentsCostUSD soma os que tem custo; nil so quando NENHUM tem (nao forja $0)")
    func agentsCostSum() {
        var session = makeSession(contextTokens: 1000, contextWindow: 200_000)
        session.agents = [
            SubagentSession(id: "a1", description: nil, model: "claude-sonnet-4-5",
                             contextTokens: 100, totalTokens: 200, costUSD: 1.5, lastActivity: Date()),
            SubagentSession(id: "a2", description: nil, model: "claude-sonnet-4-5",
                             contextTokens: 100, totalTokens: 200, costUSD: nil, lastActivity: Date()),
        ]
        #expect(session.agentsCostUSD == 1.5) // a2 sem custo entra como 0
        #expect(session.agentsCount == 2)

        // nenhum subagent com custo (ccusage sem dado) -> nil, pra UI mostrar "-" nao "$0"
        session.agents = [
            SubagentSession(id: "a3", description: nil, model: "claude-sonnet-4-5",
                             contextTokens: 100, totalTokens: 200, costUSD: nil, lastActivity: Date()),
        ]
        #expect(session.agentsCostUSD == nil)
    }

    @Test("Burn-rate so aparece com sessao de pelo menos 1min (evita numero estourado)")
    func burnRateNeedsMinimumDuration() {
        let now = Date()
        var session = makeSession(contextTokens: 1000, contextWindow: 200_000)
        session.costUSD = 3.6
        session.totalTokens = 60_000
        session.startedAt = now.addingTimeInterval(-30) // 30s: curto demais
        session.lastActivity = now
        #expect(session.burnRateUSDPerHour == nil)
        #expect(session.burnTokPerMin == nil)

        session.startedAt = now.addingTimeInterval(-3600) // 1h
        #expect(session.burnRateUSDPerHour == 3.6)
        #expect(session.burnTokPerMin == 1000)
    }

    private func makeSession(contextTokens: Int, contextWindow: Int?) -> AgentSession {
        AgentSession(
            id: "s1", project: "proj", projectPath: "/tmp/proj", model: "claude-sonnet-4-5",
            contextTokens: contextTokens, contextWindow: contextWindow, turns: 1, totalTokens: contextTokens,
            costUSD: nil, agents: [], lastActivity: Date(), startedAt: nil,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0
        )
    }
}

@Suite("Formatacao compacta")
struct AgentFormattingTests {
    @Test("Tokens compactos")
    func tokensShort() {
        #expect(formatTokensShort(900) == "900")
        #expect(formatTokensShort(45_000) == "45K")
        #expect(formatTokensShort(1_234_000) == "1.2M")
    }

    @Test("USD compacto por magnitude")
    func usdCompact() {
        #expect(formatUSD(nil) == "$0")
        #expect(formatUSD(0.42) == "$0.42")
        #expect(formatUSD(6.2) == "$6.2")
        #expect(formatUSD(163.9) == "$164")
    }

    @Test("Duracao h/min, nil vira travessao neutro")
    func duration() {
        #expect(formatDuration(nil) == "-")
        #expect(formatDuration(90 * 60) == "1h30min")
        #expect(formatDuration(20 * 60) == "20min")
    }

    @Test("Heroi Hoje/Mes/Total usa a MESMA precisao decimal (derivada do maior)")
    func spendHeroTrioSharedPrecision() {
        // Maior >= 10 -> os 3 sem decimal, mesmo o pequeno (4.3 -> "$4").
        let a = formatSpendHeroTrio((today: 4.3, month: 96.0, total: 812.0))
        #expect(a == (today: "$4", month: "$96", total: "$812"))

        // Maior entre 1 e 10 -> os 3 com 1 casa.
        let b = formatSpendHeroTrio((today: 0.42, month: 6.2, total: 6.2))
        #expect(b == (today: "$0.4", month: "$6.2", total: "$6.2"))

        // Maior < 1 -> os 3 com 2 casas.
        let c = formatSpendHeroTrio((today: 0.05, month: 0.42, total: 0.42))
        #expect(c == (today: "$0.05", month: "$0.42", total: "$0.42"))

        // nil vira "-", zero vira "$0", independente da precisao escolhida pelos outros.
        let d = formatSpendHeroTrio((today: nil, month: 0, total: 250))
        #expect(d == (today: "-", month: "$0", total: "$250"))
    }
}
