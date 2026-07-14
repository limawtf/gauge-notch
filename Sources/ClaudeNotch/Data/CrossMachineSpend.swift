import Foundation

/// Registro descritivo de UMA maquina (machines/<machineId>.json): quem ela e', nao
/// quanto ela gastou (isso mora em `MachineSpendSnapshot`). Escrito no boot/refresh SO
/// pelo dono (cada maquina escreve so o proprio arquivo, nunca o de outra).
struct MachineInfo: Codable, Equatable {
    var machineId: String
    var label: String
    var appVersion: String
    var firstSeen: Date
    var lastSeen: Date
}

/// Particao de gasto de UMA maquina (spend/<machineId>.json). Overwrite atomico do
/// snapshot INTEIRO a cada refresh (nao e' delta: `ccusage daily` ja e' idempotente por
/// dia). `dailyCostUSD` (data "yyyy-MM-dd" -> custo Claude-only em USD) e' a fonte de
/// verdade usada pelo merge; `lifetimeTotal` e' so um resumo denormalizado pra leitura
/// rapida/diagnostico, nunca recalculado a partir dele no merge (ver
/// `mergeCrossMachineSpend`, que soma sempre `dailyCostUSD`). `accountEmail` e' so
/// descritivo (aparece la pra debug/diagnostico), NUNCA usado como chave de particao --
/// a mesma conta logada em 2 Macs soma certo por construcao, porque a chave e' sempre o
/// machineId.
struct MachineSpendSnapshot: Codable, Equatable {
    var machineId: String
    var accountEmail: String?
    var lastUpdated: Date
    var dailyCostUSD: [String: Double]
    var lifetimeTotal: Double
}

/// O coracao do sync entre Macs: funde o snapshot AO VIVO da maquina local (nunca
/// relido do proprio arquivo depois de escrito, sempre o valor fresco que quem chama
/// tem em memoria) com os snapshots ja resolvidos das OUTRAS maquinas. Resolver
/// "arquivo remoto ausente/corrompido" e' responsabilidade de quem chama
/// (`CrossMachineSpendProvider`, que faz skip-and-keep-o-ultimo-bom ANTES de chegar
/// aqui) -- esta funcao e' PURA, sem I/O, testavel so com tuplas/structs de entrada.
///
/// Soma por DATA atraves dos machineIds: a particao por maquina evita dupla-contagem
/// por construcao (cada machineId so escreve o proprio arquivo), entao a MESMA conta
/// logada em 2 Macs soma certo sem nenhum tratamento especial -- e' so 2 machineIds
/// diferentes contribuindo pro mesmo total. Os buckets today/last7/month/lifetime sao
/// recalculados sobre o mapa fundido usando o "today" de QUEM ESTA LENDO: nunca compara
/// timestamp/relogio entre maquinas, entao um relogio torto numa maquina remota so
/// contamina a data (errada) que ELA escreveu -- pode sumir do "hoje"/"mes" se cair
/// fora da janela local, mas nunca derruba nem contamina o "hoje" das outras maquinas.
func mergeCrossMachineSpend(
    local: MachineSpendSnapshot,
    remotes: [MachineSpendSnapshot],
    today: Date = Date(),
    calendar: Calendar = .current
) -> PersonalSpend {
    var merged: [String: Double] = [:]
    for (date, cost) in local.dailyCostUSD {
        merged[date, default: 0] += cost
    }
    for remote in remotes {
        for (date, cost) in remote.dailyCostUSD {
            merged[date, default: 0] += cost
        }
    }
    return personalSpendBuckets(fromDailyCost: merged, today: today, calendar: calendar)
}

/// Le/escreve a pasta compartilhada (`SyncFolder`) e mantem o "ultimo valor bom" de
/// cada maquina remota entre ciclos: um arquivo remoto ausente ou corrompido NUM CICLO
/// (ex. iCloud sincronizando um snapshot no meio da escrita, ou a maquina removida) nao
/// zera a contribuicao dela pro total -- so mantem o ultimo snapshot que decodificou
/// com sucesso, ate ele voltar a aparecer valido. So entra em jogo quando
/// `AppSettings.syncAcrossMacs` esta ligado (quem chama decide isso, o provider em si
/// nao le settings).
actor CrossMachineSpendProvider {
    static let cacheTTL: TimeInterval = 180

    private let folder: SyncFolder
    private let machineId: String
    private var lastGoodRemotes: [String: MachineSpendSnapshot] = [:]
    private var lastFetchAt: Date?
    private var refreshing = false

    init(folder: SyncFolder = SyncFolder(), machineId: String = MachineIdentity.currentMachineId()) {
        self.folder = folder
        self.machineId = machineId
    }

    /// Zera o TTL (refresh manual): a proxima `refreshIfNeeded` ignora o cache de ~3min.
    func invalidate() { lastFetchAt = nil }

    /// Total fundido AGORA: a particao local (ao vivo, passada por quem chama) mais o
    /// ultimo bom conhecido de cada maquina remota. Nunca bloqueia, nunca toca disco --
    /// so le o cache em memoria de `lastGoodRemotes`, populado por `refreshIfNeeded`.
    func mergedSpend(
        localDaily: [String: Double], accountEmail: String?,
        today: Date = Date(), calendar: Calendar = .current
    ) -> PersonalSpend {
        let local = MachineSpendSnapshot(
            machineId: machineId, accountEmail: accountEmail, lastUpdated: today,
            dailyCostUSD: localDaily, lifetimeTotal: localDaily.values.reduce(0, +)
        )
        return mergeCrossMachineSpend(
            local: local, remotes: Array(lastGoodRemotes.values), today: today, calendar: calendar
        )
    }

    /// Quantas OUTRAS maquinas tem dado vivo agora (drilldown minimo da UI, ex. "Total
    /// (2 Macs)"). 0 quando o sync nunca escreveu/leu nada ainda.
    func remoteMachineCount() -> Int { lastGoodRemotes.count }

    /// Escreve a particao local (spend/<id>.json + machines/<id>.json, overwrite
    /// atomico do snapshot inteiro) e atualiza o cache de remotas lendo spend/*.json
    /// das outras maquinas. Gated por TTL de ~3min, mesmo espirito dos outros
    /// providers. Nao-op silencioso (nunca crasha) se o iCloud Drive nao estiver
    /// disponivel: so nao escreve/le nada nesse ciclo.
    func refreshIfNeeded(
        localDaily: [String: Double], accountEmail: String?, label: String, appVersion: String,
        now: Date = Date()
    ) {
        if let lastFetchAt, now.timeIntervalSince(lastFetchAt) < Self.cacheTTL { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        lastFetchAt = now

        guard folder.isAvailable else { return }
        folder.ensureFolders()

        writeLocalPartition(
            localDaily: localDaily, accountEmail: accountEmail, label: label, appVersion: appVersion, now: now
        )
        readOtherMachines()
    }

    /// Apaga machines/<id>.json e spend/<id>.json DESTA maquina (acao "Remover esta
    /// maquina"), pra um Mac aposentado nao continuar somando pra sempre no total dos
    /// outros. Tambem esvazia o cache de remotas em memoria (proximo refresh recomeca
    /// do zero, coerente com "acabei de sair do sync").
    func removeLocalMachine() {
        folder.removeMachine(machineId)
        lastGoodRemotes.removeAll()
        lastFetchAt = nil
    }

    private func writeLocalPartition(
        localDaily: [String: Double], accountEmail: String?, label: String, appVersion: String, now: Date
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let spend = MachineSpendSnapshot(
            machineId: machineId, accountEmail: accountEmail, lastUpdated: now,
            dailyCostUSD: localDaily, lifetimeTotal: localDaily.values.reduce(0, +)
        )
        if let data = try? encoder.encode(spend) {
            folder.writeAtomic(folder.spendFileURL(machineId), data: data)
        }

        let info = MachineInfo(
            machineId: machineId, label: label, appVersion: appVersion,
            firstSeen: existingFirstSeen() ?? now, lastSeen: now
        )
        if let data = try? encoder.encode(info) {
            folder.writeAtomic(folder.machineFileURL(machineId), data: data)
        }
    }

    /// `firstSeen` persiste entre refreshes: le o proprio machines/<id>.json (se ja
    /// existir) so pra preservar esse campo, nunca pra decidir gasto (a regra "nunca
    /// rele o proprio arquivo" e' sobre spend, nao sobre este metadado descritivo).
    private func existingFirstSeen() -> Date? {
        guard let data = try? Data(contentsOf: folder.machineFileURL(machineId)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MachineInfo.self, from: data).firstSeen
    }

    /// Le spend/*.json de todas as OUTRAS maquinas presentes no disco agora. Falha de
    /// parse (corrompido/truncado, ex. iCloud escrevendo no meio) = SKIP, mantendo o
    /// ultimo valor bom em `lastGoodRemotes`. Uma maquina cujo arquivo sumiu do disco
    /// tambem nao aparece em `folder.otherMachineIds`, entao simplesmente nao e'
    /// revisitada aqui -- o valor cacheado dela permanece intacto (mesmo
    /// skip-and-keep, nunca zera na hora).
    private func readOtherMachines() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for id in folder.otherMachineIds(excluding: machineId) {
            guard
                let data = try? Data(contentsOf: folder.spendFileURL(id)),
                let snapshot = try? decoder.decode(MachineSpendSnapshot.self, from: data)
            else { continue }
            lastGoodRemotes[id] = snapshot
        }
    }
}
