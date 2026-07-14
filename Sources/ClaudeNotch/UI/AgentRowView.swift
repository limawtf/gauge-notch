import SwiftUI
import AppKit

/// Uma linha de sessao ativa: colapsada mostra o essencial; tocando expande (accordion,
/// controlado pelo pai) com duracao, breakdown, burn-rate e a sub-lista de subagents.
struct AgentRowView: View {
    let session: AgentSession
    let expanded: Bool
    let onTap: () -> Void

    private static let maxSubagentRows = 6

    var body: some View {
        // Separacao por ESPACO (Gestalt), nao por caixa em cada linha: so a sessao
        // EXPANDIDA ganha um leve realce de fundo (foco visual), uniforme do topo ao
        // fim da linha (colapsado+detalhe juntos, nunca so uma parte). Colapsada, zero
        // fundo, zero borda: as outras linhas se agrupam so pelo espacamento do pai.
        VStack(alignment: .leading, spacing: 8) {
            collapsedRow
            if expanded {
                expandedDetail
            }
        }
        .padding(expanded ? 10 : 0)
        .background {
            if expanded {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.cardBackground)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .opacity(session.isActive ? 1 : 0.55) // ociosa entra esmaecida
    }

    // MARK: - Colapsado

    private var collapsedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(session.project)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Circle()
                    .fill(Theme.color(forModel: modelDotColor(session.model)))
                    .frame(width: 6, height: 6)
                Text(shortModelName(session.model))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(formatUSD(session.costUSD))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
            }

            contextRow(tokens: session.contextTokens, pct: session.contextPct)

            if !session.isActive {
                // linha propria (full width): o "ocioso ha X" nao pode truncar competindo
                // com nome/modelo/custo na 1a linha.
                Text("ocioso \(relativeTime(session.lastActivity))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
            }

            if session.agentsCount > 0 {
                Text("+\(session.agentsCount) agents \u{00B7} \(formatUSDOrDash(session.agentsCostUSD))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    /// Barra relativa a janela quando ela e conhecida; se ambigua (>200K, ver
    /// `contextWindow(forTokens:)`), so o numero absoluto, sem afirmar percentual.
    private func contextRow(tokens: Int, pct: Int?) -> some View {
        HStack(spacing: 6) {
            if let pct {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.cardBackground)
                        Capsule()
                            .fill(Theme.color(forPct: pct))
                            .frame(width: geo.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
                    }
                }
                .frame(height: 4)
            } else {
                // acima do nominal (janela ambigua, sem barra): mesmo assim ocupa o
                // espaco da barra, senao o texto perde o alinhamento a direita e cola
                // na esquerda so nessa linha (justo as sessoes mais longas/criticas).
                Spacer(minLength: 0)
            }
            Text(formatTokensShort(tokens) + " ctx")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(pct == nil ? Theme.color(forPct: 100) : Theme.tertiaryText)
                .fixedSize()
        }
    }

    // MARK: - Expandido

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.divider)

            HStack(spacing: 14) {
                detailStat("duracao", formatDuration(session.durationSeconds))
                detailStat("turnos", "\(session.turns)")
                detailStat("media", formatTokensShort(session.avgTokensPerTurn) + "/turno")
            }
            HStack(spacing: 14) {
                detailStat("in", formatTokensShort(session.inputTokens))
                detailStat("out", formatTokensShort(session.outputTokens))
                detailStat("cache", formatTokensShort(session.cacheReadTokens + session.cacheCreationTokens))
            }
            HStack(spacing: 14) {
                if let burnUSD = session.burnRateUSDPerHour {
                    detailStat("burn", formatUSD(burnUSD) + "/h")
                }
                if let burnTok = session.burnTokPerMin {
                    detailStat("burn", formatTokensShort(Int(burnTok)) + "/min")
                }
                Spacer()
                Button(action: copySessionId) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .arrowCursor()
                .help("Copiar session id")
            }

            if !session.agents.isEmpty {
                // teto POR CONTAGEM (nao por altura medida, ver AgentsPageView): uma
                // sessao com dezenas/centenas de subagents historicos nao pode inflar o
                // accordion sem limite (a janela do notch nao redimensiona e ScrollView
                // renderiza em branco na verificacao headless via ImageRenderer).
                let shown = session.agents.prefix(Self.maxSubagentRows)
                let hiddenCount = session.agents.count - shown.count
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(shown) { agent in
                        subagentRow(agent)
                    }
                    if hiddenCount > 0 {
                        Text("+\(hiddenCount) subagents mais antigos")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.leading, 12)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func detailStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(Theme.tertiaryText)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func subagentRow(_ agent: SubagentSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.color(forModel: modelDotColor(agent.model)))
                .frame(width: 5, height: 5)
            Text(shortModelName(agent.model))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
            Text(formatTokensShort(agent.contextTokens))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
            Text(formatUSDOrDash(agent.costUSD))
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
            Text(relativeTime(agent.lastActivity))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.leading, 12)
    }

    private func copySessionId() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.id, forType: .string)
    }
}
