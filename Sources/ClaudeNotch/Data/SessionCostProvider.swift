import Foundation

/// Custos derivados de UM "ccusage session --json": custo exato por sessao principal
/// (period == sessionId) + taxa media US$/token por familia de modelo (usada pra
/// ESTIMAR custo de subagent, ver nota abaixo).
struct CcusageCosts: Equatable {
    var costsBySession: [String: Double] = [:]
    /// Taxa US$/token por MODELO EXATO (ex. "claude-opus-4-8"): usada 1o pra estimar custo
    /// de subagent. Preferida a familia porque o pricing varia entre versoes (medido:
    /// opus-4-7 vs opus-4-8 = +26%, sonnet-4-6 vs sonnet-5 = 2.57x).
    var blendedRatePerModel: [String: Double] = [:]
    /// Fallback so quando o modelo exato ainda nao apareceu no ccusage (familia da amostra
    /// maior, mas mistura versoes de preco diferente: por isso e' so o ultimo recurso).
    var blendedRatePerModelFamily: [String: Double] = [:]
}

private struct CcusageOutput: Decodable {
    let session: [Entry]
    struct Entry: Decodable {
        let period: String
        let totalCost: Double
        let modelBreakdowns: [ModelBreakdown]
    }
    struct ModelBreakdown: Decodable {
        let modelName: String
        let cost: Double
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
    }
}

/// Parse puro do stdout do ccusage, sem I/O. Testavel sem rodar o binario.
///
/// Custo de subagent (achado ao validar contra a maquina real): o spec assumia
/// `period == id do agent`, mas "ccusage session --json" so lista sessoes PRINCIPAIS
/// (period e sempre um sessionId de UUID completo; os agent-*.jsonl de subagent nunca
/// aparecem la, confirmado contando as entradas: numero de period-UUID bate com o
/// numero de arquivos .jsonl principais no disco). Entao pra subagent nao ha custo
/// exato disponivel; estimamos com a taxa media US$/token OBSERVADA no proprio ccusage
/// pra cada familia de modelo (opus/sonnet/haiku, agrupado por familia pra ter amostra
/// grande o bastante), aplicada aos tokens do subagent. E uma aproximacao, documentada
/// na UI como tal (nao e o numero exato de billing).
func parseCcusageOutput(_ data: Data) -> CcusageCosts {
    guard let decoded = try? JSONDecoder().decode(CcusageOutput.self, from: data) else {
        return CcusageCosts()
    }
    var costs: [String: Double] = [:]
    var tokensByFamily: [String: Int] = [:]
    var costByFamily: [String: Double] = [:]
    var tokensByModel: [String: Int] = [:]
    var costByModel: [String: Double] = [:]

    for entry in decoded.session {
        if UUID(uuidString: entry.period) != nil {
            costs[entry.period] = entry.totalCost
        }
        for mb in entry.modelBreakdowns {
            let family = modelFamilyKey(mb.modelName)
            let tokens = mb.inputTokens + mb.outputTokens + mb.cacheReadTokens + mb.cacheCreationTokens
            tokensByFamily[family, default: 0] += tokens
            costByFamily[family, default: 0] += mb.cost
            tokensByModel[mb.modelName, default: 0] += tokens
            costByModel[mb.modelName, default: 0] += mb.cost
        }
    }

    var familyRates: [String: Double] = [:]
    for (family, tokens) in tokensByFamily where tokens > 0 {
        familyRates[family] = (costByFamily[family] ?? 0) / Double(tokens)
    }
    var modelRates: [String: Double] = [:]
    for (model, tokens) in tokensByModel where tokens > 0 {
        modelRates[model] = (costByModel[model] ?? 0) / Double(tokens)
    }
    return CcusageCosts(
        costsBySession: costs,
        blendedRatePerModel: modelRates,
        blendedRatePerModelFamily: familyRates
    )
}

/// Agrupa por familia (nao pela versao exata) pra ter amostra maior no calculo da
/// taxa media, ja que pricing entre patch-versions da mesma familia costuma ser igual.
func modelFamilyKey(_ rawModel: String) -> String {
    let m = rawModel.lowercased()
    if m.contains("opus") { return "opus" }
    if m.contains("sonnet") { return "sonnet" }
    if m.contains("haiku") { return "haiku" }
    return m
}

/// Caminhos conhecidos do ccusage, tentados ANTES de cair pro PATH herdado: o app
/// empacotado (.app, LSUIElement) e lancado pelo Finder/login item, nao por um shell de
/// login, entao NAO herda o PATH do .zshrc (so o minimo do sistema); sem isso, o custo
/// fica $0 pra sempre em producao mesmo com o ccusage instalado via Homebrew.
/// Nao-privada: reutilizada tambem pelo PersonalSpendProvider ("ccusage daily --json").
func resolveCcusagePath() -> String {
    let candidates = ["/opt/homebrew/bin/ccusage", "/usr/local/bin/ccusage"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return "ccusage" // fallback: resolvido via /usr/bin/env (PATH herdado, se houver)
}

/// Ambiente com PATH aumentado pros processos filhos: o caminho absoluto do ccusage
/// (resolveCcusagePath) NAO basta quando o app e lancado por login item/Finder -- o
/// ccusage do Homebrew e um script Node cujo shebang (#!/usr/bin/env node) resolve
/// `node` pelo PATH do filho, e o PATH do launchd (/usr/bin:/bin:/usr/sbin:/sbin) nao
/// tem /opt/homebrew/bin: o spawn morre com 127 e o custo fica "-" pra sempre, mesmo
/// com ccusage instalado. Prepend (sem duplicar) dos prefixos de pacote conhecidos;
/// o `base` parametrizado existe so pra testar sem depender do env do runner.
func augmentedPATHEnvironment(
    base: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var env = base
    let extras = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
    var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    for extra in extras.reversed() where !parts.contains(extra) {
        parts.insert(extra, at: 0)
    }
    env["PATH"] = parts.joined(separator: ":")
    return env
}

/// Timeout de verdade pro processo do ccusage: sem isso, um filho travado (ex. stderr
/// cheio, ver nota de `runCcusageSessionJSON`) deixa `refreshing` preso pra sempre no
/// SessionCostProvider e os custos da pagina Agentes congelam ate reiniciar o app.
let ccusageTimeout: TimeInterval = 10

/// Roda um `Process` ja configurado (executavel+argumentos prontos), drenando stdout E
/// stderr CONCORRENTEMENTE, com timeout de verdade. Puro I/O, sem saber nada de ccusage:
/// testavel com qualquer processo (ver SessionCostProviderTests).
///
/// stdout E stderr precisam ser lidos ao mesmo tempo: um CLI verboso (ex. warnings de
/// deprecacao do Node) que escreva mais que o buffer do Pipe (~64KB) em stderr antes de
/// terminar trava esperando alguem ler o stderr, enquanto o pai trava esperando o stdout
/// fechar -- deadlock classico se so o stdout for drenado. E se o processo nunca
/// terminar (trava de verdade, rede lenta etc), o timeout mata e desiste, sempre
/// retornando (nunca prende quem chamou pra sempre).
func runProcessCapturingStdout(_ process: Process, timeout: TimeInterval) -> Data? {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return nil
    }

    // so comeca a drenar DEPOIS do run() ter sucesso: se lancar antes disso, ninguem
    // fica preso lendo um pipe cujo processo nunca chegou a existir.
    var stdoutData = Data()
    let drainQueue = DispatchQueue(label: "process.drain", attributes: .concurrent)
    let drainGroup = DispatchGroup()
    drainGroup.enter()
    drainQueue.async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        drainGroup.leave()
    }
    drainGroup.enter()
    drainQueue.async {
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile() // so drena, descarta
        drainGroup.leave()
    }

    let timedOut = drainGroup.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
        // fecha os handles de leitura pra forcar os `readDataToEndOfFile()` das threads da
        // drainQueue a retornar (EOF) e liberar: `terminate()` so manda SIGTERM ao processo,
        // nao desbloqueia quem esta preso lendo o pipe. Sem isso, cada ccusage travado
        // vaza duas threads pra sempre (a cada refresh que expira).
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        process.terminate()
        return nil
    }
    process.waitUntilExit()
    return process.terminationStatus == 0 ? stdoutData : nil
}

/// Roda "ccusage session --json" de verdade. Bloqueante (drena + waitUntilExit), mas so
/// e chamado de dentro do actor SessionCostProvider (fora da main thread) ou, no modo de
/// snapshot headless, de um processo CLI de tiro unico onde bloquear e OK.
func runCcusageSessionJSON() -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [resolveCcusagePath(), "session", "--json"]
    process.environment = augmentedPATHEnvironment()
    return runProcessCapturingStdout(process, timeout: ccusageTimeout)
}

/// Cache de ~3min do ccusage (mesmo espirito do `get_costs` do plugin Python): o
/// refresh de 3s da pagina de agentes NUNCA espera o ccusage, so le o que ja esta
/// cacheado aqui e dispara um refresh em background quando o TTL vence.
actor SessionCostProvider {
    static let cacheTTL: TimeInterval = 180

    private var lastFetchAt: Date?
    private var refreshing = false
    private var costs = CcusageCosts()

    /// Snapshot atual (pode estar desatualizado ate 3min; nunca bloqueia).
    func current() -> CcusageCosts { costs }

    /// Zera o TTL (usado pelo refresh manual): a proxima `refreshIfNeeded` ignora o
    /// cache de 3min e busca na hora.
    func invalidate() { lastFetchAt = nil }

    /// Dispara um refresh em background se o cache expirou. Retorna na hora.
    func refreshIfNeeded(now: Date = Date()) {
        if let lastFetchAt, now.timeIntervalSince(lastFetchAt) < Self.cacheTTL { return }
        guard !refreshing else { return }
        refreshing = true
        lastFetchAt = now
        Task { [weak self] in
            guard let self else { return }
            if let data = runCcusageSessionJSON() {
                await self.apply(parseCcusageOutput(data))
            }
            await self.markRefreshDone()
        }
    }

    private func apply(_ newCosts: CcusageCosts) { costs = newCosts }
    private func markRefreshDone() { refreshing = false }
}
