import Testing
import Foundation
@testable import ClaudeNotch

/// Feature multimac-sync: `mergeCrossMachineSpend` e' o coracao puro do sync de gasto
/// entre Macs (soma por data ATRAVES das particoes, sem I/O). `CrossMachineSpendTests`
/// cobre a soma em si; `CrossMachineSpendProviderTests` (mais abaixo) cobre a camada
/// com I/O real (tmp dir), incluindo skip-and-keep de arquivo remoto ausente/corrompido.
@Suite("mergeCrossMachineSpend: soma por data atraves de machineIds, sem dupla-contagem")
struct CrossMachineSpendMergeTests {
    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = hour
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)!
    }

    private func snapshot(
        _ machineId: String, _ daily: [String: Double], email: String? = nil
    ) -> MachineSpendSnapshot {
        MachineSpendSnapshot(
            machineId: machineId, accountEmail: email, lastUpdated: Date(),
            dailyCostUSD: daily, lifetimeTotal: daily.values.reduce(0, +)
        )
    }

    @Test("soma local + 1 remota na mesma data, sem dupla-contagem (particao por machineId)")
    func sumsAcrossMachinesWithoutDoubleCounting() {
        let today = date(2026, 7, 14)
        let local = snapshot("mac-a", ["2026-07-14": 5.0])
        let remote = snapshot("mac-b", ["2026-07-14": 3.0])

        let merged = mergeCrossMachineSpend(
            local: local, remotes: [remote], today: today, calendar: utcCalendar()
        )

        #expect(merged.today == 8.0)
        #expect(merged.lifetime == 8.0)
    }

    @Test("MESMA conta logada em 2 Macs soma certo (particao e' machineId, nunca email)")
    func sameAccountTwoMachinesSumsCorrectly() {
        let today = date(2026, 7, 14)
        let local = snapshot("mac-a", ["2026-07-14": 10.0], email: "you@example.com")
        let remote = snapshot("mac-b", ["2026-07-14": 4.5], email: "you@example.com")

        let merged = mergeCrossMachineSpend(
            local: local, remotes: [remote], today: today, calendar: utcCalendar()
        )

        // Mesma conta nos 2 -- soma pelos machineIds, nao colapsa/dedupe por email.
        #expect(merged.today == 14.5)
    }

    @Test("relogio torto: data errada de uma remota fica contida naquela particao (some do 'hoje', aparece no lifetime)")
    func crookedClockContainedToThatPartition() {
        let today = date(2026, 7, 14)
        // Local escreveu hoje (relogio certo). Remota com relogio adiantado escreveu
        // sob "amanha" (2026-07-15) na visao dela -- uma data que ainda nao existe pro
        // "hoje" de quem esta lendo (local).
        let local = snapshot("mac-a", ["2026-07-14": 2.0])
        let remoteCrooked = snapshot("mac-b", ["2026-07-15": 99.0])

        let merged = mergeCrossMachineSpend(
            local: local, remotes: [remoteCrooked], today: today, calendar: utcCalendar()
        )

        // O "hoje" local NAO e' contaminado pelo relogio torto da remota...
        #expect(merged.today == 2.0)
        // ...mas o valor dela nao e' perdido, so fica contido no lifetime (a unica
        // visao que soma TODAS as datas, certas ou erradas).
        #expect(merged.lifetime == 101.0)
    }

    @Test("3+ maquinas somam todas, nenhuma fica de fora")
    func threeOrMoreMachinesSum() {
        let today = date(2026, 7, 14)
        let local = snapshot("mac-a", ["2026-07-14": 1.0])
        let b = snapshot("mac-b", ["2026-07-14": 2.0])
        let c = snapshot("mac-c", ["2026-07-14": 3.0])
        let d = snapshot("mac-d", ["2026-07-14": 4.0])

        let merged = mergeCrossMachineSpend(
            local: local, remotes: [b, c, d], today: today, calendar: utcCalendar()
        )

        #expect(merged.today == 10.0)
        #expect(merged.lifetime == 10.0)
    }

    @Test("7 dias/mes recalculados sobre o mapa fundido, nao so somando os buckets prontos")
    func last7AndMonthRecomputedOverMergedMap() {
        let today = date(2026, 7, 14)
        let local = snapshot("mac-a", ["2026-07-14": 1.0, "2026-07-01": 5.0, "2026-06-30": 50.0])
        let remote = snapshot("mac-b", ["2026-07-08": 2.0, "2026-06-01": 20.0])

        let merged = mergeCrossMachineSpend(
            local: local, remotes: [remote], today: today, calendar: utcCalendar()
        )

        // janela de 7 dias = 07-08 ate 07-14 (hoje - 6): so 07-14(1.0) e 07-08(2.0) entram.
        #expect(merged.last7 == 3.0)
        // mes corrente (07): 07-14(1.0) + 07-01(5.0) local + 07-08(2.0) remoto, NAO inclui 06-30/06-01.
        #expect(merged.month == 8.0)
        #expect(merged.lifetime == 78.0)
    }

    @Test("sem nenhuma remota, o total e' so a particao local (sync ligado, mas sozinho ainda)")
    func noRemotesYieldsLocalOnly() {
        let today = date(2026, 7, 14)
        let local = snapshot("mac-a", ["2026-07-14": 7.25])

        let merged = mergeCrossMachineSpend(local: local, remotes: [], today: today, calendar: utcCalendar())

        #expect(merged.today == 7.25)
        #expect(merged.lifetime == 7.25)
    }
}

/// Camada com I/O real (SyncFolder num tmp dir) por cima do merge puro: cobre
/// skip-and-keep de arquivo remoto ausente/corrompido, e o caminho local write ->
/// remote read.
@Suite("CrossMachineSpendProvider: escreve particao local, le remotas com skip-and-keep")
struct CrossMachineSpendProviderTests {
    /// Cria de fato o tmpDir raiz (simula o iCloud Drive "ligado": a pasta-mae existe),
    /// senao `SyncFolder.isAvailable` fica false e nada e' escrito no disco.
    private func makeFolder() throws -> (SyncFolder, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let folder = SyncFolder(cloudDocsRoot: tmpDir)
        return (folder, tmpDir)
    }

    private func writeRemote(
        _ folder: SyncFolder, id: String, daily: [String: Double], lastUpdated: Date = Date()
    ) throws {
        folder.ensureFolders()
        let snapshot = MachineSpendSnapshot(
            machineId: id, accountEmail: nil, lastUpdated: lastUpdated,
            dailyCostUSD: daily, lifetimeTotal: daily.values.reduce(0, +)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        folder.writeAtomic(folder.spendFileURL(id), data: data)
    }

    @Test("le remota valida do disco e funde com a local")
    func mergesLocalAndRemoteFromDisk() async throws {
        let (folder, tmpDir) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writeRemote(folder, id: "mac-remote", daily: ["2026-07-14": 9.0])

        let provider = CrossMachineSpendProvider(folder: folder, machineId: "mac-local")
        await provider.refreshIfNeeded(
            localDaily: ["2026-07-14": 1.0], accountEmail: nil, label: "Local", appVersion: "0.1.0"
        )
        let merged = await provider.mergedSpend(localDaily: ["2026-07-14": 1.0], accountEmail: nil)

        #expect(merged.today == 10.0)
        #expect(await provider.remoteMachineCount() == 1)
    }

    @Test("arquivo remoto CORROMPIDO: skip nesse ciclo, mantem o ultimo valor bom (nunca zera)")
    func corruptedRemoteFileSkipsAndKeepsLastGood() async throws {
        let (folder, tmpDir) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writeRemote(folder, id: "mac-remote", daily: ["2026-07-14": 9.0])

        let provider = CrossMachineSpendProvider(folder: folder, machineId: "mac-local")
        await provider.refreshIfNeeded(
            localDaily: ["2026-07-14": 1.0], accountEmail: nil, label: "Local", appVersion: "0.1.0"
        )
        let firstMerge = await provider.mergedSpend(localDaily: ["2026-07-14": 1.0], accountEmail: nil)
        #expect(firstMerge.today == 10.0)

        // Corrompe o arquivo remoto (ex. iCloud escrevendo no meio de um sync).
        folder.writeAtomic(folder.spendFileURL("mac-remote"), data: Data("{ nao e json valido".utf8))
        await provider.invalidate()
        await provider.refreshIfNeeded(
            localDaily: ["2026-07-14": 1.0], accountEmail: nil, label: "Local", appVersion: "0.1.0"
        )
        let secondMerge = await provider.mergedSpend(localDaily: ["2026-07-14": 1.0], accountEmail: nil)

        // O total NAO zera a contribuicao da remota so porque um ciclo bateu num
        // arquivo corrompido: mantem o ultimo valor bom.
        #expect(secondMerge.today == 10.0)
    }

    @Test("arquivo remoto AUSENTE: skip nesse ciclo, mantem o ultimo valor bom (nunca zera)")
    func missingRemoteFileSkipsAndKeepsLastGood() async throws {
        let (folder, tmpDir) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writeRemote(folder, id: "mac-remote", daily: ["2026-07-14": 9.0])

        let provider = CrossMachineSpendProvider(folder: folder, machineId: "mac-local")
        await provider.refreshIfNeeded(
            localDaily: ["2026-07-14": 1.0], accountEmail: nil, label: "Local", appVersion: "0.1.0"
        )
        let firstMerge = await provider.mergedSpend(localDaily: ["2026-07-14": 1.0], accountEmail: nil)
        #expect(firstMerge.today == 10.0)

        // Arquivo remoto some do disco (iCloud ainda nao materializou, ou a maquina
        // remota foi removida do outro lado).
        try? FileManager.default.removeItem(at: folder.spendFileURL("mac-remote"))
        await provider.invalidate()
        await provider.refreshIfNeeded(
            localDaily: ["2026-07-14": 1.0], accountEmail: nil, label: "Local", appVersion: "0.1.0"
        )
        let secondMerge = await provider.mergedSpend(localDaily: ["2026-07-14": 1.0], accountEmail: nil)

        #expect(secondMerge.today == 10.0)
        #expect(await provider.remoteMachineCount() == 1) // ainda cacheada, nao sumiu
    }

    @Test("iCloud Drive indisponivel: refresh nao crasha, merge cai pro so-local")
    func iCloudUnavailableDoesNotCrash() async {
        // cloudDocsRoot aponta pra um caminho que deliberadamente nao existe (nunca
        // criado): simula iCloud Drive desligado.
        let fakeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauge-sync-nao-existe-\(UUID().uuidString)")
        let folder = SyncFolder(cloudDocsRoot: fakeRoot)
        #expect(folder.isAvailable == false)

        let provider = CrossMachineSpendProvider(folder: folder, machineId: "mac-local")
        await provider.refreshIfNeeded(
            localDaily: ["2026-07-14": 3.0], accountEmail: nil, label: "Local", appVersion: "0.1.0"
        )
        let merged = await provider.mergedSpend(localDaily: ["2026-07-14": 3.0], accountEmail: nil)

        #expect(merged.today == 3.0)
        #expect(await provider.remoteMachineCount() == 0)
    }

    @Test("Remover esta maquina: apaga machines/ e spend/ do proprio id")
    func removeLocalMachineDeletesOwnFiles() async throws {
        let (folder, tmpDir) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let provider = CrossMachineSpendProvider(folder: folder, machineId: "mac-local")
        await provider.refreshIfNeeded(
            localDaily: ["2026-07-14": 1.0], accountEmail: nil, label: "Local", appVersion: "0.1.0"
        )
        #expect(FileManager.default.fileExists(atPath: folder.spendFileURL("mac-local").path))
        #expect(FileManager.default.fileExists(atPath: folder.machineFileURL("mac-local").path))

        await provider.removeLocalMachine()

        #expect(!FileManager.default.fileExists(atPath: folder.spendFileURL("mac-local").path))
        #expect(!FileManager.default.fileExists(atPath: folder.machineFileURL("mac-local").path))
    }
}
