import Testing
import Foundation
@testable import ClaudeNotch

/// Monta uma linha jsonl minima (so os campos que o parser olha).
private func jsonlLine(
    type: String, timestamp: String, sessionId: String, cwd: String? = nil,
    entrypoint: String? = nil,
    model: String? = nil, messageId: String? = nil,
    input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0
) -> String {
    var obj: [String: Any] = ["type": type, "timestamp": timestamp, "sessionId": sessionId]
    if let cwd { obj["cwd"] = cwd }
    if let entrypoint { obj["entrypoint"] = entrypoint }
    if type == "assistant" {
        var message: [String: Any] = [
            "model": model ?? "claude-sonnet-4-5",
            "usage": [
                "input_tokens": input, "output_tokens": output,
                "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheCreation,
            ] as [String: Any],
        ]
        if let messageId { message["id"] = messageId }
        obj["message"] = message
    }
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

/// ISO8601 de `secondsAgo` atras de AGORA. Fixture "ativa" precisa de turno REAL recente,
/// nao so mtime recente: a sessao ativa agora se mede pelo ultimo turno de verdade
/// (resposta do assistant), nao por quando o arquivo foi tocado por metadado.
private func recentISO(_ secondsAgo: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
}

/// Sandbox de disco temporario com o MESMO layout real validado na maquina:
/// <root>/<projeto>/<sessionId>.jsonl (principal) e
/// <root>/<projeto>/<sessionId>/subagents/agent-<id>.jsonl (subagent).
private final class ScannerSandbox {
    let root: URL
    let projectDir: URL

    init(projectSlug: String = "-Users-you-Documents-Apps-claude-notch") {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projectDir = root.appendingPathComponent(projectSlug)
        try! FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    func mainSessionURL(_ sessionId: String) -> URL {
        projectDir.appendingPathComponent("\(sessionId).jsonl")
    }

    func write(_ text: String, to url: URL) {
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try! Data(text.utf8).write(to: url)
    }

    func append(_ text: String, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    func setModificationDate(_ date: Date, at url: URL) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func subagentURL(sessionId: String, agentId: String) -> URL {
        projectDir.appendingPathComponent(sessionId).appendingPathComponent("subagents")
            .appendingPathComponent("agent-\(agentId).jsonl")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Scan incremental de sessoes")
struct SessionScannerTests {
    @Test("classifySession: ativa / ociosa / excluida (regra unica do scanner e do debug)")
    func classifySessionRule() {
        let now = Date()
        let win: TimeInterval = 7 * 60
        let idle: TimeInterval = 3 * 60 * 60
        let fresh = now.addingTimeInterval(-30)           // 30s: ativa
        let idleAge = now.addingTimeInterval(-20 * 60)    // 20min: ociosa (entre win e idle)
        let stale = now.addingTimeInterval(-4 * 60 * 60)  // 4h: fora (alem da idle)
        #expect(classifySession(entrypoint: "cli", activityTs: fresh, now: now, activeWindow: win, idleWindow: idle) == .active)
        #expect(classifySession(entrypoint: "cli", activityTs: idleAge, now: now, activeWindow: win, idleWindow: idle) == .idle)
        #expect(classifySession(entrypoint: "cli", activityTs: stale, now: now, activeWindow: win, idleWindow: idle) == .excludedStale)
        // worker/SDK = excluida por entrypoint, mesmo com turno recente
        #expect(classifySession(entrypoint: "sdk-py", activityTs: fresh, now: now, activeWindow: win, idleWindow: idle) == .excludedNonCLI("sdk-py"))
        // entrypoint ausente (formato antigo) = cli (fail-open); sem turno ainda = ativa
        #expect(classifySession(entrypoint: nil, activityTs: fresh, now: now, activeWindow: win, idleWindow: idle) == .active)
        #expect(classifySession(entrypoint: "cli", activityTs: nil, now: now, activeWindow: win, idleWindow: idle) == .active)
    }

    @Test("Alem da janela idle (arquivo >3h) nem chega a ser lido")
    func filtersByIdleWindow() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("s1")
        box.write(jsonlLine(type: "user", timestamp: recentISO(4 * 3600), sessionId: "s1",
                             cwd: "/Users/you/proj") + "\n", to: url)
        box.setModificationDate(Date().addingTimeInterval(-4 * 3600), at: url) // 4h: alem da idle

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.isEmpty)
    }

    @Test("cli ocioso (turno real entre a janela ativa e a idle) entra marcado isActive=false")
    func idleSessionMarkedIdle() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("idle1")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(20 * 60), sessionId: "idle1",
                             cwd: "/Users/you/proj", entrypoint: "cli", input: 100, cacheRead: 20) + "\n", to: url)
        box.setModificationDate(Date(), at: url) // arquivo tocado agora, mas turno real ha 20min

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.count == 1)
        #expect(sessions[0].isActive == false)      // ociosa, nao ativa
        #expect(sessions[0].contextTokens == 120)   // dados preservados
    }

    @Test("Ordena ativas antes de ociosas")
    func activeSortedBeforeIdle() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(20 * 60), sessionId: "idleS",
                             cwd: "/x", entrypoint: "cli", input: 5) + "\n", to: box.mainSessionURL("idleS"))
        box.setModificationDate(Date(), at: box.mainSessionURL("idleS"))
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(10), sessionId: "activeS",
                             cwd: "/y", entrypoint: "cli", input: 5) + "\n", to: box.mainSessionURL("activeS"))
        box.setModificationDate(Date(), at: box.mainSessionURL("activeS"))

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "activeS" && sessions[0].isActive)
        #expect(sessions[1].id == "idleS" && !sessions[1].isActive)
    }

    @Test("Worker/SDK (entrypoint != cli) no mesmo projeto de uma sessao real: nao duplica")
    func excludesSdkWorkerSessions() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        // terminal de verdade do usuario
        let cli = box.mainSessionURL("real")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: "real",
                            cwd: "/Users/you/proj", entrypoint: "cli", input: 10) + "\n", to: cli)
        box.setModificationDate(Date(), at: cli)
        // worker SDK (ex.: revisor de Workflow / code-review) gravando um jsonl top-level
        // no MESMO projeto: era isso que virava uma "segunda sessao" (a duplicata).
        let sdk = box.mainSessionURL("worker")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "worker",
                            cwd: "/Users/you/proj", entrypoint: "sdk-py", input: 10) + "\n", to: sdk)
        box.setModificationDate(Date(), at: sdk)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "real")
    }

    @Test("cli com ULTIMO turno real alem da idle (>3h), so mtime fresco por metadado: fora")
    func excludesStaleCliByRealTurn() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("ghost")
        // ultima conversa de verdade ha' 4h (alem da janela idle)...
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(4 * 3600), sessionId: "ghost",
                            cwd: "/Users/you/proj", entrypoint: "cli", input: 10) + "\n", to: url)
        // ...mas o arquivo foi TOCADO agora (last-prompt/file-history-snapshot/system).
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.isEmpty)
    }

    @Test("Sessao sem entrypoint (formato antigo) conta como interativa (fail-open)")
    func sessionWithoutEntrypointIsKept() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("legacy")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: "legacy",
                            cwd: "/Users/you/proj", input: 10) + "\n", to: url)
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "legacy")
    }

    @Test("Contexto atual = SOMENTE o ultimo turno, nao a soma cumulativa")
    func contextIsLastTurnOnly() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("s2")
        var content = jsonlLine(type: "user", timestamp: recentISO(3), sessionId: "s2",
                                 cwd: "/Users/you/proj") + "\n"
        content += jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: "s2",
                              input: 100, output: 10, cacheRead: 0, cacheCreation: 0) + "\n"
        content += jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "s2",
                              input: 50, output: 5, cacheRead: 20, cacheCreation: 0) + "\n"
        box.write(content, to: url)
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.count == 1)
        // ultimo turno: 50 + 20 = 70 (nao 100+50+20=170)
        #expect(sessions[0].contextTokens == 70)
        #expect(sessions[0].turns == 2)
        // total acumulado desde o inicio: (100+10) + (50+5+20) = 185
        #expect(sessions[0].totalTokens == 185)
    }

    @Test("Segundo scan so processa os bytes NOVOS (incremental), nao duplica contagem")
    func incrementalScanDoesNotReprocess() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("s3")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: "s3",
                             input: 10, output: 1) + "\n", to: url)
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let first = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(first[0].turns == 1)

        box.append(jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "s3",
                              input: 20, output: 2) + "\n", to: url)
        box.setModificationDate(Date(), at: url)
        let second = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(second[0].turns == 2) // 1 (ja contado) + 1 novo, nunca 1+2
        #expect(second[0].totalTokens == 11 + 22)
    }

    @Test("Linha incompleta (sem \\n ainda) fica em buffer e so conta quando fecha")
    func partialLineBuffered() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("s4")
        let fullLine = jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "s4",
                                  input: 5, output: 1)
        let half = String(fullLine.prefix(fullLine.count / 2))
        let rest = String(fullLine.suffix(fullLine.count - fullLine.count / 2))

        box.write(half, to: url) // sem newline: linha incompleta
        box.setModificationDate(Date(), at: url)
        var states: [String: SessionFileState] = [:]
        let mid = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(mid.isEmpty || mid[0].turns == 0) // nada contado ainda

        box.append(rest + "\n", to: url) // fecha a linha
        box.setModificationDate(Date(), at: url)
        let done = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(done[0].turns == 1)
        #expect(done[0].contextTokens == 5)
    }

    @Test("Arquivo truncado/rotacionado (tamanho encolheu) reprocessa do zero")
    func truncationResetsState() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("s5")
        box.write(
            jsonlLine(type: "assistant", timestamp: recentISO(3), sessionId: "s5", input: 999) + "\n"
            + jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: "s5", input: 999) + "\n",
            to: url
        )
        box.setModificationDate(Date(), at: url)
        var states: [String: SessionFileState] = [:]
        let before = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(before[0].turns == 2)

        // "rotacionou": arquivo novo, bem menor, mesmo nome
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "s5", input: 7) + "\n",
                  to: url)
        box.setModificationDate(Date(), at: url)
        let after = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(after[0].turns == 1)
        #expect(after[0].contextTokens == 7)
    }

    @Test("Subagent so agrega se a linha dele confirmar o sessionId do pai (vinculo explicito)")
    func subagentLinkageRequiresMatchingSessionId() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let parentId = "parent-1"
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(3), sessionId: parentId, input: 10) + "\n",
                  to: box.mainSessionURL(parentId))
        box.setModificationDate(Date(), at: box.mainSessionURL(parentId))

        // subagent de VERDADE: sessionId aponta pro pai certo
        let goodAgent = box.subagentURL(sessionId: parentId, agentId: "agentGood")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: parentId, input: 3) + "\n",
                  to: goodAgent)

        // arquivo "estranho" na mesma pasta, mas cita OUTRA sessao (nao deveria contar)
        let badAgent = box.subagentURL(sessionId: parentId, agentId: "agentBad")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: "outra-sessao", input: 3) + "\n",
                  to: badAgent)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions[0].agentsCount == 1)
        #expect(sessions[0].agents[0].id == "agentGood")
    }

    @Test("Rodar scan varias vezes sem mudanca nao duplica agents (sem double-count)")
    func repeatedScanDoesNotDuplicateAgents() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let parentId = "parent-2"
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(3), sessionId: parentId, input: 10) + "\n",
                  to: box.mainSessionURL(parentId))
        box.setModificationDate(Date(), at: box.mainSessionURL(parentId))
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: parentId, input: 3) + "\n",
                  to: box.subagentURL(sessionId: parentId, agentId: "ag1"))

        var states: [String: SessionFileState] = [:]
        _ = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        _ = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        let third = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(third[0].agentsCount == 1)
    }

    @Test("Varios content blocks do MESMO turno (mesmo message.id) contam so 1 vez")
    func sameMessageIdCountsOnce() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("s6")
        // um turno real vira varias linhas jsonl (thinking/text/tool_use...), todas com
        // o MESMO message.id e o MESMO usage completo repetido.
        var content = ""
        for _ in 0..<6 {
            content += jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: "s6",
                                  messageId: "msg_abc", input: 100, output: 10, cacheRead: 20) + "\n"
        }
        // 2o turno de verdade, id diferente
        content += jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "s6",
                              messageId: "msg_def", input: 50, output: 5) + "\n"
        box.write(content, to: url)
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions[0].turns == 2) // nao 7
        #expect(sessions[0].totalTokens == 130 + 55) // usage do msg_abc contado 1x + msg_def
    }

    @Test("Mesmo message.id reaparecendo NAO-adjacente (resume/rewind) conta 1x, nao de novo")
    func nonAdjacentDuplicateMessageIdCountsOnce() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("dup")
        // turno A, turno B (id diferente no meio), e A REAPARECE (replay de historico).
        var content = jsonlLine(type: "assistant", timestamp: recentISO(5), sessionId: "dup",
                                 messageId: "msg_A", input: 100, output: 10) + "\n"
        content += jsonlLine(type: "assistant", timestamp: recentISO(4), sessionId: "dup",
                              messageId: "msg_B", input: 50, output: 5) + "\n"
        content += jsonlLine(type: "assistant", timestamp: recentISO(3), sessionId: "dup",
                              messageId: "msg_A", input: 100, output: 10) + "\n" // replay do mesmo id
        box.write(content, to: url)
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions[0].turns == 2)                 // A e B, nao 3 (A recontado)
        #expect(sessions[0].totalTokens == 110 + 55)    // usage de A (1x) + B, nao A duas vezes
        #expect(sessions[0].contextTokens == 100)       // retrato = ultima linha fisica (replay A)
    }

    @Test("Turno final <synthetic> (erro de API) nao conta e mantem o ultimo turno REAL")
    func syntheticTurnIsIgnored() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("syn")
        var content = jsonlLine(type: "assistant", timestamp: recentISO(3), sessionId: "syn",
                                 model: "claude-opus-4-8", messageId: "real1", input: 200, cacheRead: 50) + "\n"
        // erro de API: model "<synthetic>", usage zerada, e a ULTIMA linha
        content += jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "syn",
                              model: "<synthetic>", messageId: "syn1", input: 0, output: 0) + "\n"
        box.write(content, to: url)
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.count == 1)
        #expect(sessions[0].turns == 1)                 // so o real, o synthetic nao conta
        #expect(sessions[0].contextTokens == 250)       // 200+50 do real, nao 0 do synthetic
        #expect(sessions[0].model == "claude-opus-4-8") // nao "<synthetic>"
    }

    @Test("Subagent fora da janela ativa (mtime velho) nao aparece mais na sessao ainda ativa")
    func staleSubagentIsExcludedByActiveWindow() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let parentId = "parent-3"
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: parentId, input: 10) + "\n",
                  to: box.mainSessionURL(parentId))
        box.setModificationDate(Date(), at: box.mainSessionURL(parentId)) // pai ativo agora

        let oldAgent = box.subagentURL(sessionId: parentId, agentId: "agentOld")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(2), sessionId: parentId, input: 3) + "\n",
                  to: oldAgent)
        box.setModificationDate(Date().addingTimeInterval(-3600), at: oldAgent) // 1h atras: fora da janela

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions[0].agentsCount == 0)
    }

    @Test("agent-*.jsonl solto na raiz do projeto nao vira sessao PRINCIPAL falsa")
    func looseAgentFileAtProjectRootIsIgnored() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let looseAgent = box.projectDir.appendingPathComponent("agent-af8a21a933142dec5.jsonl")
        box.write(jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "algumPai", input: 5) + "\n",
                  to: looseAgent)
        box.setModificationDate(Date(), at: looseAgent)

        var states: [String: SessionFileState] = [:]
        let sessions = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        #expect(sessions.isEmpty)
    }

    @Test("Arquivo grande (acima do teto por tick): contexto da cauda aparece na hora, turnos convergem aos poucos")
    func largeFilePreviewsTailThenConverges() {
        let box = ScannerSandbox()
        defer { box.cleanup() }
        let url = box.mainSessionURL("big1")
        // linhas de enchimento GRANDES (cwd inflado) pra passar do teto de 2MB/tick com
        // poucas linhas (poucos decodes), sem deixar o teste lento por causa disso.
        let padding = String(repeating: "x", count: 60_000)
        let filler = jsonlLine(type: "user", timestamp: recentISO(3), sessionId: "big1", cwd: padding) + "\n"
        let fillerBytes = filler.utf8.count
        let repeats = (3 * 1024 * 1024 / fillerBytes) + 1 // > teto de 2MB por tick
        var content = String(repeating: filler, count: repeats)
        content += jsonlLine(type: "assistant", timestamp: recentISO(1), sessionId: "big1",
                              messageId: "msg_last", input: 777) + "\n"
        box.write(content, to: url)
        box.setModificationDate(Date(), at: url)

        var states: [String: SessionFileState] = [:]
        let first = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
        // contexto/modelo do ULTIMO turno ja aparecem no 1o scan, via cauda, mesmo sem
        // ter processado o arquivo inteiro ainda (o scan incremental so alcanca o resto
        // aos poucos, ver abaixo).
        #expect(first[0].contextTokens == 777)

        // so linhas "user" antes do turno assistant: turns comeca em 0 e so vira 1
        // quando o scan incremental (budget-limitado) finalmente alcancar essa linha.
        var turns = first[0].turns
        var iterations = 0
        while turns == 0, iterations < 20 {
            let next = scanActiveSessions(projectsRoot: box.root, activeWindow: 7 * 60, states: &states)
            turns = next[0].turns
            iterations += 1
        }
        #expect(turns == 1)
    }
}
