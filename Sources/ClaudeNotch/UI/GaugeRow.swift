import SwiftUI

/// Uma linha de medidor: rotulo + barra colorida + percentual + hora do reset.
struct GaugeRow: View {
    let label: String
    let gauge: Gauge?
    var compact: Bool = false

    /// nil = NAO ha dado (fetch falhou e nao ha cache). Nunca mostrar isso como "0%":
    /// 0% verde e' uma afirmacao ("voce nao usou nada") e era exatamente o que fazia o
    /// painel parecer sincronizado estando cego.
    private var pct: Int? { gauge?.utilizationPct }
    private var barPct: Int { pct ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: compact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(compact ? Theme.secondaryText : Theme.primaryText)
                Spacer()
                Text(pct.map { "\($0)%" } ?? "-")
                    .font(.system(size: compact ? 11 : 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(pct.map { Theme.color(forPct: $0) } ?? Theme.tertiaryText)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.cardBackground)
                    Capsule()
                        .fill(pct.map { Theme.color(forPct: $0) } ?? Theme.tertiaryText)
                        .frame(width: geo.size.width * CGFloat(min(max(barPct, 0), 100)) / 100)
                }
            }
            .frame(height: compact ? 4 : 5)

            if let resetsAt = gauge?.resetsAt {
                Text("resets \(formatReset(resetsAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}
