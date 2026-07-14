import SwiftUI

/// Uso colado no notch (compactTrailing do DynamicNotch): a tira estreita a direita da
/// camera, visivel com o painel fechado. Mostra o ICONE do provedor (Claude) tingido pelo
/// limite SEMANAL (o "geral") + o NUMERO do limite de 5h (a sessao). Icone cinza e sem
/// numero quando o dado nao e' bom (sem token / expirado / offline-stale), pra nunca
/// mostrar numero velho. So aparece com `settings.showNotchUsage` ligado (gate no
/// NotchController), entao a view em si nao checa a flag.
struct CompactNotchUsageView: View {
    @ObservedObject var service: UsageService
    /// Some o compacto NA HORA que o painel abre, antes da transicao do DynamicNotchKit
    /// (que espreme o compacto e faz o numero dar um flash glitchado na abertura).
    @ObservedObject var openState: NotchOpenState
    /// Enquanto compacta, esta janela (DynamicNotch) fica POR CIMA da HotzonePanel, entao a
    /// hotzone nao recebe clique aqui; `onTap` e o jeito de fixar o painel (pin).
    var onTap: (() -> Void)? = nil

    var body: some View {
        if openState.isOpen {
            EmptyView()
        } else {
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        let snap = service.snapshot
        let ok = snap.state == .ok
        let weeklyPct = ok ? snap.sevenDay?.utilizationPct : nil
        let fivePct = ok ? snap.fiveHour?.utilizationPct : nil
        // Icone tinge pelo limite SEMANAL (o "geral"); cai pro 5h se so tiver ele, senao cinza.
        let iconColor = weeklyPct.map(Theme.color(forPct:))
            ?? fivePct.map(Theme.color(forPct:))
            ?? Theme.tertiaryText

        HStack(spacing: 4) {
            ClaudeMark()
                .fill(iconColor)
                .frame(width: 12, height: 12)
            if let fivePct {
                Text("\(fivePct)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.color(forPct: fivePct))
            }
        }
        .padding(.trailing, 3)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

/// Aproximacao da marca do Claude (sunburst da Anthropic): raios afilados saindo do
/// centro. Shape (nao imagem) pra herdar a cor de estado via `.fill()`.
struct ClaudeMark: Shape {
    var rays: Int = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rOuter = min(rect.width, rect.height) / 2
        let rInner = rOuter * 0.28
        let halfBase = rOuter * 0.12 // meia-largura do raio na base
        for i in 0..<rays {
            let a = (CGFloat(i) / CGFloat(rays)) * 2 * .pi - .pi / 2
            let dir = CGVector(dx: cos(a), dy: sin(a))
            let perp = CGVector(dx: -sin(a), dy: cos(a))
            let baseL = CGPoint(x: c.x + dir.dx * rInner + perp.dx * halfBase,
                                y: c.y + dir.dy * rInner + perp.dy * halfBase)
            let baseR = CGPoint(x: c.x + dir.dx * rInner - perp.dx * halfBase,
                                y: c.y + dir.dy * rInner - perp.dy * halfBase)
            let tip = CGPoint(x: c.x + dir.dx * rOuter, y: c.y + dir.dy * rOuter)
            p.move(to: baseL)
            p.addLine(to: tip)
            p.addLine(to: baseR)
            p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - rInner, y: c.y - rInner, width: rInner * 2, height: rInner * 2))
        return p
    }
}
