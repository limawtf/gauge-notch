import Foundation

/// Estado incremental de UM arquivo jsonl (sessao principal ou subagent). Guardado
/// entre ticks: no proximo scan so lemos os bytes NOVOS a partir de `offset` (o
/// arquivo e append-only). `leftover` guarda o resto de uma linha ainda incompleta
/// (o assistant pode estar escrevendo no meio de um flush).
final class SessionFileState {
    var offset: UInt64 = 0
    var fileSize: UInt64 = 0
    var leftover: [UInt8] = []
    var turns = 0
    var totalTokens = 0
    var model = ""
    var lastUsage = TurnUsage()
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var cwd: String?
    /// `entrypoint` da sessao (`cli` = terminal aberto pelo usuario; `sdk-py`/`sdk-*` =
    /// worker/automacao, ex.: subagente de Workflow ou code-review que grava um jsonl
    /// top-level no mesmo projeto de uma sessao real). So `cli` conta como sessao ativa.
    var entrypoint: String?
    /// timestamp do ULTIMO turno REAL (resposta do assistant), nao de qualquer linha:
    /// eventos de metadado (last-prompt, file-history-snapshot, system) tocam o arquivo
    /// sem conversa nova. A "atividade" da sessao se mede por isto, nao pelo mtime.
    var lastRealTurnTimestamp: Date?
    /// timestamp da linha que fixou o RETRATO atual (cwd/modelo/contexto). O snapshot so
    /// avanca no tempo: o scan incremental relê o COMECO do arquivo (linhas antigas) e nao
    /// pode sobrescrever o cwd/modelo/contexto que o previewTail leu da cauda (mais recente).
    var snapshotTs: Date?
    /// campo `sessionId` visto dentro do PROPRIO arquivo (nas linhas de subagent isso
    /// e o id da sessao PAI: vinculo explicito, ver `scanActiveSessions`).
    var sessionIdSeen: String?
    /// `message.id` da ULTIMA linha assistant contada. Um turno vira varias linhas jsonl
    /// (thinking/text/tool_use...), todas com o MESMO `message.id` e o MESMO `usage`
    /// completo repetido: so contamos turno/token quando o id muda (ver `applyJSONLLine`).
    var lastMessageId: String?
    /// TODOS os `message.id` ja contados neste arquivo. Num resume/rewind o Claude Code
    /// reemite blocos de historico com o MESMO id, longe da 1a ocorrencia e com outros ids
    /// no meio: comparar so com o id ANTERIOR (lastMessageId) recontava esses turnos/tokens
    /// (medido +20-27% num arquivo real). O Set garante dedupe global por arquivo.
    var seenMessageIds = Set<String>()

    func reset() {
        offset = 0
        fileSize = 0 // sem isso a condicao "1o encontro" (offset==0 && fileSize==0) nunca
                     // volta a ser verdadeira apos truncar, e o previewTail nao re-roda.
        leftover = []
        turns = 0
        totalTokens = 0
        model = ""
        lastUsage = TurnUsage()
        firstTimestamp = nil
        lastTimestamp = nil
        cwd = nil
        entrypoint = nil
        lastRealTurnTimestamp = nil
        snapshotTs = nil
        sessionIdSeen = nil
        lastMessageId = nil
        seenMessageIds.removeAll()
    }
}

private struct JSONLLine: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let entrypoint: String?
    let message: Msg?

    struct Msg: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }
}

private let lineDecoder = JSONDecoder()

/// A mais RECENTE de duas datas (qualquer uma pode faltar). Usada pra que o timestamp de
/// atividade so AVANCE: o `previewTail` ja fixou o ultimo turno da cauda (recente); o scan
/// incremental depois relê o COMECO do arquivo (linhas antigas) e nao pode rebaixar isso.
private func laterDate(_ a: Date?, _ b: Date?) -> Date? {
    switch (a, b) {
    case let (a?, b?): return a > b ? a : b
    case let (a?, nil): return a
    case let (nil, b?): return b
    default: return nil
    }
}

/// Aplica UMA linha jsonl ja decodificada ao estado do arquivo. Livre de I/O, testavel
/// isoladamente.
func applyJSONLLine(_ data: Data, to state: SessionFileState) {
    guard let line = try? lineDecoder.decode(JSONLLine.self, from: data) else { return }
    let ts = parseISO8601(line.timestamp)
    if let ts {
        if state.firstTimestamp == nil { state.firstTimestamp = ts }
        state.lastTimestamp = laterDate(state.lastTimestamp, ts)
    }
    if let ep = line.entrypoint { state.entrypoint = ep }
    if let sid = line.sessionId { state.sessionIdSeen = sid }
    // "mais nova ou igual" que a linha que fixou o retrato: so assim atualiza cwd/modelo/
    // contexto, pra o backfill do inicio do arquivo nao rebaixar o que veio da cauda.
    let isNewerSnapshot = ts != nil && (state.snapshotTs == nil || ts! >= state.snapshotTs!)
    if isNewerSnapshot, let cwd = line.cwd { state.cwd = cwd }

    guard line.type == "assistant", let usage = line.message?.usage else { return }
    // turno sintetico: o Claude Code grava model "<synthetic>" com usage zerada quando a
    // API erra (rate limit / 5xx / 401). Nao e turno real: ignora por completo (senao um
    // erro zerava o contexto exibido e sumia o custo do agent).
    if line.message?.model == "<synthetic>" { return }

    let turnUsage = TurnUsage(
        inputTokens: usage.input_tokens ?? 0,
        outputTokens: usage.output_tokens ?? 0,
        cacheReadTokens: usage.cache_read_input_tokens ?? 0,
        cacheCreationTokens: usage.cache_creation_input_tokens ?? 0
    )
    // RETRATO do ultimo turno (modelo/contexto/atividade): so a linha MAIS RECENTE fixa, pra
    // o replay/backfill de linha antiga nao sobrescrever a cauda.
    if isNewerSnapshot {
        if let model = line.message?.model { state.model = model }
        state.lastUsage = turnUsage
        state.snapshotTs = ts
        state.lastRealTurnTimestamp = laterDate(state.lastRealTurnTimestamp, ts)
    }

    // CONTADORES cumulativos (turns/totalTokens): 1x por message.id. O Set deduplica tanto
    // os content-blocks consecutivos do mesmo turno (thinking/text/tool_use, mesmo id e
    // usage) quanto um replay NAO-adjacente do mesmo id num resume/rewind (senao recontava,
    // +20-27% de turnos/tokens medido num arquivo real).
    let messageId = line.message?.id
    if let messageId {
        if state.seenMessageIds.contains(messageId) { return }
        state.seenMessageIds.insert(messageId)
    }
    state.lastMessageId = messageId
    state.turns += 1
    state.totalTokens += turnUsage.totalTokens
}

/// So atualiza o "retrato" do ultimo turno (modelo/contexto/timestamp), sem contar
/// turno/token cumulativo -- usado so pela pre-visualizacao da cauda (`previewTail`);
/// quem conta de verdade e o scan incremental normal (`applyJSONLLine`), que alcanca
/// essa mesma linha mais tarde.
private func previewLastTurn(_ data: Data, to state: SessionFileState) {
    guard let line = try? lineDecoder.decode(JSONLLine.self, from: data) else { return }
    let ts = parseISO8601(line.timestamp)
    if let ts { state.lastTimestamp = laterDate(state.lastTimestamp, ts) }
    if let ep = line.entrypoint { state.entrypoint = ep }
    if let sid = line.sessionId { state.sessionIdSeen = sid }
    let isNewerSnapshot = ts != nil && (state.snapshotTs == nil || ts! >= state.snapshotTs!)
    if isNewerSnapshot, let cwd = line.cwd { state.cwd = cwd }
    guard line.type == "assistant", let usage = line.message?.usage else { return }
    if line.message?.model == "<synthetic>" { return } // erro de API: mantem o ultimo turno REAL
    guard isNewerSnapshot else { return }
    state.lastRealTurnTimestamp = laterDate(state.lastRealTurnTimestamp, ts)
    if let model = line.message?.model { state.model = model }
    state.lastUsage = TurnUsage(
        inputTokens: usage.input_tokens ?? 0,
        outputTokens: usage.output_tokens ?? 0,
        cacheReadTokens: usage.cache_read_input_tokens ?? 0,
        cacheCreationTokens: usage.cache_creation_input_tokens ?? 0
    )
    state.snapshotTs = ts
}

/// Rabo lido no 1o encontro pra ja mostrar contexto/modelo e o ULTIMO turno real na hora.
/// 512KB (nao 64KB): um unico tool_result grande no fim pode empurrar o ultimo turno
/// assistant pra tras de 64KB, e ai a sessao apareceria com turno falso-velho (ou ate
/// excluida como fantasma) ate o scan incremental alcancar o meio do arquivo. 512KB cobre
/// praticamente qualquer cauda de tool output sem ter que ler o arquivo inteiro.
private let tailPreviewBytes: UInt64 = 512 * 1024

/// No 1o encontro de um arquivo (offset==0), le so a CAUDA pra ja mostrar contexto e
/// modelo atuais na hora (o spec pede isso: "le a cauda do arquivo"). O scan incremental
/// normal (budget-limitado por tick, ver `updateFileState`) alcanca essa mesma linha
/// mais tarde e confirma turns/totalTokens aos poucos, sem travar a 1a exibicao num
/// arquivo de dezenas de MB.
private func previewTail(_ state: SessionFileState, atPath path: String, fileSize: UInt64) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return }
    defer { try? handle.close() }
    let start = fileSize > tailPreviewBytes ? fileSize - tailPreviewBytes : 0
    do { try handle.seek(toOffset: start) } catch { return }
    let tail = handle.readDataToEndOfFile()
    guard !tail.isEmpty else { return }
    let bytes = [UInt8](tail)

    var lineStart = 0
    if start > 0, let firstNewline = bytes.firstIndex(of: 0x0A) {
        lineStart = firstNewline + 1 // a 1a linha da cauda pode estar cortada no meio
    }
    for i in lineStart..<bytes.count where bytes[i] == 0x0A {
        if i > lineStart {
            previewLastTurn(Data(bytes[lineStart..<i]), to: state)
        }
        lineStart = i + 1
    }
}

/// Teto de bytes NOVOS processados por chamada. Um arquivo de dezenas de MB (sessao
/// longa) nao trava um tick inteiro: o excesso fica pro proximo scan (~3s depois),
/// convergindo aos poucos em vez de bloquear a 1a exibicao da pagina.
private let maxBytesPerScan = 2 * 1024 * 1024

/// Le os bytes NOVOS de `path` (desde `state.offset`, limitado a `maxBytesPerScan` por
/// chamada) e aplica linha por linha. Se o arquivo encolheu (rotacionado/truncado),
/// reprocessa do zero. Nunca releem bytes ja consumidos: o que sobra de uma linha
/// incompleta fica em memoria (`leftover`), nao e re-lido do disco no proximo tick.
func updateFileState(_ state: SessionFileState, atPath path: String) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let sizeNumber = attrs[.size] as? NSNumber else { return }
    let size = sizeNumber.uint64Value

    if size < state.fileSize {
        state.reset()
    }

    // 1o encontro (offset zerado, nunca escaneado): mostra o ultimo turno na hora via
    // cauda, antes mesmo do scan incremental (abaixo) comecar a alcancar o resto.
    if state.offset == 0, state.fileSize == 0, size > 0 {
        previewTail(state, atPath: path, fileSize: size)
    }

    guard size > state.offset else {
        state.fileSize = size
        return
    }
    guard let handle = FileHandle(forReadingAtPath: path) else { return }
    defer { try? handle.close() }
    do { try handle.seek(toOffset: state.offset) } catch { return }
    let toRead = min(size - state.offset, UInt64(maxBytesPerScan))
    guard let newData = try? handle.read(upToCount: Int(toRead)), !newData.isEmpty else {
        state.fileSize = size
        return
    }
    state.offset += UInt64(newData.count)
    state.fileSize = size

    var buffer = state.leftover
    state.leftover = [] // quebra a referencia compartilhada: o append abaixo nao copia (COW)
    buffer.append(contentsOf: newData)

    var lineStart = 0
    for i in 0..<buffer.count where buffer[i] == 0x0A {
        if i > lineStart {
            applyJSONLLine(Data(buffer[lineStart..<i]), to: state)
        }
        lineStart = i + 1
    }
    state.leftover = Array(buffer[lineStart...])
}

/// Descricao curta do subagent (meta.json irmao do agent-<id>.jsonl), so enriquecimento
/// visual: se faltar ou nao parsear, segue sem.
func agentDescription(atPath jsonlPath: String) -> String? {
    let metaPath = (jsonlPath as NSString).deletingPathExtension + ".meta.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)) else { return nil }
    struct Meta: Decodable { let description: String? }
    return (try? JSONDecoder().decode(Meta.self, from: data))?.description
}

/// Veredito de por que uma sessao candidata entra ou nao na lista de ATIVAS. Fonte UNICA
/// da decisao: usado pelo scan de producao (`scanActiveSessions`) e pelo dump de debug
/// (`diagnoseSessions`), pra os dois nunca divergirem.
enum SessionVerdict: Equatable {
    case active                 // ultimo turno real dentro da janela ativa (~7min)
    case idle                   // turno real entre a janela ativa e a idle (ocioso ha X)
    case excludedNonCLI(String) // entrypoint sdk-py/sdk-*: worker/subagente, nao terminal
    case excludedStale          // turno real alem da janela idle (fechado/fantasma)
}

/// Decide se uma sessao conta e em qual estado. `activityTs` = timestamp do ULTIMO turno
/// real (fallback pro ultimo evento qualquer quando ainda nao vimos turno). nil = sessao
/// recem criada sem turno ainda: fail-open (ativa), pra nao esconder o que acabou de
/// comecar. `activeWindow` < `idleWindow`: dentro da 1a = ativa; entre as duas = ociosa;
/// alem da idle = fora (terminal fechado ou fantasma tocado so por metadado).
func classifySession(
    entrypoint: String?, activityTs: Date?, now: Date,
    activeWindow: TimeInterval, idleWindow: TimeInterval
) -> SessionVerdict {
    if let entrypoint, entrypoint != "cli" { return .excludedNonCLI(entrypoint) }
    guard let activityTs else { return .active } // sem turno ainda: fail-open
    let age = now.timeIntervalSince(activityTs)
    if age <= activeWindow { return .active }
    if age <= idleWindow { return .idle }
    return .excludedStale
}

/// Varre `projectsRoot` procurando sessoes principais ATIVAS (mtime dentro de
/// `activeWindow`) e os subagents delas. Mantem e muta `states` (chave = caminho
/// absoluto do arquivo) entre chamadas pro scan incremental funcionar.
///
/// Linkagem subagent -> pai: o layout real no disco (validado na maquina, difere do
/// que o spec assumia) e `<projeto>/<sessionId>/subagents/**/agent-<agentId>.jsonl`
/// (as vezes direto em `subagents/`, as vezes aninhado em `subagents/workflows/wf_*/`).
/// Em vez de confiar so no nome da pasta, cada linha do agent-*.jsonl carrega um campo
/// `sessionId` explicito com o id da sessao PAI: e esse campo que usamos pra confirmar
/// o vinculo (mais forte que o fallback de "mesma pasta + janela de atividade" do
/// spec, que so seria necessario se esse campo nao existisse).
func scanActiveSessions(
    projectsRoot: URL,
    activeWindow: TimeInterval,
    idleWindow: TimeInterval = SessionScanner.defaultIdleWindow,
    states: inout [String: SessionFileState],
    now: Date = Date()
) -> [AgentSession] {
    let fm = FileManager.default
    guard let projectDirs = try? fm.contentsOfDirectory(
        at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else { return [] }

    var result: [AgentSession] = []

    for projectDir in projectDirs {
        guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { continue }

        for entry in entries where entry.pathExtension == "jsonl" {
            // subagent solto na raiz do projeto (agent-*.jsonl) nao e sessao principal:
            // quem trata isso e scanSubagents, aninhado sob o pai certo.
            guard !entry.lastPathComponent.hasPrefix("agent-") else { continue }
            guard let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            // pre-filtro barato pela janela IDLE (mtime e sempre >= idade do ultimo turno,
            // entao quem tem turno real dentro da idle passa aqui); a decisao fina e por
            // turno real, abaixo.
            guard now.timeIntervalSince(mtime) <= idleWindow else { continue }

            let sessionId = entry.deletingPathExtension().lastPathComponent
            let state = states[entry.path] ?? SessionFileState()
            states[entry.path] = state
            updateFileState(state, atPath: entry.path)

            // Veredito unico (mesma regra do dump de debug): so terminal `cli` (worker/SDK
            // grava jsonl top-level no mesmo projeto e viraria duplicata); ultimo TURNO REAL
            // decide ativa (dentro da janela) vs OCIOSA (entre ativa e idle) vs fora.
            let activityTs = state.lastRealTurnTimestamp ?? state.lastTimestamp
            let isActive: Bool
            switch classifySession(entrypoint: state.entrypoint, activityTs: activityTs,
                                   now: now, activeWindow: activeWindow, idleWindow: idleWindow) {
            case .active: isActive = true
            case .idle: isActive = false
            case .excludedNonCLI, .excludedStale: continue
            }

            let subagentsDir = projectDir.appendingPathComponent(sessionId).appendingPathComponent("subagents")
            let subagents = scanSubagents(
                under: subagentsDir, parentSessionId: sessionId, activeWindow: activeWindow, now: now, states: &states
            )

            result.append(AgentSession(
                id: sessionId,
                project: projectDisplayName(cwd: state.cwd, folderSlug: projectDir.lastPathComponent),
                projectPath: state.cwd ?? projectDir.lastPathComponent,
                model: state.model,
                contextTokens: state.lastUsage.contextTokens,
                contextWindow: contextWindow(forTokens: state.lastUsage.contextTokens),
                turns: state.turns,
                totalTokens: state.totalTokens,
                costUSD: nil,
                agents: subagents,
                lastActivity: state.lastRealTurnTimestamp ?? state.lastTimestamp ?? mtime,
                startedAt: state.firstTimestamp,
                inputTokens: state.lastUsage.inputTokens,
                outputTokens: state.lastUsage.outputTokens,
                cacheReadTokens: state.lastUsage.cacheReadTokens,
                cacheCreationTokens: state.lastUsage.cacheCreationTokens,
                isActive: isActive
            ))
        }
    }

    // ativas antes das ociosas; dentro de cada grupo, mais recente em cima.
    return result.sorted {
        if $0.isActive != $1.isActive { return $0.isActive }
        return $0.lastActivity > $1.lastActivity
    }
}

/// Constroi as AgentSessions a partir das sessoes RODANDO agora (`claude agents --json`), a
/// fonte de verdade: quem esta na lista esta aberto, e `isBusy` (status) diz ativa vs ociosa
/// SEM depender de janela de tempo (tarefa longa fica busy). Cada uma e enriquecida com o
/// jsonl (contexto/tokens/modelo/subagents); sessao aberta sem jsonl localizavel entra com o
/// basico (aparece mesmo assim, marcada pelo status).
func scanRunningSessions(
    _ running: [RunningSession],
    projectsRoot: URL,
    activeWindow: TimeInterval = SessionScanner.defaultActiveWindow,
    states: inout [String: SessionFileState],
    now: Date = Date()
) -> [AgentSession] {
    var result: [AgentSession] = []
    result.reserveCapacity(running.count)
    for rs in running {
        let state: SessionFileState
        var subs: [SubagentSession] = []
        var folderSlug = projectSlug(fromCwd: rs.cwd)
        if let jsonl = locateSessionJSONL(sessionId: rs.sessionId, cwd: rs.cwd, projectsRoot: projectsRoot) {
            let s = states[jsonl.path] ?? SessionFileState()
            states[jsonl.path] = s
            updateFileState(s, atPath: jsonl.path)
            state = s
            let projectDir = jsonl.deletingLastPathComponent()
            folderSlug = projectDir.lastPathComponent
            let subagentsDir = projectDir.appendingPathComponent(rs.sessionId).appendingPathComponent("subagents")
            subs = scanSubagents(under: subagentsDir, parentSessionId: rs.sessionId,
                                 activeWindow: activeWindow, now: now, states: &states)
        } else {
            state = SessionFileState() // aberta mas sem jsonl em disco ainda: so o basico
        }
        result.append(AgentSession(
            id: rs.sessionId,
            project: projectDisplayName(cwd: state.cwd ?? rs.cwd, folderSlug: folderSlug),
            projectPath: state.cwd ?? rs.cwd,
            model: state.model,
            contextTokens: state.lastUsage.contextTokens,
            contextWindow: contextWindow(forTokens: state.lastUsage.contextTokens),
            turns: state.turns,
            totalTokens: state.totalTokens,
            costUSD: nil,
            agents: subs,
            lastActivity: state.lastRealTurnTimestamp ?? state.lastTimestamp ?? now,
            startedAt: state.firstTimestamp,
            inputTokens: state.lastUsage.inputTokens,
            outputTokens: state.lastUsage.outputTokens,
            cacheReadTokens: state.lastUsage.cacheReadTokens,
            cacheCreationTokens: state.lastUsage.cacheCreationTokens,
            isActive: rs.isBusy // busy = ativa; idle/ausente = ociosa (mas aberta)
        ))
    }
    // ativas (busy) antes das ociosas; dentro de cada, mais recente em cima.
    return result.sorted {
        if $0.isActive != $1.isActive { return $0.isActive }
        return $0.lastActivity > $1.lastActivity
    }
}

func scanSubagents(
    under subagentsDir: URL, parentSessionId: String, activeWindow: TimeInterval, now: Date,
    states: inout [String: SessionFileState]
) -> [SubagentSession] {
    let fm = FileManager.default
    guard let walker = fm.enumerator(
        at: subagentsDir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var result: [SubagentSession] = []
    for case let url as URL in walker {
        guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("agent-") else { continue }
        // mesma janela de atividade do pai: subagent de dias atras numa sessao-projeto
        // longeva nao deve aparecer pra sempre (so o que rodou de fato ha pouco).
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { continue }
        guard now.timeIntervalSince(mtime) <= activeWindow else { continue }

        let state = states[url.path] ?? SessionFileState()
        states[url.path] = state
        updateFileState(state, atPath: url.path)

        // vinculo explicito: so agrega se o proprio arquivo confirmar que pertence a
        // ESTA sessao pai (nunca confia so na localizacao no disco).
        guard state.sessionIdSeen == parentSessionId, state.turns > 0 else { continue }

        let agentId = String(url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
        result.append(SubagentSession(
            id: agentId,
            description: agentDescription(atPath: url.path),
            model: state.model,
            contextTokens: state.lastUsage.contextTokens,
            totalTokens: state.totalTokens,
            costUSD: nil,
            lastActivity: state.lastTimestamp ?? Date()
        ))
    }
    return result.sorted { $0.lastActivity > $1.lastActivity }
}

/// Wrapper com estado, isolado do MainActor (roda no executor proprio do actor, nunca
/// bloqueia a UI). O `SessionsService` chama isso a cada tick de ~3s.
actor SessionScanner {
    static let defaultActiveWindow: TimeInterval = 7 * 60
    /// Ate aqui a sessao continua na lista, esmaecida como "ocioso ha X" (turno real entre
    /// activeWindow e isto). Alem disso some. 3h cobre pausa/reuniao sem virar fantasma.
    static let defaultIdleWindow: TimeInterval = 3 * 60 * 60

    private let projectsRoot: URL
    private let activeWindow: TimeInterval
    private let idleWindow: TimeInterval
    private var states: [String: SessionFileState] = [:]
    private var scanCount = 0
    /// Poda `states` a cada N scans (~1min com o tick de 3s): sem isso, arquivo que sai
    /// da janela ativa (ou some do disco) fica pra sempre em memoria enquanto o app roda.
    private static let pruneEveryNScans = 20

    init(
        projectsRoot: URL = SessionScanner.defaultProjectsRoot,
        activeWindow: TimeInterval = SessionScanner.defaultActiveWindow,
        idleWindow: TimeInterval = SessionScanner.defaultIdleWindow
    ) {
        self.projectsRoot = projectsRoot
        self.activeWindow = activeWindow
        self.idleWindow = idleWindow
    }

    static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    func scan(now: Date = Date()) -> [AgentSession] {
        let result: [AgentSession]
        if let data = runClaudeAgentsJSON() {
            // FONTE DE VERDADE: sessoes interativas rodando agora, com busy/idle real.
            result = scanRunningSessions(parseRunningSessions(data), projectsRoot: projectsRoot,
                                         activeWindow: activeWindow, states: &states, now: now)
        } else {
            // fallback (claude nao instalado / versao sem `agents`): metodo antigo por mtime
            // + ultimo turno real + janela idle.
            result = scanActiveSessions(projectsRoot: projectsRoot, activeWindow: activeWindow,
                                        idleWindow: idleWindow, states: &states, now: now)
        }
        scanCount += 1
        if scanCount % Self.pruneEveryNScans == 0 {
            pruneStaleStates(now: now)
        }
        return result
    }

    /// Retencao GENEROSA do estado incremental: 8h. O estado guarda o offset ja lido e os
    /// contadores cumulativos (turns/totalTokens/seenMessageIds); descartar por "ficou
    /// ocioso" faz a MESMA sessao (arquivo append-only) que volta a receber turnos ser
    /// reconstruida do ZERO, relendo o arquivo inteiro a 2MB/tick e recontando turns/tokens
    /// a partir de 0 (mostra numeros baixos errados enquanto converge). 8h cobre qualquer
    /// pausa realista de uma sessao de trabalho; ainda liberamos memoria de sessao
    /// abandonada e, sempre, de arquivo que sumiu do disco.
    private static let stateRetention: TimeInterval = 8 * 60 * 60
    private func pruneStaleStates(now: Date) {
        let fm = FileManager.default
        states = states.filter { path, _ in
            guard fm.fileExists(atPath: path) else { return false }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return true }
            return now.timeIntervalSince(mtime) <= Self.stateRetention
        }
    }
}
