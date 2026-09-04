import Foundation

/// Estado geral do painel (porta de `_reset_passed`/erros do plugin Python).
enum UsageState: Equatable {
    case ok
    case noToken
    case expired
    case offline
}

/// Um medidor (5h, semanal, opus, sonnet): percentual + hora do reset.
struct Gauge: Equatable {
    let utilizationPct: Int
    let resetsAt: Date?
}

/// Conta Claude logada agora (porta de `current_account`, so os campos que a UI mostra).
struct LoggedInAccount: Equatable {
    var email: String?
    var displayName: String?

    static let none = LoggedInAccount(email: nil, displayName: nil)
}

/// Snapshot atual de uso, publicado pelo UsageService e consumido pelo PanelView.
struct UsageSnapshot: Equatable {
    var fiveHour: Gauge?
    var sevenDay: Gauge?
    var opus: Gauge?
    var sonnet: Gauge?
    var planLabel: String
    var stale: String?
    var state: UsageState
    var fetchedAt: Date?
    var account: LoggedInAccount = .none
    var extraUsage: ExtraUsageNode?

    static let initial = UsageSnapshot(
        fiveHour: nil, sevenDay: nil, opus: nil, sonnet: nil,
        planLabel: "", stale: nil, state: .noToken, fetchedAt: nil
    )

    /// True quando ha ao menos um medidor com numero (fresco ou de cache). False = o app
    /// esta cego (fetch falhou e nao ha cache), e a UI precisa dizer isso em vez de 0%.
    var hasAnyGauge: Bool {
        fiveHour != nil || sevenDay != nil || opus != nil || sonnet != nil
    }

    /// Pior percentual entre 5h e semanal (aciona o AlertPeek).
    var worstPct: Int {
        max(fiveHour?.utilizationPct ?? 0, sevenDay?.utilizationPct ?? 0)
    }
}

/// Nome amigavel do plano a partir do rate_limit_tier (ex.: "default_claude_max_20x" -> "Max 20x").
/// Cai para o subscriptionType do Keychain quando o tier vem vazio (porta de `plan_label`).
func planLabel(tier: String?, fallback: String?) -> String {
    let t = (tier ?? "").lowercased()
    if t.isEmpty {
        let fb = (fallback?.isEmpty == false) ? fallback! : "subscription"
        return fb.prefix(1).uppercased() + fb.dropFirst()
    }
    if t.contains("max_20x") { return "Max 20x" }
    if t.contains("max_5x") { return "Max 5x" }
    if t.contains("pro") { return "Pro" }
    if t.contains("free") { return "Free" }
    return t
        .replacingOccurrences(of: "default_", with: "")
        .replacingOccurrences(of: "_", with: " ")
        .capitalized
}
