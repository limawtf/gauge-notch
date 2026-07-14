import SwiftUI

/// Uma linha de medidor: rotulo + barra colorida + percentual + hora do reset.
struct GaugeRow: View {
    let label: String
    let gauge: Gauge?
    var compact: Bool = false

    private var pct: Int { gauge?.utilizationPct ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: compact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(compact ? Theme.secondaryText : Theme.primaryText)
                Spacer()
                Text("\(pct)%")
                    .font(.system(size: compact ? 11 : 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.color(forPct: pct))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.cardBackground)
                    Capsule()
                        .fill(Theme.color(forPct: pct))
                        .frame(width: geo.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
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
