import Foundation

/// Dump de debug da pagina Consumo (`--debug-agents`): roda o scanner REAL de tiro unico e
/// imprime, pra CADA sessao candidata (janela larga de lookback), o veredito e POR QUE ela
/// entra ou nao na lista. Serve pra debugar "por que apareceu X / sumiu Y" na hora, sem PNG
/// e sem reproduzir a logica por fora: usa as mesmas funcoes do app, entao bate 1:1.
///
/// Uso:
///   ClaudeNotch --debug-agents                      (tabela de decisao, rapido)
///   ClaudeNotch --debug-agents --lookback-min 60    (olha 60min de mtime, nao 30)
///   ClaudeNotch --debug-agents --with-cost          (tambem roda ccusage: custo + subagents)
enum AgentsDebugDump {
    /// Imprime e chama exit() se `--debug-agents` estiver nos args. Retorna false se nao.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--debug-agents") else { return false }
        let lookback = value(of: "--lookback-min", in: args).flatMap(Double.init).map { $0 * 60 } ?? 30 * 60
        run(lookback: lookback, withCost: args.contains("--with-cost"))
        exit(0)
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }

    private static func age(_ raw: TimeInterval?) -> String {
        guard let raw else { return "-" }
        let s = max(0, raw) // clamp: skew de relogio nao deve virar "-1s"
        if s < 90 { return "\(Int(s))s" }
        if s < 5400 { return "\(Int(s / 60))min" }
        return String(format: "%.1fh", s / 3600)
    }

    private static func tildify(_ path: String?) -> String {
        guard let path else { return "?" }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func verdictLabel(_ v: SessionVerdict) -> String {
        switch v {
        case .active: return "ACTIVE"
        case .idle: return "IDLE"
        case .excludedNonCLI(let ep): return "excl:\(ep)"
        case .excludedStale: return "excl:stale"
        }
    }

    static func run(lookback: TimeInterval, withCost: Bool, now: Date = Date()) {
        let window = SessionScanner.defaultActiveWindow
        let idle = SessionScanner.defaultIdleWindow
        let root = SessionScanner.defaultProjectsRoot
        let diags = diagnoseSessions(projectsRoot: root, activeWindow: window, idleWindow: idle,
                                     lookback: lookback, now: now)
        let activeCount = diags.filter { $0.verdict == .active }.count
        let idleCount = diags.filter { $0.verdict == .idle }.count

        print("=== claude-notch --debug-agents ===")
        print("projectsRoot: \(root.path)")

        // FONTE DE VERDADE nova: claude agents --json (o que o app usa de fato).
        print("\n--- sessoes RODANDO (claude agents --json = fonte do app) ---")
        if let data = runClaudeAgentsJSON() {
            let running = parseRunningSessions(data)
            if running.isEmpty {
                print("  (nenhuma sessao interativa rodando)")
            }
            for rs in running {
                let jsonl = locateSessionJSONL(sessionId: rs.sessionId, cwd: rs.cwd, projectsRoot: root)
                let state = rs.isBusy ? "BUSY " : "idle "
                print("  \(state) \(pad(String(rs.sessionId.prefix(8)), 10)) pid \(pad("\(rs.pid)", 7)) "
                    + "\(pad(rs.name ?? "-", 18)) jsonl:\(jsonl == nil ? "NAO-ACHADO" : "ok") \(tildify(rs.cwd))")
            }
        } else {
            print("  claude agents --json indisponivel -> app cai pro fallback (jsonl por tempo, abaixo)")
        }

        print("\n--- diagnostico jsonl (fallback / comparacao por tempo) ---")
        print("janela ativa: \(Int(window / 60))min · idle: \(Int(idle / 60))min · lookback: \(Int(lookback / 60))min")
        print("candidatos: \(diags.count) · ATIVAS: \(activeCount) · ociosas: \(idleCount) · excluidas: \(diags.count - activeCount - idleCount)")
        print("")
        print(pad("VERDICT", 13) + pad("SID", 10) + pad("ENTRY", 8) + pad("MTIME", 7)
              + pad("REALTURN", 10) + pad("TURNS", 7) + pad("CTX", 8) + pad("SUB", 5)
              + pad("MODEL", 13) + "PROJETO (cwd)")
        for d in diags {
            print(pad(verdictLabel(d.verdict), 13)
                + pad(String(d.sessionId.prefix(8)), 10)
                + pad(d.entrypoint ?? "-", 8)
                + pad(age(d.mtimeAge), 7)
                + pad(age(d.realTurnAge), 10)
                + pad("\(d.turns)", 7)
                + pad(formatTokensShort(d.contextTokens), 8)
                + pad(d.subagentCount > 0 ? "+\(d.subagentCount)" : "-", 5)
                + pad(d.model.isEmpty ? "?" : shortModelName(d.model), 13)
                + tildify(d.cwd))
        }

        guard withCost else {
            print("\n(rode com --with-cost pra ver custo/subagents das ativas via ccusage)")
            return
        }

        print("\n--- custo (ccusage) das sessoes RODANDO ---")
        // usa a MESMA fonte do app (claude agents), drenando o jsonl ate os turnos
        // estabilizarem (scanRunningSessions e incremental, 2MB/arquivo por chamada).
        let running = runClaudeAgentsJSON().map(parseRunningSessions) ?? []
        var states: [String: SessionFileState] = [:]
        var sessions = scanRunningSessions(running, projectsRoot: root, states: &states, now: now)
        var lastTurns = -1
        for _ in 0..<60 {
            let t = sessions.reduce(0) { $0 + $1.turns }
            if t == lastTurns { break }
            lastTurns = t
            sessions = scanRunningSessions(running, projectsRoot: root, states: &states, now: now)
        }
        let costs = runCcusageSessionJSON().map(parseCcusageOutput) ?? CcusageCosts()
        let merged = mergeCosts(sessions: sessions, costs: costs)
        if let spend = runCcusageDailyJSON().flatMap({ parsePersonalSpend($0) }) {
            print(String(format: "gasto claude: hoje $%.2f · 7d $%.2f · mes $%.2f · lifetime $%.2f",
                         spend.today, spend.last7, spend.month, spend.lifetime))
        } else {
            print("gasto: ccusage indisponivel")
        }
        for s in merged {
            let cost = s.costUSD.map { String(format: "$%.2f", $0) } ?? "-"
            print("  \(pad(String(s.id.prefix(8)), 10)) \(pad(s.project, 16)) "
                + "\(pad(shortModelName(s.model), 12)) ctx \(pad(formatTokensShort(s.contextTokens), 7)) "
                + "turnos \(pad("\(s.turns)", 5)) custo \(cost)")
            for a in s.agents {
                let ac = a.costUSD.map { String(format: "$%.2f", $0) } ?? "-"
                print("      - \(pad(shortModelName(a.model), 12)) ctx \(pad(formatTokensShort(a.contextTokens), 7)) "
                    + "\(pad(ac, 8)) \(relativeTime(a.lastActivity, now: now))")
            }
        }
    }
}
