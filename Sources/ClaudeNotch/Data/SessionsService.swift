import Foundation
import Combine

/// Servico de dados da pagina Agentes: publica as sessoes ativas + resumo. Timer de
/// ~3s SO roda entre `start()`/`stop()` (chamados no onAppear/onDisappear da
/// AgentsPageView): pagina fechada = zero custo de CPU/IO. O scan pesado roda no
/// SessionScanner (actor, fora da main thread); so o resultado final e publicado aqui.
@MainActor
final class SessionsService: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Gasto pessoal por bucket (heroi da pagina Consumo). Ja vem FUNDIDO entre Macs
    /// quando `AppSettings.syncAcrossMacs` esta ligado (ver `tick()`); nil ate o
    /// primeiro fetch do ccusage local (ou se ele nao esta instalado).
    @Published private(set) var personalSpend: PersonalSpend?
    /// Quantas OUTRAS maquinas contribuiram pro `personalSpend` acima (drilldown
    /// minimo da UI, ex. "Total (2 Macs)"). 0 quando o sync esta desligado ou nenhuma
    /// outra maquina foi vista ainda.
    @Published private(set) var syncedOtherMachines: Int = 0

    private let scanner: SessionScanner
    private let costProvider: SessionCostProvider
    private let personalSpendProvider: PersonalSpendProvider
    private let crossMachineProvider: CrossMachineSpendProvider
    private weak var settings: AppSettings?
    private var timer: Timer?
    private var tickInFlight = false
    /// Incrementada em `stop()`: a Task do tick em andamento so escreve em `sessions`
    /// se a geracao ainda bater no fim (pagina fechada no meio de um scan demorado nao
    /// deixa resultado atrasado vazar depois do onDisappear).
    private var tickGeneration = 0

    static let tickInterval: TimeInterval = 3

    init(
        scanner: SessionScanner = SessionScanner(),
        costProvider: SessionCostProvider = SessionCostProvider(),
        personalSpendProvider: PersonalSpendProvider = PersonalSpendProvider(),
        crossMachineProvider: CrossMachineSpendProvider = CrossMachineSpendProvider(),
        settings: AppSettings? = nil
    ) {
        self.scanner = scanner
        self.costProvider = costProvider
        self.personalSpendProvider = personalSpendProvider
        self.crossMachineProvider = crossMachineProvider
        self.settings = settings
    }

    /// Constroi com sessoes/gasto fixos, sem tocar scanner/ccusage nem o timer. Usado
    /// pelo snapshot headless (SnapshotRenderer) pra montar a AgentsPageView num estado
    /// deterministico (fixture ou scan real de tiro unico, ja mesclado).
    init(sessions: [AgentSession], personalSpend: PersonalSpend? = nil) {
        self.scanner = SessionScanner()
        self.costProvider = SessionCostProvider()
        self.personalSpendProvider = PersonalSpendProvider()
        self.crossMachineProvider = CrossMachineSpendProvider()
        self.settings = nil
        self.sessions = sessions
        self.personalSpend = personalSpend
    }

    var summary: (active: Int, idle: Int, totalContextTokens: Int) {
        let active = sessions.filter(\.isActive)
        let ctx = active.reduce(0) { $0 + $1.contextTokens } // ctx das ATIVAS (as que queimam)
        return (active.count, sessions.count - active.count, ctx)
    }

    func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tickGeneration += 1 // invalida qualquer tick em voo: nao escreve mais em sessions
    }

    /// Refresh manual (botao do rodape, so chamado quando a pagina Consumo esta aberta):
    /// zera os TTLs de ccusage (e do sync entre Macs, se ligado) e forca um tick imediato.
    func forceRefresh() async {
        await costProvider.invalidate()
        await personalSpendProvider.invalidate()
        await crossMachineProvider.invalidate()
        tick()
    }

    /// Acao "Remover esta maquina" (Config): apaga machines/spend/<esta maquina>.json
    /// da pasta compartilhada, pra ela nao continuar somando pra sempre no total dos
    /// outros Macs depois de aposentada. So faz sentido com o sync ligado; chamavel de
    /// qualquer jeito (nao-op silencioso se a pasta nunca foi criada).
    func removeThisMachineFromSync() async {
        await crossMachineProvider.removeLocalMachine()
    }

    private func tick() {
        guard !tickInFlight else { return }
        tickInFlight = true
        let scanner = self.scanner
        let costProvider = self.costProvider
        let personalSpendProvider = self.personalSpendProvider
        let crossMachineProvider = self.crossMachineProvider
        let syncEnabled = settings?.syncAcrossMacs ?? false
        let generation = tickGeneration
        Task {
            await costProvider.refreshIfNeeded()
            await personalSpendProvider.refreshIfNeeded()
            let scanned = await scanner.scan()
            let costs = await costProvider.current()
            var spend = await personalSpendProvider.current()
            var otherMachines = 0

            // So participa do sync depois do 1o fetch local bem-sucedido (`spend != nil`):
            // `currentDailyMap()` comeca vazio ([:]) e o fetch do ccusage e' fire-and-forget
            // (refreshIfNeeded acima nao espera o processo terminar), entao no boot da
            // sessao o mapa local pode ainda estar vazio quando este tick chega aqui. Como
            // `CrossMachineSpendProvider.refreshIfNeeded` faz OVERWRITE do arquivo inteiro
            // (nao e' delta) e tem seu proprio TTL de ~3min, escrever esse mapa vazio
            // clobberia o historico de verdade desta maquina no arquivo compartilhado ate o
            // TTL vencer de novo -- possivelmente nunca, se a pagina Consumo nao ficar
            // aberta 3min+ nessa sessao. `spend != nil` so' fica true apos um fetch real
            // (mesmo que o resultado seja legitimamente zero), entao nunca escreve "vazio
            // por ainda nao ter carregado" como se fosse "vazio de verdade".
            if syncEnabled, spend != nil {
                let localDaily = await personalSpendProvider.currentDailyMap()
                let account = AccountReader.currentAccount()
                await crossMachineProvider.refreshIfNeeded(
                    localDaily: localDaily, accountEmail: account.email,
                    label: MachineIdentity.defaultLabel(), appVersion: appVersionString
                )
                spend = await crossMachineProvider.mergedSpend(
                    localDaily: localDaily, accountEmail: account.email
                )
                otherMachines = await crossMachineProvider.remoteMachineCount()
            }

            self.tickInFlight = false
            guard generation == self.tickGeneration else { return } // pagina fechou no meio do scan
            self.sessions = mergeCosts(sessions: scanned, costs: costs)
            self.personalSpend = spend
            self.syncedOtherMachines = otherMachines
        }
    }
}

/// Versao curta do app (CFBundleShortVersionString), pro campo `appVersion` de
/// machines/<machineId>.json. "?" so no caso teorico do Info.plist nao ter a chave
/// (nunca acontece no bundle de producao, mas evita crash em teste/CLI sem bundle).
private var appVersionString: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
}
