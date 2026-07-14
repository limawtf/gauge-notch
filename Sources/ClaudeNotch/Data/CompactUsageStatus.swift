import SwiftUI

/// Pior % + cor pro indicador compacto colado no notch (compactTrailing do
/// DynamicNotch). Pura (so depende de Theme/UsageSnapshot), testavel sem SwiftUI/hover.
struct CompactUsageStatus: Equatable {
    let pct: Int?
    let color: Color?
}

/// So mostra numero quando o snapshot tem dado BOM: `state == .ok` e pelo menos um
/// medidor presente. Qualquer outro estado (sem token, expirado, offline/stale) vira
/// dot cinza neutro, nunca um numero desatualizado/errado (spec secao D).
func compactUsageStatus(for snapshot: UsageSnapshot) -> CompactUsageStatus {
    guard snapshot.state == .ok, snapshot.fiveHour != nil || snapshot.sevenDay != nil else {
        return CompactUsageStatus(pct: nil, color: nil)
    }
    let pct = snapshot.worstPct
    return CompactUsageStatus(pct: pct, color: Theme.color(forPct: pct))
}
