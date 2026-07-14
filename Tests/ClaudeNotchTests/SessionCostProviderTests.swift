import Testing
import Foundation
@testable import ClaudeNotch

@Suite("Mapeamento ccusage period -> custo")
struct SessionCostProviderTests {
    @Test("period em formato UUID vira custo de sessao principal")
    func mapsSessionCostByUUIDPeriod() {
        let json = """
        {"session": [
            {"period": "11111111-1111-1111-1111-111111111111", "totalCost": 4.5,
             "modelBreakdowns": [{"modelName": "claude-opus-4-8", "cost": 4.5,
                                  "inputTokens": 10, "outputTokens": 100,
                                  "cacheReadTokens": 1000, "cacheCreationTokens": 500}]}
        ]}
        """
        let costs = parseCcusageOutput(Data(json.utf8))
        #expect(costs.costsBySession["11111111-1111-1111-1111-111111111111"] == 4.5)
    }

    @Test("period fora do formato UUID (ex. outro agente CLI) e ignorado como sessao")
    func ignoresNonUUIDPeriods() {
        let json = """
        {"session": [
            {"period": "20260703_145735_5a509b", "totalCost": 1.0, "modelBreakdowns": []}
        ]}
        """
        let costs = parseCcusageOutput(Data(json.utf8))
        #expect(costs.costsBySession.isEmpty)
    }

    @Test("Taxa media por familia = custo total / tokens totais daquela familia")
    func blendedRatePerFamily() {
        let json = """
        {"session": [
            {"period": "11111111-1111-1111-1111-111111111111", "totalCost": 10.0,
             "modelBreakdowns": [{"modelName": "claude-sonnet-4-5", "cost": 10.0,
                                  "inputTokens": 0, "outputTokens": 0,
                                  "cacheReadTokens": 1000000, "cacheCreationTokens": 0}]},
            {"period": "22222222-2222-2222-2222-222222222222", "totalCost": 5.0,
             "modelBreakdowns": [{"modelName": "claude-sonnet-4-7", "cost": 5.0,
                                  "inputTokens": 0, "outputTokens": 0,
                                  "cacheReadTokens": 500000, "cacheCreationTokens": 0}]}
        ]}
        """
        let costs = parseCcusageOutput(Data(json.utf8))
        // agrupado por FAMILIA (sonnet), nao por versao exata: (10+5) / (1_000_000+500_000)
        let rate = costs.blendedRatePerModelFamily["sonnet"]
        #expect(rate != nil)
        #expect(abs(rate! - (15.0 / 1_500_000.0)) < 0.0000001)
    }

    @Test("JSON invalido devolve custos vazios, nunca crasha")
    func invalidJSONReturnsEmpty() {
        let costs = parseCcusageOutput(Data("nao e json".utf8))
        #expect(costs.costsBySession.isEmpty)
        #expect(costs.blendedRatePerModelFamily.isEmpty)
    }

    @Test("modelFamilyKey agrupa por familia, ignorando versao")
    func familyKeyGrouping() {
        #expect(modelFamilyKey("claude-opus-4-8") == "opus")
        #expect(modelFamilyKey("claude-3-5-haiku-20241022") == "haiku")
        #expect(modelFamilyKey("gpt-4o") == "gpt-4o")
    }
}

@Suite("Merge de custo nas sessoes escaneadas")
struct SessionCostMergeTests {
    @Test("Custo do pai vem do dicionario por sessionId; agent vem da taxa media x tokens")
    func mergesParentAndAgentCosts() {
        let session = AgentSession(
            id: "sess-1", project: "p", projectPath: "/tmp/p", model: "claude-opus-4-8",
            contextTokens: 100, contextWindow: 200_000, turns: 1, totalTokens: 100, costUSD: nil,
            agents: [
                SubagentSession(id: "a1", description: nil, model: "claude-sonnet-4-5",
                                 contextTokens: 10, totalTokens: 1000, costUSD: nil, lastActivity: Date())
            ],
            lastActivity: Date(), startedAt: nil,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0
        )
        let costs = CcusageCosts(
            costsBySession: ["sess-1": 7.0],
            blendedRatePerModelFamily: ["sonnet": 0.002]
        )
        let merged = mergeCosts(sessions: [session], costs: costs)
        #expect(merged[0].costUSD == 7.0)
        #expect(merged[0].agents[0].costUSD == 2.0) // 1000 * 0.002
    }

    @Test("Custo do agent usa a taxa do MODELO EXATO; familia so como fallback")
    func exactModelRatePreferredOverFamily() {
        func agent(_ model: String) -> SubagentSession {
            SubagentSession(id: "a", description: nil, model: model, contextTokens: 0,
                            totalTokens: 1000, costUSD: nil, lastActivity: Date())
        }
        func session(_ a: SubagentSession) -> AgentSession {
            AgentSession(id: "s", project: "p", projectPath: "/p", model: "claude-opus-4-8",
                         contextTokens: 0, contextWindow: nil, turns: 1, totalTokens: 0, costUSD: nil,
                         agents: [a], lastActivity: Date(), startedAt: nil,
                         inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        }
        let costs = CcusageCosts(
            blendedRatePerModel: ["claude-sonnet-5": 0.001],   // versao nova, taxa propria
            blendedRatePerModelFamily: ["sonnet": 0.005]        // blend da familia (mistura versoes)
        )
        // modelo exato existe -> usa 0.001 (nao o 0.005 da familia)
        #expect(mergeCosts(sessions: [session(agent("claude-sonnet-5"))], costs: costs)[0].agents[0].costUSD == 1.0)
        // modelo exato AUSENTE do ccusage -> cai pro blend da familia (0.005)
        #expect(mergeCosts(sessions: [session(agent("claude-sonnet-4-6"))], costs: costs)[0].agents[0].costUSD == 5.0)
    }

    @Test("Sessao/familia sem dado no ccusage fica com custo nil, nao zero forjado")
    func missingCostStaysNil() {
        let session = AgentSession(
            id: "sess-2", project: "p", projectPath: "/tmp/p", model: "claude-opus-4-8",
            contextTokens: 100, contextWindow: 200_000, turns: 1, totalTokens: 100, costUSD: nil,
            agents: [], lastActivity: Date(), startedAt: nil,
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0
        )
        let merged = mergeCosts(sessions: [session], costs: CcusageCosts())
        #expect(merged[0].costUSD == nil)
    }
}

@Suite("Execucao de processo externo (drain concorrente + timeout)")
struct RunProcessCapturingStdoutTests {
    @Test("Processo que enche o stderr ANTES de terminar nao trava (deadlock classico se so o stdout for lido)")
    func doesNotDeadlockOnFullStderrBuffer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // escreve > 64KB (buffer tipico do Pipe) em stderr num comando SO (sem pipe
        // shell, que teria redirecionamento ambiguo), so DEPOIS ecoa o stdout
        process.arguments = ["-c", "head -c 200000 /dev/zero >&2; echo '{\"ok\":true}'"]

        let start = Date()
        let data = runProcessCapturingStdout(process, timeout: 5)
        #expect(Date().timeIntervalSince(start) < 5) // nao esperou o timeout: nao travou
        #expect(data != nil)
        #expect(String(data: data ?? Data(), encoding: .utf8)?.contains("ok") == true)
    }

    @Test("Processo que nunca termina e morto pelo timeout, sem prender quem chamou pra sempre")
    func killsHangingProcessAfterTimeout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 30"]

        let start = Date()
        let data = runProcessCapturingStdout(process, timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        #expect(data == nil)
        #expect(elapsed < 5) // matou perto do timeout de 1s, nao esperou os 30s do sleep
    }

    @Test("Processo normal (saida pequena, termina rapido) retorna o stdout")
    func returnsStdoutForNormalProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["ola"]
        let data = runProcessCapturingStdout(process, timeout: 5)
        #expect(String(data: data ?? Data(), encoding: .utf8) == "ola\n")
    }
}
