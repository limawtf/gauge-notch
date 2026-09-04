import Foundation

/// Formas cruas da resposta da API (nomes iguais ao JSON, decodificadas 1:1).
struct UsageNode: Codable, Equatable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Credito extra/pago (alem do plano), so aparece quando a org tem essa modalidade
/// habilitada. Renderizacao condicional na pagina Consumo (gate em `isEnabled`).
struct ExtraUsageNode: Codable, Equatable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

/// Gate de exibicao (a org logada esta out_of_credits, entao isso normalmente e
/// false/nil): livre pra testar sem SwiftUI, usado direto pela AgentsPageView.
func shouldShowExtraUsage(_ extra: ExtraUsageNode?) -> Bool {
    extra?.isEnabled == true
}

struct UsageResponse: Codable, Equatable {
    let fiveHour: UsageNode?
    let sevenDay: UsageNode?
    let sevenDayOpus: UsageNode?
    let sevenDaySonnet: UsageNode?
    let extraUsage: ExtraUsageNode?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

struct ProfileResponse: Codable, Equatable {
    struct Org: Codable, Equatable {
        let rateLimitTier: String?
        enum CodingKeys: String, CodingKey { case rateLimitTier = "rate_limit_tier" }
    }
    struct Account: Codable, Equatable {
        let rateLimitTier: String?
        enum CodingKeys: String, CodingKey { case rateLimitTier = "rate_limit_tier" }
    }

    let organization: Org?
    let account: Account?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case organization
        case account
        case rateLimitTier = "rate_limit_tier"
    }

    /// Ordem de busca do tier: organization -> topo -> account (porta de `profile_tier`).
    var tier: String? {
        organization?.rateLimitTier ?? rateLimitTier ?? account?.rateLimitTier
    }
}

enum UsageAPIError: Error {
    /// `retryAfter` = header `Retry-After` em segundos, quando o servidor mandou (429).
    /// Quem trata decide a espera (ver `UsageBackoff`).
    case http(Int, retryAfter: TimeInterval?)
    case network(Error)
    case decode(Error)
}

/// O que o UsageService precisa da rede. Existe pra o servico poder ser testado com um
/// duble (comportamento sob 429/erro) sem bater na API de verdade.
protocol UsageFetching: AnyObject {
    func fetchUsageRaw(token: String) async throws -> Data
    func fetchProfileRaw(token: String) async throws -> Data
}

/// Cliente HTTP fino: GET oauth/usage e oauth/profile, header anthropic-beta + Bearer, timeout 10s.
final class UsageAPI: UsageFetching {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config)
    }

    /// Retorna os bytes crus da resposta (o chamador decodifica e cacheia).
    private func getRaw(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageAPIError.network(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let retryAfter = UsageBackoff.parseRetryAfter(
                http.value(forHTTPHeaderField: "Retry-After")
            )
            throw UsageAPIError.http(http.statusCode, retryAfter: retryAfter)
        }
        return data
    }

    func fetchUsageRaw(token: String) async throws -> Data {
        try await getRaw(Self.usageURL, token: token)
    }

    func fetchProfileRaw(token: String) async throws -> Data {
        try await getRaw(Self.profileURL, token: token)
    }
}
