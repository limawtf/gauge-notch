import Foundation

/// Uma sessao interativa do Claude Code RODANDO agora, lida de `claude agents --json`.
/// Essa e a fonte OFICIAL e estavel de "quais sessoes existem e seu estado": os docs
/// avisam pra NAO parsear os arquivos internos (`~/.claude/sessions/*.json`, formato muda
/// entre versoes). So lista `kind: interactive` -> worker/sdk, fantasma e duplicata nunca
/// entram, e nao precisa de janela de tempo: `status` diz busy/idle de verdade (uma tarefa
/// longa fica `busy` mesmo sem turno novo, resolvendo o falso-ocioso).
struct RunningSession: Equatable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String?     // "busy" | "idle" | ausente (recem-iniciada)
    var isBusy: Bool { status == "busy" }
}

private struct AgentsEntry: Decodable {
    let pid: Int?
    let sessionId: String?
    let cwd: String?
    let name: String?
    let status: String?
    let kind: String?
}

/// Parse puro da saida de `claude agents --json`. Ignora entradas nao-interativas e sem id.
func parseRunningSessions(_ data: Data) -> [RunningSession] {
    guard let entries = try? JSONDecoder().decode([AgentsEntry].self, from: data) else { return [] }
    return entries.compactMap { e in
        guard let sid = e.sessionId, let pid = e.pid else { return nil }
        if let kind = e.kind, kind != "interactive" { return nil } // so terminal do usuario
        return RunningSession(pid: pid, sessionId: sid, cwd: e.cwd ?? "", name: e.name, status: e.status)
    }
}

/// Caminhos conhecidos do binario `claude` (o .app nao herda o PATH do shell), ordem de
/// tentativa; cai pro `claude` via PATH se nenhum existir.
func resolveClaudePath() -> String {
    let home = NSHomeDirectory()
    let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
    return "claude"
}

/// Roda `claude agents --json` (bloqueante, ~0.3s; so chamado de dentro do actor do scanner,
/// fora da main thread). nil se o binario nao existe ou a versao nao tem o subcomando.
func runClaudeAgentsJSON() -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [resolveClaudePath(), "agents", "--json"]
    process.environment = augmentedPATHEnvironment()
    return runProcessCapturingStdout(process, timeout: 8)
}

/// Slug de projeto do Claude Code a partir do cwd: caractere nao-alfanumerico (ASCII) vira
/// "-" (ex.: "/Users/you" -> "-Users-you"). So um FAST-PATH pra achar o jsonl; se nao
/// bater, `locateSessionJSONL` cai pra busca pelo sessionId (que e unico).
private let projectSlugAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

func projectSlug(fromCwd cwd: String) -> String {
    return String(cwd.map { projectSlugAllowed.contains($0) ? $0 : "-" })
}

/// Acha o `<sessionId>.jsonl` de uma sessao: 1o tenta o slug derivado do cwd, senao busca
/// em todos os projetos (o sessionId e unico). nil se nao existir em disco ainda.
func locateSessionJSONL(sessionId: String, cwd: String, projectsRoot: URL) -> URL? {
    let fm = FileManager.default
    let direct = projectsRoot
        .appendingPathComponent(projectSlug(fromCwd: cwd))
        .appendingPathComponent("\(sessionId).jsonl")
    if fm.fileExists(atPath: direct.path) { return direct }

    guard let dirs = try? fm.contentsOfDirectory(
        at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return nil }
    for dir in dirs {
        let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}
