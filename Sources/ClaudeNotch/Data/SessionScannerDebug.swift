import Foundation

/// Diagnostico de UMA sessao candidata, pro dump de debug (`--debug-agents`): o que o
/// scanner ve e por que decide incluir ou nao. Usa as MESMAS funcoes livres do scan real
/// (updateFileState + classifySession + scanSubagents), entao bate 1:1 com o que a pagina
/// Consumo mostra, sem reproduzir a logica por fora (que foi o que deu drift ao debugar
/// com Python durante o desenvolvimento).
struct SessionDiagnostic {
    let sessionId: String
    let projectSlug: String
    let cwd: String?
    let entrypoint: String?
    let mtimeAge: TimeInterval          // ha quanto o arquivo foi tocado (qualquer evento)
    let realTurnAge: TimeInterval?      // ha quanto foi o ultimo turno assistant REAL (nil = nunca)
    let verdict: SessionVerdict
    let turns: Int
    let totalTokens: Int
    let contextTokens: Int
    let model: String
    let subagentCount: Int
}

/// Varre TODAS as sessoes tocadas nos ultimos `lookback` segundos (janela LARGA de
/// proposito, pra aparecerem tambem as que o scan de producao pre-filtra por mtime) e
/// classifica cada uma com a MESMA regra da producao (`classifySession`). Estado fresco a
/// cada arquivo (nao incremental): e' um retrato de tiro unico, so pra debug.
func diagnoseSessions(
    projectsRoot: URL,
    activeWindow: TimeInterval,
    idleWindow: TimeInterval,
    lookback: TimeInterval,
    now: Date = Date()
) -> [SessionDiagnostic] {
    let fm = FileManager.default
    guard let projectDirs = try? fm.contentsOfDirectory(
        at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else { return [] }

    var result: [SessionDiagnostic] = []
    for projectDir in projectDirs {
        guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { continue }

        for entry in entries where entry.pathExtension == "jsonl" {
            guard !entry.lastPathComponent.hasPrefix("agent-") else { continue }
            guard let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            let mtimeAge = now.timeIntervalSince(mtime)
            guard mtimeAge <= lookback else { continue }

            // DRENA o arquivo inteiro (nao um tiro so de 2MB como o scan ao vivo): o debug
            // quer a VERDADE. Num arquivo grande, o ultimo turno real fica no MEIO, que o
            // previewTail (64KB do fim) + 1o chunk de 2MB do inicio nao alcancam num tiro so
            // -- isso daria um realTurn falso-velho aqui.
            let state = SessionFileState()
            while true {
                let prev = state.offset
                updateFileState(state, atPath: entry.path)
                if state.offset <= prev { break } // chegou ao fim do arquivo
            }

            let activityTs = state.lastRealTurnTimestamp ?? state.lastTimestamp
            let verdict = classifySession(
                entrypoint: state.entrypoint, activityTs: activityTs, now: now,
                activeWindow: activeWindow, idleWindow: idleWindow
            )

            let sessionId = entry.deletingPathExtension().lastPathComponent
            let subagentsDir = projectDir.appendingPathComponent(sessionId).appendingPathComponent("subagents")
            var subStates: [String: SessionFileState] = [:]
            let subs = scanSubagents(
                under: subagentsDir, parentSessionId: sessionId, activeWindow: activeWindow, now: now, states: &subStates
            )

            result.append(SessionDiagnostic(
                sessionId: sessionId,
                projectSlug: projectDir.lastPathComponent,
                cwd: state.cwd,
                entrypoint: state.entrypoint,
                mtimeAge: mtimeAge,
                realTurnAge: state.lastRealTurnTimestamp.map { now.timeIntervalSince($0) },
                verdict: verdict,
                turns: state.turns,
                totalTokens: state.totalTokens,
                contextTokens: state.lastUsage.contextTokens,
                model: state.model,
                subagentCount: subs.count
            ))
        }
    }

    // ativas, depois ociosas, depois excluidas; dentro de cada, mais recente em cima.
    func rank(_ v: SessionVerdict) -> Int {
        switch v {
        case .active: return 0
        case .idle: return 1
        default: return 2
        }
    }
    return result.sorted {
        rank($0.verdict) != rank($1.verdict) ? rank($0.verdict) < rank($1.verdict) : $0.mtimeAge < $1.mtimeAge
    }
}
