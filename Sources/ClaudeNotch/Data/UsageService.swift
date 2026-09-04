import Foundation
import Combine

/// Resultado interno de uma tentativa de obter o usage (dado, motivo de stale, se e token expirado).
struct UsageOutcome: Equatable {
    let response: UsageResponse?
    let staleReason: String?
    let expired: Bool
}

/// True se o reset da janela de 5h ja passou (cache ficou obsoleto: a janela virou).
/// Livre (nao-privada) pra ser testada isoladamente (porta de `_reset_passed`).
func fiveHourResetPassed(_ resp: UsageResponse, now: Date = Date()) -> Bool {
    guard let iso = resp.fiveHour?.resetsAt, let date = parseISO8601(iso) else { return false }
    return date <= now
}

/// Mapeia um erro de rede/HTTP pro (motivo de stale, se e expirado, quanto o servidor
/// pediu de espera). Livre pra testar sem precisar de rede de verdade. 401/403 -> expired;
/// 429 -> "429 (busy)"; outro HTTP -> "HTTP n"; qualquer outra coisa -> "offline".
func mapUsageError(_ error: Error) -> (reason: String, expired: Bool, retryAfter: TimeInterval?) {
    if let apiError = error as? UsageAPIError, case .http(let code, let retryAfter) = apiError {
        if code == 401 || code == 403 { return ("HTTP \(code)", true, retryAfter) }
        if code == 429 { return ("429 (busy)", false, retryAfter) }
        return ("HTTP \(code)", false, retryAfter)
    }
    return ("offline", false, nil)
}

/// Servico de dados: entrega um UsageSnapshot observavel, com cache/TTL e fallback (porta do plugin Python).
@MainActor
final class UsageService: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .initial

    private let api: UsageFetching
    private let cache: UsageCache
    private let credentialsProvider: () -> KeychainReader.Credentials?
    private let decoder = JSONDecoder()
    private var timer: Timer?

    /// Portao de rede: depois de uma falha, respeita o `Retry-After`/backoff em vez de
    /// deixar o timer de 60s e cada hover baterem na API de novo (ver `UsageBackoff`).
    private var gate = UsageFetchGate()
    /// Ultimo motivo de falha, pra continuar marcando o snapshot como stale enquanto o
    /// portao esta fechado (nada de fingir que o dado e fresco so porque nao tentamos).
    private var lastFailure: (reason: String, expired: Bool)?

    /// Refresh em andamento, se houver. Evita que o timer de 60s e um hover concorrente
    /// disparem 2 fetches ao mesmo tempo (e um mais lento sobrescrever o resultado do outro).
    private var inFlightRefresh: Task<Void, Never>?

    /// Cache em memoria da conta logada (leitura sincrona de ~/.claude.json, que so cresce
    /// com o historico do Claude Code). Sem isto, CADA hover no notch (onHoverEnter chama
    /// refresh) pagaria disco+parse de novo na main thread; aqui so rele a cada 60s, mesmo
    /// ritmo do timer de fundo.
    private var cachedAccount: LoggedInAccount?
    private var cachedAccountAt: Date?
    private static let accountTTL: TimeInterval = 60

    private func currentAccountCached() -> LoggedInAccount {
        if let cachedAccount, let cachedAccountAt, Date().timeIntervalSince(cachedAccountAt) < Self.accountTTL {
            return cachedAccount
        }
        let account = AccountReader.currentAccount()
        cachedAccount = account
        cachedAccountAt = Date()
        return account
    }

    init(
        api: UsageFetching = UsageAPI(),
        cache: UsageCache = UsageCache(),
        credentialsProvider: @escaping () -> KeychainReader.Credentials? = {
            KeychainReader.readCredentials()
        }
    ) {
        self.api = api
        self.cache = cache
        self.credentialsProvider = credentialsProvider
    }

    /// Inicializa com um snapshot fixo, sem tocar rede. Usado pelo render headless de
    /// verificacao (SnapshotRenderer) pra montar o PanelView num estado deterministico.
    init(snapshot: UsageSnapshot) {
        self.api = UsageAPI()
        self.cache = UsageCache()
        self.credentialsProvider = { KeychainReader.readCredentials() }
        self.snapshot = snapshot
    }

    /// Dispara o primeiro refresh e o loop de ~60s (a rede em si e gated por TTL dentro do refresh).
    func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Refresh manual (botao do rodape): ignora o TTL do cache E o backoff, e vai direto na
    /// rede. NAO apaga mais o arquivo de cache antes de tentar (era um bug: com a API fora
    /// do ar/429 o fetch falhava e o ultimo valor bom ja tinha sido destruido, entao o
    /// painel ficava sem numero nenhum). O arquivo so' e' sobrescrito por um fetch que deu
    /// certo -- e enquanto isso ele segue servindo de fallback.
    func forceRefresh() async {
        await refresh(force: true)
    }

    /// Tambem chamavel diretamente no hover (gated por TTL, entao nao bate rede toda hora).
    /// Coalesce chamadas concorrentes: se ja tem um refresh rodando, so espera ele terminar
    /// em vez de comecar outro fetch em paralelo.
    func refresh(force: Bool = false) async {
        if let inFlightRefresh {
            await inFlightRefresh.value
            // Um refresh manual nao pode se contentar com o resultado de um refresh de
            // fundo que talvez nem tenha ido na rede (portao fechado): tenta o dele.
            if !force { return }
        }
        let task = Task { await performRefresh(force: force) }
        inFlightRefresh = task
        await task.value
        inFlightRefresh = nil
    }

    private func performRefresh(force: Bool = false) async {
        // Independente do Keychain (fonte separada, ~/.claude.json): mostra a conta logada
        // mesmo que o token de usage esteja ausente/expirado.
        let account = currentAccountCached()

        // off-main: readCredentials roda um subprocesso (`security`) e pode esperar um prompt
        // do Keychain na 1a vez; nao pode bloquear a MainActor.
        let readCredentials = credentialsProvider
        guard let creds = await Task.detached(priority: .utility, operation: {
            readCredentials()
        }).value else {
            snapshot = .initial
            snapshot.account = account
            return
        }

        let outcome = await loadUsage(token: creds.accessToken, force: force)

        guard let resp = outcome.response else {
            // Sem nenhum cache utilizavel: so agora "expirado" faz sentido (nao ha nada pra mostrar).
            snapshot = UsageSnapshot(
                fiveHour: nil, sevenDay: nil, opus: nil, sonnet: nil,
                planLabel: "", stale: outcome.staleReason,
                state: outcome.expired ? .expired : .offline,
                fetchedAt: nil, account: account
            )
            return
        }

        // Ha uma resposta utilizavel (fresca ou cache antigo): nunca esconder os medidores so
        // porque o ultimo fetch deu 401/403 (porta do plugin: so bloqueia quando nao ha cache).
        let state: UsageState = outcome.staleReason != nil ? .offline : .ok

        // Nao bate na rede do profile se o usage ja veio stale (evita 2a chamada fadada).
        let profile = await loadProfile(token: creds.accessToken, allowFetch: outcome.staleReason == nil)
        let plan = planLabel(tier: profile?.tier, fallback: creds.subscriptionType)

        snapshot = UsageSnapshot(
            fiveHour: gauge(resp.fiveHour),
            sevenDay: gauge(resp.sevenDay),
            opus: gauge(resp.sevenDayOpus),
            sonnet: gauge(resp.sevenDaySonnet),
            planLabel: plan,
            stale: outcome.staleReason,
            state: state,
            fetchedAt: Date(),
            account: account,
            extraUsage: resp.extraUsage
        )
    }

    // MARK: - Usage (cache + fetch + fallback)

    private func loadUsage(token: String, force: Bool = false) async -> UsageOutcome {
        if !force {
            // 1. cache proprio fresco e com janela ainda nao virada -> nao bate rede
            if let cached = cache.readFresh(cache.usageURL, ttl: UsageCache.usageTTL),
               let decoded = try? decoder.decode(UsageResponse.self, from: cached),
               !fiveHourResetPassed(decoded) {
                return UsageOutcome(response: decoded, staleReason: nil, expired: false)
            }

            // 1b. otimizacao opcional: fast-path no cache que o plugin SwiftBar ja mantem
            if let pluginData = cache.readFresh(cache.pluginUsageURL, ttl: UsageCache.usageTTL),
               let decoded = try? decoder.decode(UsageResponse.self, from: pluginData),
               !fiveHourResetPassed(decoded) {
                cache.write(cache.usageURL, data: pluginData)
                return UsageOutcome(response: decoded, staleReason: nil, expired: false)
            }
        }

        // 1c. falhou ha pouco e o servidor pediu espera (429 com Retry-After, rede fora):
        // segurar a rede ate o deadline, servindo o ultimo valor bom marcado como stale.
        guard gate.shouldFetch(now: Date(), force: force) else {
            let failure = lastFailure ?? (reason: "aguardando", expired: false)
            return fallbackUsage(reason: failure.reason, expired: failure.expired)
        }

        // 2. fetch ao vivo
        do {
            let raw = try await api.fetchUsageRaw(token: token)
            guard let decoded = try? decoder.decode(UsageResponse.self, from: raw) else {
                // Resposta 200 que nao decodifica nao e' culpa de rate limit: nao fecha o
                // portao (senao um deploy quebrado da API cegaria o app por 15 min).
                return fallbackUsage(reason: "offline", expired: false)
            }
            cache.write(cache.usageURL, data: raw)
            gate.recordSuccess()
            lastFailure = nil
            return UsageOutcome(response: decoded, staleReason: nil, expired: false)
        } catch {
            let mapped = mapUsageError(error)
            gate.recordFailure(retryAfter: mapped.retryAfter, now: Date())
            lastFailure = (reason: mapped.reason, expired: mapped.expired)
            return fallbackUsage(reason: mapped.reason, expired: mapped.expired)
        }
    }

    private func fallbackUsage(reason: String, expired: Bool) -> UsageOutcome {
        if let cached = cache.read(cache.usageURL),
           let decoded = try? decoder.decode(UsageResponse.self, from: cached) {
            return UsageOutcome(response: decoded, staleReason: reason, expired: expired)
        }
        return UsageOutcome(response: nil, staleReason: reason, expired: expired)
    }

    // MARK: - Profile (cache longo + fetch opcional)

    private func loadProfile(token: String, allowFetch: Bool) async -> ProfileResponse? {
        if let cached = cache.readFresh(cache.profileURL, ttl: UsageCache.profileTTL),
           let decoded = try? decoder.decode(ProfileResponse.self, from: cached) {
            return decoded
        }
        if allowFetch {
            do {
                let raw = try await api.fetchProfileRaw(token: token)
                if let decoded = try? decoder.decode(ProfileResponse.self, from: raw) {
                    cache.write(cache.profileURL, data: raw)
                    return decoded
                }
            } catch {
                // segue pro fallback do cache velho
            }
        }
        if let cached = cache.read(cache.profileURL),
           let decoded = try? decoder.decode(ProfileResponse.self, from: cached) {
            return decoded
        }
        return nil
    }

    // MARK: - Mapeamento

    private func gauge(_ node: UsageNode?) -> Gauge? {
        guard let node, let utilization = node.utilization else { return nil }
        // .toNearestOrEven casa com o round() do Python (round-half-to-even) do plugin de origem,
        // senao um valor .5 exato (ex. 62.5) arredonda pra lados diferentes nos dois.
        return Gauge(utilizationPct: Int(utilization.rounded(.toNearestOrEven)), resetsAt: parseISO8601(node.resetsAt))
    }
}
