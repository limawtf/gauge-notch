import Foundation

/// Os 3 valores sempre visiveis do heroi de gasto da pagina Consumo (Hoje . Mes . Total).
/// "Total" = lifetime (extraido pra ser testado isoladamente, sem SwiftUI).
func spendHeroValues(_ spend: PersonalSpend?) -> (today: Double?, month: Double?, total: Double?) {
    (spend?.today, spend?.month, spend?.lifetime)
}

/// Formata custo em dolar, compacto (poucas casas conforme a magnitude, pra caber na
/// linha estreita do notch).
func formatUSD(_ value: Double?) -> String {
    guard let value, value > 0 else { return "$0" }
    if value >= 10 { return String(format: "$%.0f", value) }
    if value >= 1 { return String(format: "$%.1f", value) }
    return String(format: "$%.2f", value)
}

/// Como `formatUSD`, mas distingue "sem dado ainda" (nil, ex. ccusage indisponivel) de
/// "gastou de fato $0": nil vira "-", nunca "$0" forjado. Usada no heroi de gasto pessoal.
func formatUSDOrDash(_ value: Double?) -> String {
    guard let value else { return "-" }
    return formatUSD(value)
}

/// Formata o trio Hoje/Mes/Total do heroi de gasto com a MESMA quantidade de casas
/// decimais pros 3 (derivada do MAIOR dos 3 valores), em vez de cada um escolher sua
/// propria faixa isoladamente (`formatUSD`). Sem isso, "Hoje $4.3" (com decimal) aparece
/// do lado de "Mes $96"/"Total $812" (sem decimal) na mesma linha, lendo como
/// inconsistencia bem no elemento mais em destaque da pagina. nil sempre "-".
func formatSpendHeroTrio(
    _ values: (today: Double?, month: Double?, total: Double?)
) -> (today: String, month: String, total: String) {
    let maxValue = [values.today, values.month, values.total].compactMap { $0 }.max() ?? 0
    let decimals: Int
    if maxValue >= 10 { decimals = 0 } else if maxValue >= 1 { decimals = 1 } else { decimals = 2 }

    func fmt(_ value: Double?) -> String {
        guard let value else { return "-" }
        guard value > 0 else { return "$0" }
        return String(format: "$%.\(decimals)f", value)
    }
    return (fmt(values.today), fmt(values.month), fmt(values.total))
}

/// Tokens compactos: 1_234_000 -> "1.2M", 45_000 -> "45K", 900 -> "900".
func formatTokensShort(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return String(format: "%.0fK", Double(tokens) / 1_000) }
    return "\(tokens)"
}

/// Duracao "1h23min" / "23min". nil ou <=0 -> "-".
func formatDuration(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds > 0 else { return "-" }
    let totalMinutes = Int(seconds) / 60
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if h > 0 { return "\(h)h\(m)min" }
    return "\(m)min"
}

/// "ha Ns" / "ha Nmin" / "ha Nh", pro "ultima atividade" de cada subagent.
func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "ha \(seconds)s" }
    if seconds < 3600 { return "ha \(seconds / 60)min" }
    return "ha \(seconds / 3600)h"
}
