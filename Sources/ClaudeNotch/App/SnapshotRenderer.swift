import SwiftUI
import AppKit

/// Verificacao headless da UI: renderiza o PanelView num PNG via ImageRenderer, sem janela,
/// sem window server, sem mouse e sem simulador (in-process, macOS 13+). E o jeito correto de
/// conferir como o painel do notch fica de verdade sem depender de screenshot da tela.
///
/// Uso:  ClaudeNotch --snapshot <caminho.png>
///           [--state ok|opus|offline|expired|noToken|agents|agents-real|credits|compact]
///           [--appearance dark|light] [--expand <sessionId>]
/// "compact" renderiza a tira de uso colada no notch (compactTrailing, feature D) em
/// varios casos (verde, vermelho, offline/stale, sem token) lado a lado -- prova que so
/// o estado .ok com medidor de verdade mostra numero, o resto vira dot cinza.
/// "agents" usa 3 sessoes fixture (uma com +agents, uma perto/acima do limite de contexto).
/// "agents-real" faz um scan de tiro unico das sessoes E do gasto pessoal de verdade
/// desta maquina (ccusage daily --json).
/// "credits" e como "agents", mas com extra_usage LIGADO (fixture: a org logada esta
/// out_of_credits, entao esse estado nunca acontece de verdade, so serve pra conferir o
/// layout condicional).
/// "--expand" forca o accordion de uma sessao aberto; sem a flag, "agents"/"agents-real"
/// ja expandem a 1a sessao com subagents por padrao (cobre o caso mais denso do design).
@MainActor
enum SnapshotRenderer {
    /// Roda o render e encerra o processo se `--snapshot` estiver nos argumentos. Retorna false
    /// (nao encerra) quando nao foi pedido, pra o app seguir o boot normal.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let path = args[i + 1]
        let state = value(of: "--state", in: args) ?? "ok"
        let appearance = value(of: "--appearance", in: args) ?? "dark"
        render(state: state, appearance: appearance, to: path) // chama exit()
        return true
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Conta fixture pro header da pagina Uso (feature "conta logada"): so usada nos
    /// estados sinteticos, "real"/"agents-real" leem a conta de verdade. MOCK generico
    /// de proposito (nunca dado pessoal) porque esses estados alimentam os screenshots
    /// publicos do README.
    private static let fixtureAccount = LoggedInAccount(email: "you@example.com", displayName: "You")

    /// Snapshots deterministicos por estado. O "ok" usa os numeros reais atuais (21% / 14% /
    /// Max 20x) pra o PNG bater com o que o app mostra ao vivo.
    private static func snapshot(for state: String) -> UsageSnapshot {
        let reset5h = Date().addingTimeInterval(3 * 3600)
        let reset7d = Date().addingTimeInterval(6 * 24 * 3600)
        let now = Date().addingTimeInterval(-12) // "atualizado ha 12s"
        switch state {
        case "real":
            return realSnapshot() ?? fixtureOK(reset5h: reset5h, reset7d: reset7d, now: now)
        case "noToken":
            return UsageSnapshot(fiveHour: nil, sevenDay: nil, opus: nil, sonnet: nil,
                                 planLabel: "", stale: nil, state: .noToken, fetchedAt: now)
        case "expired":
            return UsageSnapshot(fiveHour: nil, sevenDay: nil, opus: nil, sonnet: nil,
                                 planLabel: "Max 20x", stale: nil, state: .expired, fetchedAt: now)
        case "offline":
            return UsageSnapshot(fiveHour: Gauge(utilizationPct: 21, resetsAt: reset5h),
                                 sevenDay: Gauge(utilizationPct: 14, resetsAt: reset7d),
                                 opus: nil, sonnet: nil, planLabel: "Max 20x",
                                 stale: "429 (busy)", state: .offline, fetchedAt: now, account: fixtureAccount)
        case "opus":
            return UsageSnapshot(fiveHour: Gauge(utilizationPct: 78, resetsAt: reset5h),
                                 sevenDay: Gauge(utilizationPct: 41, resetsAt: reset7d),
                                 opus: Gauge(utilizationPct: 63, resetsAt: reset7d),
                                 sonnet: Gauge(utilizationPct: 22, resetsAt: reset7d),
                                 planLabel: "Max 20x", stale: nil, state: .ok, fetchedAt: now, account: fixtureAccount)
        default: // "ok" com % reais mas resets sinteticos (so pra demo visual)
            return fixtureOK(reset5h: reset5h, reset7d: reset7d, now: now)
        }
    }

    private static func fixtureOK(
        reset5h: Date, reset7d: Date, now: Date, extraUsage: ExtraUsageNode? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(fiveHour: Gauge(utilizationPct: 21, resetsAt: reset5h),
                      sevenDay: Gauge(utilizationPct: 14, resetsAt: reset7d),
                      opus: nil, sonnet: nil, planLabel: "Max 20x",
                      stale: nil, state: .ok, fetchedAt: now, account: fixtureAccount, extraUsage: extraUsage)
    }

    /// Gasto pessoal fixture (feature "gasto pessoal"), usado no estado "agents".
    private static func fixturePersonalSpend() -> PersonalSpend {
        PersonalSpend(today: 4.32, last7: 38.90, month: 96.14, lifetime: 812.47)
    }

    /// Extra usage fixture LIGADO (feature "extra usage/creditos" condicional), so
    /// pro estado "credits" -- a org logada esta out_of_credits, entao isso nunca
    /// aparece no "real"/"agents-real".
    private static func fixtureExtraUsageEnabled() -> ExtraUsageNode {
        ExtraUsageNode(isEnabled: true, monthlyLimit: 200, usedCredits: 143.60,
                       utilization: 71.8, currency: "BRL")
    }

    /// Monta o snapshot a partir dos JSON REAIS que o app ja escreveu no cache, com o MESMO
    /// mapeamento do UsageService (mesmo arredondamento round-half-to-even + parseISO8601 +
    /// planLabel). Sem Keychain, sem rede: le so os arquivos. nil se o cache nao existe.
    private static func realSnapshot() -> UsageSnapshot? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/claude-notch")
        let decoder = JSONDecoder()
        guard let usageData = try? Data(contentsOf: dir.appendingPathComponent("usage.json")),
              let usage = try? decoder.decode(UsageResponse.self, from: usageData) else {
            return nil
        }
        let profileData = try? Data(contentsOf: dir.appendingPathComponent("profile.json"))
        let profile = profileData.flatMap { try? decoder.decode(ProfileResponse.self, from: $0) }

        func gauge(_ node: UsageNode?) -> Gauge? {
            guard let node, let util = node.utilization else { return nil }
            return Gauge(utilizationPct: Int(util.rounded(.toNearestOrEven)),
                         resetsAt: parseISO8601(node.resetsAt))
        }
        return UsageSnapshot(
            fiveHour: gauge(usage.fiveHour),
            sevenDay: gauge(usage.sevenDay),
            opus: gauge(usage.sevenDayOpus),
            sonnet: gauge(usage.sevenDaySonnet),
            planLabel: planLabel(tier: profile?.tier, fallback: nil),
            stale: nil, state: .ok, fetchedAt: Date(),
            account: AccountReader.currentAccount(), extraUsage: usage.extraUsage
        )
    }

    private static func render(state: String, appearance: String, to path: String) {
        if state == "compact" {
            renderCompact(appearance: appearance, to: path) // chama exit()
            return
        }

        let scheme: ColorScheme = (appearance == "light") ? .light : .dark
        let wallpaper = (appearance == "light")
            ? Color(white: 0.90) : Color(white: 0.10)

        let navigation = PanelNavigation()
        let sessionsService: SessionsService
        let usageSnap: UsageSnapshot
        // --expand <id>: forca o accordion de uma sessao aberto (sem isso, o snapshot
        // headless nunca renderizava a parte mais densa/arriscada do design: breakdown +
        // sub-lista de subagents). Sem a flag, expande a 1a sessao com agents por padrao
        // nos estados "agents"/"agents-real", pra essa verificacao cobrir esse caso sempre.
        let explicitExpandId = value(of: "--expand", in: CommandLine.arguments)
        var expandId: String?
        switch state {
        case "agents":
            navigation.page = .agents
            let sessions = fixtureAgentSessions()
            sessionsService = SessionsService(sessions: sessions, personalSpend: fixturePersonalSpend())
            expandId = explicitExpandId ?? sessions.first(where: { $0.agentsCount > 0 })?.id
            usageSnap = fixtureOK(
                reset5h: Date().addingTimeInterval(3 * 3600),
                reset7d: Date().addingTimeInterval(6 * 24 * 3600),
                now: Date().addingTimeInterval(-12)
            )
        case "agents-real":
            navigation.page = .agents
            sessionsService = realSessionsService()
            let sessions = sessionsService.sessions
            expandId = explicitExpandId ?? sessions.first(where: { $0.agentsCount > 0 })?.id ?? sessions.first?.id
            usageSnap = fixtureOK(
                reset5h: Date().addingTimeInterval(3 * 3600),
                reset7d: Date().addingTimeInterval(6 * 24 * 3600),
                now: Date().addingTimeInterval(-12)
            )
        case "credits":
            // Fixture com extra_usage LIGADO (a org logada esta out_of_credits, entao
            // isso nunca aparece no "real"/"agents-real" -- so pra conferir o layout).
            navigation.page = .agents
            let sessions = fixtureAgentSessions()
            sessionsService = SessionsService(sessions: sessions, personalSpend: fixturePersonalSpend())
            expandId = explicitExpandId ?? sessions.first(where: { $0.agentsCount > 0 })?.id
            usageSnap = fixtureOK(
                reset5h: Date().addingTimeInterval(3 * 3600),
                reset7d: Date().addingTimeInterval(6 * 24 * 3600),
                now: Date().addingTimeInterval(-12),
                extraUsage: fixtureExtraUsageEnabled()
            )
        default:
            sessionsService = SessionsService(sessions: [])
            usageSnap = snapshot(for: state)
        }

        let content = PanelView(
            service: UsageService(snapshot: usageSnap),
            settings: AppSettings(),
            pinState: PinState(),
            navigation: navigation,
            sessionsService: sessionsService,
            updateService: UpdateService(),
            updater: Updater(),
            onTogglePin: {}, onQuit: {},
            expandAgentId: expandId
        )
        .padding(28)                 // respiro pra ver a borda/sombra do painel
        .background(wallpaper)       // simula o desktop atras do painel
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2           // retina

        guard let nsImage = renderer.nsImage, let png = pngData(from: nsImage) else {
            fail("ImageRenderer nao produziu imagem")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            let w = Int(nsImage.size.width), h = Int(nsImage.size.height)
            print("snapshot escrito: \(path)  (\(w)x\(h) pt @2x, estado=\(state), \(appearance))")
            exit(0)
        } catch {
            fail("write falhou: \(error)")
        }
    }

    /// Renderiza a view compacta (feature D) em 4 casos lado a lado, num fundo escuro
    /// (aproxima a faixa do menu bar/notch, bem diferente do card do painel expandido).
    private static func renderCompact(appearance: String, to path: String) {
        let scheme: ColorScheme = (appearance == "light") ? .light : .dark
        let wallpaper = (appearance == "light") ? Color(white: 0.90) : Color(white: 0.10)
        let reset5h = Date().addingTimeInterval(3 * 3600)
        let reset7d = Date().addingTimeInterval(6 * 24 * 3600)

        func snap(fiveHour: Int?, sevenDay: Int?, state: UsageState) -> UsageSnapshot {
            UsageSnapshot(
                fiveHour: fiveHour.map { Gauge(utilizationPct: $0, resetsAt: reset5h) },
                sevenDay: sevenDay.map { Gauge(utilizationPct: $0, resetsAt: reset7d) },
                opus: nil, sonnet: nil, planLabel: "Max 20x", stale: nil,
                state: state, fetchedAt: Date(), account: .none, extraUsage: nil
            )
        }

        // 4 casos: verde, vermelho (pior = semanal alto), offline/stale, sem token. Os 2
        // ultimos TEM medidores no fiveHour/sevenDay mas o estado nao e .ok -- provam que
        // `compactUsageStatus` ignora o numero e cai no dot cinza (spec: nunca numero errado).
        let cases: [(String, UsageSnapshot)] = [
            ("21% verde", snap(fiveHour: 21, sevenDay: 14, state: .ok)),
            ("96% vermelho", snap(fiveHour: 41, sevenDay: 96, state: .ok)),
            ("offline/stale", snap(fiveHour: 21, sevenDay: 14, state: .offline)),
            ("sem token", snap(fiveHour: nil, sevenDay: nil, state: .noToken)),
        ]

        let content = VStack(alignment: .leading, spacing: 16) {
            ForEach(cases, id: \.0) { label, snapshot in
                HStack(spacing: 14) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 96, alignment: .leading)
                    CompactNotchUsageView(service: UsageService(snapshot: snapshot), openState: NotchOpenState())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
                }
            }
        }
        .padding(24)
        .background(wallpaper)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        guard let nsImage = renderer.nsImage, let png = pngData(from: nsImage) else {
            fail("ImageRenderer nao produziu imagem (compact)")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            let w = Int(nsImage.size.width), h = Int(nsImage.size.height)
            print("snapshot escrito: \(path)  (\(w)x\(h) pt @2x, estado=compact, \(appearance))")
            exit(0)
        } catch {
            fail("write falhou: \(error)")
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    // MARK: - Fixtures/scan real da pagina Agentes

    /// 3 sessoes fixture: uma com subagents ("+N agents"), uma com contexto ACIMA do
    /// nominal de 200K (ambiguo: barra vira so-numero, ver `contextWindow(forTokens:)`),
    /// uma simples.
    private static func fixtureAgentSessions() -> [AgentSession] {
        let now = Date()
        let comAgents = AgentSession(
            id: "11111111-1111-1111-1111-111111111111",
            project: "web-dashboard",
            projectPath: "/Users/you/Developer/web-dashboard",
            model: "claude-opus-4-8",
            contextTokens: 82_000,
            contextWindow: contextWindow(forTokens: 82_000),
            turns: 64,
            totalTokens: 4_200_000,
            costUSD: 13.51,
            agents: [
                SubagentSession(
                    id: "a101e7f8740352fab", description: "build da tela de login",
                    model: "claude-sonnet-4-5", contextTokens: 41_000, totalTokens: 620_000,
                    costUSD: 0.83, lastActivity: now.addingTimeInterval(-40)
                ),
                SubagentSession(
                    id: "a92936e7667e9a02c", description: "review de seguranca",
                    model: "claude-sonnet-4-5", contextTokens: 58_000, totalTokens: 710_000,
                    costUSD: 0.94, lastActivity: now.addingTimeInterval(-90)
                ),
            ],
            lastActivity: now.addingTimeInterval(-12),
            startedAt: now.addingTimeInterval(-2 * 3600),
            inputTokens: 8, outputTokens: 340, cacheReadTokens: 61_000, cacheCreationTokens: 21_000
        )
        let pertoDoLimite = AgentSession(
            id: "22222222-2222-2222-2222-222222222222",
            project: "payments-api",
            projectPath: "/Users/you/Developer/payments-api",
            model: "claude-sonnet-4-5",
            contextTokens: 396_000,
            contextWindow: contextWindow(forTokens: 396_000), // nil: acima de 200K, ambiguo
            turns: 210,
            totalTokens: 9_800_000,
            costUSD: 6.20,
            agents: [],
            lastActivity: now.addingTimeInterval(-200),
            startedAt: now.addingTimeInterval(-5 * 3600),
            inputTokens: 2, outputTokens: 233, cacheReadTokens: 257_425, cacheCreationTokens: 803
        )
        let simples = AgentSession(
            id: "33333333-3333-3333-3333-333333333333",
            project: "mobile-app",
            projectPath: "/Users/you/Developer/mobile-app",
            model: "claude-haiku-4-5",
            contextTokens: 12_400,
            contextWindow: contextWindow(forTokens: 12_400),
            turns: 18,
            totalTokens: 340_000,
            costUSD: 0.42,
            agents: [],
            lastActivity: now.addingTimeInterval(-340),
            startedAt: now.addingTimeInterval(-600),
            inputTokens: 4, outputTokens: 90, cacheReadTokens: 9_800, cacheCreationTokens: 2_500
        )
        return [comAgents, pertoDoLimite, simples]
    }

    /// Scan real de tiro unico (sem timer, sem actor a esperar): usa as mesmas funcoes
    /// livres do SessionScanner/SessionCostProvider, so que chamadas direto e
    /// sincronamente, ja que o modo --snapshot nao roda um RunLoop pra dar tempo de um
    /// Task assincrono terminar antes do exit().
    private static func realSessionsService() -> SessionsService {
        var states: [String: SessionFileState] = [:]
        let root = SessionScanner.defaultProjectsRoot
        let sessions: [AgentSession]
        if let data = runClaudeAgentsJSON() {
            // o app ao vivo converge via scan incremental entre ticks; aqui (tiro unico)
            // dreno ate os turnos estabilizarem pro PNG bater com a verdade.
            let running = parseRunningSessions(data)
            var drained = scanRunningSessions(running, projectsRoot: root, states: &states)
            var lastTurns = -1
            for _ in 0..<60 {
                let t = drained.reduce(0) { $0 + $1.turns }
                if t == lastTurns { break }
                lastTurns = t
                drained = scanRunningSessions(running, projectsRoot: root, states: &states)
            }
            sessions = drained
        } else {
            sessions = scanActiveSessions(projectsRoot: root, activeWindow: SessionScanner.defaultActiveWindow,
                                          states: &states)
        }
        let costs = runCcusageSessionJSON().map(parseCcusageOutput) ?? CcusageCosts()
        let spend = runCcusageDailyJSON().flatMap { parsePersonalSpend($0) }
        return SessionsService(sessions: mergeCosts(sessions: sessions, costs: costs), personalSpend: spend)
    }
}
