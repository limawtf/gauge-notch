import Foundation

/// Uso de tokens de UM turno assistant (linha do jsonl). Contexto = o que fica na
/// janela agora (input + cache); total = tudo que passou pela API nesse turno.
struct TurnUsage: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    var contextTokens: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

/// Janela nominal de contexto assumida quando o modelo nao sinaliza 1M beta (jan/2026:
/// todos os modelos Claude correntes sao 200K por padrao). Acima disso NAO afirmamos
/// "% da janela" (pode ser sessao com beta de 1M, ou so cache alto) e caimos pro numero
/// absoluto (ressalva do spec: turno real mediu ~390K, acima dos 200K nominais).
let nominalContextWindow = 200_000

func contextWindow(forTokens tokens: Int) -> Int? {
    tokens > nominalContextWindow ? nil : nominalContextWindow
}

/// Um subagent (Task tool) vinculado a uma sessao principal. Linkagem explicita: o
/// campo `sessionId` de dentro do proprio agent-*.jsonl aponta pra sessao pai (ver
/// SessionScanner). Custo e estimado (ccusage nao expoe period por agentId).
struct SubagentSession: Identifiable, Equatable {
    let id: String
    var description: String?
    var model: String
    var contextTokens: Int
    var totalTokens: Int
    var costUSD: Double?
    var lastActivity: Date
}

/// Uma sessao principal ativa do Claude Code, com os subagents dela agregados.
struct AgentSession: Identifiable, Equatable {
    let id: String              // sessionId (nome do arquivo .jsonl)
    var project: String         // nome legivel (ultimo componente do cwd, ou fallback do slug)
    var projectPath: String     // cwd completo, se capturado
    var model: String           // do ultimo turno assistant
    var contextTokens: Int      // do ultimo turno: input + cache_read + cache_creation
    var contextWindow: Int?     // nil = ambiguo, UI mostra so o numero
    var turns: Int               // contagem de mensagens assistant com usage
    var totalTokens: Int         // soma de tokens desde o inicio (contador incremental)
    var costUSD: Double?         // ccusage, period == sessionId
    var agents: [SubagentSession]
    var lastActivity: Date
    var startedAt: Date?
    // breakdown do ULTIMO turno (nao cumulativo), pra mostrar composicao do burn atual
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    /// true = ativa (ultimo turno real dentro da janela ativa). false = OCIOSA (turno real
    /// mais antigo que a janela ativa, mas ainda dentro da idle): a UI mostra esmaecida com
    /// "ocioso ha X". Default true pros fixtures/testes; o scanner seta de verdade.
    var isActive: Bool = true

    var avgTokensPerTurn: Int { turns > 0 ? totalTokens / turns : 0 }
    var agentsCount: Int { agents.count }
    /// Soma do custo estimado dos subagents. nil quando NENHUM tem custo (ex. ccusage sem
    /// dado ainda): a UI mostra "-" em vez de forjar "$0". Se ao menos um tem custo, soma
    /// os que tem (os sem estimativa entram como 0).
    var agentsCostUSD: Double? {
        let costs = agents.compactMap { $0.costUSD }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var contextPct: Int? {
        guard let w = contextWindow, w > 0 else { return nil }
        return Int((Double(contextTokens) / Double(w) * 100).rounded())
    }

    var durationSeconds: TimeInterval? {
        guard let startedAt else { return nil }
        let d = lastActivity.timeIntervalSince(startedAt)
        return d > 0 ? d : nil
    }

    /// US$/hora desde o inicio da sessao. nil se sessao muito nova (<1min) pra nao
    /// mostrar um numero estourado por causa de arredondamento.
    var burnRateUSDPerHour: Double? {
        guard let costUSD, let durationSeconds, durationSeconds >= 60 else { return nil }
        return costUSD / (durationSeconds / 3600)
    }

    var burnTokPerMin: Double? {
        guard let durationSeconds, durationSeconds >= 60 else { return nil }
        return Double(totalTokens) / (durationSeconds / 60)
    }
}
