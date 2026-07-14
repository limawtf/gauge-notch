import Testing
import Foundation
@testable import ClaudeNotch

private func assistantLine(sessionId: String, input: Int, cacheRead: Int) -> String {
    let obj: [String: Any] = [
        "type": "assistant",
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "sessionId": sessionId,
        "message": [
            "model": "claude-opus-4-8",
            "usage": ["input_tokens": input, "cache_read_input_tokens": cacheRead,
                      "output_tokens": 0, "cache_creation_input_tokens": 0],
        ] as [String: Any],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

@Suite("Sessoes rodando (claude agents --json)")
struct RunningSessionsTests {
    @Test("parse: pega interativas, ignora nao-interativas e sem id; status vira busy/idle")
    func parsesAndFilters() {
        let json = """
        [
          {"pid": 1, "sessionId": "aaa", "cwd": "/Users/you", "name": "n1", "status": "busy", "kind": "interactive"},
          {"pid": 2, "sessionId": "bbb", "cwd": "/x", "name": "n2", "status": "idle", "kind": "interactive"},
          {"pid": 3, "sessionId": "ccc", "cwd": "/y", "kind": "interactive"},
          {"pid": 4, "sessionId": "ddd", "cwd": "/z", "kind": "worker"},
          {"pid": 5, "cwd": "/w", "kind": "interactive"}
        ]
        """
        let rs = parseRunningSessions(Data(json.utf8))
        #expect(rs.count == 3)                 // ddd (worker) e a sem sessionId ficam fora
        #expect(rs[0].isBusy == true)
        #expect(rs[1].isBusy == false)         // idle
        #expect(rs[2].isBusy == false)         // status ausente = nao-busy
        #expect(!rs.contains { $0.sessionId == "ddd" })
    }

    @Test("json invalido devolve vazio, nunca crasha")
    func invalidJSON() {
        #expect(parseRunningSessions(Data("nao e json".utf8)).isEmpty)
    }

    @Test("projectSlug: caractere nao-alfanumerico vira '-'")
    func slug() {
        #expect(projectSlug(fromCwd: "/Users/you") == "-Users-you")
        #expect(projectSlug(fromCwd: "/Users/you/Documents/Apps/claude-notch")
                == "-Users-you-Documents-Apps-claude-notch")
    }

    @Test("scanRunningSessions: status vira isActive, enriquece com jsonl, ordena busy antes")
    func buildsFromRunning() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(projectSlug(fromCwd: "/Users/you/proj"))
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data((assistantLine(sessionId: "sess-busy", input: 100, cacheRead: 20) + "\n").utf8)
            .write(to: dir.appendingPathComponent("sess-busy.jsonl"))

        let running = [
            RunningSession(pid: 1, sessionId: "sess-busy", cwd: "/Users/you/proj", name: "n", status: "busy"),
            RunningSession(pid: 2, sessionId: "sess-none", cwd: "/Users/you/other", name: "m", status: "idle"),
        ]
        var states: [String: SessionFileState] = [:]
        let sessions = scanRunningSessions(running, projectsRoot: root, states: &states)

        #expect(sessions.count == 2)
        let busy = sessions.first { $0.id == "sess-busy" }!
        #expect(busy.isActive == true)
        #expect(busy.contextTokens == 120)    // enriquecido pelo jsonl (100 + 20)
        let idle = sessions.first { $0.id == "sess-none" }!
        #expect(idle.isActive == false)        // idle
        #expect(idle.contextTokens == 0)       // aberta mas sem jsonl: entra so com o basico
        #expect(sessions[0].id == "sess-busy") // busy ordenada antes da ociosa
    }

    @Test("locateSessionJSONL: acha pelo slug do cwd e, se nao bater, pela busca do id")
    func locates() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("-algum-outro-slug")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: dir.appendingPathComponent("theid.jsonl"))

        // cwd NAO bate com o slug do arquivo -> cai pra busca pelo sessionId (unico)
        let found = locateSessionJSONL(sessionId: "theid", cwd: "/Users/you/nao-bate", projectsRoot: root)
        #expect(found?.lastPathComponent == "theid.jsonl")
        // id inexistente -> nil
        #expect(locateSessionJSONL(sessionId: "naoexiste", cwd: "/x", projectsRoot: root) == nil)
    }
}
