import SwiftUI

/// Painel principal que desce do notch: header, medidores, rodape.
struct PanelView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var pinState: PinState
    @ObservedObject var navigation: PanelNavigation
    @ObservedObject var sessionsService: SessionsService
    @ObservedObject var updateService: UpdateService
    @ObservedObject var updater: Updater
    let onTogglePin: () -> Void
    let onQuit: () -> Void
    /// Refresh manual (botao do rodape): limpa cache de usage + refaz o fetch, e as
    /// sessoes tambem se a pagina Consumo estiver aberta (ver AppDelegate).
    var onRefresh: () -> Void = {}
    /// So usado pela verificacao headless (`--snapshot --expand <id>`) pra forcar o
    /// accordion de uma sessao aberto sem precisar de mouse/click.
    var expandAgentId: String? = nil

    private var snapshot: UsageSnapshot { service.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch navigation.page {
            case .usage:
                header
                Divider().overlay(Theme.divider)
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            case .agents:
                AgentsPageView(
                    service: sessionsService, onBack: { navigation.page = .usage },
                    extraUsage: snapshot.extraUsage, initialExpandedId: expandAgentId
                )
            }
            Divider().overlay(Theme.divider).padding(.top, 12)
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.panelBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                if !snapshot.planLabel.isEmpty {
                    Text("·")
                        .foregroundStyle(Theme.tertiaryText)
                    Text(snapshot.planLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if let stale = snapshot.stale {
                    // "cached" so' quando ha mesmo um valor cacheado pra mostrar; sem
                    // nenhum dado, o selo diz o MOTIVO (ex. "429 (busy)") em vez de fingir
                    // que o painel esta servindo cache.
                    Text(snapshot.hasAnyGauge ? "cached" : stale)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.cardBackground))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            // 3a informacao, discreta: a conta logada nao compete com os medidores.
            if let email = snapshot.account.email, !email.isEmpty {
                Text(email)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Corpo (por estado)

    @ViewBuilder
    private var content: some View {
        switch snapshot.state {
        case .noToken:
            statusMessage("Faca login no Claude Code")
        case .expired:
            statusMessage("Token expirado, abra o Claude Code")
        case .offline, .ok:
            gauges
        }
    }

    private func statusMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.secondaryText)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gauges: some View {
        VStack(alignment: .leading, spacing: 14) {
            GaugeRow(label: "5h (sessao)", gauge: snapshot.fiveHour)
            GaugeRow(label: "Semanal (all)", gauge: snapshot.sevenDay)

            if snapshot.opus != nil || snapshot.sonnet != nil {
                Divider().overlay(Theme.divider)
                VStack(alignment: .leading, spacing: 8) {
                    if let opus = snapshot.opus {
                        GaugeRow(label: "Semanal Opus", gauge: opus, compact: true)
                    }
                    if let sonnet = snapshot.sonnet {
                        GaugeRow(label: "Semanal Sonnet", gauge: sonnet, compact: true)
                    }
                }
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: - Rodape

    private var footer: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(updatedAgoText(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Button(action: onTogglePin) {
                Image(systemName: pinState.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .arrowCursor()
            .help(pinState.pinned ? "Soltar (deixar de fixar aberto)" : "Fixar aberto")

            Menu {
                Toggle("Avisar em uso alto (>90%)", isOn: $settings.peekEnabled)
                Toggle("Mostrar uso no notch", isOn: $settings.showNotchUsage)
                Divider()
                Toggle("Sincronizar uso entre Macs", isOn: $settings.syncAcrossMacs)
                if settings.syncAcrossMacs && !SyncFolder().isAvailable {
                    Text("iCloud Drive indisponivel")
                }
                if settings.syncAcrossMacs {
                    Button("Remover esta maquina do sync") {
                        Task { await sessionsService.removeThisMachineFromSync() }
                        settings.syncAcrossMacs = false
                    }
                }
                Divider()
                Toggle("Abrir no login", isOn: launchAtLoginBinding)
                if let update = updateService.available {
                    Divider()
                    Button(updater.isInstalling ? "Atualizando..." : "Atualizar para v\(update.version)") {
                        Task { await updater.install(update) }
                    }
                    .disabled(updater.isInstalling)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .arrowCursor()
            .help("Config")

            if navigation.page == .usage {
                Button {
                    navigation.page = .agents
                } label: {
                    Image(systemName: "person.2")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .arrowCursor()
                .help("Ver consumo")
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .arrowCursor()
            .help("Atualizar agora")

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .arrowCursor()
            .help("Sair do Claude Notch")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// SMAppService nao e @Published/observavel: le/escreve direto a cada abertura do
    /// menu (o Menu reconstroi o conteudo toda vez que abre, entao fica sempre fresco).
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.setEnabled($0) }
        )
    }

    private func updatedAgoText(now: Date) -> String {
        guard let fetchedAt = snapshot.fetchedAt else { return "sem dados ainda" }
        let seconds = max(0, Int(now.timeIntervalSince(fetchedAt)))
        if seconds < 60 { return "atualizado ha \(seconds)s" }
        return "atualizado ha \(seconds / 60)min"
    }
}
