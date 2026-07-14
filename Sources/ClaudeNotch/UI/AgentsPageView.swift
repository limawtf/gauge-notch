import SwiftUI

/// Segunda pagina do painel: sessoes ativas do Claude Code nesta maquina. So refresca
/// (timer de 3s dentro do SessionsService) enquanto esta na tela: liga no onAppear,
/// desliga no onDisappear.
struct AgentsPageView: View {
    @ObservedObject var service: SessionsService
    let onBack: () -> Void
    /// Credito extra/pago da org (feature condicional): vem do oauth/usage decodificado
    /// na pagina Uso, so passado aqui pra desenhar. nil ou `isEnabled != true` = some.
    let extraUsage: ExtraUsageNode?

    @State private var spendExpanded = false
    @State private var expandedId: String?

    /// `initialExpandedId` so existe pra forcar o accordion aberto na verificacao
    /// headless (`--snapshot --state agents-real --expand <id>`): sem isso, o caso mais
    /// denso do design (breakdown + sub-lista de subagents) nunca era renderizado nem
    /// conferido visualmente antes de shippar.
    init(
        service: SessionsService, onBack: @escaping () -> Void,
        extraUsage: ExtraUsageNode? = nil, initialExpandedId: String? = nil
    ) {
        self.service = service
        self.onBack = onBack
        self.extraUsage = extraUsage
        self._expandedId = State(initialValue: initialExpandedId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            VStack(alignment: .leading, spacing: 14) {
                spendHero
                extraUsageRow
                Divider().overlay(Theme.divider)
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .onAppear { service.start() }
        .onDisappear { service.stop() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Voltar")

            Text("Consumo")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Spacer()

            if !summaryText.isEmpty {
                Text(summaryText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaryText: String {
        let s = service.summary
        guard s.active > 0 || s.idle > 0 else { return "" }
        var parts: [String] = []
        if s.active > 0 { parts.append("\(s.active) ativa\(s.active == 1 ? "" : "s")") }
        if s.idle > 0 { parts.append("\(s.idle) ociosa\(s.idle == 1 ? "" : "s")") }
        if s.active > 0 { parts.append("\(formatTokensShort(s.totalContextTokens)) ctx") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Heroi: gasto pessoal (Hoje . Mes . Total, sempre os 3; tap revela 7 dias)

    private var spendHero: some View {
        let values = spendHeroValues(service.personalSpend)
        // Precisao decimal COMPARTILHADA pros 3 (derivada do maior), pra Hoje/Mes/Total
        // nunca lerem com numero de casas diferente na mesma linha (ver AgentFormatting).
        let formatted = formatSpendHeroTrio(values)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                spendBucket("Hoje", formatted.today, hero: true)
                spendBucket("Mes", formatted.month, hero: true)
                spendBucket(totalLabel, formatted.total, hero: true)
                Spacer(minLength: 0)
            }
            if spendExpanded {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    spendBucket("7 dias", formatUSDOrDash(service.personalSpend?.last7), hero: false)
                    Spacer(minLength: 0)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { spendExpanded.toggle() }
        }
    }

    /// "Total" sozinho, ou "Total (N Macs)" quando o sync entre Macs esta ligado e ja
    /// enxergou pelo menos uma outra maquina viva (drilldown minimo, feature
    /// multimac-sync: nao muda o layout quando o sync esta desligado ou sem par).
    private var totalLabel: String {
        let others = service.syncedOtherMachines
        guard others > 0 else { return "Total" }
        return "Total (\(others + 1) Macs)"
    }

    /// `$` sempre neutro (cinza tabular): e gasto, nao um estado de alerta, entao nao
    /// usa Theme.color(forPct:). Os 3 (Hoje/Mes/Total) sao o heroi desta pagina, precisam
    /// caber juntos sem quebrar linha; 7 dias revela do mesmo jeito no tap, so menor.
    private func spendBucket(_ label: String, _ formattedValue: String, hero: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: hero ? 10 : 9.5))
                .foregroundStyle(Theme.tertiaryText)
            Text(formattedValue)
                .font(.system(size: hero ? 16 : 13, weight: hero ? .semibold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(hero ? Theme.primaryText : Theme.secondaryText)
        }
    }

    // MARK: - Extra usage / creditos (condicional)

    @ViewBuilder
    private var extraUsageRow: some View {
        if shouldShowExtraUsage(extraUsage), let extra = extraUsage {
            HStack(spacing: 6) {
                Text("Credito extra")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                Text(extraUsageText(extra))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func extraUsageText(_ extra: ExtraUsageNode) -> String {
        let used = extra.usedCredits ?? 0
        let limit = extra.monthlyLimit ?? 0
        let currency = extra.currency ?? ""
        var text = String(format: "%@ %.2f / %.2f", currency, used, limit)
        if let utilization = extra.utilization {
            text += " \u{00B7} \(Int(utilization.rounded()))%"
        }
        return text
    }

    /// Teto de QUANTAS sessoes desenham na lista. A janela do DynamicNotch tem altura
    /// FIXA (metade da tela, definida uma vez) e o conteudo so cresce via `.fixedSize()`
    /// (nao ha como redimensionar a janela nem, por limitacao do ImageRenderer usado na
    /// verificacao headless, usar ScrollView -- ele renderiza em branco ali). Entao o
    /// teto e por CONTAGEM (deterministico), nao por altura medida: alem disso, so um
    /// aviso "+N sessoes mais antigas" em vez de transbordar silenciosamente.
    private static let maxSessionRows = 6

    @ViewBuilder
    private var content: some View {
        if service.sessions.isEmpty {
            Text("Nenhuma sessao ativa")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let shown = service.sessions.prefix(Self.maxSessionRows)
            let hiddenCount = service.sessions.count - shown.count
            // Espacamento generoso entre sessoes: sem caixa/fundo por linha, o
            // agrupamento agora e so por proximidade (Gestalt).
            VStack(alignment: .leading, spacing: 16) {
                ForEach(shown) { session in
                    AgentRowView(
                        session: session,
                        expanded: expandedId == session.id,
                        onTap: { toggle(session.id) }
                    )
                }
                if hiddenCount > 0 {
                    Text("+\(hiddenCount) sessoes mais antigas nao mostradas")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        expandedId = (expandedId == id) ? nil : id
    }
}
