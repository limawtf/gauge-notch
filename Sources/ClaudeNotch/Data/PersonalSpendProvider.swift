import Foundation

/// Gasto pessoal por bucket de calendario (porta de `compute_costs` do plugin Python):
/// hoje, ultimos 7 dias (INCLUI hoje), mes corrente, lifetime. Deliberadamente por
/// calendario, nunca pelo "bloco de 5h" do ccusage (ele ancora em hora cheia e nao bate
/// com a janela ROLANTE da API, que e o que os medidores da pagina Uso mostram) -- $ e %
/// sao eixos independentes aqui.
struct PersonalSpend: Equatable {
    var today: Double
    var last7: Double
    var month: Double
    var lifetime: Double
}

private struct CcusageDailyOutput: Decodable {
    struct ModelBreakdown: Decodable {
        let modelName: String
        let cost: Double
    }
    struct Row: Decodable {
        let date: String?
        let period: String?
        let totalCost: Double?
        let costUSD: Double?
        let modelBreakdowns: [ModelBreakdown]?
    }
    let daily: [Row]?
}

private func rowKey(_ r: CcusageDailyOutput.Row) -> String { r.date ?? r.period ?? "" }

// So gasto do Claude Code: `ccusage daily` agrega TODAS as CLIs de codigo detectadas
// (Gemini, Codex, etc.) e o hero "Consumo" e' rotulado so "Hoje"/"Mes", sem qualificar,
// entao gasto de outra CLI entraria como se fosse Claude. Quando ha modelBreakdowns,
// soma so os modelos "claude-"; sem breakdown (formato antigo), cai pro custo bruto.
private func rowCost(_ r: CcusageDailyOutput.Row) -> Double {
    if let mbs = r.modelBreakdowns, !mbs.isEmpty {
        return mbs
            .filter { $0.modelName.lowercased().hasPrefix("claude") }
            .reduce(0) { $0 + $1.cost }
    }
    return r.totalCost ?? r.costUSD ?? 0
}

/// Mapa bruto data(yyyy-MM-dd) -> custo Claude-only do stdout de "ccusage daily
/// --json", sem I/O (testavel sem rodar o binario). E' a mesma fonte de linhas usada
/// pelos 4 buckets de `parsePersonalSpend` (ver `personalSpendBuckets`), e tambem a
/// particao local escrita em spend/<machineId>.json pelo CrossMachineSpendProvider
/// (feature multimac-sync). Linhas sem data E sem period (chave vazia) sao ignoradas
/// (nao da pra atribuir a nenhuma particao). nil se o JSON nao decodifica.
func parsePersonalSpendDailyMap(_ data: Data) -> [String: Double]? {
    guard let decoded = try? JSONDecoder().decode(CcusageDailyOutput.self, from: data) else {
        return nil
    }
    var map: [String: Double] = [:]
    for row in decoded.daily ?? [] {
        let key = rowKey(row)
        guard !key.isEmpty else { continue }
        map[key, default: 0] += rowCost(row)
    }
    return map
}

/// Deriva os 4 buckets (hoje/7 dias/mes/lifetime) de um mapa data->custo ja pronto.
/// Compartilhada entre o parse local (`parsePersonalSpend`) e o merge entre maquinas
/// (`mergeCrossMachineSpend`, em CrossMachineSpend.swift), pra garantir a MESMA regra
/// de data nos dois lugares (nunca diverge sem querer). "today" e' sempre calculado por
/// quem esta LENDO (nunca comparado entre maquinas): um relogio torto que escreveu sob
/// uma data errada so contamina aquela chave (aparece no lifetime, pode nao aparecer no
/// "hoje"/"mes" se cair fora da janela).
func personalSpendBuckets(
    fromDailyCost map: [String: Double], today: Date = Date(), calendar: Calendar = .current
) -> PersonalSpend {
    let df = DateFormatter()
    df.calendar = calendar
    df.timeZone = calendar.timeZone
    df.dateFormat = "yyyy-MM-dd"

    let todayKey = df.string(from: today)
    let monthKey = String(todayKey.prefix(7))
    let todayCost = map[todayKey] ?? 0
    let lifetime = map.values.reduce(0, +)

    guard let since7Date = calendar.date(byAdding: .day, value: -6, to: today) else {
        // Praticamente inalcancavel (aritmetica de calendario padrao nunca falha aqui),
        // mas nunca crasha/derruba o total por causa disso: degrada pros buckets menores.
        return PersonalSpend(today: todayCost, last7: todayCost, month: todayCost, lifetime: lifetime)
    }
    let since7Key = df.string(from: since7Date)
    // >= since7Key inclui hoje (comparacao lexicografica de "yyyy-MM-dd" == comparacao de data)
    let last7 = map.filter { $0.key >= since7Key }.values.reduce(0, +)
    let month = map.filter { $0.key.prefix(7) == monthKey }.values.reduce(0, +)

    return PersonalSpend(today: todayCost, last7: last7, month: month, lifetime: lifetime)
}

/// Parse puro do stdout de "ccusage daily --json", sem I/O (testavel sem rodar o
/// binario). nil se o JSON nao decodifica.
func parsePersonalSpend(_ data: Data, today: Date = Date(), calendar: Calendar = .current) -> PersonalSpend? {
    guard let map = parsePersonalSpendDailyMap(data) else { return nil }
    return personalSpendBuckets(fromDailyCost: map, today: today, calendar: calendar)
}

/// Roda "ccusage daily --json" de verdade (reusa o mesmo binario/PATH/timeout do
/// SessionCostProvider). Bloqueante: so chamado de dentro do actor PersonalSpendProvider
/// (fora da main thread) ou do modo --snapshot de tiro unico.
func runCcusageDailyJSON() -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [resolveCcusagePath(), "daily", "--json"]
    return runProcessCapturingStdout(process, timeout: ccusageTimeout)
}

/// Cache de ~3min (mesmo espirito do `get_costs` do plugin Python): a pagina Consumo
/// nunca espera o ccusage, so le o que ja esta cacheado e dispara refresh em background.
actor PersonalSpendProvider {
    static let cacheTTL: TimeInterval = 180

    private var lastFetchAt: Date?
    private var refreshing = false
    private var spend: PersonalSpend?
    private var dailyMap: [String: Double] = [:]

    /// Snapshot atual, nil ate o primeiro fetch bem-sucedido (ou se ccusage nao esta
    /// instalado: a UI mostra "-" em vez de forjar $0).
    func current() -> PersonalSpend? { spend }

    /// Mapa bruto data->custo (Claude-only) do ultimo fetch bem-sucedido: e' a
    /// particao LOCAL que o CrossMachineSpendProvider escreve em spend/<machineId>.json
    /// e usa pro merge (feature multimac-sync). Vazio ate o 1o fetch (nunca precisa ser
    /// opcional: um mapa vazio so faz o merge somar "nada" dessa maquina ainda).
    func currentDailyMap() -> [String: Double] { dailyMap }

    /// Zera o TTL (refresh manual): a proxima `refreshIfNeeded` ignora o cache.
    func invalidate() { lastFetchAt = nil }

    func refreshIfNeeded(now: Date = Date()) {
        if let lastFetchAt, now.timeIntervalSince(lastFetchAt) < Self.cacheTTL { return }
        guard !refreshing else { return }
        refreshing = true
        lastFetchAt = now
        Task { [weak self] in
            guard let self else { return }
            if let data = runCcusageDailyJSON(), let map = parsePersonalSpendDailyMap(data) {
                await self.apply(map)
            }
            await self.markRefreshDone()
        }
    }

    private func apply(_ map: [String: Double]) {
        dailyMap = map
        spend = personalSpendBuckets(fromDailyCost: map)
    }
    private func markRefreshDone() { refreshing = false }
}
