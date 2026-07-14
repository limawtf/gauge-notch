import Foundation

/// Junta os custos do ccusage (exato pro pai, estimado pro agent) nas sessoes ja
/// escaneadas. Puro (sem I/O), usado tanto pelo tick do SessionsService quanto pelo
/// snapshot headless (`--state agents-real`), pra garantir o MESMO calculo nos dois.
func mergeCosts(sessions: [AgentSession], costs: CcusageCosts) -> [AgentSession] {
    sessions.map { session in
        var session = session
        session.costUSD = costs.costsBySession[session.id]
        session.agents = session.agents.map { agent in
            var agent = agent
            // taxa do MODELO EXATO 1o (preco varia entre versoes); familia so como fallback
            // quando aquele modelo ainda nao apareceu no ccusage.
            let rate = costs.blendedRatePerModel[agent.model]
                ?? costs.blendedRatePerModelFamily[modelFamilyKey(agent.model)]
            if let rate {
                agent.costUSD = rate * Double(agent.totalTokens)
            }
            return agent
        }
        return session
    }
}
